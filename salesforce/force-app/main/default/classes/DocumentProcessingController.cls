public without sharing class DocumentProcessingController {

    @TestVisible private static final Boolean AUDIT_ENABLED = false;

    // ─── saveFile ─────────────────────────────────────────────────────────────
    /**
     * Save an uploaded file as a ContentVersion linked to the given record, and
     * return its ContentDocumentId. Used by the custom compact uploader
     * (scDocumentUploaderRow) which replaced lightning-file-upload, so the
     * parent receives the same { documentId, name } shape it always did.
     */
    @AuraEnabled
    public static String saveFile(String recordId, String fileName, String base64Data) {
        if (String.isBlank(recordId) || String.isBlank(base64Data)) {
            throw new AuraHandledException('recordId and file data are required.');
        }
        ContentVersion cv = new ContentVersion(
            Title        = fileName,
            PathOnClient = fileName,
            VersionData  = EncodingUtil.base64Decode(base64Data),
            Origin       = 'H'
        );
        insert cv;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1]
                   .ContentDocumentId;
        insert new ContentDocumentLink(
            ContentDocumentId = docId,
            LinkedEntityId    = recordId,
            ShareType         = 'V',
            Visibility        = 'AllUsers'
        );
        return docId;
    }

    // ─── linkDocumentToCompliance ─────────────────────────────────────────────
    /**
     * Called by scDocumentUploader.js after lightning-file-upload fires
     * onuploadfinished.
     *
     * At the point this method is called:
     *  - ContentDocument exists (created by lightning-file-upload)
     *  - ContentDocumentLink (ContentDocument → Account) exists
     *  - We need to: create Compliance_Document__c, add a second CDL to it,
     *    update the Compliance_Assessment__c, publish Platform Event.
     *
     * @param accountId          Supplier Account Id
     * @param contentDocumentId  ContentDocument.Id from event.detail.files[0].documentId
     * @param documentType       Requirement key / document type string
     * @param assessmentId       Compliance_Assessment__c.Id to update
     * @param fileName           Original file name for audit
     * @return                   Compliance_Document__c.Id
     */
    @AuraEnabled(cacheable=false)
    public static String linkDocumentToCompliance(
        String accountId,
        String contentDocumentId,
        String documentType,
        String assessmentId,
        String fileName
    ) {
        try {
            // ── Validate ───────────────────────────────────────────────────
            if (String.isBlank(accountId) || String.isBlank(contentDocumentId)) {
                throw new AuraHandledException(
                    'accountId and contentDocumentId are required.'
                );
            }

            // ── Find or create Compliance_Document__c ──────────────────────
            List<Compliance_Document__c> existing = [
                SELECT Id, Status__c
                FROM   Compliance_Document__c
                WHERE  Account__c       = :accountId
                AND    Document_Type__c = :documentType
                AND    Status__c        IN ('Pending', 'Rejected')
                ORDER  BY CreatedDate DESC
                LIMIT  1
            ];

            Compliance_Document__c compDoc;

            if (!existing.isEmpty() && existing[0].Status__c == 'Pending') {
                // Reuse the existing Pending shell created by the rule engine
                compDoc = existing[0];
                compDoc.Upload_Channel__c      = 'Portal';
                compDoc.Uploaded_By_Contact__c = getPortalContactId();
                update compDoc;
            } else {
                String docName = documentType.contains(';')
                    ? documentType.substringBefore(';').trim()
                    : documentType;
                if (docName.length() > 80) docName = docName.left(80);
                compDoc = new Compliance_Document__c(
                    Name                   = docName,
                    Account__c             = accountId,
                    Document_Type__c       = documentType,
                    Status__c              = 'Pending',
                    Upload_Channel__c      = 'Portal',
                    Uploaded_By_Contact__c = getPortalContactId()
                );
                insert compDoc;
            }

            // ── Add ContentDocumentLink to Compliance_Document__c ──────────
            // lightning-file-upload already created CDL → Account.
            // We add a SECOND CDL → Compliance_Document__c so the file
            // appears on the compliance record and is queryable from it.
            List<ContentDocumentLink> existingCDL = [
                SELECT Id FROM ContentDocumentLink
                WHERE  ContentDocumentId = :contentDocumentId
                AND    LinkedEntityId    = :compDoc.Id
                LIMIT  1
            ];
            if (existingCDL.isEmpty()) {
                insert new ContentDocumentLink(
                    ContentDocumentId = contentDocumentId,
                    LinkedEntityId    = compDoc.Id,
                    ShareType         = 'V',
                    Visibility        = 'AllUsers'
                );
            }

            // ── Update Compliance_Assessment__c ────────────────────────────
            if (String.isNotBlank(assessmentId)) {
                update new Compliance_Assessment__c(
                    Id                     = assessmentId,
                    Compliance_Document__c = compDoc.Id,
                    Reason_Detail__c       = 'Document received — pending AI extraction'
                );
            }

            // ── Set Source_File__c on the Compliance_Document__c ──────────
            update new Compliance_Document__c(
                Id             = compDoc.Id,
                Source_File__c = contentDocumentId
            );

            // ── Resolve ContentVersion Id ──────────────────────────────────
            // ContentVersion.IsLatest is set synchronously on file creation
            // in standard orgs. If it returns null the upload was incomplete;
            // throw so the LWC shows an actionable error rather than silently
            // publishing an event that the queueable cannot process.
            Id cvId = getLatestContentVersionId(contentDocumentId);
            if (cvId == null) {
                throw new AuraHandledException(
                    'Could not locate the uploaded file version (ContentVersion). '
                    + 'The file may not have finished uploading. Please try again.'
                );
            }

            // ── Trigger the AI assessment DIRECTLY ─────────────────────────
            // Previously this published Document_Uploaded__e for a flow to pick
            // up and enqueue DocAssessQueueable — but that platform-event hop was
            // misfiring (assessments stuck on Pending). Enqueue the queueable
            // straight away: reliable, no flow dependency. DocAssessQueueable does
            // the /assess callout and writes the verdict back onto the assessment.
            System.enqueueJob(new DocAssessQueueable(
                compDoc.Id, cvId, accountId, documentType, assessmentId));

            // ── Audit log ──────────────────────────────────────────────────
            if (AUDIT_ENABLED) {
                AuditLogService.logDocumentReceived(
                    compDoc.Id, accountId, documentType, fileName
                );
            }

            return compDoc.Id;

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to link document: ' + e.getMessage());
        }
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    /**
     * Returns the Contact Id of the currently running user if they are
     * an Experience Cloud portal user. Returns null for internal users.
     */
    private static Id getPortalContactId() {
        String userType = UserInfo.getUserType();
        if (userType == 'PowerCustomerSuccess'
                || userType == 'PowerPartner'
                || userType == 'CustomerSuccess') {
            List<User> u = [
                SELECT ContactId FROM User
                WHERE  Id        = :UserInfo.getUserId()
                AND    ContactId != null
                LIMIT  1
            ];
            return u.isEmpty() ? null : u[0].ContactId;
        }
        return null;
    }

    /**
     * Returns the most recent ContentVersion Id for the given ContentDocument.
     * Required by AIExtractionQueueable to access VersionData (the file bytes).
     */
    private static Id getLatestContentVersionId(Id contentDocumentId) {
        List<ContentVersion> cv = [
            SELECT Id FROM ContentVersion
            WHERE  ContentDocumentId = :contentDocumentId
            AND    IsLatest          = true
            LIMIT  1
        ];
        return cv.isEmpty() ? null : cv[0].Id;
    }

    // ─── removeDocumentFromCompliance ─────────────────────────────────────────
    /**
     * Called when the supplier clicks "Remove" on an uploaded document.
     *
     * Steps:
     *  1. Delete ContentDocumentLink → Compliance_Document__c
     *     (removes the file from the compliance record but keeps it on Account)
     *  2. Reset Compliance_Document__c.Status__c back to Pending
     *     and clear Source_File__c so the row is ready for re-upload
     *  3. Reset Compliance_Assessment__c.Status__c back to Pending
     *     and clear Compliance_Document__c lookup so it shows as unsubmitted
     *
     * We do NOT delete the ContentDocument itself — the file stays on the
     * Account record so the supplier's upload history is preserved.
     *
     * @param complianceDocId   Compliance_Document__c.Id to reset
     * @param assessmentId      Compliance_Assessment__c.Id to reset
     * @return                  'success' on completion
     */
    @AuraEnabled(cacheable=false)
    public static String removeDocumentFromCompliance(
        String complianceDocId,
        String assessmentId
    ) {
        try {
            if (String.isBlank(complianceDocId)) {
                throw new AuraHandledException('complianceDocId is required.');
            }

            // ── 1. Remove CDL from Compliance_Document__c ─────────────────
            // This unlinks the file from the compliance record.
            // The CDL to Account remains — file stays visible on the Account.
            List<ContentDocumentLink> cdlsToDelete = [
                SELECT Id FROM ContentDocumentLink
                WHERE  LinkedEntityId = :complianceDocId
                LIMIT  50
            ];
            if (!cdlsToDelete.isEmpty()) {
                delete cdlsToDelete;
            }

            // ── 2. Reset Compliance_Document__c ───────────────────────────
            update new Compliance_Document__c(
                Id                  = complianceDocId,
                Status__c           = 'Pending',
                Source_File__c      = null,
                Confidence_Score__c = null,
                Notes__c            = 'Document removed by supplier — awaiting re-upload'
            );

            // ── 3. Reset Compliance_Assessment__c ─────────────────────────
            if (String.isNotBlank(assessmentId)) {
                update new Compliance_Assessment__c(
                    Id                     = assessmentId,
                    Status__c              = 'Pending',
                    Compliance_Document__c = null,
                    Reason_Code__c         = 'Missing Document',
                    Reason_Detail__c       = 'Document removed — awaiting re-upload'
                );
            }

            return 'success';

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(
                'Failed to remove document: ' + e.getMessage()
            );
        }
    }

    // ─── getProcessingStatus ─────────────────────────────────────────────────
    /**
     * Called by scDocumentUploader to poll for AI pipeline completion.
     *
     * Returns the current Compliance_Document__c.Status__c (set by
     * AIExtractionQueueable / AuthoritativeVerificationQueueable) and the
     * Compliance_Assessment__c.Status__c + Reason_Detail__c (set by
     * ComplianceEvaluationQueueable — the last step in the chain).
     *
     * The LWC polls this every 5 s. Once assessmentStatus != 'Pending' the
     * full chain has completed and polling stops.
     *
     * @param complianceDocId   Compliance_Document__c.Id
     * @param assessmentId      Compliance_Assessment__c.Id
     * @return Map with docStatus, assessmentStatus, reasonDetail
     */
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getProcessingStatus(
        String complianceDocId,
        String assessmentId
    ) {
        Map<String, Object> result = new Map<String, Object>{
            'docStatus'        => null,
            'assessmentStatus' => null,
            'reasonDetail'     => null
        };

        if (String.isNotBlank(complianceDocId)) {
            List<Compliance_Document__c> docs = [
                SELECT Status__c
                FROM   Compliance_Document__c
                WHERE  Id = :complianceDocId
                LIMIT  1
            ];
            if (!docs.isEmpty()) {
                result.put('docStatus', docs[0].Status__c);
            }
        }

        if (String.isNotBlank(assessmentId)) {
            List<Compliance_Assessment__c> assessments = [
                SELECT Status__c, Reason_Detail__c
                FROM   Compliance_Assessment__c
                WHERE  Id = :assessmentId
                LIMIT  1
            ];
            if (!assessments.isEmpty()) {
                result.put('assessmentStatus', assessments[0].Status__c);
                result.put('reasonDetail',     assessments[0].Reason_Detail__c);
            }
        }

        return result;
    }

    // ─── getChecklistWithDocStatus ────────────────────────────────────────────
    /**
     * Called by scProcurementDocumentUploader (internal Account record page).
     *
     * Returns all Compliance_Assessment__c rows for a supplier Account,
     * each enriched with the current Compliance_Document__c state so
     * the procurement UI can show:
     *   - Upload button  (no document yet)
     *   - Uploaded badge (document exists, Pending or Validated)
     *   - Rejected badge (document exists but Rejected — re-upload needed)
     *
     * Read-only — no DML, no callouts.
     */
    @AuraEnabled(cacheable=false)
    public static List<ChecklistRow> getChecklistWithDocStatus(Id accountId) {
        if (accountId == null) {
            throw new AuraHandledException('accountId is required');
        }

        // Load assessments + linked document in one pass via subquery
        Map<Id, Compliance_Document__c> docByAssessmentId =
            new Map<Id, Compliance_Document__c>();

        List<Compliance_Assessment__c> assessments = [
            SELECT  Id,
                    Requirement_Key__c,
                    Requirement_Label__c,
                    Status__c,
                    Severity__c,
                    Reason_Code__c,
                    Reason_Detail__c,
                    Compliance_Document__c,
                    Evaluation_DateTime__c
            FROM    Compliance_Assessment__c
            WHERE   Supplier__c = :accountId
            ORDER BY Requirement_Label__c ASC
        ];

        // Collect linked document IDs and fetch them
        Set<Id> docIds = new Set<Id>();
        for (Compliance_Assessment__c a : assessments) {
            if (a.Compliance_Document__c != null) docIds.add(a.Compliance_Document__c);
        }

        Map<Id, Compliance_Document__c> docsById = new Map<Id, Compliance_Document__c>();
        if (!docIds.isEmpty()) {
            for (Compliance_Document__c d : [
                SELECT  Id, Name, Status__c, Document_Type__c,
                        Confidence_Score__c, CreatedDate,
                        Expiry_Date__c, Notes__c, Source_File__c
                FROM    Compliance_Document__c
                WHERE   Id IN :docIds
            ]) {
                docsById.put(d.Id, d);
            }
        }

        // Pre-load CMT DeveloperName → Document_Type__c so every row carries
        // the canonical document type (e.g. "IATF 16949 Certificate") rather
        // than the internal composite key ("supplierId__RULE_X_001").
        Map<String, String> devNameToDocType = new Map<String, String>();
        for (Compliance_Requirement__mdt cmt : [
            SELECT DeveloperName, Document_Type__c
            FROM   Compliance_Requirement__mdt
            WHERE  Document_Type__c != null
        ]) {
            devNameToDocType.put(cmt.DeveloperName, cmt.Document_Type__c);
        }

        List<ChecklistRow> rows = new List<ChecklistRow>();
        for (Compliance_Assessment__c a : assessments) {
            Compliance_Document__c doc =
                a.Compliance_Document__c != null
                ? docsById.get(a.Compliance_Document__c)
                : null;

            // Strip the "{accountId}__" prefix to get the CMT DeveloperName,
            // then resolve the canonical document type label.
            String reqKey = a.Requirement_Key__c;
            String cmtDevName = (reqKey != null && reqKey.contains('__'))
                ? reqKey.substringAfter('__')
                : reqKey;
            String canonicalDocType = devNameToDocType.containsKey(cmtDevName)
                ? devNameToDocType.get(cmtDevName)
                : cmtDevName;

            ChecklistRow row = new ChecklistRow();
            row.assessmentId       = a.Id;
            row.requirementKey     = a.Requirement_Key__c;
            row.requirementLabel   = a.Requirement_Label__c;
            row.assessmentStatus   = a.Status__c;
            row.severity           = a.Severity__c;
            row.reasonDetail       = a.Reason_Detail__c;
            row.documentType       = canonicalDocType;

            if (doc != null) {
                row.hasDocument        = true;
                row.documentId         = doc.Id;
                row.documentName       = doc.Name;
                row.documentStatus     = doc.Status__c;
                row.confidenceScore    = doc.Confidence_Score__c;
                row.uploadedDate       = doc.CreatedDate;
                row.expiryDate         = doc.Expiry_Date__c;
                row.rejectionNote      = (doc.Status__c == 'Rejected') ? doc.Notes__c : null;
            } else {
                row.hasDocument        = false;
            }

            rows.add(row);
        }

        System.debug('Checklist rows with document status: ' + JSON.serialize(rows));
        return rows;
    }

    /** DTO returned to scProcurementDocumentUploader */
    public class ChecklistRow {
        @AuraEnabled public String   assessmentId;
        @AuraEnabled public String   requirementKey;
        @AuraEnabled public String   requirementLabel;
        @AuraEnabled public String   assessmentStatus;
        @AuraEnabled public String   severity;
        @AuraEnabled public String   reasonDetail;
        @AuraEnabled public Boolean  hasDocument;
        @AuraEnabled public String   documentId;
        @AuraEnabled public String   documentName;
        @AuraEnabled public String   documentStatus;
        @AuraEnabled public String   documentType;
        @AuraEnabled public Decimal  confidenceScore;
        @AuraEnabled public DateTime uploadedDate;
        @AuraEnabled public Date     expiryDate;
        @AuraEnabled public String   rejectionNote;
    }
}