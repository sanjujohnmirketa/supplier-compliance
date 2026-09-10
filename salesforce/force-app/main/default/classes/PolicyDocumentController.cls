/**
 * PolicyDocumentController
 * ═══════════════════════════════════════════════════════════════════════════
 * Backs scPolicyUpload — the internal (non-portal) Procurement screen for
 * uploading company policy documents into the RAG policy corpus.
 *
 * Flow: LWC reads the picked file client-side (FileReader -> base64), then
 * calls uploadPolicyDocument in ONE call — creates the Policy_Document__c,
 * attaches the ContentVersion, and enqueues ingestion together. This is
 * deliberately NOT the lightning-file-upload two-step (create record on
 * button click -> wait for user to pick a file) that this component used
 * before: that pattern left an orphaned "Uploaded" record with no file
 * whenever a user clicked Attach and then closed the file picker without
 * choosing anything. Manual base64 upload (same pattern as
 * DocumentProcessingController.saveFile / scSupplierPortal's uploader)
 * guarantees a record only exists once its file genuinely does.
 *
 * Force-recompiled 2026-08-13 to rule out a stale compiled version serving
 * a non-admin user's requests (debug logs showed zero SOQL/DML statement
 * lines even at FINEST detail for uploadPolicyDocument, which is impossible
 * for the actual source — pointing at cached bytecode, not a permissions gap).
 *
 * CRUD/FLS: every entry point checks the running user's object permissions
 * (Schema.sObjectType.X.isAccessible/isCreateable/isUpdateable/isDeletable)
 * before its SOQL/DML, and fire-and-forget writes go through
 * Security.stripInaccessible so field-level security is enforced too.
 * without sharing is kept on purpose — Policy_Document__c is an org-wide
 * corpus (OWD Read) that Procurement maintains regardless of record owner —
 * so WITH USER_MODE, which would also enforce sharing, is not used here.
 */
public without sharing class PolicyDocumentController {

    private static final String NO_ACCESS =
        'You do not have permission to perform this action.';

    // ─── uploadPolicyDocument ────────────────────────────────────────────────
    // Creates the Policy_Document__c, attaches the file (ContentVersion +
    // ContentDocumentLink), and enqueues ingestion — atomically from the LWC's
    // perspective. No record is ever created without a file behind it.
    @AuraEnabled
    public static Id uploadPolicyDocument(String fileName, String base64Data, String domainOverride) {
        if (String.isBlank(fileName) || String.isBlank(base64Data)) {
            throw new AuraHandledException('A file is required.');
        }
        if (!Schema.sObjectType.Policy_Document__c.isCreateable()
                || !Schema.sObjectType.Policy_Document__c.isUpdateable()
                || !Schema.sObjectType.ContentVersion.isCreateable()
                || !Schema.sObjectType.ContentVersion.isAccessible()
                || !Schema.sObjectType.ContentDocumentLink.isCreateable()) {
            throw new AuraHandledException(NO_ACCESS);
        }

        Policy_Document__c pd = new Policy_Document__c(
            Status__c = 'Processing',
            Domain__c = String.isNotBlank(domainOverride) ? domainOverride : 'Auto-Detect'
        );
        insert pd;

        ContentVersion cv = new ContentVersion(
            Title        = fileName,
            PathOnClient = fileName,
            VersionData  = EncodingUtil.base64Decode(base64Data),
            Origin       = 'H'
        );
        insert cv;
        Id contentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1]
            .ContentDocumentId;
        insert Security.stripInaccessible(AccessType.CREATABLE, new List<ContentDocumentLink>{
            new ContentDocumentLink(
                ContentDocumentId = contentDocumentId,
                LinkedEntityId     = pd.Id,
                ShareType          = 'V',
                Visibility         = 'AllUsers'
            )
        }).getRecords();

        update Security.stripInaccessible(AccessType.UPDATABLE, new List<Policy_Document__c>{
            new Policy_Document__c(
                Id             = pd.Id,
                Source_File__c = contentDocumentId
            )
        }).getRecords();

        logPolicyDocumentAudit(pd.Id, 'Document_Uploaded', 'Uploaded policy document: ' + fileName);

        System.enqueueJob(new PolicyIngestQueueable(pd.Id, cv.Id));
        return pd.Id;
    }

    // Policy_Document__c-specific audit helper — AuditLogService.logDocumentReceived
    // hardcodes Related_Object__c='Compliance_Document', which would mislabel
    // policy-document events; this writes directly with the correct object tag.
    private static void logPolicyDocumentAudit(Id policyDocumentId, String eventType, String detail) {
        AuditLogService.write(new Audit_Log__c(
            Event_Type__c        = eventType,
            Related_Object__c    = 'Policy_Document',
            Related_Record_Id__c = policyDocumentId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'User',
            Source_System__c     = 'Salesforce',
            New_Value__c         = detail
        ));
    }

    // ─── reuploadPolicyDocument ──────────────────────────────────────────────
    // Replaces an existing Policy_Document__c's file with a new version and
    // re-runs ingestion — used by the "Reupload" row action. The OLD
    // ContentVersion is superseded (new ContentVersion on the same
    // ContentDocument, so Salesforce's native versioning keeps the history);
    // the audit log records the replacement explicitly since Audit_Log__c is
    // the durable trail the user asked for (Salesforce's file version history
    // is real but not what gets surfaced in this app's own audit UI).
    @AuraEnabled
    public static void reuploadPolicyDocument(Id policyDocumentId, String fileName, String base64Data) {
        if (policyDocumentId == null || String.isBlank(fileName) || String.isBlank(base64Data)) {
            throw new AuraHandledException('policyDocumentId and a file are required.');
        }
        if (!Schema.sObjectType.Policy_Document__c.isAccessible()
                || !Schema.sObjectType.Policy_Document__c.isUpdateable()
                || !Schema.sObjectType.ContentVersion.isAccessible()
                || !Schema.sObjectType.ContentVersion.isCreateable()
                || !Schema.sObjectType.ContentDocumentLink.isCreateable()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        List<Policy_Document__c> matches = [
            SELECT Id, Source_File__c, Domain__c
            FROM   Policy_Document__c
            WHERE  Id = :policyDocumentId
            LIMIT  1
        ];
        if (matches.isEmpty()) {
            throw new AuraHandledException(
                'This policy document no longer exists — it may have been deleted. Refresh the list and try again.');
        }
        Policy_Document__c pd = matches[0];

        ContentVersion cv;
        if (String.isNotBlank(pd.Source_File__c)) {
            // New version of the SAME ContentDocument — preserves file version history.
            cv = new ContentVersion(
                ContentDocumentId = pd.Source_File__c,
                PathOnClient       = fileName,
                VersionData        = EncodingUtil.base64Decode(base64Data)
            );
            insert cv;
        } else {
            cv = new ContentVersion(
                Title        = fileName,
                PathOnClient = fileName,
                VersionData  = EncodingUtil.base64Decode(base64Data),
                Origin       = 'H'
            );
            insert cv;
            Id contentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1]
                .ContentDocumentId;
            insert Security.stripInaccessible(AccessType.CREATABLE, new List<ContentDocumentLink>{
                new ContentDocumentLink(
                    ContentDocumentId = contentDocumentId,
                    LinkedEntityId     = pd.Id,
                    ShareType          = 'V',
                    Visibility         = 'AllUsers'
                )
            }).getRecords();
            pd.Source_File__c = contentDocumentId;
        }

        update Security.stripInaccessible(AccessType.UPDATABLE, new List<Policy_Document__c>{
            new Policy_Document__c(
                Id                = policyDocumentId,
                Source_File__c    = pd.Source_File__c,
                Status__c         = 'Processing',
                Failure_Reason__c = null,
                Chunk_Count__c    = null,
                Corpus_Version__c = null,
                Ingested_Date__c  = null
            )
        }).getRecords();

        logPolicyDocumentAudit(policyDocumentId, 'Document_Uploaded', 'Reuploaded new version: ' + fileName);

        Id cvIdForIngest = String.isNotBlank(pd.Source_File__c)
            ? [SELECT Id FROM ContentVersion WHERE ContentDocumentId = :pd.Source_File__c AND IsLatest = true LIMIT 1].Id
            : cv.Id;
        System.enqueueJob(new PolicyIngestQueueable(policyDocumentId, cvIdForIngest));
    }

    // ─── deletePolicyDocument ────────────────────────────────────────────────
    // Deleting the Salesforce record alone left the underlying policy_chunk
    // rows live in the engine's Postgres index forever — a "deleted" policy
    // kept silently grounding every future /scope and /assess call. This now
    // hard-deletes the engine-side chunks FIRST (best-effort; a callout
    // failure doesn't block the Salesforce delete, since the user's intent —
    // remove this document — should still succeed even if the engine is
    // temporarily unreachable) using the real uploaded filename, which is
    // policy_chunk.source's exact key (NOT the POL-0000 autonumber).
    @AuraEnabled
    public static void deletePolicyDocument(Id policyDocumentId) {
        if (policyDocumentId == null) {
            throw new AuraHandledException('policyDocumentId is required.');
        }
        if (!Schema.sObjectType.Policy_Document__c.isAccessible()
                || !Schema.sObjectType.Policy_Document__c.isDeletable()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        List<Policy_Document__c> matches = [
            SELECT Id, Name, Source_File__c FROM Policy_Document__c
            WHERE Id = :policyDocumentId LIMIT 1
        ];
        if (matches.isEmpty()) {
            // Already deleted (double-click, stale row from a previous delete,
            // or removed by someone else) — not an error from the user's point
            // of view, the end state they wanted (this document gone) already
            // holds. Let the caller refresh its list instead of throwing.
            return;
        }
        Policy_Document__c pd = matches[0];

        String realFileName = resolveSourceFileName(pd.Source_File__c);
        if (String.isNotBlank(realFileName)) {
            try {
                PolicyIngestService.deleteBySourceFile(realFileName);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    '[PolicyDocumentController] engine-side delete failed for ' +
                    realFileName + ': ' + e.getMessage());
            }
        }

        logPolicyDocumentAudit(policyDocumentId, 'Status_Changed', 'Deleted policy document ' + pd.Name);

        delete pd;
    }

    // Resolves the real uploaded filename from ContentVersion — same lookup
    // getPolicyDocuments() does in bulk; here it's single-record since delete
    // only needs the one document. Returns null if no file exists yet.
    private static String resolveSourceFileName(Id sourceFileContentDocId) {
        if (String.isBlank(sourceFileContentDocId)) return null;
        if (!Schema.sObjectType.ContentVersion.isAccessible()) return null;
        List<ContentVersion> cv = [
            SELECT Title, FileExtension
            FROM   ContentVersion
            WHERE  ContentDocumentId = :sourceFileContentDocId
            AND    IsLatest = true
            LIMIT  1
        ];
        if (cv.isEmpty()) return null;
        String title = cv[0].Title;
        if (String.isNotBlank(cv[0].FileExtension)
                && !title.toLowerCase().endsWith('.' + cv[0].FileExtension.toLowerCase())) {
            title += '.' + cv[0].FileExtension;
        }
        return title;
    }

    private static Id getLatestContentVersionId(Id contentDocumentId) {
        if (!Schema.sObjectType.ContentVersion.isAccessible()) return null;
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
        if (!Schema.sObjectType.Policy_Document__c.isAccessible()
                || !Schema.sObjectType.ContentVersion.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        List<Policy_Document__c> pds = [
            SELECT Id, Name, Domain__c, Status__c, Chunk_Count__c, Corpus_Version__c,
                   Failure_Reason__c, Ingested_Date__c, CreatedDate, Source_File__c
            FROM   Policy_Document__c
            ORDER  BY CreatedDate DESC
            LIMIT  200
        ];

        // Bulk-resolve the real uploaded filename from ContentVersion (Source_File__c
        // is the ContentDocumentId) — Name is just the POL-0000 auto-number, not
        // what the user actually uploaded.
        Set<Id> contentDocIds = new Set<Id>();
        for (Policy_Document__c pd : pds) {
            if (String.isNotBlank(pd.Source_File__c)) contentDocIds.add(pd.Source_File__c);
        }
        Map<Id, String> fileNameByContentDocId = new Map<Id, String>();
        if (!contentDocIds.isEmpty()) {
            for (ContentVersion cv : (List<ContentVersion>) Security.stripInaccessible(AccessType.READABLE, [
                SELECT ContentDocumentId, Title, FileExtension
                FROM   ContentVersion
                WHERE  ContentDocumentId IN :contentDocIds
                AND    IsLatest = true
            ]).getRecords()) {
                String title = cv.Title;
                if (String.isNotBlank(cv.FileExtension)
                        && !title.toLowerCase().endsWith('.' + cv.FileExtension.toLowerCase())) {
                    title += '.' + cv.FileExtension;
                }
                fileNameByContentDocId.put(cv.ContentDocumentId, title);
            }
        }

        List<PolicyDocumentRow> rows = new List<PolicyDocumentRow>();
        for (Policy_Document__c pd : pds) {
            PolicyDocumentRow row = new PolicyDocumentRow();
            row.id            = pd.Id;
            row.name          = String.isNotBlank(pd.Source_File__c) && fileNameByContentDocId.containsKey(pd.Source_File__c)
                                     ? fileNameByContentDocId.get(pd.Source_File__c)
                                     : pd.Name;   // fallback: auto-number, e.g. mid-upload before a file exists
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