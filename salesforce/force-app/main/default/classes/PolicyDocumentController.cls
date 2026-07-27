/**
 * PolicyDocumentController
 * ═══════════════════════════════════════════════════════════════════════════
 * Backs scPolicyUpload — the internal (non-portal) Procurement screen for
 * uploading company policy documents into the RAG policy corpus.
 *
 * Flow: LWC creates a Policy_Document__c (Status__c='Uploaded') -> uses
 * lightning-file-upload with record-id={that Id} (same pattern as
 * scProcurementDocumentUploader) -> onuploadfinished calls startIngestion(),
 * which enqueues PolicyIngestQueueable directly (no Platform Event hop — that
 * pattern was already tried and abandoned for Document_Uploaded__e; see
 * DocumentProcessingController.cls's own comment on why).
 */
public without sharing class PolicyDocumentController {

    // ─── createPolicyDocument ───────────────────────────────────────────────
    // Creates the record BEFORE any file exists so lightning-file-upload has a
    // record-id to attach to (mirrors how Compliance_Document__c is created
    // ahead of its own file upload in DocumentProcessingController).
    @AuraEnabled
    public static Id createPolicyDocument(String domainOverride) {
        Policy_Document__c pd = new Policy_Document__c(
            Status__c = 'Uploaded',
            Domain__c = String.isNotBlank(domainOverride) ? domainOverride : 'Auto-Detect'
        );
        insert pd;
        return pd.Id;
    }

    // ─── startIngestion ──────────────────────────────────────────────────────
    // Called from onuploadfinished once lightning-file-upload has attached the
    // ContentVersion to the Policy_Document__c. Enqueues the ingest callout.
    @AuraEnabled
    public static void startIngestion(Id policyDocumentId, Id contentDocumentId) {
        if (policyDocumentId == null || contentDocumentId == null) {
            throw new AuraHandledException('policyDocumentId and contentDocumentId are required.');
        }
        Id cvId = getLatestContentVersionId(contentDocumentId);
        if (cvId == null) {
            throw new AuraHandledException(
                'Could not locate the uploaded file version. The file may not have finished uploading. Please try again.');
        }

        update new Policy_Document__c(
            Id             = policyDocumentId,
            Source_File__c = contentDocumentId,
            Status__c      = 'Processing'
        );

        System.enqueueJob(new PolicyIngestQueueable(policyDocumentId, cvId));
    }

    private static Id getLatestContentVersionId(Id contentDocumentId) {
        List<ContentVersion> cv = [
            SELECT Id FROM ContentVersion
            WHERE  ContentDocumentId = :contentDocumentId
            AND    IsLatest          = true
            LIMIT  1
        ];
        return cv.isEmpty() ? null : cv[0].Id;
    }

    // ─── getPolicyDocuments ──────────────────────────────────────────────────
    // Powers the list panel — most recently uploaded first.
    public class PolicyDocumentRow {
        @AuraEnabled public Id       id;
        @AuraEnabled public String   name;
        @AuraEnabled public String   domain;
        @AuraEnabled public String   status;
        @AuraEnabled public Integer  chunkCount;
        @AuraEnabled public String   corpusVersion;
        @AuraEnabled public String   failureReason;
        @AuraEnabled public Datetime ingestedDate;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public String   sourceFileContentDocumentId;
    }

    @AuraEnabled(cacheable=false)
    public static List<PolicyDocumentRow> getPolicyDocuments() {
        List<PolicyDocumentRow> rows = new List<PolicyDocumentRow>();
        for (Policy_Document__c pd : [
            SELECT Id, Name, Domain__c, Status__c, Chunk_Count__c, Corpus_Version__c,
                   Failure_Reason__c, Ingested_Date__c, CreatedDate, Source_File__c
            FROM   Policy_Document__c
            ORDER  BY CreatedDate DESC
            LIMIT  200
        ]) {
            PolicyDocumentRow row = new PolicyDocumentRow();
            row.id            = pd.Id;
            row.name          = pd.Name;
            row.domain        = pd.Domain__c;
            row.status        = pd.Status__c;
            row.chunkCount    = pd.Chunk_Count__c != null ? Integer.valueOf(pd.Chunk_Count__c) : null;
            row.corpusVersion = pd.Corpus_Version__c;
            row.failureReason = pd.Failure_Reason__c;
            row.ingestedDate  = pd.Ingested_Date__c;
            row.createdDate   = pd.CreatedDate;
            row.sourceFileContentDocumentId = pd.Source_File__c;
            rows.add(row);
        }
        return rows;
    }
}
