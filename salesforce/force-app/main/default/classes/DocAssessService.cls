/**
 * DocAssessService
 * ═══════════════════════════════════════════════════════════════════════════
 * HTTP client for the local RAG document-assessment endpoint (`app.py` /assess).
 * Mirrors ScopeService. Replaces the Azure extract→validate→evaluate chain:
 * the local service extracts the document text, retrieves policy clauses, and
 * an LLM judges Compliant / Non-Compliant / Needs Analyst with citations.
 *
 * Transport: callout:Local_Compliance_Service (same Named Credential + bearer
 * token as /scope). Callable only from an async context (DocAssessQueueable).
 */
public with sharing class DocAssessService {

    @TestVisible private static final String  NAMED_CRED = 'callout:Local_Compliance_Service';
    @TestVisible private static final Integer TIMEOUT_MS = 60000;   // LLM call can be slow

    public class AssessException extends Exception {}

    // ── Request (mirrors app.py AssessRequest) ────────────────────────────────
    public class AssessRequest {
        public String supplierId;
        public String domain;          // optional — service infers if blank
        public String requirementKey;  // optional — echoed back
        public String documentType;    // the upload's type hint
        public String documentBase64;  // base64 file bytes
        public String fileName;        // used by the service to pick its extractor
    }

    // ── Response (mirrors app.py /assess output; extra fields ignored) ─────────
    public class AssessResponse {
        public String       supplierId;
        public String       requirementKey;
        public String       domain;        // resolved domain (caller-supplied or inferred)
        public String       verdict;       // Compliant | Non-Compliant | Needs Analyst
        public String       severity;      // Critical | High | Medium | Low
        public Integer      confidence;    // 0-100
        public String       reasons;
        public Map<String, Object> summary;          // {headline, key_facts[], concerns[]}
        public List<String> citations;
        public String       model;
        public Integer      extractionChars;
        // Document Intelligence (extract → deterministic verify)
        public Map<String, Object> extractedFields;  // issuer, identifier, expiry_date, coverage_amount, …
        public Map<String, Object> keyDates;         // expiry_date, is_expired, days_to_expiry
        public List<Object>        clauseChecks;     // [{requirement, expected, found, pass}]
        public Map<String, Object> registryValidation; // {authority, method, status, detail}
    }

    public static AssessResponse assess(AssessRequest req) {
        HttpRequest httpReq = new HttpRequest();
        httpReq.setEndpoint(NAMED_CRED + '/assess');
        httpReq.setMethod('POST');
        httpReq.setHeader('Content-Type', 'application/json');
        httpReq.setHeader('X-Tunnel-Skip-AntiPhishing-Page', 'true'); // VS Code dev tunnel: skip interstitial
        httpReq.setTimeout(TIMEOUT_MS);
        httpReq.setBody(JSON.serialize(req, true));   // suppress null fields

        HttpResponse res = new Http().send(httpReq);
        if (res.getStatusCode() != 200) {
            throw new AssessException(
                'Assess service returned HTTP ' + res.getStatusCode() + ': ' + res.getBody());
        }
        // Untyped parse — the response has nested objects (extractedFields, keyDates,
        // clauseChecks, registryValidation). Typed JSON.deserialize can't map those
        // into Object/Map fields ("Apex Type unsupported in JSON: Object").
        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        AssessResponse r = new AssessResponse();
        r.supplierId      = (String) m.get('supplierId');
        r.requirementKey  = (String) m.get('requirementKey');
        r.domain          = (String) m.get('domain');
        r.verdict         = (String) m.get('verdict');
        r.severity        = (String) m.get('severity');
        r.reasons         = (String) m.get('reasons');
        r.model           = (String) m.get('model');
        if (m.get('confidence') != null)      r.confidence = Integer.valueOf(String.valueOf(m.get('confidence')));
        if (m.get('extractionChars') != null) r.extractionChars = Integer.valueOf(String.valueOf(m.get('extractionChars')));
        r.citations = new List<String>();
        if (m.get('citations') instanceof List<Object>) {
            for (Object o : (List<Object>) m.get('citations')) if (o != null) r.citations.add(String.valueOf(o));
        }
        r.summary            = (Map<String, Object>) m.get('summary');
        r.extractedFields    = (Map<String, Object>) m.get('extractedFields');
        r.keyDates           = (Map<String, Object>) m.get('keyDates');
        r.clauseChecks       = (List<Object>)        m.get('clauseChecks');
        r.registryValidation = (Map<String, Object>) m.get('registryValidation');
        return r;
    }
}