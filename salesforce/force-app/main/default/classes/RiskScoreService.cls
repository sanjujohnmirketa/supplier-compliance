/**
 * RiskScoreService
 * ═══════════════════════════════════════════════════════════════════════════
 * Recomputes Account.Risk_Score__c — the ONE supplier-level risk number,
 * shown everywhere a supplier is represented (queue, dashboard, portal).
 *
 * Distinct from AI_Confidence__c, which stays document-level ONLY (how well
 * the AI extracted/understood one specific file) and is never rolled up or
 * shown at the supplier level — VendorPortalController.getScreeningQueue used
 * to average document confidence into a supplier-level column; that was
 * removed because it conflated two unrelated concepts: "how sure was the AI
 * about this document" vs "how risky is this supplier."
 *
 * MODEL — three defined scenarios:
 *   1. ALL assessed documents Compliant  -> score settles toward the LOW end
 *      of the supplier's profile-risk band. It does not drop to 0 — the
 *      profile baseline (industry/material/engagement risk, captured by
 *      Risk_Tier__c at checklist-generation time) is real and independent of
 *      paperwork being in order, but a fully clean checklist measurably
 *      pulls the score down from the raw profile floor.
 *   2. ALL assessed documents Non-Compliant/At-Risk -> score climbs toward
 *      the TOP of the band, severity-weighted — several Critical findings
 *      can push even a Low-profile supplier into High/Critical territory.
 *   3. PARTIAL (a mix) -> score lands PROPORTIONALLY between those two
 *      poles based on the actual ratio of good-to-bad assessed documents,
 *      not a flat per-bad-document add-on. 1-of-7 Non-Compliant reads very
 *      differently from 5-of-7.
 *   Documents still Pending (not yet uploaded/assessed) are NEUTRAL — they
 *   don't move the score either way. "How much is still outstanding" is a
 *   separate, already-existing onboarding-progress indicator, not conflated
 *   into risk. An empty checklist (nothing assessed yet) reports the
 *   profile-only baseline, unchanged from before any document lands.
 *   'At Risk' (Status__c set whenever the AI verdict was 'Needs Analyst' or
 *   unrecognized — see DocAssessQueueable.mapVerdict) means "not yet judged
 *   by a human," not "a confirmed finding." It's excluded from badWeight for
 *   the same reason Pending is: uncertainty isn't evidence of a problem. It
 *   moves into one of the two real buckets once EITHER human checkpoint
 *   judges it — an Analyst's confirm/override (Status__c, saveDocValidation)
 *   or Procurement's own Approve/Reject (Procurement_Decision__c,
 *   recordProcurementDecision), whichever happens; most suppliers only ever
 *   get the latter, since routeDecision() auto-routes anything at or below
 *   the HITL threshold and no Analyst ever sees it.
 *
 * IMPORTANT — profile floor stability: Risk_Tier__c is OVERWRITTEN by this
 * service (it becomes this class's own derived verdict), so it cannot also
 * be read back as the input floor without compounding on every call. The
 * stable input is Profile_Risk_Tier__c — a frozen snapshot ScopeCalloutQueueable
 * writes ONCE at checklist-generation time and never touches again. This
 * service always floors against Profile_Risk_Tier__c, never against its own
 * prior Risk_Tier__c output, which is what keeps recompute() idempotent
 * across repeated calls for the same assessment data.
 *
 * This score is AI/human-suggestive, not the compliance verdict itself —
 * that's still the Analyst's Confirm/Override call (Compliance_Assessment__c.
 * Status__c / Analyst_Validated__c) OR Procurement's own Approve/Reject
 * (Procurement_Decision__c) where no Analyst ever reviews the case at all
 * (see VendorPortalController.routeDecision — anything at or below the HITL
 * threshold auto-routes and NEVER reaches an Analyst). Recomputing the score
 * never changes or bypasses either checkpoint; it only reflects what's
 * already been decided. Per document, Procurement_Decision__c takes
 * precedence over Status__c when they disagree — it's the more recent, human
 * call, and for auto-routed suppliers it's the only human call that will
 * ever exist. Deferred isn't a compliance signal (Procurement couldn't
 * decide) and is excluded, same as a Pending/unassessed document.
 *
 * Called from:
 *   - DocAssessQueueable (after the AI writes a fresh verdict) — recompute()
 *   - VendorPortalController.saveDocValidation (Analyst Confirm/Override) — recompute()
 *   - VendorPortalController.recordProcurementDecision (Procurement Approve/Reject) — recompute()
 *   - ComplianceExpiryBatch (bulk expiry sweep, many suppliers/execute() call) — recomputeBulk()
 */
public without sharing class RiskScoreService {

    // Severity weight per NON-compliant/at-risk assessed document — mirrors
    // ScopeCalloutQueueable.tierToScore's 10/35/60/85 tier scale. A single
    // Critical finding alone should read as seriously as a full tier jump.
    private static final Map<String, Decimal> SEVERITY_WEIGHT = new Map<String, Decimal>{
        'Critical' => 90,
        'High'     => 65,
        'Medium'   => 40,
        'Low'      => 20
    };
    private static final Decimal DEFAULT_WEIGHT = 40; // unrecognized/blank severity → treat as Medium

    // How far toward 0 a fully-clean checklist can pull the score below the
    // raw profile floor — a clean paperwork trail is real signal, but never
    // erases inherent industry/material risk entirely.
    private static final Decimal CLEAN_CHECKLIST_DISCOUNT = 0.35;

    // Recomputes and writes Risk_Score__c (and, if it moved into a new tier,
    // Risk_Tier__c) for one supplier. Safe to call redundantly — idempotent
    // given the same assessment data (always recomputed from the stable
    // profile floor + current assessment mix, never compounded on itself).
    public static void recompute(Id supplierId) {
        if (supplierId == null) return;
        recomputeBulk(new Set<Id>{ supplierId });
    }

    // Bulk-safe version — used by anything that recomputes MANY suppliers in
    // one transaction (ComplianceExpiryBatch), where calling recompute() in a
    // loop would run 2 SOQL queries PER SUPPLIER and blow the 100-query
    // governor limit once a batch chunk spans more than ~50 distinct
    // suppliers (guaranteed at real volume — Valid_Until__c dates aren't
    // correlated with supplier grouping, so a 100-row scope of "documents
    // expiring soon" realistically touches close to 100 distinct suppliers).
    // Exactly 2 queries total here, regardless of how many supplierIds are
    // passed in: one bulk Account fetch, one bulk aggregate grouped by
    // supplier — everything else is done in memory.
    public static void recomputeBulk(Set<Id> supplierIds) {
        if (supplierIds == null || supplierIds.isEmpty()) return;

        Map<Id, Account> accounts = new Map<Id, Account>([
            SELECT Id, Risk_Score__c, Risk_Tier__c, Profile_Risk_Tier__c
            FROM   Account
            WHERE  Id IN :supplierIds
        ]);
        if (accounts.isEmpty()) return;

        // goodCount/badWeight/badCount per supplier. Row-level (not aggregate)
        // because classifying a document now needs BOTH Status__c and
        // Procurement_Decision__c, with Procurement's call taking precedence
        // when it disagrees with the AI — a GROUP BY can't express that
        // precedence rule across two independent fields without either
        // double-counting a document that has both, or ignoring one field.
        //
        // Procurement's Approve/Reject is real human judgment, and for any
        // supplier whose risk tier auto-routes (never reaches an Analyst —
        // see routeDecision()), it is the ONLY human judgment that will ever
        // exist on that document. Excluding it left the score frozen at
        // whatever the AI alone said, for every auto-routed supplier, even
        // after Procurement explicitly overruled a finding.
        Map<Id, Decimal> goodCountBySupplier = new Map<Id, Decimal>();
        Map<Id, Decimal> badWeightBySupplier = new Map<Id, Decimal>();
        Map<Id, Decimal> badCountBySupplier  = new Map<Id, Decimal>();

        for (Compliance_Assessment__c ca : [
            SELECT Supplier__c, Status__c, Severity__c, Procurement_Decision__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c IN :supplierIds
              AND  (Status__c IN ('Compliant', 'Non-Compliant')
                    OR Procurement_Decision__c IN ('Approved', 'Rejected'))
        ]) {
            // Procurement's explicit call wins over the AI's Status__c when
            // both exist — it's the more recent, human-considered judgment,
            // and per design should count even when it disagrees with the AI.
            // Deferred isn't a compliance call (Procurement couldn't decide),
            // so it falls through to Status__c same as if no decision existed.
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
            Decimal weight = SEVERITY_WEIGHT.containsKey(ca.Severity__c)
                ? SEVERITY_WEIGHT.get(ca.Severity__c) : DEFAULT_WEIGHT;

            if (effectiveVerdict == 'Compliant') {
                goodCountBySupplier.put(sid, (goodCountBySupplier.containsKey(sid) ? goodCountBySupplier.get(sid) : 0) + 1);
            } else {
                badWeightBySupplier.put(sid, (badWeightBySupplier.containsKey(sid) ? badWeightBySupplier.get(sid) : 0) + weight);
                badCountBySupplier.put(sid, (badCountBySupplier.containsKey(sid) ? badCountBySupplier.get(sid) : 0) + 1);
            }
        }

        List<Account> toUpdate = new List<Account>();
        for (Account acc : accounts.values()) {
            Decimal goodCount = goodCountBySupplier.containsKey(acc.Id) ? goodCountBySupplier.get(acc.Id) : 0;
            Decimal badWeight = badWeightBySupplier.containsKey(acc.Id) ? badWeightBySupplier.get(acc.Id) : 0;
            Decimal badCount  = badCountBySupplier.containsKey(acc.Id) ? badCountBySupplier.get(acc.Id) : 0;

            String floorTier = String.isNotBlank(acc.Profile_Risk_Tier__c)
                ? acc.Profile_Risk_Tier__c : acc.Risk_Tier__c;
            Decimal newScore = computeScore(floorTier, goodCount, badWeight, badCount);
            String newTier = scoreToTier(newScore);

            if (acc.Risk_Score__c != newScore || acc.Risk_Tier__c != newTier) {
                toUpdate.add(new Account(
                    Id             = acc.Id,
                    Risk_Score__c  = newScore,
                    Risk_Tier__c   = newTier,
                    Risk_Last_Computed__c = DateTime.now()
                ));
            }
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    // Pure scoring math, shared by recompute()/recomputeBulk() — see the
    // class header for the 3-scenario model this implements.
    private static Decimal computeScore(String floorTier, Decimal goodCount, Decimal badWeight, Decimal badCount) {
        Decimal profileFloor = tierFloor(floorTier);
        Decimal totalAssessed = goodCount + badCount;
        Decimal newScore;

        if (totalAssessed == 0) {
            // Nothing assessed yet — pending documents are neutral, so the
            // score is exactly the profile baseline, unchanged.
            newScore = profileFloor;
        } else {
            // badRatio: 0 (everything compliant) .. 1 (everything bad),
            // weighted by severity on the bad side so a handful of Critical
            // findings dominate the ratio the way a reviewer would react.
            // Denominator = "all documents were bad at the max weight" vs.
            // actual bad weight accrued, blended against the good count so
            // a single Low-severity miss among many Compliant docs barely
            // moves the needle, while a single Critical miss moves it hard.
            Decimal maxPossibleBadWeight = totalAssessed * SEVERITY_WEIGHT.get('Critical');
            Decimal badRatio = badWeight / maxPossibleBadWeight;
            if (badRatio > 1) badRatio = 1;

            if (badRatio <= 0) {
                // Scenario 1 — all compliant: pull down from the profile
                // floor, never past 0, capped by CLEAN_CHECKLIST_DISCOUNT so
                // inherent profile risk is never fully erased by paperwork.
                newScore = profileFloor * (1 - CLEAN_CHECKLIST_DISCOUNT);
            } else {
                // Scenarios 2 & 3 — blend from the clean-checklist floor up
                // toward a ceiling near (but not quite) 100, proportional to
                // how bad the assessed mix is. badRatio=1 (all non-compliant/
                // at-risk, all Critical) reaches the ceiling; a partial mix
                // lands proportionally between the two poles.
                Decimal cleanFloor = profileFloor * (1 - CLEAN_CHECKLIST_DISCOUNT);
                Decimal ceiling    = 100 - (100 - profileFloor) * 0.1; // leaves a sliver of headroom
                newScore = cleanFloor + (ceiling - cleanFloor) * badRatio;
            }
        }

        if (newScore > 100) newScore = 100;
        if (newScore < 0)   newScore = 0;
        return newScore.setScale(0, System.RoundingMode.HALF_UP);
    }

    private static Decimal tierFloor(String tier) {
        if (tier == 'Critical') return 85;
        if (tier == 'High')     return 60;
        if (tier == 'Medium')   return 35;
        if (tier == 'Low')      return 10;
        return 10;
    }

    private static String scoreToTier(Decimal score) {
        if (score >= 85) return 'Critical';
        if (score >= 60) return 'High';
        if (score >= 35) return 'Medium';
        return 'Low';
    }
}