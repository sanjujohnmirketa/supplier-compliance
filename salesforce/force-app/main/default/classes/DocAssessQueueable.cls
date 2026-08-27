/**
 * DocAssessQueueable
 * ═══════════════════════════════════════════════════════════════════════════
 * RAG replacement for AIExtractionQueueable. Triggered by the
 * Document_Upload_Event_Handler flow on Document_Uploaded__e — same invocable
 * inputs, so the flow rebinds with no payload change.
 *
 * Per uploaded document it:
 *   1. Loads the ContentVersion file (base64)
 *   2. Calls the local /assess RAG service (DocAssessService) — which extracts
 *      text, retrieves policy clauses, and an LLM renders a grounded verdict
 *   3. Writes a DRAFT finding to the supplier's Compliance_Assessment__c for the
 *      document's (service-resolved) domain — idempotent upsert on
 *      Requirement_Key__c = <supplierId>__SCOPE_<domain>; creates the row if the
 *      checklist didn't already have it (so unexpected evidence is never lost)
 *   4. Audit_Log__c entry with the AI model + confidence
 *
 * Autonomy L2 — DRAFTS the finding. Evaluated_By__c='Auto' marks it machine-
 * generated; an analyst confirms or flips it to Manual_Override (the human gate).
 *
 * Callout ordering: SOQL (load file) → callout (/assess) → DML. No DML before
 * the callout.
 */
public without sharing class DocAssessQueueable
        implements Queueable, Database.AllowsCallouts {

    private final String complianceDocId;
    private final String contentVersionId;
    private final String supplierId;
    private final String documentTypeHint;
    private final String assessmentId;   // the checklist row to update (may be null)
    private final Id     docLinkId;      // multi-doc: this file's own Compliance_Document_Link__c row (may be null)

    public DocAssessQueueable(
        String complianceDocId,
        String contentVersionId,
        String supplierId,
        String documentTypeHint
    ) {
        this(complianceDocId, contentVersionId, supplierId, documentTypeHint, null);
    }

    // Preferred constructor: pass the assessmentId of the checklist row that was
    // set to 'Pending' at upload, so the verdict updates THAT row (not a separate
    // domain-keyed row — which left the original 'Pending' row stuck forever).
    public DocAssessQueueable(
        String complianceDocId,
        String contentVersionId,
        String supplierId,
        String documentTypeHint,
        String assessmentId
    ) {
        this(complianceDocId, contentVersionId, supplierId, documentTypeHint, assessmentId, null);
    }

    // Multi-document-per-requirement: docLinkId is this file's own
    // Compliance_Document_Link__c row (set when DocumentProcessingController.
    // linkDocumentToCompliance ran in 'add' mode) — when present, the verdict
    // is written to THAT junction row instead of directly onto the
    // requirement, and the requirement's own Status__c is then recomputed as
    // a worst-wins rollup over ALL its linked documents, not just this one.
    public DocAssessQueueable(
        String complianceDocId,
        String contentVersionId,
        String supplierId,
        String documentTypeHint,
        String assessmentId,
        Id docLinkId
    ) {
        this.complianceDocId  = complianceDocId;
        this.contentVersionId = contentVersionId;
        this.supplierId       = supplierId;
        this.documentTypeHint = documentTypeHint;
        this.assessmentId     = assessmentId;
        this.docLinkId        = docLinkId;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // @InvocableMethod — entry point from Document_Upload_Event_Handler flow
    // (same variable names as AIExtractionQueueable so the flow rebinds cleanly)
    // ═════════════════════════════════════════════════════════════════════════
    public class AssessInvokeRequest {
        @InvocableVariable(label='Compliance Document Id' required=true)
        public String complianceDocId;
        @InvocableVariable(label='Content Version Id' required=true)
        public String contentVersionId;
        @InvocableVariable(label='Supplier Id')
        public String supplierId;
        @InvocableVariable(label='Document Type Hint')
        public String documentTypeHint;
    }

    @InvocableMethod(
        label       = 'Enqueue RAG Document Assessment'
        description = 'Called by Document_Upload_Event_Handler flow. Sends the uploaded document to the local /assess RAG service and writes a draft compliance finding.'
        category    = 'Compliance'
    )
    public static void enqueueFromEvent(List<AssessInvokeRequest> requests) {
        if (requests == null || requests.isEmpty()) return;
        for (AssessInvokeRequest req : requests) {
            if (String.isBlank(req.complianceDocId) || String.isBlank(req.contentVersionId)) {
                System.debug(LoggingLevel.ERROR,
                    '[DocAssessQueueable] Missing IDs: docId=' + req.complianceDocId
                    + ' cvId=' + req.contentVersionId);
                continue;
            }
            System.enqueueJob(new DocAssessQueueable(
                req.complianceDocId, req.contentVersionId, req.supplierId, req.documentTypeHint));
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // execute — its own transaction
    // ═════════════════════════════════════════════════════════════════════════
    public void execute(QueueableContext ctx) {
        // 1. Load the file (SOQL is fine before the callout)
        ContentVersion cv;
        for (ContentVersion c : [
            SELECT Id, VersionData, Title, PathOnClient, ContentSize
            FROM   ContentVersion
            WHERE  Id = :contentVersionId
            LIMIT 1
        ]) {
            cv = c;
        }
        if (cv == null || cv.VersionData == null) {
            System.debug(LoggingLevel.ERROR,
                '[DocAssessQueueable] ContentVersion missing/empty: ' + contentVersionId);
            return;
        }

        // 1b. Supplier's own legal name + industry — name lets /assess's
        // entity-name gate (Issue 3b) flag a document whose extracted entity
        // doesn't match who it's actually for; industry is the same strict
        // corpus filter /scope already applies (see ScopeCalloutQueueable's
        // identical Industry/Industry__c fallback), without which /assess's
        // policy-clause retrieval searches the ENTIRE corpus regardless of
        // this supplier's actual industry. Best-effort: a missing/deleted
        // Account just means both gates are skipped server-side, never
        // blocks the assessment itself.
        String supplierName;
        String supplierIndustry;
        if (String.isNotBlank(supplierId)) {
            for (Account a : [SELECT Name, Industry, Industry__c FROM Account WHERE Id = :supplierId LIMIT 1]) {
                supplierName = a.Name;
                supplierIndustry = String.isNotBlank(a.Industry) ? a.Industry : a.Industry__c;
            }
        }

        // 2. Call /assess (callout)
        DocAssessService.AssessRequest areq = new DocAssessService.AssessRequest();
        areq.supplierId     = supplierId;
        areq.documentType   = documentTypeHint;
        areq.fileName       = String.isNotBlank(cv.PathOnClient) ? cv.PathOnClient : cv.Title;
        areq.documentBase64 = EncodingUtil.base64Encode(cv.VersionData);
        areq.supplierName   = supplierName;
        areq.industry       = supplierIndustry;

        DocAssessService.AssessResponse resp;
        try {
            resp = DocAssessService.assess(areq);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[DocAssessQueueable] /assess failed: ' + e.getMessage());
            IntegrationErrorLogger.log(supplierId, 'Document Assessment (/assess)', e.getMessage());
            // Without this, a failed callout left the checklist row silently
            // stuck on its upload-time placeholder ("Document received —
            // pending AI extraction") forever — no error surfaced anywhere a
            // procurement/analyst user would see it, and the supplier portal
            // just showed no summary with no explanation. At Risk (the closest
            // valid Status__c value to "needs human attention") makes the
            // failure visible and actionable instead of silently invisible.
            if (String.isNotBlank(assessmentId)) {
                update new Compliance_Assessment__c(
                    Id                     = assessmentId,
                    Status__c              = 'At Risk',
                    Severity__c            = 'Medium',
                    Reason_Code__c         = 'Other',
                    Reason_Detail__c       = 'AI assessment failed: ' + e.getMessage().left(200)
                        + '. Please retry the upload or ask an analyst to review manually.',
                    Evaluated_By__c        = 'Auto',
                    Evaluation_DateTime__c = DateTime.now(),
                    Compliance_Document__c = complianceDocId
                );
                if (String.isNotBlank(supplierId)) {
                    try {
                        RiskScoreService.recompute(supplierId);
                    } catch (Exception recomputeEx) {
                        System.debug(LoggingLevel.WARN, '[DocAssessQueueable] risk score recompute failed: ' + recomputeEx.getMessage());
                    }
                }
            }
            return;
        }

        String domain = String.isNotBlank(resp.domain) ? resp.domain : 'general';
        String label  = String.isNotBlank(documentTypeHint) ? documentTypeHint : ('RAG: ' + domain);

        // 3. Write the verdict. If we know the exact checklist row that was set to
        //    'Pending' at upload, UPDATE THAT ROW (so the document the user uploaded
        //    moves off 'Pending'). Otherwise fall back to a domain-keyed upsert so
        //    unexpected evidence is still captured.
        Date expiryDate = parseExpiryDate(resp.keyDates);

        if (docLinkId != null) {
            // Multi-doc: this file's verdict belongs to ITS OWN junction row,
            // not directly on the requirement — other documents already
            // linked to the same requirement keep their own verdicts
            // untouched. The requirement's Status__c is then recomputed as a
            // worst-wins rollup over every linked document (see
            // rollupRequirementStatus below), which is the only thing that
            // should ever set Compliance_Assessment__c.Status__c once a
            // requirement has multiple documents.
            update new Compliance_Document_Link__c(
                Id                     = docLinkId,
                Status__c              = mapVerdict(resp.verdict),
                Severity__c            = mapSeverity(resp.severity),
                Reason_Code__c         = mapReasonCode(resp.verdict),
                Reason_Detail__c       = buildDetail(resp),
                AI_Confidence__c       = (resp.confidence == null) ? null : Decimal.valueOf(resp.confidence),
                Valid_Until__c         = expiryDate,
                Evaluation_DateTime__c = DateTime.now()
            );
            if (String.isNotBlank(assessmentId)) {
                rollupRequirementStatus(assessmentId);
            }
        } else if (String.isNotBlank(assessmentId)) {
            update new Compliance_Assessment__c(
                Id                     = assessmentId,
                Status__c              = mapVerdict(resp.verdict),
                Severity__c            = mapSeverity(resp.severity),
                Reason_Code__c         = mapReasonCode(resp.verdict),
                Reason_Detail__c       = buildDetail(resp),
                AI_Confidence__c       = (resp.confidence == null) ? null : Decimal.valueOf(resp.confidence),
                Valid_Until__c         = expiryDate,
                Evaluated_By__c        = 'Auto',
                Evaluation_DateTime__c = DateTime.now(),
                Compliance_Document__c = complianceDocId
            );
        } else {
            String reqKey = supplierId + '__SCOPE_' + domain;
            Compliance_Assessment__c a = new Compliance_Assessment__c(
                Name                   = label.length() > 80 ? label.left(80) : label,
                Supplier__c            = supplierId,
                Requirement_Key__c     = reqKey,
                Requirement_Label__c   = label,
                Status__c              = mapVerdict(resp.verdict),
                Severity__c            = mapSeverity(resp.severity),
                Reason_Code__c         = mapReasonCode(resp.verdict),
                Reason_Detail__c       = buildDetail(resp),
                AI_Confidence__c       = (resp.confidence == null) ? null : Decimal.valueOf(resp.confidence),
                Valid_Until__c         = expiryDate,
                Evaluated_By__c        = 'Auto',
                Evaluation_DateTime__c = DateTime.now(),
                Compliance_Document__c = complianceDocId
            );
            Database.upsert(a, Compliance_Assessment__c.Requirement_Key__c, false);
        }

        // 4. Audit (confidence stored as a 0-1 fraction, matching the Azure convention)
        Database.insert(new Audit_Log__c(
            Event_Type__c        = 'Compliance_Evaluated',
            Related_Object__c    = 'Compliance_Assessment',
            Related_Record_Id__c = complianceDocId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'AI',
            Source_System__c     = 'Other',
            AI_Model_Name__c     = resp.model,
            AI_Confidence__c     = resp.confidence == null ? null : Decimal.valueOf(resp.confidence) / 100,
            New_Value__c         = buildDetail(resp)
        ), false);

        // 4b. Recompute the supplier's dashboard risk score so it reflects this
        // finding — previously frozen at whatever the pre-document profile
        // guess was, even after a real Non-Compliant document landed.
        if (String.isNotBlank(supplierId)) {
            try {
                RiskScoreService.recompute(supplierId);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[DocAssessQueueable] risk score recompute failed: ' + e.getMessage());
            }
        }

        // 5. Fire the risk-propagation platform event so the hierarchy traversal
        //    engine re-calculates all parent tiers in real time (PublishAfterCommit
        //    — fires after this transaction commits, ensuring the assessment DML
        //    above is visible when RiskPropagationService queries the org).
        // if (String.isNotBlank(supplierId)) {
        //     String verdict = mapVerdict(resp.verdict);
        //     EventBus.publish(new Supplier_Risk_Changed__e(
        //         Supplier_Id__c  = supplierId,
        //         New_Status__c   = verdict,
        //         New_Score__c    = null,          // score is computed by RiskPropagationService
        //         Triggered_By__c = assessmentId   // traceability: which assessment row changed
        //     ));
        // }
    }

    // Parses r.keyDates.expiry_date (ISO "YYYY-MM-DD" string, per the
    // document_intelligence.md prompt's rule 2) into a real Date so it can
    // be persisted on Valid_Until__c. Previously this value only ever made
    // it into the free-text summary ("Expiry · 2027-03-01 (412d left)") and
    // was NEVER written to the actual Date field — meaning nothing could
    // ever query "documents expiring soon" even though the AI was already
    // extracting the date on every assessment.
    @TestVisible
    static Date parseExpiryDate(Map<String, Object> keyDates) {
        if (keyDates == null) return null;
        Object raw = keyDates.get('expiry_date');
        if (raw == null) return null;
        try {
            return Date.valueOf(String.valueOf(raw));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[DocAssessQueueable] unparseable expiry_date: ' + raw);
            return null;
        }
    }

    // Multi-document-per-requirement: rolls the requirement's OWN Status__c/
    // Severity__c/Reason_Detail__c/Valid_Until__c up from ALL its linked
    // Compliance_Document_Link__c rows — worst-wins, per the agreed design:
    // any single Non-Compliant file makes the whole requirement Non-Compliant,
    // since the requirement isn't genuinely satisfied until every piece of
    // required evidence checks out. Precedence (worst to best): Non-Compliant
    // > At Risk (uncertain/not yet human-judged) > Pending (nothing assessed
    // yet) > Compliant (only when EVERY linked document is Compliant).
    @TestVisible
    static void rollupRequirementStatus(Id assessmentId) {
        List<Compliance_Document_Link__c> links = [
            SELECT Status__c, Severity__c, Reason_Detail__c, Reason_Code__c, Valid_Until__c
            FROM   Compliance_Document_Link__c
            WHERE  Compliance_Assessment__c = :assessmentId
            AND    Status__c != 'Superseded'
        ];
        if (links.isEmpty()) return;

        Compliance_Document_Link__c worst;
        Date earliestExpiry;
        Integer rank = -1;   // higher = worse; picks the single worst-ranked link to drive the rollup
        for (Compliance_Document_Link__c l : links) {
            Integer r = verdictRank(l.Status__c);
            if (r > rank) {
                rank = r;
                worst = l;
            }
            if (l.Valid_Until__c != null && (earliestExpiry == null || l.Valid_Until__c < earliestExpiry)) {
                earliestExpiry = l.Valid_Until__c;
            }
        }
        if (worst == null) return;

        String combinedDetail = buildCombinedDetail(links);
        update new Compliance_Assessment__c(
            Id               = assessmentId,
            Status__c        = worst.Status__c,
            Severity__c      = worst.Severity__c,
            Reason_Code__c   = worst.Reason_Code__c,
            Reason_Detail__c = combinedDetail,
            Valid_Until__c   = earliestExpiry
        );
    }

    // Non-Compliant is always worse than an uncertain/incomplete state, which
    // is always worse than Compliant — matches RiskScoreService's own
    // treatment of 'At Risk'/Pending as neutral-not-good rather than a
    // confirmed finding either way.
    private static Integer verdictRank(String status) {
        if (status == 'Non-Compliant') return 3;
        if (status == 'At Risk')       return 2;
        if (status == 'Pending')       return 1;
        return 0;   // Compliant
    }

    // One line per linked document, so a requirement with multiple files
    // shows each one's own finding distinctly rather than collapsing them
    // into a single blended summary — the UI's per-file display parses this
    // the same way _parseSummary already does for a single document's detail.
    private static String buildCombinedDetail(List<Compliance_Document_Link__c> links) {
        List<String> lines = new List<String>();
        for (Compliance_Document_Link__c l : links) {
            lines.add((String.isBlank(l.Reason_Detail__c) ? 'No summary recorded.' : l.Reason_Detail__c));
        }
        return String.join(lines, '\n\n---\n\n').left(4000);
    }

    // ── Mapping helpers (values validated against the existing picklists) ──────
    @TestVisible
    static String mapVerdict(String v) {
        if (v == 'Compliant')     return 'Compliant';
        if (v == 'Non-Compliant') return 'Non-Compliant';
        return 'At Risk';   // 'Needs Analyst' / unknown → flagged for an analyst
    }
    static String mapSeverity(String s) {
        if (s == 'Critical' || s == 'High' || s == 'Medium' || s == 'Low') return s;
        return 'Medium';
    }
    static String mapReasonCode(String v) {
        if (v == 'Compliant')     return null;
        if (v == 'Non-Compliant') return 'Rule Not Met';
        return 'Other';
    }
    static String buildDetail(DocAssessService.AssessResponse r) {
        String cites = (r.citations != null && !r.citations.isEmpty())
            ? String.join(r.citations, '; ') : 'none';

        // ── Two-section summary: everything that checks out vs. everything
        // that's wrong, folded into ONE green list and ONE red list — no
        // separate "clause checks" / "extracted fields" blocks. Deterministic
        // gates (expiry, coverage, TIN, scope-exclusion — see
        // app.py's _doc_intelligence) are exactly as trustworthy as the LLM's
        // own checks_passed/concerns, so they're merged in by their own `pass`
        // boolean rather than shown as a separate, differently-styled section
        // the reader has to reconcile against the two above it. ─────────────
        List<String> passed = new List<String>();
        List<String> wrong  = new List<String>();

        if (r.summary != null) {
            Object checksPassed = r.summary.get('checks_passed');
            if (checksPassed instanceof List<Object>) {
                for (Object o : (List<Object>) checksPassed) passed.add(String.valueOf(o));
            }
            Object concerns = r.summary.get('concerns');
            if (concerns instanceof List<Object>) {
                for (Object o : (List<Object>) concerns) wrong.add(String.valueOf(o));
            }
        }
        if (r.clauseChecks != null) {
            for (Object o : r.clauseChecks) {
                Map<String, Object> c = (Map<String, Object>) o;
                String label = String.valueOf(c.get('requirement'));
                String found = c.get('found') != null ? String.valueOf(c.get('found')) : null;
                String line  = found != null ? (label + ' — ' + found) : label;
                if (c.get('pass') == true) passed.add(line); else wrong.add(line);
            }
        }
        if (r.registryValidation != null && r.registryValidation.get('status') != null) {
            Map<String, Object> rv = r.registryValidation;
            String status = String.valueOf(rv.get('status')).toUpperCase();
            String line = String.valueOf(rv.get('authority')) + ' registry: ' + status
                + (rv.get('detail') != null ? ' — ' + String.valueOf(rv.get('detail')) : '');
            // NOT_CONFIGURED/MANUAL_REQUIRED mean the check never ran — a
            // procedural gap, not a finding. Routing these into the same
            // red "what's wrong" list as a genuine failure (an expired
            // license, a sanctions hit) reads as a compliance problem when
            // it's actually "we don't have an automated check for this
            // document type yet." Left out of both lists entirely — a
            // human reviewer doesn't need this to judge the DOCUMENT, only
            // to know registry screening itself is incomplete, which the
            // Screening tab already surfaces separately.
            if (status == 'PASS' || status == 'VERIFIED' || status == 'CLEAR') passed.add(line);
            else if (status != 'NOT_CONFIGURED' && status != 'MANUAL_REQUIRED') wrong.add(line);
        }

        String headline = (r.summary != null && r.summary.get('headline') != null)
            ? String.valueOf(r.summary.get('headline'))
            : (r.reasons != null ? r.reasons : '');

        String detail = headline.trim();
        if (!passed.isEmpty()) {
            List<String> pl = new List<String>();
            for (String s : passed) pl.add('✓ ' + s);
            detail += '\nChecks passed:\n' + String.join(pl, '\n');
        }
        if (!wrong.isEmpty()) {
            List<String> wl = new List<String>();
            for (String s : wrong) wl.add('⚠ ' + s);
            detail += '\nConcerns:\n' + String.join(wl, '\n');
        }

        detail += '\n\nPolicy citations: ' + cites;
        return detail.length() > 4000 ? detail.left(4000) : detail;
    }
}