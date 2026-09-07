/**
 * DocumentValidatorService
 * ═══════════════════════════════════════════════════════════════════════════
 * Apex Action for the Document Validator Agentforce topic.
 *
 * ROLE
 * ────
 * After AIExtractionQueueable produces a Document_Extraction__c, this service
 * decides whether the extraction can be trusted. It goes beyond a confidence
 * threshold — it cross-checks the extracted data against:
 *   - the Compliance_Requirement__mdt rule the document was uploaded for
 *   - the supplier's Account record (name match, country match)
 *   - business rules (issue < expiry, expiry not absurdly far in future)
 *   - issuer accreditation (when known issuer list is configured)
 *
 * Output is a structured verdict the agent can return to a human OR the
 * background pipeline can use to update records.
 *
 * INVOCATION
 * ──────────
 * 1. From the Agentforce agent topic (genAiPluginFunction) — when a
 *    compliance analyst asks "Validate the latest document for Acme"
 * 2. From AIExtractionQueueable chain — called automatically after each
 *    extraction completes, in the same Queueable execution context
 *
 * AGENT-FRIENDLY DESIGN
 * ─────────────────────
 * Every @InvocableVariable has a `description` attribute. This is what
 * the LLM reads to know what each field means. Bad descriptions = bad
 * routing decisions by the agent. Descriptions are written in plain English,
 * not internal jargon.
 */
public with sharing class DocumentValidatorService {

    // ── Configuration ────────────────────────────────────────────────────────
    @TestVisible private static final String  AI_ENDPOINT = 'callout:Azure_OpenAI_GPT4o';
    @TestVisible private static final Integer AI_MAX_TOKENS = 1500;
    @TestVisible private static final Integer CALLOUT_TIMEOUT_MS = 60000;

    // Verdict constants — used by both the agent and the Queueable
    public static final String VERDICT_VALID      = 'Valid';
    public static final String VERDICT_INVALID    = 'Invalid';
    public static final String VERDICT_NEEDS_HITL = 'Needs Human Review';

    // ═════════════════════════════════════════════════════════════════════════
    // Input wrapper
    // ═════════════════════════════════════════════════════════════════════════
    public class ValidateRequest {
        @InvocableVariable(
            label='Compliance Document Id'
            description='The Salesforce ID of the Compliance_Document__c record to validate. If you do not have an ID, leave this blank and provide Supplier Name (and optionally Document Type) instead — the action will look up the document.'
            required=false
        )
        public String complianceDocId;

        @InvocableVariable(
            label='Supplier Name'
            description='Optional alternative to Compliance Document Id. If provided, the action looks up the supplier and finds their latest matching document. Use this when the user gives a supplier name like "Acme" or "vv" instead of a document ID.'
        )
        public String supplierName;

        @InvocableVariable(
            label='Document Type'
            description='Optional — only used together with Supplier Name. Narrows the document lookup to a specific type (e.g. "ISO 9001", "Certificate of Insurance", "IATF 16949"). If multiple documents of this type exist, the most recently created one is validated.'
        )
        public String documentType;

        @InvocableVariable(
            label='Persist Result'
            description='Whether to write the validation verdict back to the Compliance_Document__c record. Set to false to do a dry-run analysis without changing data.'
        )
        public Boolean persistResult = true;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Output wrapper — every field has a description for the agent
    // ═════════════════════════════════════════════════════════════════════════
    public class ValidateResponse {
        @InvocableVariable(
            label='Verdict'
            description='The final validation verdict. One of: Valid, Invalid, Needs Human Review. "Valid" means the document can be trusted as evidence of compliance. "Invalid" means it should be rejected and re-uploaded. "Needs Human Review" means an analyst must look at it.'
        )
        public String verdict;

        @InvocableVariable(
            label='Confidence'
            description='The confidence score of the underlying extraction, between 0.0 and 1.0. Higher is better.'
        )
        public Decimal confidence;

        @InvocableVariable(
            label='Reasoning'
            description='Human-readable explanation of why this verdict was reached. Suitable for displaying to a compliance analyst or supplier.'
        )
        public String reasoning;

        @InvocableVariable(
            label='Issues Found'
            description='Comma-separated list of specific issues detected during validation. Empty if verdict is Valid.'
        )
        public String issuesFound;

        @InvocableVariable(
            label='Document Type Detected'
            description='The document type the AI identified from the file content. May differ from what the supplier claimed it was.'
        )
        public String documentTypeDetected;

        @InvocableVariable(
            label='Expiry Date'
            description='The expiry date extracted from the document, in YYYY-MM-DD format. Empty if not found or not applicable.'
        )
        public String expiryDate;

        @InvocableVariable(
            label='Issuer'
            description='The issuing organisation or certification body named on the document.'
        )
        public String issuer;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // @InvocableMethod — entry point for both the agent and the Queueable
    // ═════════════════════════════════════════════════════════════════════════
    @InvocableMethod(
        label='Validate Compliance Document'
        description='Analyses an extracted compliance document to determine if it can be trusted as evidence. Checks document type matches expectation, dates are coherent, issuer is plausible, and company name aligns with the supplier. Returns a verdict (Valid / Invalid / Needs Human Review) with reasoning.'
        category='Compliance'
        callout=true
    )
    public static List<ValidateResponse> validateDocument(List<ValidateRequest> requests) {
        List<ValidateResponse> results = new List<ValidateResponse>();

        for (ValidateRequest req : requests) {
            results.add(validateOne(req));
        }
        return results;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Single-document validation
    // ═════════════════════════════════════════════════════════════════════════
    private static ValidateResponse validateOne(ValidateRequest req) {
        ValidateResponse resp = new ValidateResponse();

        try {
            // ── 0. Resolve document ID if only supplier name was provided ──
            // If the agent passed a Document ID, we use it directly.
            // If the agent passed only a Supplier Name (+ optional Doc Type),
            // we look up the latest matching document for that supplier.
            // If the lookup returns multiple suppliers or no documents,
            // we return an informative message asking the user to clarify.
            if (String.isBlank(req.complianceDocId)
                    && String.isNotBlank(req.supplierName)) {
                String resolved = lookupDocumentBySupplier(
                    req.supplierName, req.documentType);
                if (resolved == null) {
                    return failResponse(resp, lastLookupMessage);
                }
                req.complianceDocId = resolved;
            }

            if (String.isBlank(req.complianceDocId)) {
                return failResponse(resp,
                    'No Compliance Document Id or Supplier Name was provided. '
                    + 'Provide either a document ID directly, or a supplier name '
                    + '(plus optionally a document type).');
            }

            // ── 1. Load the document + extraction + related records ───────
            Compliance_Document__c compDoc = loadDocument(req.complianceDocId);
            if (compDoc == null) {
                return failResponse(resp, 'Compliance document not found: ' + req.complianceDocId);
            }

            Document_Extraction__c extraction = loadLatestExtraction(req.complianceDocId);
            if (extraction == null) {
                return failResponse(resp, 'No extraction has run yet for this document');
            }

            Account supplier = loadSupplier(compDoc.Account__c);
            Compliance_Requirement__mdt rule = lookupRule(compDoc.Document_Type__c);

            // ── 2. Build the validator prompt ──────────────────────────────
            String prompt = buildValidationPrompt(compDoc, extraction, supplier, rule);

            // ── 3. Call the LLM for reasoning ──────────────────────────────
            ValidationLLMResult llmResult = callValidatorLLM(prompt);

            // ── 4. Populate response from LLM result + extraction data ─────
            resp.verdict             = llmResult.verdict;
            resp.confidence          = extraction.Overall_Confidence__c;
            resp.reasoning           = llmResult.reasoning;
            resp.issuesFound         = String.join(llmResult.issues, '; ');
            resp.documentTypeDetected = llmResult.documentTypeDetected;
            resp.expiryDate          = llmResult.expiryDate;
            resp.issuer              = llmResult.issuer;

            // ── 5. Persist if requested (default true) ────────────────────
            if (req.persistResult == null || req.persistResult) {
                persistVerdict(compDoc.Id, resp, llmResult);
            }

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                '[DocumentValidatorService] ' + e.getMessage()
                + '\n' + e.getStackTraceString());
            resp.verdict = VERDICT_NEEDS_HITL;
            resp.reasoning = 'Validation could not complete due to a technical error: '
                + e.getMessage() + '. A human reviewer should examine this document.';
        }

        return resp;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Prompt construction
    // ═════════════════════════════════════════════════════════════════════════
    @TestVisible
    private static String buildValidationPrompt(
        Compliance_Document__c compDoc,
        Document_Extraction__c extraction,
        Account supplier,
        Compliance_Requirement__mdt rule
    ) {
        String supplierName = supplier != null ? supplier.Name : 'unknown';
        String supplierCountry = supplier != null && supplier.BillingCountry != null
            ? supplier.BillingCountry : 'unknown';
        String expectedDocType = rule != null
            ? (rule.Document_Type__c + ' (rule ' + rule.Label + ')')
            : compDoc.Document_Type__c;
        String severity = rule != null ? rule.Severity_on_Failure__c : 'Unknown';

        return String.join(new List<String>{
            'You are a compliance document validator for US manufacturing supply chains.',
            '',
            'TASK',
            'Decide whether the document described below is a valid piece of compliance evidence.',
            'You are NOT extracting fields — that has already been done. You are auditing the extraction.',
            '',
            'EXPECTED DOCUMENT',
            'The supplier was asked to upload: ' + expectedDocType,
            'Failure severity: ' + severity,
            '',
            'SUPPLIER CONTEXT',
            'Supplier name: ' + supplierName,
            'Supplier country: ' + supplierCountry,
            '',
            'EXTRACTED FIELDS (what the previous AI step pulled from the file)',
            (extraction.Extracted_Fields__c != null
                ? extraction.Extracted_Fields__c.left(8000)
                : '{}'),
            '',
            'EXTRACTION CONFIDENCE: ' + extraction.Overall_Confidence__c,
            '',
            'VALIDATION CHECKS to perform — apply ALL of these',
            '  1. Does the extracted document_type match the expected document type? '
                + 'If the supplier uploaded a W-9 when an ISO 9001 cert was expected, flag Invalid.',
            '  2. Does the extracted company name align with the supplier name "' + supplierName + '"? '
                + 'Allow for minor variations (Inc./Ltd./Co.). Big mismatch = Invalid.',
            '  3. Is the expiry date in the future and not unreasonably far out (more than 5 years)?',
            '  4. Is the issue date before the expiry date?',
            '  5. Is the issuer a recognised certification body or authority for this document type? '
                + 'ISO certs: BSI, DNV, TÜV, SGS, Lloyd\'s Register, Bureau Veritas, NQA, NSF.',
            '  6. Are all required fields present and not null?',
            '  7. Overall extraction confidence below 0.65 = Needs Human Review regardless of other checks.',
            '',
            'OUTPUT — return ONLY a JSON object with no markdown fences:',
            '{',
            '  "verdict": "Valid" | "Invalid" | "Needs Human Review",',
            '  "reasoning": "2-3 sentence explanation of the verdict",',
            '  "issues": ["specific issue 1", "specific issue 2"],',
            '  "document_type_detected": "what the extraction said it was",',
            '  "expiry_date": "YYYY-MM-DD or null",',
            '  "issuer": "issuing organisation name or null"',
            '}',
            '',
            'DECISION RULES',
            '  - Valid: all checks pass with no concerns',
            '  - Invalid: wrong document, wrong company, expired, dates incoherent — and the issue is unambiguous',
            '  - Needs Human Review: ambiguous match, low confidence, edge cases'
        }, '\n');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // LLM callout for validation reasoning
    // ═════════════════════════════════════════════════════════════════════════
    @TestVisible
    private static ValidationLLMResult callValidatorLLM(String prompt) {
        Map<String, Object> body = new Map<String, Object>{
            'max_tokens'  => AI_MAX_TOKENS,
            'temperature' => 0.0,
            'messages'    => new List<Object>{
                new Map<String, Object>{
                    'role'    => 'system',
                    'content' => 'You are a compliance validation agent. Return only valid JSON.'
                },
                new Map<String, Object>{
                    'role'    => 'user',
                    'content' => prompt
                }
            }
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(AI_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(CALLOUT_TIMEOUT_MS);
        req.setBody(JSON.serialize(body));

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new ValidatorException('LLM HTTP ' + res.getStatusCode()
                + ': ' + res.getBody().left(500));
        }

        Map<String, Object> parsed =
            (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> choices = (List<Object>) parsed.get('choices');
        Map<String, Object> message = (Map<String, Object>) ((Map<String, Object>) choices[0]).get('message');
        String content = (String) message.get('content');

        // Strip markdown fences if present
        String cleaned = content.replaceAll('```json', '').replaceAll('```', '').trim();
        Map<String, Object> verdictJson = (Map<String, Object>) JSON.deserializeUntyped(cleaned);

        ValidationLLMResult result = new ValidationLLMResult();
        result.verdict              = (String) verdictJson.get('verdict');
        result.reasoning            = toStringValue(verdictJson.get('reasoning'));
        result.documentTypeDetected = (String) verdictJson.get('document_type_detected');
        result.expiryDate           = (String) verdictJson.get('expiry_date');
        result.issuer               = (String) verdictJson.get('issuer');
        result.rawJson              = cleaned;

        result.issues = new List<String>();
        Object rawIssues = verdictJson.get('issues');
        if (rawIssues instanceof List<Object>) {
            for (Object i : (List<Object>) rawIssues) result.issues.add(String.valueOf(i));
        }
        return result;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Persist verdict to Compliance_Document__c
    // ═════════════════════════════════════════════════════════════════════════
    private static void persistVerdict(
        Id complianceDocId,
        ValidateResponse resp,
        ValidationLLMResult llmResult
    ) {
        String newStatus;
        if (resp.verdict == VERDICT_VALID) {
            newStatus = 'Validated';
        } else if (resp.verdict == VERDICT_INVALID) {
            newStatus = 'Rejected';
        } else {
            newStatus = 'Pending';     // Needs Human Review stays Pending
        }

        Compliance_Document__c docToUpdate = new Compliance_Document__c(
            Id        = complianceDocId,
            Status__c = newStatus,
            Notes__c  = ('Validator verdict: ' + resp.verdict + '\n'
                       + 'Reasoning: ' + resp.reasoning + '\n'
                       + (String.isNotBlank(resp.issuesFound)
                           ? 'Issues: ' + resp.issuesFound : ''))
                       .left(32768)
        );

        // Set expiry date if extracted and parseable
        if (String.isNotBlank(resp.expiryDate)) {
            try {
                docToUpdate.Expiry_Date__c = Date.valueOf(resp.expiryDate);
            } catch (Exception ignored) {}
        }
        if (String.isNotBlank(resp.issuer)) {
            docToUpdate.Issuer__c = resp.issuer.left(120);
        }

        update docToUpdate;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Data loading helpers
    // ═════════════════════════════════════════════════════════════════════════
    private static Compliance_Document__c loadDocument(Id docId) {
        List<Compliance_Document__c> docs = [
            SELECT Id, Document_Type__c, Account__c, Status__c, Latest_Extraction__c
            FROM   Compliance_Document__c
            WHERE  Id = :docId
            LIMIT  1
        ];
        return docs.isEmpty() ? null : docs[0];
    }

    private static Document_Extraction__c loadLatestExtraction(Id docId) {
        List<Document_Extraction__c> ext = [
            SELECT Id, Overall_Confidence__c, Extracted_Fields__c, Raw_Response__c,
                   Below_Threshold__c, Model_Name__c
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
            SELECT Id, Name, BillingCountry, Industry__c, Country_of_Origin__c
            FROM   Account
            WHERE  Id = :supplierId
            LIMIT  1
        ];
        return accts.isEmpty() ? null : accts[0];
    }

    private static Compliance_Requirement__mdt lookupRule(String requirementKey) {
        if (String.isBlank(requirementKey)) return null;
        try {
            return Compliance_Requirement__mdt.getInstance(requirementKey);
        } catch (Exception e) {
            return null;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Helpers + types
    // ═════════════════════════════════════════════════════════════════════════
    @TestVisible
    private class ValidationLLMResult {
        public String verdict;
        public String reasoning;
        public List<String> issues = new List<String>();
        public String documentTypeDetected;
        public String expiryDate;
        public String issuer;
        public String rawJson;
    }

    private static ValidateResponse failResponse(ValidateResponse resp, String msg) {
        resp.verdict   = VERDICT_NEEDS_HITL;
        resp.reasoning = msg;
        return resp;
    }

    private static String toStringValue(Object val) {
        if (val == null) return null;
        if (val instanceof String) return (String) val;
        if (val instanceof List<Object>) {
            List<String> parts = new List<String>();
            for (Object item : (List<Object>) val) {
                if (item != null) parts.add(String.valueOf(item));
            }
            return String.join(parts, '\n');
        }
        return String.valueOf(val);
    }

    public class ValidatorException extends Exception {}

    // ═════════════════════════════════════════════════════════════════════════
    // Supplier-name → Document-Id lookup
    // ═════════════════════════════════════════════════════════════════════════
    @TestVisible private static String lastLookupMessage = '';

    /**
     * Resolves a supplier name (+ optional document type) to a single
     * Compliance_Document__c ID. Returns null with lastLookupMessage set
     * if the supplier is ambiguous or no matching document exists.
     */
    @TestVisible
    private static String lookupDocumentBySupplier(
        String supplierName, String documentTypeFilter
    ) {
        lastLookupMessage = '';
        if (String.isBlank(supplierName)) {
            lastLookupMessage = 'No supplier name provided.';
            return null;
        }

        // Find supplier — must be unambiguous
        Id supplierRtId;
        try {
            Map<String, Schema.RecordTypeInfo> rtMap =
                Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
            if (rtMap.containsKey('Supplier')) {
                supplierRtId = rtMap.get('Supplier').getRecordTypeId();
            }
        } catch (Exception e) {}

        List<Account> suppliers;
        if (supplierRtId != null) {
            suppliers = [
                SELECT Id, Name FROM Account
                WHERE Name LIKE :('%' + supplierName.trim() + '%')
                AND   RecordTypeId = :supplierRtId
                ORDER BY LastModifiedDate DESC
                LIMIT 5
            ];
        } else {
            suppliers = [
                SELECT Id, Name FROM Account
                WHERE Name LIKE :('%' + supplierName.trim() + '%')
                ORDER BY LastModifiedDate DESC
                LIMIT 5
            ];
        }

        if (suppliers.isEmpty()) {
            lastLookupMessage = 'No supplier found matching "' + supplierName + '".';
            return null;
        }
        if (suppliers.size() > 1) {
            List<String> names = new List<String>();
            for (Account a : suppliers) names.add(a.Name);
            lastLookupMessage = 'Multiple suppliers match "' + supplierName
                + '": ' + String.join(names, ', ')
                + '. Please ask the user which supplier they mean.';
            return null;
        }

        Id supplierId = suppliers[0].Id;
        String matchedName = suppliers[0].Name;

        // Find document — apply type filter if provided
        List<Compliance_Document__c> docs;
        if (String.isNotBlank(documentTypeFilter)) {
            String typePattern = '%' + documentTypeFilter + '%';
            docs = [
                SELECT Id, Document_Type__c, Status__c, CreatedDate
                FROM   Compliance_Document__c
                WHERE  Account__c = :supplierId
                AND    Document_Type__c LIKE :typePattern
                ORDER BY CreatedDate DESC
                LIMIT  5
            ];
        } else {
            docs = [
                SELECT Id, Document_Type__c, Status__c, CreatedDate
                FROM   Compliance_Document__c
                WHERE  Account__c = :supplierId
                ORDER BY CreatedDate DESC
                LIMIT  5
            ];
        }

        if (docs.isEmpty()) {
            lastLookupMessage = 'Supplier "' + matchedName + '" has no compliance documents'
                + (String.isNotBlank(documentTypeFilter)
                    ? ' of type "' + documentTypeFilter + '"' : '')
                + ' uploaded yet.';
            return null;
        }

        // If multiple docs match and no type filter, prefer the most recent
        // (already ordered DESC). If a type filter was provided and we still
        // got multiple, also pick most recent — same record sort.
        return (String) docs[0].Id;
    }
}