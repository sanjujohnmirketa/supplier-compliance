/**
 * ComplianceExpiryBatch
 * ═══════════════════════════════════════════════════════════════════════════
 * Scheduled safety net that catches document expiry SILENTLY — a Compliant
 * document whose Valid_Until__c crosses its warning window or lapses, with
 * no new upload or reassessment ever triggered, previously sat invisible
 * forever (nothing re-checked it). This batch is what makes that visible AND
 * actionable:
 *
 *   1. Flags it — flips Status__c from Compliant to At Risk with
 *      Reason_Code__c='Expired', so it surfaces in the HITL Priority Queue
 *      widget and IntelligenceDashboardController's supplier-alerts widget
 *      without duplicating any of that logic here. NOT counted as a risk-
 *      score finding by RiskScoreService — At Risk means "needs a human,"
 *      not a confirmed problem, so it stays neutral there until an analyst
 *      actually judges it Compliant/Non-Compliant.
 *   2. Unlocks the supplier's renewal path — scSupplierPortal's checklist
 *      row rendering treats Reason_Code__c='Expired' as a distinct state
 *      from a real AI rejection, showing a "Renew" action that re-targets
 *      THIS exact assessmentId (see scSupplierPortal.js's isExpired/handle
 *      Renew) instead of relying on fuzzy-matching a new upload to an
 *      "open" (unticked) row — expired rows are still ticked=true today,
 *      which is exactly why they were never offered as an upload target.
 *
 * NOT a re-run of the AI: this batch never calls /assess. It has no basis to
 * judge compliance — it only knows a date passed. The verdict on whatever
 * the supplier uploads next is still entirely DocAssessQueueable's job, same
 * as any other upload.
 *
 * Idempotent: only touches rows currently Compliant with Valid_Until__c in
 * the window — an already-flagged (At Risk/Expired) row is left alone on
 * every subsequent run until the supplier actually renews it (which resets
 * Status__c back to whatever the fresh /assess verdict says).
 *
 * WARNING_WINDOW_DAYS mirrors IntelligenceDashboardController.getSupplierAlerts'
 * 30-day threshold — kept as a literal in both places rather than a shared
 * constant since they're two different classes with no natural shared base;
 * if this window changes, update both.
 *
 * Schedule via scripts/apex/schedule-compliance-expiry.apex (2-week cadence,
 * matching the cadence explicitly requested).
 */
// Explicit without sharing (Apex's own default when undeclared — no behavior
// change): a scheduled sweep across ALL suppliers must not silently narrow
// to whatever the running user happens to see.
public without sharing class ComplianceExpiryBatch implements Database.Batchable<SObject>, Schedulable {

    private static final Integer WARNING_WINDOW_DAYS = 30;

    public Database.QueryLocator start(Database.BatchableContext bc) {
        Date threshold = Date.today().addDays(WARNING_WINDOW_DAYS);
        return Database.getQueryLocator([
            SELECT Id, Status__c, Valid_Until__c, Supplier__c
            FROM   Compliance_Assessment__c
            WHERE  Status__c   = 'Compliant'
              AND  Valid_Until__c != null
              AND  Valid_Until__c <= :threshold
              AND  Supplier__r.Onboarding_Status__c IN ('Approved', 'Reviewed')
              AND  (NOT Requirement_Key__c LIKE 'SCREEN_%')
        ]);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        List<Compliance_Assessment__c> toFlag = new List<Compliance_Assessment__c>();
        Set<Id> supplierIds = new Set<Id>();

        for (SObject s : scope) {
            Compliance_Assessment__c a = (Compliance_Assessment__c) s;
            Boolean expired = a.Valid_Until__c < Date.today();
            toFlag.add(new Compliance_Assessment__c(
                Id                = a.Id,
                Status__c         = 'At Risk',
                Reason_Code__c    = 'Expired',
                Reason_Detail__c  = expired
                    ? 'Document expired ' + a.Valid_Until__c.format() + ' — renewal required.'
                    : 'Document expires ' + a.Valid_Until__c.format() + ' — renewal recommended.'
            ));
            supplierIds.add(a.Supplier__c);
        }

        if (!toFlag.isEmpty()) {
            // Partial-success mode: one locked/invalid row must not silently
            // drop the entire chunk's flagging (default `update` throws on the
            // first failure and rolls back ALL 100 rows with no retry — at
            // real volume, a supplier record being edited concurrently by a
            // user becomes a statistically likely occurrence, not an edge
            // case). Failures are logged, not silently swallowed — see finish().
            List<Database.SaveResult> results = Database.update(toFlag, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    String errs = '';
                    for (Database.Error e : results[i].getErrors()) errs += e.getMessage() + '; ';
                    IntegrationErrorLogger.log(null, 'ComplianceExpiryBatch',
                        'Failed to flag ' + toFlag[i].Id + ': ' + errs);
                }
            }
        }

        // Recompute even though At Risk itself doesn't move the score
        // (RiskScoreService treats it as neutral, same as Pending) — this
        // flips the assessment OFF 'Compliant', which DOES matter: that
        // document no longer counts toward goodCount, so a supplier that
        // was scored on an assumption of full compliance correctly loses
        // that credit once one of its documents goes stale.
        //
        // Bulk, not looped: at real volume (10-15 docs/supplier) a 100-row
        // scope realistically spans close to 100 distinct suppliers — calling
        // recompute() per supplier would run ~2 SOQL queries EACH, blowing
        // the 100-query governor limit well before the loop finished. See
        // RiskScoreService.recomputeBulk's own comment for the full math.
        try {
            RiskScoreService.recomputeBulk(supplierIds);
        } catch (Exception e) {
            IntegrationErrorLogger.log(null, 'ComplianceExpiryBatch',
                'Risk score bulk recompute failed for ' + supplierIds.size() + ' supplier(s): ' + e.getMessage());
        }
    }

    // Surfaces a chunk-level DML/limit failure that would otherwise be
    // invisible — Batch Apex catches unhandled exceptions PER CHUNK and moves
    // on, so without this, a single locked-record or governor-limit failure
    // at 5-10K suppliers could silently stop the weekly safety net from
    // catching real expirations with zero indication anywhere. Job-level
    // NumberOfErrors/JobItemsProcessed comes from AsyncApexJob itself, not
    // anything this class tracked manually — no separate counter to keep in
    // sync with execute()'s own per-row logging above.
    public void finish(Database.BatchableContext bc) {
        AsyncApexJob job = [
            SELECT Id, Status, NumberOfErrors, JobItemsProcessed, TotalJobItems
            FROM   AsyncApexJob
            WHERE  Id = :bc.getJobId()
            LIMIT  1
        ];
        if (job.NumberOfErrors > 0) {
            IntegrationErrorLogger.log(null, 'ComplianceExpiryBatch',
                'Batch completed with ' + job.NumberOfErrors + ' failed chunk(s) out of '
                + job.TotalJobItems + ' — check Setup > Apex Jobs for this run (Id ' + job.Id + ').');
        }
    }

    public void execute(SchedulableContext sc) {
        Database.executeBatch(new ComplianceExpiryBatch(), 100);
    }
}