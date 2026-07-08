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
        this.complianceDocId  = complianceDocId;
        this.contentVersionId = contentVersionId;
        this.supplierId       = supplierId;
        this.documentTypeHint = documentTypeHint;
        this.assessmentId     = assessmentId;
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

        // 2. Call /assess (callout)
        DocAssessService.AssessRequest areq = new DocAssessService.AssessRequest();
        areq.supplierId     = supplierId;
        areq.documentType   = documentTypeHint;
        areq.fileName       = String.isNotBlank(cv.PathOnClient) ? cv.PathOnClient : cv.Title;
        areq.documentBase64 = EncodingUtil.base64Encode(cv.VersionData);

        DocAssessService.AssessResponse resp;
        try {
            resp = DocAssessService.assess(areq);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[DocAssessQueueable] /assess failed: ' + e.getMessage());
            IntegrationErrorLogger.log(supplierId, 'Document Assessment (/assess)', e.getMessage());
            return;
        }

        String domain = String.isNotBlank(resp.domain) ? resp.domain : 'general';
        String label  = String.isNotBlank(documentTypeHint) ? documentTypeHint : ('RAG: ' + domain);

        // 3. Write the verdict. If we know the exact checklist row that was set to
        //    'Pending' at upload, UPDATE THAT ROW (so the document the user uploaded
        //    moves off 'Pending'). Otherwise fall back to a domain-keyed upsert so
        //    unexpected evidence is still captured.
        if (String.isNotBlank(assessmentId)) {
            update new Compliance_Assessment__c(
                Id                     = assessmentId,
                Status__c              = mapVerdict(resp.verdict),
                Severity__c            = mapSeverity(resp.severity),
                Reason_Code__c         = mapReasonCode(resp.verdict),
                Reason_Detail__c       = buildDetail(resp),
                AI_Confidence__c       = (resp.confidence == null) ? null : Decimal.valueOf(resp.confidence),
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

        // ── STRUCTURED SUMMARY first: a field-grounded headline + key facts, so the
        //    stored summary leads with specifics (not vague prose). No leading
        //    "[verdict · conf%]" bracket — the Status badge already shows the verdict
        //    and the confidence rides in its own line below for a clean read. ───────
        String detail = '';
        if (r.summary != null && r.summary.get('headline') != null) {
            detail += String.valueOf(r.summary.get('headline'));
            Object facts = r.summary.get('key_facts');
            if (facts instanceof List<Object> && !((List<Object>) facts).isEmpty()) {
                List<String> fl = new List<String>();
                for (Object o : (List<Object>) facts) fl.add('• ' + String.valueOf(o));
                detail += '\n' + String.join(fl, '\n');
            }
            Object concerns = r.summary.get('concerns');
            if (concerns instanceof List<Object> && !((List<Object>) concerns).isEmpty()) {
                List<String> cl = new List<String>();
                for (Object o : (List<Object>) concerns) cl.add('⚠ ' + String.valueOf(o));
                detail += '\nConcerns:\n' + String.join(cl, '\n');
            }
        } else {
            detail += (r.reasons != null ? r.reasons : '');
        }
        detail = detail.trim();

        // ── Document Intelligence: extracted fields + expiry + clause checks ──
        if (r.extractedFields != null && !r.extractedFields.isEmpty()) {
            Map<String, Object> f = r.extractedFields;
            List<String> bits = new List<String>();
            if (f.get('issuer') != null)          bits.add('Issuer: ' + f.get('issuer'));
            if (f.get('identifier') != null)      bits.add('ID: ' + f.get('identifier'));
            if (f.get('coverage_amount') != null) bits.add('Coverage: ' + f.get('coverage_amount')
                                                            + ' ' + String.valueOf(f.get('currency') != null ? f.get('currency') : ''));
            if (!bits.isEmpty()) detail += '\n\nExtracted · ' + String.join(bits, ' · ');
        }
        if (r.keyDates != null && r.keyDates.get('expiry_date') != null) {
            Boolean isExp = r.keyDates.get('is_expired') == true;
            detail += '\nExpiry · ' + r.keyDates.get('expiry_date')
                + (isExp ? ' (EXPIRED)' : ' (' + r.keyDates.get('days_to_expiry') + 'd left)');
        }
        if (r.clauseChecks != null && !r.clauseChecks.isEmpty()) {
            List<String> lines = new List<String>();
            for (Object o : r.clauseChecks) {
                Map<String, Object> c = (Map<String, Object>) o;
                lines.add((c.get('pass') == true ? '[PASS] ' : '[FAIL] ')
                    + String.valueOf(c.get('requirement')));
            }
            detail += '\n\nClause checks:\n' + String.join(lines, '\n');
        }

        if (r.registryValidation != null && r.registryValidation.get('status') != null) {
            Map<String, Object> rv = r.registryValidation;
            detail += '\n\nRegistry · ' + String.valueOf(rv.get('authority'))
                + ': ' + String.valueOf(rv.get('status')).toUpperCase()
                + ' — ' + String.valueOf(rv.get('detail'));
        }

        detail += '\n\nPolicy citations: ' + cites;
        return detail.length() > 4000 ? detail.left(4000) : detail;
    }
}