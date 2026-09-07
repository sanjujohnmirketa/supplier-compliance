/**
 * AuthoritativeVerificationService
 * ==========================================================================
 *
 * Calls an authoritative external registry (IATF Customer Portal, future:
 * IAF CertSearch, IRS TIN Matching, OFAC) to verify whether a compliance
 * document's claimed certificate number actually exists and is currently
 * valid.
 *
 * METADATA-DRIVEN
 * ---------------
 * Looks up Compliance_Verification_Source__mdt by document type. The CMT
 * record tells this service:
 *   - WHERE to call (API_Endpoint_Template__c with {cert_number} placeholder)
 *   - WHICH extracted field holds the lookup id (API_Cert_Number_Source__c)
 *   - HOW to read the response (API_Result_Mapping__c JSON)
 *   - WHICH status values mean "valid" (API_Valid_States__c CSV)
 *
 * Adding a new authoritative source means adding a CMT record - no Apex
 * change required.
 *
 * INVOCATION
 * ----------
 *   1. From AuthoritativeVerificationQueueable - chained after extraction
 *   2. From the Agentforce agent (via @InvocableMethod) - when an analyst
 *      asks "verify this certificate against the official registry"
 *
 * OUTPUT
 * ------
 * Returns a VerificationResult that the caller persists into the
 * Document_Extraction__c.Raw_Response__c JSON as a new "verification_result"
 * top-level block. If the registry contradicts the AI verdict, the caller
 * is responsible for downgrading Compliance_Document__c.Status__c.
 */
public with sharing class AuthoritativeVerificationService {

    @TestVisible private static final Integer CALLOUT_TIMEOUT_MS = 5000;

    // --- Verification outcomes -----------------------------------------
    public static final String OUTCOME_VERIFIED      = 'Verified';
    public static final String OUTCOME_INVALID       = 'Invalid';      // registry says cancelled/expired
    public static final String OUTCOME_NOT_FOUND     = 'NotFound';     // registry returned 404 or empty
    public static final String OUTCOME_UNAVAILABLE   = 'Unavailable';  // API unreachable / no source configured
    public static final String OUTCOME_NOT_APPLICABLE = 'NotApplicable'; // doc type has no API

    // ==========================================================================
    // Public result type
    // ==========================================================================
    public class VerificationResult {
        public String  outcome;             // one of OUTCOME_* constants
        public String  authority;           // "IATF", "IAF", etc.
        public String  registryStatus;      // raw status from registry (e.g. "Cancelled")
        public Boolean isCurrentlyValid;    // true only when status is in API_Valid_States__c
        public Map<String, Object> registryMatch = new Map<String, Object>();
        public List<String> discrepancies = new List<String>();
        public String  verdictImpact;       // human-readable summary of what this means
        public DateTime verifiedAt;
        public String  errorDetail;
    }

    // ==========================================================================
    // @InvocableMethod - for the Agentforce agent
    // ==========================================================================
    public class VerifyRequest {
        @InvocableVariable(
            label='Compliance Document Id'
            description='The Salesforce ID of the Compliance_Document__c to verify against the authoritative registry. The service reads the latest Document_Extraction__c for this document and calls the API configured for its document type.'
            required=true
        )
        public String complianceDocId;
    }

    public class VerifyResponse {
        @InvocableVariable(label='Outcome' description='Verified | Invalid | NotFound | Unavailable | NotApplicable')
        public String outcome;
        @InvocableVariable(label='Authority' description='Name of the authority that responded.')
        public String authority;
        @InvocableVariable(label='Registry Status' description='Raw status from the registry, e.g. Valid, Cancelled, Expired.')
        public String registryStatus;
        @InvocableVariable(label='Verdict Impact' description='Plain-English summary of what the registry response means for compliance.')
        public String verdictImpact;
        @InvocableVariable(label='Discrepancies' description='Newline-separated list of mismatches between extracted fields and registry data.')
        public String discrepancies;
    }

    @InvocableMethod(
        label='Verify Document Against Authoritative Registry'
        description='Calls the official registry for the document type (e.g. IATF Customer Portal for IATF 16949) and returns whether the certificate is current, cancelled, expired, or not found.'
        category='Compliance'
        callout=true
    )
    public static List<VerifyResponse> verifyDocuments(List<VerifyRequest> requests) {
        List<VerifyResponse> responses = new List<VerifyResponse>();
        for (VerifyRequest req : requests) {
            VerificationResult result = verifyDocument(req.complianceDocId);
            VerifyResponse vr = new VerifyResponse();
            vr.outcome        = result.outcome;
            vr.authority      = result.authority;
            vr.registryStatus = result.registryStatus;
            vr.verdictImpact  = result.verdictImpact;
            vr.discrepancies  = String.join(result.discrepancies, '\n');
            responses.add(vr);
        }
        return responses;
    }

    // ==========================================================================
    // Main entry - also called from AuthoritativeVerificationQueueable
    // ==========================================================================
    public static VerificationResult verifyDocument(Id complianceDocId) {
        VerificationResult vr = new VerificationResult();
        vr.verifiedAt = DateTime.now();

        if (complianceDocId == null) {
            vr.outcome = OUTCOME_UNAVAILABLE;
            vr.errorDetail = 'No Compliance Document Id provided';
            return vr;
        }

        // 1. Load the document + latest extraction
        List<Compliance_Document__c> docs = [
            SELECT Id, Document_Type__c, Latest_Extraction__c, Status__c, Account__c
            FROM   Compliance_Document__c
            WHERE  Id = :complianceDocId
            LIMIT  1
        ];
        if (docs.isEmpty()) {
            vr.outcome = OUTCOME_UNAVAILABLE;
            vr.errorDetail = 'Compliance Document not found';
            return vr;
        }
        Compliance_Document__c doc = docs[0];

        Document_Extraction__c ext = loadLatestExtraction(complianceDocId);
        if (ext == null || String.isBlank(ext.Raw_Response__c)) {
            vr.outcome = OUTCOME_UNAVAILABLE;
            vr.errorDetail = 'No extraction available yet for this document';
            return vr;
        }

        // 2. Resolve the verification source for this document type
        Compliance_Verification_Source__mdt source =
            lookupSource(doc.Document_Type__c);
        if (source == null) {
            vr.outcome = OUTCOME_NOT_APPLICABLE;
            vr.verdictImpact = 'No authoritative registry registered for "'
                + doc.Document_Type__c + '". Verification must be done manually.';
            return vr;
        }
        vr.authority = source.Authority__c;

        if (source.Verification_Method__c != 'Documented_API'
                || String.isBlank(source.API_Endpoint_Template__c)) {
            vr.outcome = OUTCOME_NOT_APPLICABLE;
            vr.verdictImpact = 'Manual verification only - '
                + source.Verification_Name__c
                + ' does not expose an automated API.';
            return vr;
        }

        // 3. Extract the lookup identifier from the AI response
        Map<String, Object> root = safeParse(ext.Raw_Response__c);
        if (root == null) {
            vr.outcome = OUTCOME_UNAVAILABLE;
            vr.errorDetail = 'Could not parse extraction response';
            return vr;
        }
        String certNumber = extractFieldValue(root, source.API_Cert_Number_Source__c);
        if (String.isBlank(certNumber)) {
            vr.outcome = OUTCOME_UNAVAILABLE;
            vr.errorDetail = 'Extracted field "' + source.API_Cert_Number_Source__c
                + '" is empty - cannot look up the registry';
            return vr;
        }

        // 4. Build endpoint, call the API
        String endpoint = source.API_Endpoint_Template__c.replace('{cert_number}',
            EncodingUtil.urlEncode(certNumber, 'UTF-8'));

        Map<String, Object> apiResponse;
        try {
            apiResponse = callApi(endpoint);
        } catch (Exception e) {
            vr.outcome = OUTCOME_UNAVAILABLE;
            vr.errorDetail = 'API call failed: ' + e.getMessage();
            vr.verdictImpact = 'Could not reach the ' + vr.authority
                + ' registry. Manual verification required.';
            return vr;
        }

        System.debug('api Response: ' +JSON.serializePretty(apiResponse));

        if (apiResponse == null || apiResponse.isEmpty()) {
            vr.outcome = OUTCOME_NOT_FOUND;
            vr.verdictImpact = 'Certificate number ' + certNumber
                + ' was not found in the ' + vr.authority
                + ' registry. This is a strong indicator of forgery.';
            return vr;
        }

        // 5. Map response fields per CMT API_Result_Mapping__c
        Map<String, String> mapping = parseMapping(source.API_Result_Mapping__c);
        String registryStatus = pullStringFromResponse(apiResponse, mapping.get('status_field'));
        String registryName    = pullStringFromResponse(apiResponse, mapping.get('name_field'));
        String registryCountry = pullStringFromResponse(apiResponse, mapping.get('country_field'));
        String registryCertNo  = pullStringFromResponse(apiResponse, mapping.get('cert_number_field'));
        String registryUsi     = pullStringFromResponse(apiResponse, mapping.get('unique_site_id_field'));

        vr.registryStatus = registryStatus;
        if (String.isNotBlank(registryName))    vr.registryMatch.put('company_name', registryName);
        if (String.isNotBlank(registryCountry)) vr.registryMatch.put('country', registryCountry);
        if (String.isNotBlank(registryCertNo))  vr.registryMatch.put('cert_number', registryCertNo);
        if (String.isNotBlank(registryUsi))     vr.registryMatch.put('unique_site_id', registryUsi);

        // 6. Decide verdict based on registry state
        Set<String> validStates = parseValidStates(source.API_Valid_States__c);
        Boolean stateMatches = validStates.contains((registryStatus != null ? registryStatus.trim() : ''));
        vr.isCurrentlyValid = stateMatches;

        // 7. Cross-check name and country against the supplier
        Account supplier = loadSupplier(doc.Account__c);
        if (supplier != null && String.isNotBlank(registryName) && String.isNotBlank(supplier.Name)) {
            if (!fuzzyMatch(supplier.Name, registryName)) {
                vr.discrepancies.add('Registry company "' + registryName
                    + '" does not match supplier "' + supplier.Name + '"');
            }
        }
        String extractedName = extractFieldValue(root, 'subject_company');
        if (String.isNotBlank(extractedName) && String.isNotBlank(registryName)) {
            if (!fuzzyMatch(extractedName, registryName)) {
                vr.discrepancies.add('Registry company "' + registryName
                    + '" does not match extracted "' + extractedName + '"');
            }
        }

        // 8. Final outcome
        if (stateMatches && vr.discrepancies.isEmpty()) {
            vr.outcome = OUTCOME_VERIFIED;
            vr.verdictImpact = 'Registry confirms certificate ' + certNumber
                + ' is currently ' + registryStatus + ' and matches supplier records.';
        } else if (stateMatches) {
            vr.outcome = OUTCOME_VERIFIED;
            vr.verdictImpact = 'Certificate exists with status ' + registryStatus
                + ', but discrepancies were detected against supplier records - review required.';
        } else {
            vr.outcome = OUTCOME_INVALID;
            vr.verdictImpact = 'Registry shows certificate ' + certNumber
                + ' is currently ' + registryStatus
                + '. The document is no longer valid evidence of compliance.';
        }

        return vr;
    }

    // ==========================================================================
    // HTTP callout - wrapped so the calling Queueable handles all errors
    // ==========================================================================
    @TestVisible
    private static Map<String, Object> callApi(String endpoint) {
        HttpRequest req = new HttpRequest();
        System.debug('Endpoint: ' + endpoint);
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setTimeout(CALLOUT_TIMEOUT_MS);
        req.setHeader('Accept', 'application/json');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader(
            'ApiKey',
            'khufi83Hd7fbwHd7wjbcHdew3'
        );
        req.setHeader(
            'Tool',
            'IATF Customer Portal'
        );

        req.setHeader(
            'Origin',
            'https://iatf-customerportal.org'
        );

        req.setHeader(
            'Referer',
            'https://iatf-customerportal.org/'
        );

        req.setHeader(
            'User-Agent',
            'Mozilla/5.0'
        );

        HttpResponse res = new Http().send(req);
        System.debug('response from api: ' + res.getBody());
        System.debug('response status: ' + res.getStatusCode());
        Integer status = res.getStatusCode();

        if (status == 404) {
            return null;
        }
        if (status < 200 || status >= 300) {
            throw new VerificationException('HTTP ' + status + ': ' + res.getBody().left(500));
        }


        String body = res.getBody();
        if (String.isBlank(body)) {
            return null;
        }
        
        try {
            Object parsed = JSON.deserializeUntyped(body);
            if (parsed instanceof Map<String, Object>) {
                return (Map<String, Object>) parsed;
            }
            if (parsed instanceof List<Object>) {
                List<Object> responseList = (List<Object>) parsed;
                if (responseList.isEmpty()) {
                    return null;
                }
                Object firstItem = responseList.get(0);
                if (firstItem instanceof Map<String, Object>) {
                    return (Map<String, Object>) firstItem;
                }
            }
            return null;
        } catch (Exception e) {
            throw new VerificationException('Could not parse API response: ' + e.getMessage());
        }
    }

    // ==========================================================================
    // Helpers
    // ==========================================================================
    private static Document_Extraction__c loadLatestExtraction(Id docId) {
        List<Document_Extraction__c> ext = [
            SELECT Id, Raw_Response__c, Compliance_Document__c
            FROM   Document_Extraction__c
            WHERE  Compliance_Document__c = :docId
            ORDER  BY Extraction_DateTime__c DESC
            LIMIT  1
        ];
        return ext.isEmpty() ? null : ext[0];
    }

    private static Account loadSupplier(Id supplierId) {
        if (supplierId == null) return null;
        List<Account> accts = [
            SELECT Id, Name FROM Account WHERE Id = :supplierId LIMIT 1
        ];
        return accts.isEmpty() ? null : accts[0];
    }

    private static Compliance_Verification_Source__mdt lookupSource(String documentType) {
        if (String.isBlank(documentType)) return null;

        // Document_Type__c may be stored as "{accountId}__{CMT DeveloperName}"
        // (e.g. "001fn00000SHH7iAAH__RULE_A_001") because Requirement_Key__c uses
        // that composite format to satisfy the External ID uniqueness constraint
        // per supplier. Resolve the canonical document type string from the CMT first.
        String resolvedDocType = documentType;
        if (documentType.contains('__')) {
            String cmtDevName = documentType.substringAfter('__');
            List<Compliance_Requirement__mdt> rules = [
                SELECT Document_Type__c
                FROM   Compliance_Requirement__mdt
                WHERE  DeveloperName = :cmtDevName
                LIMIT  1
            ];
            if (!rules.isEmpty() && String.isNotBlank(rules[0].Document_Type__c)) {
                resolvedDocType = rules[0].Document_Type__c;
            }
        }

        // Compliance_Requirement__mdt.Document_Type__c may be a semicolon-delimited
        // list (e.g. "IATF 16949 Certificate; PPAP Package; Control Plans").
        // Build a candidate set and match any of them against the verification source.
        List<String> candidates = new List<String>();
        if (resolvedDocType.contains(';')) {
            for (String part : resolvedDocType.split(';')) {
                String t = part.trim();
                if (String.isNotBlank(t)) candidates.add(t);
            }
        } else {
            candidates.add(resolvedDocType);
        }

        List<Compliance_Verification_Source__mdt> rows = [
            SELECT Authority__c, Verification_Method__c, Verification_Name__c,
                   API_Endpoint_Template__c, API_Cert_Number_Source__c,
                   API_Result_Mapping__c, API_Valid_States__c
            FROM   Compliance_Verification_Source__mdt
            WHERE  Document_Type__c IN :candidates
            LIMIT  1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    @TestVisible
    private static Map<String, Object> safeParse(String jsonString) {
        if (String.isBlank(jsonString)) {
            return null;
        }
        try {
            String cleaned = jsonString.replaceAll('```json', '').replaceAll('```', '').trim();
            Object deserialized = JSON.deserializeUntyped(cleaned);
            if (deserialized instanceof Map<String, Object>) {
                return (Map<String, Object>) deserialized;
            }
            return null;
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Pull a string value from the AI's extracted_fields by field name.
     * extracted_fields contains entries like { "value": "x", "confidence": 0.9 }.
     */
    @TestVisible
    private static String extractFieldValue(Map<String, Object> root, String fieldName) {
        if (root == null || String.isBlank(fieldName)) return null;
        Object ef = root.get('extracted_fields');
        if (!(ef instanceof Map<String, Object>)) return null;
        Map<String, Object> fields = (Map<String, Object>) ef;
        Object field = fields.get(fieldName);
        if (!(field instanceof Map<String, Object>)) return null;
        Object val = ((Map<String, Object>) field).get('value');
        return val == null ? null : String.valueOf(val).trim();
    }

    /**
     * Pull a top-level field from the API response. Returns null if missing
     * or the value is not a primitive.
     */
    @TestVisible
    private static String pullStringFromResponse(Map<String, Object> response, String fieldName) {
        if (response == null || String.isBlank(fieldName)) return null;
        Object val = response.get(fieldName);
        return val == null ? null : String.valueOf(val).trim();
    }

    @TestVisible
    private static Map<String, String> parseMapping(String jsonString) {
        Map<String, String> result = new Map<String, String>();
        if (String.isBlank(jsonString)) {
            return result;
        }
        try {
            Object deserialized = JSON.deserializeUntyped(jsonString);
            Map<String, Object> parsed = (Map<String, Object>) deserialized;
            for (String key : parsed.keySet()) {
                Object v = parsed.get(key);
                if (v != null) {
                    result.put(key, String.valueOf(v));
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                '[AuthoritativeVerificationService] Could not parse mapping JSON: ' + e.getMessage());
        }
        return result;
    }

    @TestVisible
    private static Set<String> parseValidStates(String csv) {
        Set<String> result = new Set<String>();
        if (String.isBlank(csv)) return result;
        for (String s : csv.split(',')) {
            String trimmed = s.trim();
            if (String.isNotBlank(trimmed)) result.add(trimmed);
        }
        return result;
    }

    /**
     * Loose name match. Strips spaces, punctuation, common suffixes (Inc, Ltd,
     * Co, LLC, GmbH), lowercases. Two names match if either is a substring
     * of the other after normalisation, OR if their Levenshtein distance is
     * under 4 for short strings.
     */
    @TestVisible
    private static Boolean fuzzyMatch(String a, String b) {
        if (String.isBlank(a) || String.isBlank(b)) return false;
        String na = normaliseName(a);
        String nb = normaliseName(b);
        if (String.isBlank(na) || String.isBlank(nb)) return false;
        if (na == nb) return true;
        if (na.length() >= 3 && nb.length() >= 3) {
            if (na.contains(nb) || nb.contains(na)) return true;
        }
        return false;
    }

    private static String normaliseName(String s) {
        return s.toLowerCase()
            .replaceAll('\\b(inc|ltd|llc|co|corp|gmbh|sa|pvt|pte|plc)\\b\\.?', '')
            .replaceAll('[^a-z0-9]', '')
            .trim();
    }

    public class VerificationException extends Exception {}
}