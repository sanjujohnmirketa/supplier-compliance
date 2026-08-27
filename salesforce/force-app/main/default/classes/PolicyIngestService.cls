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

    // Returned by POST /policy/ingest — the engine now enqueues the actual
    // parse/chunk/embed work as a background job instead of blocking the
    // request, since a 40-100 page PDF can take well past Salesforce's 120s
    // hard callout ceiling. jobId is polled via checkStatus() below.
    public class IngestSubmitResponse {
        public String jobId;
        public String status;     // 'queued' immediately after submit
        public String fileName;
    }

    // Returned by GET /policy/ingest/status/{jobId}.
    public class IngestStatusResponse {
        public String  jobId;
        public String  status;      // 'queued' | 'processing' | 'done' | 'failed'
        public String  fileName;
        public String  domain;      // present when status == 'done'
        public String  industry;
        public Integer chunkCount;
        public String  version;
        public String  error;       // present when status == 'failed'
    }

    public static IngestSubmitResponse submit(IngestRequest req) {
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

        return (IngestSubmitResponse) JSON.deserialize(res.getBody(), IngestSubmitResponse.class);
    }

    public static IngestStatusResponse checkStatus(String jobId) {
        HttpRequest httpReq = new HttpRequest();
        httpReq.setEndpoint(NAMED_CRED + '/policy/ingest/status/' + EncodingUtil.urlEncode(jobId, 'UTF-8'));
        httpReq.setMethod('GET');
        httpReq.setHeader('X-Tunnel-Skip-AntiPhishing-Page', 'true');
        httpReq.setTimeout(TIMEOUT_MS);

        HttpResponse res;
        try {
            res = new Http().send(httpReq);
        } catch (CalloutException ce) {
            res = new Http().send(httpReq);
        }

        if (res.getStatusCode() != 200) {
            throw new IngestException(
                'Policy ingest status check failed: HTTP ' + res.getStatusCode() + ': ' + res.getBody());
        }

        return (IngestStatusResponse) JSON.deserialize(res.getBody(), IngestStatusResponse.class);
    }

    public class DeleteRequest {
        public String fileName;
    }
    public class DeleteResponse {
        public String  fileName;
        public Integer chunksDeleted;
    }

    // Hard-deletes every chunk (all versions) for one source file from
    // policy_chunk — called by PolicyDocumentController.deletePolicyDocument
    // so a removed policy stops grounding future /scope and /assess calls,
    // not just disappears from the Salesforce list view.
    public static DeleteResponse deleteBySourceFile(String fileName) {
        DeleteRequest req = new DeleteRequest();
        req.fileName = fileName;

        HttpRequest httpReq = new HttpRequest();
        httpReq.setEndpoint(NAMED_CRED + '/policy/delete');
        httpReq.setMethod('POST');
        httpReq.setHeader('Content-Type', 'application/json');
        httpReq.setHeader('X-Tunnel-Skip-AntiPhishing-Page', 'true');
        httpReq.setTimeout(TIMEOUT_MS);
        httpReq.setBody(JSON.serialize(req, true));

        HttpResponse res;
        try {
            res = new Http().send(httpReq);
        } catch (CalloutException ce) {
            res = new Http().send(httpReq);
        }

        if (res.getStatusCode() != 200) {
            throw new IngestException(
                'Policy delete failed: HTTP ' + res.getStatusCode() + ': ' + res.getBody());
        }

        return (DeleteResponse) JSON.deserialize(res.getBody(), DeleteResponse.class);
    }
}