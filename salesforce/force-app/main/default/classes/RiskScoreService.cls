/**
 * RiskScoreService
 * ═══════════════════════════════════════════════════════════════════════════
 * Recomputes Account.Risk_Score__c — the ONE supplier-level compliance score,
 * shown everywhere a supplier is represented (queue, dashboard, portal).
 *
 * Distinct from AI_Confidence__c, which stays document-level ONLY (how well
 * the AI extracted/understood one specific file) and is never rolled up or
 * shown at the supplier level.
 *
 * MODEL — additive, per-document, whole-number, starts at 0:
 *   - A brand-new supplier (no documents assessed yet) has Risk_Score__c = 0.
 *     It is NOT screened/scored just because a checklist exists — scoring
 *     only starts once the vendor uploads something and the AI/human verdict
 *     lands (Status__c or Procurement_Decision__c leaves Pending).
 *   - N = Account.Checklist_Item_Count__c, the checklist size FROZEN at the
 *     moment the checklist was first generated (ScopeCalloutQueueable /
 *     VendorPortalController.persistCuratedChecklist). Using a frozen N (not
 *     a live recount) means a document's point value never silently shifts
 *     because the checklist was edited later — a document already scored at
 *     +8 (100/12, rounded) stays worth +8 even if two items are later added.
 *   - Each Compliant document contributes +round(100 / N) points.
 *   - Each Non-Compliant/Rejected document contributes
 *     -round(100 / N) * severityMultiplier points, where the multiplier
 *     scales the base per-document share by how bad the finding is
 *     (Critical hits hardest, Low barely dents it) — see SEVERITY_MULTIPLIER.
 *   - Score is capped at MAX_SCORE (97), never a perfect 100, even when every
 *     document is Compliant — see computeScore's clamp comment for why.
 *   - Pending/At-Risk/Deferred documents are neutral — they don't move the
 *     score. 'At Risk' means "not yet judged by a human," not a confirmed
 *     finding (see DocAssessQueueable.mapVerdict); it only counts once a
 *     human checkpoint judges it (Analyst confirm/override — Status__c via
 *     saveDocValidation, or Procurement's own Approve/Reject —
 *     Procurement_Decision__c via recordProcurementDecision). Most suppliers
 *     only ever get the latter, since routeDecision() auto-routes anything
 *     at or below the HITL threshold and no Analyst ever sees it.
 *   - Per document, Procurement_Decision__c takes precedence over Status__c
 *     when they disagree — it's the more recent, human call, and for
 *     auto-routed suppliers it's the only human call that will ever exist.
 *   - Result is clamped to [0, 100] and always a whole number.
 *
 * Risk_Tier__c is a pure function of Risk_Score__c (see scoreToTier) — there
 * is no separate tier computation to drift out of sync with the score.
 * Profile_Risk_Tier__c (the industry/material profile guess, written once by
 * ScopeCalloutQueueable) is kept as a separate, frozen reference field for
 * display/context — it is NOT blended into the live score/tier anymore.
 *
 * This score is AI/human-suggestive, not the compliance verdict itself —
 * that's still the Analyst's Confirm/Override call (Compliance_Assessment__c.
 * Status__c / Analyst_Validated__c) OR Procurement's own Approve/Reject
 * (Procurement_Decision__c). Recomputing the score never changes or bypasses
 * either checkpoint; it only reflects what's already been decided.
 *
 * Called from:
 *   - DocAssessQueueable (after the AI writes a fresh verdict) — recompute()
 *   - VendorPortalController.saveDocValidation (Analyst Confirm/Override) — recompute()
 *   - VendorPortalController.recordProcurementDecision (Procurement Approve/Reject) — recompute()
 *   - ComplianceExpiryBatch (bulk expiry sweep, many suppliers/execute() call) — recomputeBulk()
 */
public without sharing class RiskScoreService {

    // How much a non-compliant document's penalty is scaled relative to its
    // own +round(100/N) share — a Critical finding costs MORE than a single
    // clean document earns, so a supplier can't "average out" a serious
    // problem with unrelated clean paperwork. Low-severity misses barely
    // register, matching how a reviewer would actually weigh them.
    private static final Map<String, Decimal> SEVERITY_MULTIPLIER = new Map<String, Decimal>{
        'Critical' => 2.0,
        'High'     => 1.5,
        'Medium'   => 1.0,
        'Low'      => 0.5
    };
    private static final Decimal DEFAULT_MULTIPLIER = 1.0; // unrecognized/blank severity → treat as Medium

    // Deliberate ceiling below a perfect 100 — see computeScore's own comment
    // at the clamp for why. 97 keeps "fully compliant" reading as a clearly
    // top-tier score without asserting zero residual risk.
    private static final Decimal MAX_SCORE = 97;

    // Recomputes and writes Risk_Score__c (and its derived Risk_Tier__c) for
    // one supplier. Safe to call redundantly — always recomputed fresh from
    // the current assessment mix, never compounded on its own prior value.
    public static void recompute(Id supplierId) {
        if (supplierId == null) return;
        recomputeBulk(new Set<Id>{ supplierId });
    }

    // Bulk-safe version — used by anything that recomputes MANY suppliers in
    // one transaction (ComplianceExpiryBatch). Exactly 2 queries total,
    // regardless of how many supplierIds are passed in.
    public static void recomputeBulk(Set<Id> supplierIds) {
        if (supplierIds == null || supplierIds.isEmpty()) return;

        Map<Id, Account> accounts = new Map<Id, Account>([
            SELECT Id, Risk_Score__c, Risk_Tier__c, Checklist_Item_Count__c
            FROM   Account
            WHERE  Id IN :supplierIds
        ]);
        if (accounts.isEmpty()) return;

        // Row-level (not aggregate) because classifying a document needs BOTH
        // Status__c and Procurement_Decision__c, with Procurement's call
        // taking precedence when it disagrees with the AI.
        Map<Id, List<AssessmentOutcome>> outcomesBySupplier = new Map<Id, List<AssessmentOutcome>>();

        for (Compliance_Assessment__c ca : [
            SELECT Supplier__c, Status__c, Severity__c, Procurement_Decision__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c IN :supplierIds
              AND  (Status__c IN ('Compliant', 'Non-Compliant')
                    OR Procurement_Decision__c IN ('Approved', 'Rejected'))
        ]) {
            // Procurement's explicit call wins over the AI's Status__c when
            // both exist. Deferred isn't a compliance call, so it falls
            // through to Status__c same as if no decision existed.
            String effectiveVerdict;
            if (ca.Procurement_Decision__c == 'Approved') {
                effectiveVerdict = 'Compliant';
            } else if (ca.Procurement_Decision__c == 'Rejected') {
                effectiveVerdict = 'Non-Compliant';
            } else {
                effectiveVerdict = ca.Status__c;
            }
            if (effectiveVerdict != 'Compliant' && effectiveVerdict != 'Non-Compliant') continue;

            Id sid = ca.Supplier__c;
            if (!outcomesBySupplier.containsKey(sid)) outcomesBySupplier.put(sid, new List<AssessmentOutcome>());
            outcomesBySupplier.get(sid).add(new AssessmentOutcome(effectiveVerdict, ca.Severity__c));
        }

        List<Account> toUpdate = new List<Account>();
        for (Account acc : accounts.values()) {
            List<AssessmentOutcome> outcomes = outcomesBySupplier.containsKey(acc.Id)
                ? outcomesBySupplier.get(acc.Id) : new List<AssessmentOutcome>();

            Decimal newScore = computeScore(acc.Checklist_Item_Count__c, outcomes);
            String  newTier  = scoreToTier(newScore);

            // Always write Risk_Last_Computed__c, even when the score/tier
            // itself lands unchanged (e.g. a supplier already at the MAX_SCORE
            // cap, or a Deferred/neutral re-decision) — a Procurement/Analyst
            // decision that DOES trigger a recompute should always leave a
            // visible "last evaluated" timestamp, otherwise a capped score
            // that correctly stops moving looks identical to a recompute that
            // silently never ran (reported as "compliance score isn't
            // updating" even though the math was right all along).
            toUpdate.add(new Account(
                Id                    = acc.Id,
                Risk_Score__c         = newScore,
                Risk_Tier__c          = newTier,
                Risk_Last_Computed__c = DateTime.now()
            ));
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    // Pure scoring math, shared by recompute()/recomputeBulk() — see the
    // class header for the additive per-document model this implements.
    @TestVisible
    static Decimal computeScore(Decimal checklistItemCount, List<AssessmentOutcome> outcomes) {
        if (outcomes == null || outcomes.isEmpty()) {
            // Nothing assessed yet (including "no checklist exists at all") —
            // the supplier hasn't been screened, so the score is 0, not a
            // profile-based guess.
            return 0;
        }

        // N defaults to the number of assessed documents themselves if the
        // checklist size was never frozen (e.g. legacy Accounts predating
        // Checklist_Item_Count__c) — keeps the math sane rather than dividing
        // by a null/zero N.
        Decimal n = (checklistItemCount != null && checklistItemCount > 0)
            ? checklistItemCount : outcomes.size();
        Decimal perDocShare = (100 / n).setScale(0, System.RoundingMode.HALF_UP);
        if (perDocShare < 1) perDocShare = 1; // never let a large checklist round a document's worth to 0

        Decimal score = 0;
        for (AssessmentOutcome o : outcomes) {
            if (o.verdict == 'Compliant') {
                score += perDocShare;
            } else {
                Decimal mult = SEVERITY_MULTIPLIER.containsKey(o.severity)
                    ? SEVERITY_MULTIPLIER.get(o.severity) : DEFAULT_MULTIPLIER;
                score -= perDocShare * mult;
            }
        }

        // Deliberate ceiling below 100 (not a rounding accident): a perfect
        // 100 reads as "zero residual risk," which this app never actually
        // asserts — Procurement/Analyst sign-off means the paperwork checks
        // out today, not that the supplier carries no risk at all. Whole-
        // number rounding of 100/N already tends to undershoot for many N
        // (e.g. N=7 -> 7x14=98) — MAX_SCORE just makes that the guaranteed,
        // deliberate ceiling instead of an incidental side effect of the
        // rounding, so a genuine 100 never appears again for any N.
        if (score > MAX_SCORE) score = MAX_SCORE;
        if (score < 0)         score = 0;
        return score.setScale(0, System.RoundingMode.HALF_UP);
    }

    // Tier is purely derived from the score — no independent tier logic to
    // drift out of sync. Boundaries match the pre-existing scale used
    // elsewhere in the app (dashboards, HITL thresholds).
    //
    // Inverted relative to the old profile-floor model: computeScore() is now
    // an ADDITIVE COMPLIANCE score (Compliant documents raise it, Non-Compliant
    // ones lower it) — a HIGH score means the supplier is well-documented and
    // compliant, not high-risk. So a high score must map to the LOW risk tier
    // (and a low/near-0 score, e.g. nothing assessed yet or mostly rejected,
    // maps to Critical) — the opposite direction of the old risk-score scale.
    @TestVisible
    static String scoreToTier(Decimal score) {
        if (score >= 85) return 'Low';
        if (score >= 60) return 'Medium';
        if (score >= 35) return 'High';
        return 'Critical';
    }

    class AssessmentOutcome {
        String verdict;
        String severity;
        AssessmentOutcome(String verdict, String severity) {
            this.verdict = verdict;
            this.severity = severity;
        }
    }
}