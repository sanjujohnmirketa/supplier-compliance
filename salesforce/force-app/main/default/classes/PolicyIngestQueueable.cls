/**
 * PolicyIngestQueueable
 * ═══════════════════════════════════════════════════════════════════════════
 * Enqueued directly by PolicyDocumentController.startIngestion() once a policy
 * file finishes uploading (no Platform Event hop — that pattern was already
 * tried for document uploads and abandoned as unreliable; see
 * DocumentProcessingController.cls's comment on Document_Uploaded__e).
 *
 * Per policy document it:
 *   1. Loads the ContentVersion file (base64)
 *   2. Calls the engine's /policy/ingest (PolicyIngestService) — parses,
 *      chunks, embeds, and upserts into policy_chunk (same pipeline the SFTP
 *      bulk script ingest_policies.py uses)
 *   3. Writes the result back onto Policy_Document__c: Status__c='Ingested',
 *      Domain__c (resolved), Chunk_Count__c, Corpus_Version__c, Ingested_Date__c
 *      — or Status__c='Failed' + Failure_Reason__c on error
 *
 * Callout-then-DML ordering: SOQL (load file) -> callout (/policy/ingest) -> DML.
 */
public without sharing class PolicyIngestQueueable
        implements Queueable, Database.AllowsCallouts {

    private final Id policyDocumentId;
    private final Id contentVersionId;

    public PolicyIngestQueueable(Id policyDocumentId, Id contentVersionId) {
        this.policyDocumentId = policyDocumentId;
        this.contentVersionId = contentVersionId;
    }

    public void execute(QueueableContext ctx) {
        Policy_Document__c pd = [
            SELECT Id, Name, Domain__c
            FROM   Policy_Document__c
            WHERE  Id = :policyDocumentId
            LIMIT  1
        ];
        ContentVersion cv = [
            SELECT Title, PathOnClient, VersionData
            FROM   ContentVersion
            WHERE  Id = :contentVersionId
            LIMIT  1
        ];

        String fileName = String.isNotBlank(cv.PathOnClient) ? cv.PathOnClient : cv.Title;

        PolicyIngestService.IngestRequest req = new PolicyIngestService.IngestRequest();
        req.fileName = fileName;
        req.documentBase64 = EncodingUtil.base64Encode(cv.VersionData);
        req.domainHint = pd.Domain__c;   // 'Auto-Detect' or an explicit domain override

        try {
            PolicyIngestService.IngestResponse resp = PolicyIngestService.ingest(req);
            update new Policy_Document__c(
                Id                = policyDocumentId,
                Status__c         = 'Ingested',
                Domain__c         = resp.domain,
                Chunk_Count__c    = resp.chunkCount,
                Corpus_Version__c = resp.version,
                Ingested_Date__c  = DateTime.now()
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                '[PolicyIngestQueueable] /policy/ingest failed for ' + policyDocumentId + ': ' + e.getMessage());
            update new Policy_Document__c(
                Id             = policyDocumentId,
                Status__c      = 'Failed',
                Failure_Reason__c = e.getMessage().left(255)
            );
        }
    }
}
