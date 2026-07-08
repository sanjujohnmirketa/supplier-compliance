/**
 * ScreeningService
 * ═══════════════════════════════════════════════════════════════════════════
 * Thin client for the local screening endpoint (`app.py` /verify) — Stage-02
 * due-diligence registry verification (GLEIF identity + OpenSanctions sanctions/
 * PEP, with conflict-minerals routed to the human gate until the RMI list is
 * ingested). Mirrors ScopeService: same Named Credential + skip header.
 * Callable from an async or @AuraEnabled (LWC) context.
 */
public with sharing class ScreeningService {

    @TestVisible private static final String  NAMED_CRED = 'callout:Local_Compliance_Service';
    @TestVisible private static final Integer TIMEOUT_MS = 120000;   // Salesforce max; gpt-4o keeps /verify well under this

    public class ScreeningException extends Exception {}

    // ── Request (mirrors app.py VerifyRequest) ────────────────────────────────
    public class VerifyRequest {
        public String       legalName;
        public String       country;
        public String       commodity;
        public List<String> domains = new List<String>();
    }

    // ── Response (mirrors app.py /verify; extra fields like evidence ignored) ─
    public class VerifyResult {
        public String authority;
        public String category;   // Financials | Sanctions | Conflict Minerals
        public String status;     // Verified | Clear | Review | Flag | NotFound | NotConfigured
        public String summary;
    }
    public class VerifyResponse {
        public String             legalName;
        public String             signal;    // clear | review | flag
        public List<VerifyResult> results;
    }

    public static VerifyResponse verify(VerifyRequest req) {
        HttpRequest httpReq = new HttpRequest();
        httpReq.setMethod('POST');
        httpReq.setEndpoint(NAMED_CRED + '/verify');
        httpReq.setHeader('Content-Type', 'application/json');
        httpReq.setHeader('X-Tunnel-Skip-AntiPhishing-Page', 'true');
        httpReq.setTimeout(TIMEOUT_MS);
        httpReq.setBody(JSON.serialize(req, true));

        HttpResponse res = new Http().send(httpReq);
        if (res.getStatusCode() != 200) {
            throw new ScreeningException(
                'Screening service returned HTTP ' + res.getStatusCode() + ': ' + res.getBody());
        }
        // Untyped parse — results carry nested 'evidence' arrays and the payload has
        // a 'disambiguation' object; typed deserialize can choke on those.
        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        VerifyResponse out = new VerifyResponse();
        out.legalName = (String) m.get('legalName');
        out.signal    = (String) m.get('signal');
        out.results   = new List<VerifyResult>();
        if (m.get('results') instanceof List<Object>) {
            for (Object o : (List<Object>) m.get('results')) {
                Map<String, Object> rm = (Map<String, Object>) o;
                VerifyResult vr = new VerifyResult();
                vr.authority = (String) rm.get('authority');
                vr.category  = (String) rm.get('category');
                vr.status    = (String) rm.get('status');
                vr.summary   = (String) rm.get('summary');
                out.results.add(vr);
            }
        }
        return out;
    }
}