/**
 * ComplianceEvaluationQueueable  (v2 — reads Raw_Response__c, no LLM)
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * WHAT CHANGED FROM v1
 * ────────────────────
 * v1 called ComplianceEvaluatorService which made a second LLM round-trip
 * to evaluate the supplier's compliance against each rule.
 *
 * v2 reads the compliance block from Document_Extraction__c.Raw_Response__c
 * that AIExtractionQueueable already wrote in its single-pass call. Pure
 * SOQL + JSON.parse — zero LLM cost, zero callout, fast.
 *
 * RUN MODEL
 * ─────────
 * Chained from AIExtractionQueueable.execute() after each successful
 * extraction. For every Compliance_Assessment__c on the supplier that has
 * a linked Compliance_Document__c, read the latest Document_Extraction__c,
 * parse the compliance block, and update the assessment.
 *
 * Then compute the supplier-wide risk rollup and write it to:
 *   - Account.Compliance_Status_Rollup__c
 *   - Account.Risk_Score__c
 *   - Account.Risk_Tier__c
 *   - Account.Risk_Last_Computed__c
 *   - Account.Risk_Snapshot_JSON__c   (for the dashboard)
 *
 * NO CALLOUTS — this Queueable does not implement Database.AllowsCallouts.
 * If you need to add an LLM step later (e.g. supplier-level narrative),
 * do it via a new chained Queueable, not here.
 */
public class ComplianceEvaluationQueueable implements Queueable {

    private final String supplierId;

    public ComplianceEvaluationQueueable(String supplierId) {
        this.supplierId = supplierId;
    }

    public void execute(QueueableContext ctx) {
        System.debug(LoggingLevel.INFO,
            '[ComplianceEvaluationQueueable v2] Starting evaluation for Supplier='
            + supplierId + ' Job=' + ctx.getJobId());

        if (String.isBlank(supplierId)) {
            System.debug(LoggingLevel.WARN,
                '[ComplianceEvaluationQueueable v2] Blank supplierId — skipping');
            return;
        }

        try {
            // ── 1. Load every assessment + linked document + latest extraction
            List<Compliance_Assessment__c> assessments = [
                SELECT Id, Requirement_Key__c, Requirement_Label__c, Severity__c,
                       Status__c, Compliance_Document__c
                FROM   Compliance_Assessment__c
                WHERE  Supplier__c = :supplierId
                LIMIT  500
            ];

            if (assessments.isEmpty()) {
                System.debug(LoggingLevel.INFO,
                    '[ComplianceEvaluationQueueable v2] No assessments — nothing to do');
                return;
            }

            // ── 2. Collect document Ids that have linked assessments
            Set<Id> docIds = new Set<Id>();
            for (Compliance_Assessment__c a : assessments) {
                if (a.Compliance_Document__c != null) docIds.add(a.Compliance_Document__c);
            }

            // ── 3. Load the latest extraction per document
            Map<Id, Document_Extraction__c> latestByDocId =
                loadLatestExtractions(docIds);

            // ── 4. Apply compliance verdicts to each assessment
            List<Compliance_Assessment__c> toUpdate = new List<Compliance_Assessment__c>();
            Integer metCount = 0, failedCount = 0, pendingCount = 0;
            List<String> criticalFails = new List<String>();
            Decimal riskScore = 0;

            for (Compliance_Assessment__c a : assessments) {
                AssessmentDecision decision = decideAssessment(
                    a, latestByDocId.get(a.Compliance_Document__c)
                );

                // Tally for rollup
                if (decision.status == 'Compliant')         metCount++;
                else if (decision.status == 'Non-Compliant') {
                    failedCount++;
                    if (a.Severity__c == 'Critical') {
                        criticalFails.add(a.Requirement_Label__c);
                    }
                } else pendingCount++;

                // Accumulate risk
                riskScore += decision.riskPoints;

                // Build assessment update
                Map<String, Object> evalJson = new Map<String, Object>{
                    'status'        => decision.status,
                    'reason_code'   => decision.reasonCode,
                    'reason_detail' => decision.reasonDetail,
                    'risk_points'   => decision.riskPoints,
                    'evaluated_at'  => DateTime.now().format('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
                };

                toUpdate.add(new Compliance_Assessment__c(
                    Id                        = a.Id,
                    Status__c                 = decision.status,
                    Reason_Code__c            = decision.reasonCode,
                    Reason_Detail__c          = decision.reasonDetail != null
                                                    ? decision.reasonDetail.left(4000) : null,
                    Evaluation_DateTime__c    = DateTime.now(),
                    Evaluated_By__c           = 'Auto'
                    // If you've deployed Evaluation_Result_JSON__c, uncomment:
                    // , Evaluation_Result_JSON__c = JSON.serialize(evalJson).left(32768)
                ));
            }

            if (!toUpdate.isEmpty()) {
                Database.update(toUpdate, false);
            }

            // ── 5. Compute supplier rollup and persist to Account
            if (riskScore > 100) riskScore = 100;
            String riskTier;
            if (riskScore >= 75)      riskTier = 'Critical';
            else if (riskScore >= 50) riskTier = 'High';
            else if (riskScore >= 25) riskTier = 'Medium';
            else                      riskTier = 'Low';

            String rollupStatus;
            if (failedCount > 0 && !criticalFails.isEmpty()) rollupStatus = 'Non-Compliant';
            else if (pendingCount > 0)                       rollupStatus = 'Pending';
            else                                             rollupStatus = 'Compliant';

            Map<String, Object> snapshotJson = new Map<String, Object>{
                'overallStatus'      => rollupStatus,
                'totalRequirements'  => assessments.size(),
                'requirementsMet'    => metCount,
                'requirementsFailed' => failedCount,
                'requirementsPending'=> pendingCount,
                'criticalFailures'   => criticalFails,
                'riskScore'          => riskScore,
                'riskTier'           => riskTier,
                'evaluatedAt'        => DateTime.now().format('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
            };

            Account toAccount = new Account(
                Id                          = supplierId,
                Compliance_Status_Rollup__c = rollupStatus,
                Risk_Score__c               = riskScore,
                Risk_Tier__c                = riskTier,
                Risk_Last_Computed__c       = DateTime.now()
                // If you've deployed Risk_Snapshot_JSON__c, uncomment:
                // , Risk_Snapshot_JSON__c   = JSON.serialize(snapshotJson).left(131072)
            );

            update toAccount;

            System.debug(LoggingLevel.INFO,
                '[ComplianceEvaluationQueueable v2] Evaluation complete. '
                + 'Status=' + rollupStatus + ' Risk=' + riskScore + ' (' + riskTier + ') '
                + 'Met=' + metCount + ' Failed=' + failedCount + ' Pending=' + pendingCount);

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                '[ComplianceEvaluationQueueable v2] Exception: '
                + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Decision per assessment — pure logic, no LLM, no callouts
    // ═════════════════════════════════════════════════════════════════════════
    private AssessmentDecision decideAssessment(
        Compliance_Assessment__c a, Document_Extraction__c extraction
    ) {
        AssessmentDecision d = new AssessmentDecision();

        // No linked document at all → Missing
        if (a.Compliance_Document__c == null || extraction == null) {
            d.status       = 'Non-Compliant';
            d.reasonCode   = 'Missing Document';
            d.reasonDetail = 'No document has been uploaded for this requirement.';
            d.riskPoints   = severityPoints(a.Severity__c);
            return d;
        }

        // Parse the AI's compliance block from Raw_Response__c
        Map<String, Object> root = parseRaw(extraction.Raw_Response__c);
        if (root == null) {
            // Extraction exists but JSON unparseable — leave pending for HITL
            d.status       = 'Needs Human Review';
            d.reasonCode   = 'Other';
            d.reasonDetail = 'AI response could not be parsed. Analyst review required.';
            d.riskPoints   = severityPoints(a.Severity__c) / 2; // half weight for ambiguous
            return d;
        }

        Object cRaw = root.get('compliance');
        if (cRaw instanceof Map<String, Object>) {
            Map<String, Object> c = (Map<String, Object>) cRaw;
            d.status       = coerceString(c.get('status'));
            d.reasonCode   = normaliseReasonCode(coerceString(c.get('reason_code')));
            d.reasonDetail = coerceString(c.get('reason_detail'));
        }

        // risk_contribution from the extraction JSON (set by the prompt)
        Object rc = root.get('risk_contribution');
        if (rc != null) {
            try { d.riskPoints = Decimal.valueOf(String.valueOf(rc)); }
            catch (Exception ignored) { d.riskPoints = 0; }
        }

        // Defensive defaults if the prompt didn't return what we expected
        if (String.isBlank(d.status)) {
            d.status = 'Needs Human Review';
            d.reasonCode = 'Other';
            d.reasonDetail = 'AI did not return a compliance verdict for this document.';
            d.riskPoints = severityPoints(a.Severity__c) / 2;
        }
        // For Non-Compliant rules with no risk_contribution from the AI,
        // fall back to a severity-based score so the rollup isn't zero.
        if (d.status == 'Non-Compliant' && d.riskPoints == 0) {
            d.riskPoints = severityPoints(a.Severity__c);
        }

        return d;
    }

    private Map<Id, Document_Extraction__c> loadLatestExtractions(Set<Id> docIds) {
        Map<Id, Document_Extraction__c> byDocId = new Map<Id, Document_Extraction__c>();
        if (docIds.isEmpty()) return byDocId;

        // Order DESC and keep only the first per document
        for (Document_Extraction__c e : [
            SELECT Id, Compliance_Document__c, Raw_Response__c,
                   Overall_Confidence__c, Extraction_DateTime__c
            FROM   Document_Extraction__c
            WHERE  Compliance_Document__c IN :docIds
            ORDER BY Extraction_DateTime__c DESC
            LIMIT  1000
        ]) {
            if (!byDocId.containsKey(e.Compliance_Document__c)) {
                byDocId.put(e.Compliance_Document__c, e);
            }
        }
        return byDocId;
    }

    private Map<String, Object> parseRaw(String rawJson) {
        if (String.isBlank(rawJson)) return null;
        try {
            String cleaned = rawJson
                .replaceAll('```json', '')
                .replaceAll('```', '')
                .trim();
            return (Map<String, Object>) JSON.deserializeUntyped(cleaned);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                '[ComplianceEvaluationQueueable v2] Raw JSON parse failed: '
                + e.getMessage());
            return null;
        }
    }

    private Decimal severityPoints(String severity) {
        if (severity == 'Critical') return 25;
        if (severity == 'High')     return 15;
        if (severity == 'Medium')   return 8;
        return 3;
    }

    private String normaliseReasonCode(String raw) {
        if (String.isBlank(raw)) return 'Other';
        String lower = raw.toLowerCase();
        if (lower.contains('missing')) return 'Missing Document';
        if (lower.contains('expir'))   return 'Expired';
        if (lower.contains('not met') || lower.contains('rule')) return 'Rule Not Met';
        return 'Other';
    }

    private static String coerceString(Object val) {
        if (val == null) return null;
        if (val instanceof String) return (String) val;
        if (val instanceof List<Object>) {
            List<String> parts = new List<String>();
            for (Object o : (List<Object>) val) if (o != null) parts.add(String.valueOf(o));
            return String.join(parts, '\n');
        }
        return String.valueOf(val);
    }

    private class AssessmentDecision {
        String  status;
        String  reasonCode;
        String  reasonDetail;
        Decimal riskPoints = 0;
    }
}