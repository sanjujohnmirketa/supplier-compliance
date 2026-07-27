/**
 * ScopeService
 * ═══════════════════════════════════════════════════════════════════════════
 * Thin client for the local Python compliance RAG service (`app.py` /scope).
 *
 * Replaces the static CMT rule engine as the source of the required-document
 * checklist. Given supplier attributes, /scope retrieves matching policy
 * clauses (pgvector RAG) and returns a risk tier + a checklist of required
 * documents, each justified by the policy clause that triggered it.
 *
 * Transport: callout:Local_Compliance_Service (Named Credential) carries the
 * endpoint URL (a cloudflared tunnel in dev) and the bearer token via the
 * Local_Compliance_Auth external credential. Callable only from an async
 * (Queueable) context — see ScopeCalloutQueueable.
 *
 * Request/response shapes mirror the FastAPI models in app.py exactly.
 */
public with sharing class ScopeService {

    @TestVisible private static final String  NAMED_CRED  = 'callout:Local_Compliance_Service';
    @TestVisible private static final Integer TIMEOUT_MS  = 30000;

    public class ScopeException extends Exception {}

    // ── Request (mirrors app.py ScopeRequest) ─────────────────────────────────
    public class ScopeRequest {
        public String       supplierId;
        public String       legalName;
        public String       country;
        public String       commodity;
        public List<String> jurisdictions = new List<String>();
        // Optional — sharpens domain selection beyond industry/engagement text.
        // Blank behaves exactly as before these fields existed.
        public String       materialType;
        public String       serviceCategory;
    }

    // ── Response (mirrors app.py /scope output) ───────────────────────────────
    public class ChecklistItem {
        public String document;
        public String domain;
        public String justificationClauseId;
        public String justification;
    }
    public class ScopeResponse {
        public String              supplierId;
        public String              riskTier;
        public String              riskSummary;
        public List<ChecklistItem> checklist;
        public List<String>        riskReasons;   // bullet reasoning behind the tier
        public List<String>        notes;         // e.g. no-policy-match explanation
        public Boolean             noPolicyMatch; // true → only baseline applied
    }

    /**
     * POSTs supplier attributes to /scope and returns the parsed response.
     * Throws ScopeException on any non-200 so the caller can record the miss
     * without committing a partial checklist.
     */
    public static ScopeResponse getScope(ScopeRequest req) {
        HttpRequest httpReq = new HttpRequest();
        httpReq.setMethod('POST');
        httpReq.setEndpoint(NAMED_CRED + '/scope');
        httpReq.setHeader('Content-Type', 'application/json');
        httpReq.setHeader('X-Tunnel-Skip-AntiPhishing-Page', 'true'); // VS Code dev tunnel: skip interstitial
        httpReq.setTimeout(TIMEOUT_MS);
        // suppressApexObjectNulls = true → omit null country/commodity so the
        // FastAPI Optional defaults apply.
        httpReq.setBody(JSON.serialize(req, true));

        // The dev tunnel occasionally stalls a connection with no bytes back
        // (CalloutException: Read timed out) even though the engine itself
        // responds in well under a second. One retry masks that transient
        // tunnel flake from the user without hiding a REAL engine error
        // (4xx/5xx), which is handled below, outside this retry.
        HttpResponse res;
        try {
            res = new Http().send(httpReq);
        } catch (CalloutException ce) {
            res = new Http().send(httpReq);   // one retry, same request
        }

        if (res.getStatusCode() != 200) {
            throw new ScopeException(
                'Scope service returned HTTP ' + res.getStatusCode()
                + ': ' + res.getBody());
        }
        // Untyped parse — the payload now carries a nested 'domainReasons' map
        // which typed deserialize would choke on ("Object unsupported in JSON").
        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        ScopeResponse out = new ScopeResponse();
        out.supplierId  = (String) m.get('supplierId');
        out.riskTier    = (String) m.get('riskTier');
        out.riskSummary = (String) m.get('riskSummary');
        out.noPolicyMatch = (Boolean) m.get('noPolicyMatch');

        out.riskReasons = new List<String>();
        if (m.get('riskReasons') instanceof List<Object>) {
            for (Object o : (List<Object>) m.get('riskReasons')) out.riskReasons.add((String) o);
        }
        out.notes = new List<String>();
        if (m.get('notes') instanceof List<Object>) {
            for (Object o : (List<Object>) m.get('notes')) out.notes.add((String) o);
        }
        out.checklist = new List<ChecklistItem>();
        if (m.get('checklist') instanceof List<Object>) {
            for (Object o : (List<Object>) m.get('checklist')) {
                Map<String, Object> cm = (Map<String, Object>) o;
                ChecklistItem ci = new ChecklistItem();
                ci.document              = (String) cm.get('document');
                ci.domain                = (String) cm.get('domain');
                ci.justificationClauseId = (String) cm.get('justificationClauseId');
                ci.justification         = (String) cm.get('justification');
                out.checklist.add(ci);
            }
        }
        return out;
    }
}