/**
 * DocumentProcessingController
 * ═══════════════════════════════════════════════════════════════════════════
 * CRUD/FLS model — same as VendorPortalController (see its header):
 *  • Internal entry points check the running user's object permissions with
 *    literal Schema.sObjectType.X.isX() guards and use stripInaccessible for
 *    fire-and-forget writes.
 *  • without sharing is retained (documents belong to Accounts whose OWD is
 *    Private, yet Procurement/Analysts work every supplier's uploads).
 *  • The guest upload path (*ByToken, token re-verified on every call) runs
 *    the shared private *Impl/Internal methods in system context by design —
 *    the guest user holds no object permissions. Those sites (saveFileImpl,
 *    linkDocumentToComplianceInternal, getLatestContentVersionId) are the
 *    documented exceptions in the review's false-positive list.
 */
public without sharing class DocumentProcessingController {

    @TestVisible private static final Boolean AUDIT_ENABLED = false;

    private static final String NO_ACCESS =
        'You do not have permission to perform this action.';

    // ─── saveFile ─────────────────────────────────────────────────────────────
    /**
     * Save an uploaded file as a ContentVersion linked to the given record, and
     * return its ContentDocumentId. Used by the custom compact uploader
     * (scDocumentUploaderRow) which replaced lightning-file-upload, so the
     * parent receives the same { documentId, name } shape it always did.
     */
    @AuraEnabled
    public static String saveFile(String recordId, String fileName, String base64Data) {
        if (!Schema.sObjectType.ContentVersion.isCreateable()
                || !Schema.sObjectType.ContentVersion.isAccessible()
                || !Schema.sObjectType.ContentDocumentLink.isCreateable()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        return saveFileImpl(recordId, fileName, base64Data);
    }

    // Shared with saveFileByToken (guest, token-verified) — system context by
    // design, see class header.
    @SuppressWarnings('PMD.ApexCRUDViolation') // guest token path — see class header
    private static String saveFileImpl(String recordId, String fileName, String base64Data) {
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
        if (!Schema.sObjectType.Compliance_Assessment__c.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isUpdateable()
                || !Schema.sObjectType.Compliance_Document__c.isAccessible()
                || !Schema.sObjectType.Compliance_Document__c.isCreateable()
                || !Schema.sObjectType.Compliance_Document__c.isUpdateable()
                || !Schema.sObjectType.Compliance_Document_Link__c.isAccessible()
                || !Schema.sObjectType.Compliance_Document_Link__c.isCreateable()
                || !Schema.sObjectType.Compliance_Document_Link__c.isUpdateable()
                || !Schema.sObjectType.ContentDocumentLink.isAccessible()
                || !Schema.sObjectType.ContentDocumentLink.isCreateable()
                || !Schema.sObjectType.ContentVersion.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        return linkDocumentToComplianceInternal(accountId, contentDocumentId, documentType, assessmentId, fileName, 'replace');
    }

    // Multi-document-per-requirement: adds this file as ADDITIONAL evidence
    // for a requirement that may already have one or more other files linked
    // (via a new Compliance_Document_Link__c junction row), instead of
    // replacing the requirement's single file — see linkDocumentToComplianceInternal's
    // 'add' mode. Apex doesn't allow overloading an @AuraEnabled method, so
    // this is a distinctly-named entry point rather than a 6th parameter on
    // linkDocumentToCompliance.
    @AuraEnabled(cacheable=false)
    public static String addDocumentToCompliance(
        String accountId,
        String contentDocumentId,
        String documentType,
        String assessmentId,
        String fileName
    ) {
        if (!Schema.sObjectType.Compliance_Assessment__c.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isUpdateable()
                || !Schema.sObjectType.Compliance_Document__c.isAccessible()
                || !Schema.sObjectType.Compliance_Document__c.isCreateable()
                || !Schema.sObjectType.Compliance_Document__c.isUpdateable()
                || !Schema.sObjectType.Compliance_Document_Link__c.isAccessible()
                || !Schema.sObjectType.Compliance_Document_Link__c.isCreateable()
                || !Schema.sObjectType.Compliance_Document_Link__c.isUpdateable()
                || !Schema.sObjectType.ContentDocumentLink.isAccessible()
                || !Schema.sObjectType.ContentDocumentLink.isCreateable()
                || !Schema.sObjectType.ContentVersion.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        return linkDocumentToComplianceInternal(accountId, contentDocumentId, documentType, assessmentId, fileName, 'add');
    }

    // mode:
    //   'replace' — repoints the requirement's single Compliance_Document__c
    //   pointer, same as always (renewal, re-upload after rejection — these
    //   genuinely mean "this IS the new version of the one file", not "here's
    //   an additional file").
    //   'add' — multi-document-per-requirement: this file is ADDITIONAL
    //   evidence for a requirement that may already have one or more other
    //   files linked, via a new Compliance_Document_Link__c junction row.
    //   The requirement's own Compliance_Document__c pointer is left as
    //   whatever it already was (or set to this file if it had none), purely
    //   for backward-compat with any code still reading that single field —
    //   the real per-file data now lives on the junction rows.
    @SuppressWarnings('PMD.ApexCRUDViolation') // guest token path — see class header
    private static String linkDocumentToComplianceInternal(
        String accountId,
        String contentDocumentId,
        String documentType,
        String assessmentId,
        String fileName,
        String mode
    ) {
        try {
            // ── Validate ───────────────────────────────────────────────────
            if (String.isBlank(accountId) || String.isBlank(contentDocumentId)) {
                throw new AuraHandledException(
                    'accountId and contentDocumentId are required.'
                );
            }
            Boolean isAdd = (mode == 'add');

            // ── Find or create Compliance_Document__c ──────────────────────
            // 'add' mode ALWAYS creates a fresh shell — this file is
            // additional evidence, never a replacement, so there is no
            // "reuse the existing Pending shell" case to consider (that
            // reuse logic exists specifically for the single-file-replace
            // flows: renewal, re-upload after rejection).
            //
            // 'replace' mode (default): when the caller passes an
            // assessmentId, check what document is CURRENTLY linked to that
            // exact assessment first — this is how a renewal (handleRenewClick)
            // targets an expired-but-Compliant document: its status is
            // neither Pending nor Rejected, so the status-filtered lookup
            // below would never find it and would silently create a
            // duplicate Compliance_Document__c shell every renewal cycle
            // instead of reusing the one slot for this requirement. Any
            // status is reusable here — the document is being explicitly
            // replaced by the assessment that already owns it, not matched
            // by guesswork.
            Compliance_Document__c compDoc;
            if (!isAdd && String.isNotBlank(assessmentId)) {
                List<Compliance_Assessment__c> linked = [
                    SELECT Compliance_Document__c
                    FROM   Compliance_Assessment__c
                    WHERE  Id = :assessmentId
                    AND    Compliance_Document__c != null
                    LIMIT  1
                ];
                if (!linked.isEmpty()) {
                    compDoc = new Compliance_Document__c(Id = linked[0].Compliance_Document__c);
                }
            }

            if (compDoc == null) {
                List<Compliance_Document__c> existing = isAdd ? new List<Compliance_Document__c>() : [
                    SELECT Id, Status__c
                    FROM   Compliance_Document__c
                    WHERE  Account__c       = :accountId
                    AND    Document_Type__c = :documentType
                    AND    Status__c        IN ('Pending', 'Rejected')
                    ORDER  BY CreatedDate DESC
                    LIMIT  1
                ];

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
            }

            // ── Reset a reused document shell back to Pending ──────────────
            // Only applies to the assessment-linked reuse path above (a
            // renewal reusing an expired/Compliant/Non-Compliant shell) — the
            // Pending-status branch already resets nothing further because it
            // was already Pending, and the newly-inserted branch already
            // starts at Pending.
            if (compDoc.Status__c != 'Pending') {
                compDoc.Status__c = 'Pending';
                update compDoc;
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

            // ── Update Compliance_Assessment__c / create the junction row ──
            Id docLinkId;
            if (isAdd) {
                // Multi-doc: this file joins whatever's already linked to the
                // requirement via a NEW Compliance_Document_Link__c row —
                // the requirement's own Status__c/Reason_Detail__c are NOT
                // touched here; they stay whatever the worst-wins rollup last
                // computed until THIS file's own assessment completes and
                // triggers a fresh rollup (see RiskScoreService-adjacent
                // rollup in Compliance_Assessment__c... rollup logic lives in
                // DocAssessQueueable once this file's own verdict lands).
                // The single Compliance_Document__c pointer is backfilled
                // only if the requirement had none at all yet, purely so any
                // remaining single-file-model reader isn't left with a null.
                if (String.isNotBlank(assessmentId)) {
                    Compliance_Assessment__c ca = [
                        SELECT Compliance_Document__c FROM Compliance_Assessment__c WHERE Id = :assessmentId LIMIT 1
                    ];
                    if (ca.Compliance_Document__c == null) {
                        update new Compliance_Assessment__c(Id = assessmentId, Compliance_Document__c = compDoc.Id);
                    }
                    Compliance_Document_Link__c link = new Compliance_Document_Link__c(
                        Compliance_Assessment__c = assessmentId,
                        Compliance_Document__c   = compDoc.Id,
                        Status__c                = 'Pending',
                        Reason_Detail__c         = 'Document received — pending AI extraction'
                    );
                    insert link;
                    docLinkId = link.Id;
                }
            } else if (String.isNotBlank(assessmentId)) {
                // Mark any Compliance_Document_Link__c rows already tied to
                // this requirement (from an earlier "Add another file") as
                // Superseded — they used to be left completely untouched by a
                // replace, so a stale Rejected/Non-Compliant sub-row from a
                // PRIOR file kept showing under the requirement forever, even
                // after the requirement's own top-level status reset to
                // Pending for the new file. Superseded rows are excluded from
                // both the consoles' linked-document display
                // (getDocumentLinksByAssessment) and the worst-wins rollup
                // (DocAssessQueueable.rollupRequirementStatus), so history is
                // kept (not deleted) but stops influencing anything live.
                List<Compliance_Document_Link__c> priorLinks = [
                    SELECT Id FROM Compliance_Document_Link__c
                    WHERE  Compliance_Assessment__c = :assessmentId
                    AND    Status__c != 'Superseded'
                ];
                if (!priorLinks.isEmpty()) {
                    for (Compliance_Document_Link__c l : priorLinks) l.Status__c = 'Superseded';
                    update priorLinks;
                }

                // Clear any prior Procurement Approve/Reject/Deferred decision
                // — it was made against the file being replaced, not this new
                // one, so the UI must offer the decision buttons again instead
                // of showing a decision that no longer applies. The full
                // comment history (Audit_Log__c, see recordProcurementDecision)
                // is untouched — only this "current decision" pointer resets.
                //
                // Status__c is ALSO reset to Pending here — previously this
                // was left untouched, so the status pill kept showing the OLD
                // document's verdict (e.g. a stale "Non-Compliant") for the
                // several seconds between re-upload and DocAssessQueueable
                // actually writing the new one, reading as "the re-upload
                // didn't do anything." Pending is honest about the real state
                // (no fresh verdict yet) instead of showing a wrong one.
                // Analyst_Validated__c/_Comment__c reset for the same reason
                // as the Procurement fields above: they were recorded against
                // the file being replaced, not this new one. Previously left
                // untouched, so a re-uploaded (unreviewed) file still showed
                // as "validated" by the Analyst — and since the Supplier
                // Portal's own re-upload button visibility depends on
                // Status__c (now correctly reset to Pending above), a
                // lingering Analyst_Validated__c=true here didn't block that,
                // but WOULD have misrepresented the new file's real review
                // state everywhere else that reads it (getCaseForAnalyst,
                // the Analyst's own list "validated" count).
                update new Compliance_Assessment__c(
                    Id                                = assessmentId,
                    Compliance_Document__c            = compDoc.Id,
                    Status__c                         = 'Pending',
                    Reason_Detail__c                  = 'Document received — pending AI extraction',
                    Procurement_Decision__c            = null,
                    Procurement_Decision_Reason__c      = null,
                    Procurement_Decision_By__c          = null,
                    Procurement_Decision_DateTime__c    = null,
                    Analyst_Validated__c               = false,
                    Analyst_Comment__c                 = null
                );
            }

            // Log every upload as its own dated entry in the SAME thread as
            // Procurement's decisions and the supplier's replies (see
            // getSupplierSnapshot's bulk Audit_Log__c query) — Reason__c holds
            // the requirement's document name (documentType), not the raw
            // uploaded filename, so the history reads "Uploaded <document
            // name>" regardless of what the file itself was called. Logged for
            // BOTH branches above (multi-doc add and single-doc replace).
            if (String.isNotBlank(assessmentId)) {
                AuditLogService.write(new Audit_Log__c(
                    Event_Type__c        = 'Document_Uploaded',
                    Related_Object__c    = 'Compliance_Assessment',
                    Related_Record_Id__c = assessmentId,
                    Event_DateTime__c    = DateTime.now(),
                    Actor_Type__c        = 'User',
                    Actor_User__c        = VendorPortalController.isSupplierRunningUser() ? null : UserInfo.getUserId(),
                    Source_System__c     = 'Other',
                    // The actual uploaded file's name (e.g. "SelfAssessment_..._Nordwind.txt"),
                    // not the requirement/document-type label — history reads
                    // "Uploaded <file name>".
                    Reason__c             = fileName
                ));
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
            // the /assess callout and writes the verdict back onto the assessment
            // (or, in 'add' mode, onto this specific Compliance_Document_Link__c
            // row, then rolls the requirement's own Status__c up from all its
            // linked documents).
            //
            // Only when assessmentId is known — a truly unmatched upload (no
            // fuzzy match, not yet manually Connected) has no requirement to
            // assess against. DocAssessQueueable's own blank-assessmentId
            // fallback used to paper over that by inventing a BRAND NEW
            // Compliance_Assessment__c named after the raw filename, which
            // silently inflated the checklist count (e.g. 3 required
            // documents becoming 4) and could never be reconciled with the
            // real requirement the supplier later connected the same file to
            // via the "Connect" flow. Leaving the file unassessed here keeps
            // it sitting in "Unmatched documents" until a human (or a
            // successful fuzzy match) supplies a real assessmentId.
            if (String.isNotBlank(assessmentId)) {
                System.enqueueJob(new DocAssessQueueable(
                    compDoc.Id, cvId, accountId, documentType, assessmentId, docLinkId));
            }

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

    // ─── Guest-portal token-verified wrappers (security fix) ──────────────────
    // saveFile/linkDocumentToCompliance take a plain recordId/accountId with no
    // check that the caller is actually authorized for that record — fine for
    // the authenticated Procurement console, but the guest supplier portal
    // used to call these directly with a client-held accountId that was never
    // re-verified against the caller's actual token. Same fix pattern as
    // VendorPortalController's *ByToken wrappers: re-resolve accountId from
    // the token on every call instead of trusting what the client sends.
    @AuraEnabled
    public static String saveFileByToken(String token, String fileName, String base64Data) {
        Id accountId = VendorPortalController.verifyPortalTokenId(token);
        return saveFileImpl(accountId, fileName, base64Data);
    }

    @AuraEnabled(cacheable=false)
    public static String linkDocumentToComplianceByToken(
        String token,
        String contentDocumentId,
        String documentType,
        String assessmentId,
        String fileName
    ) {
        Id accountId = VendorPortalController.verifyPortalTokenId(token);
        return linkDocumentToComplianceInternal(accountId, contentDocumentId, documentType, assessmentId, fileName, 'replace');
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
            if (!Schema.sObjectType.User.isAccessible()) return null;
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
     * Reached only through linkDocumentToComplianceInternal (guarded internal
     * entry or token-verified guest path) — see class header.
     */
    @SuppressWarnings('PMD.ApexCRUDViolation') // guest token path — see class header
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
            if (!Schema.sObjectType.ContentDocumentLink.isAccessible()
                    || !Schema.sObjectType.ContentDocumentLink.isDeletable()
                    || !Schema.sObjectType.Compliance_Document__c.isUpdateable()
                    || !Schema.sObjectType.Compliance_Assessment__c.isUpdateable()) {
                throw new AuraHandledException(NO_ACCESS);
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
            update Security.stripInaccessible(AccessType.UPDATABLE, new List<Compliance_Document__c>{
                new Compliance_Document__c(
                    Id                  = complianceDocId,
                    Status__c           = 'Pending',
                    Source_File__c      = null,
                    Confidence_Score__c = null,
                    Notes__c            = 'Document removed by supplier — awaiting re-upload'
                )
            }).getRecords();

            // ── 3. Reset Compliance_Assessment__c ─────────────────────────
            if (String.isNotBlank(assessmentId)) {
                update Security.stripInaccessible(AccessType.UPDATABLE, new List<Compliance_Assessment__c>{
                    new Compliance_Assessment__c(
                        Id                     = assessmentId,
                        Status__c              = 'Pending',
                        Compliance_Document__c = null,
                        Reason_Code__c         = 'Missing Document',
                        Reason_Detail__c       = 'Document removed — awaiting re-upload'
                    )
                }).getRecords();
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
        if (!Schema.sObjectType.Compliance_Document__c.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }

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
        if (!Schema.sObjectType.Compliance_Assessment__c.isAccessible()
                || !Schema.sObjectType.Compliance_Document__c.isAccessible()
                || !Schema.sObjectType.Compliance_Requirement__mdt.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
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
            for (Compliance_Document__c d : (List<Compliance_Document__c>) Security.stripInaccessible(AccessType.READABLE, [
                SELECT  Id, Name, Status__c, Document_Type__c,
                        Confidence_Score__c, CreatedDate,
                        Expiry_Date__c, Notes__c, Source_File__c
                FROM    Compliance_Document__c
                WHERE   Id IN :docIds
            ]).getRecords()) {
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