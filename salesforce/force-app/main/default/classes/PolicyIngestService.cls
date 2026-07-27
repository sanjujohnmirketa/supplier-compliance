/**
 * PolicyIngestService — HTTP client for the engine's /policy/ingest endpoint.
 * Same Named Credential + bearer token + tunnel header as ScopeService/DocAssessService.
 */
public with sharing class PolicyIngestService {

    @TestVisible private static final String  NAMED_CRED = 'callout:Local_Compliance_Service';
    @TestVisible private static final Integer TIMEOUT_MS = 60000;   // embedding a full doc can take a few seconds

    public class IngestException extends Exception {}

    public class IngestRequest {
        public String fileName;
        public String documentBase64;
        public String domainHint;   // null/blank -> engine auto-detects
    }

    public class IngestResponse {
        public String  fileName;
        public String  domain;
        public Integer chunkCount;
        public String  version;
    }

    public static IngestResponse ingest(IngestRequest req) {
        HttpRequest httpReq = new HttpRequest();
        httpReq.setEndpoint(NAMED_CRED + '/policy/ingest');
        httpReq.setMethod('POST');
        httpReq.setHeader('Content-Type', 'application/json');
        httpReq.setHeader('X-Tunnel-Skip-AntiPhishing-Page', 'true');
        httpReq.setTimeout(TIMEOUT_MS);
        httpReq.setBody(JSON.serialize(req, true));

        // Same tunnel-flake retry as ScopeService — one retry on a stalled
        // connection, not on a real 4xx/5xx (handled below, outside the retry).
        HttpResponse res;
        try {
            res = new Http().send(httpReq);
        } catch (CalloutException ce) {
            res = new Http().send(httpReq);
        }

        if (res.getStatusCode() != 200) {
            throw new IngestException(
                'Policy ingest failed: HTTP ' + res.getStatusCode() + ': ' + res.getBody());
        }

        return (IngestResponse) JSON.deserialize(res.getBody(), IngestResponse.class);
    }
}
