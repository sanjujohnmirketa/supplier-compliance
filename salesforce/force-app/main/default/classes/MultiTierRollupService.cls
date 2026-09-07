/**
 * MultiTierRollupService — two coexisting cascading-risk signals computed in
 * one bottom-up walk across the Account.ParentId supplier hierarchy (T1 -> T2 -> T3 ...):
 *
 *   1. Cascading_Risk_Tier__c — WORST-CASE propagation (docs/multi-tier-risk-rollup.md).
 *      effective_tier(node) = worst(own_tier(node), [effective_tier(child) for child in children(node)])
 *      "One Non-Compliant T3 makes the whole chain High." Audit-defensible, not diluted.
 *
 *   2. Cascading_Risk_Score__c — WEIGHTED-AVERAGE blend (the "New Score" formula):
 *      New Score = (Own Score x Own_Score_Weight__c) + (avg of weighted sub-supplier
 *      contributions x Sub_Supplier_Weight__c), where each child's contribution is its
 *      own effective score x its Relationship_Type_To_Parent__c weight (Sole Source/Preferred/
 *      Secondary — Risk_Rollup_Setting__mdt). T1 only ever sees T2's already-updated
 *      score, never T3 directly — T2 is the shock absorber. These two signals will
 *      often disagree (a Critical T3 buried among clean siblings barely moves the
 *      blended score) — that's intentional, they answer different questions.
 *
 * Account.ParentId is a lookup hierarchy, not Master-Detail, so native Roll-Up Summary
 * fields cannot compute either of these — this has to be Apex that walks the chain.
 *
 * Entry points: MultiTierRollupQueueable (structural changes — re-parenting, new
 * sub-supplier) and SupplierRiskChangeTrigger (Supplier_Risk_Change__e, published when
 * Account.Risk_Tier__c itself changes — the real-time, non-batch path the cascading
 * SCORE feature is built around). MultiTierRollupBatch is the nightly safety net.
 *
 * SYSTEM CONTEXT BY DESIGN (documented CRUD/FLS scanner exception): every entry
 * point above is asynchronous (queueable, platform-event trigger, batch) — the
 * cascading rollup is maintained by the platform, not performed by a user, and
 * a parent supplier's rollup must update even when the user whose change
 * enqueued it holds no Edit on that parent Account. The writes are
 * allOrNone=false and audited; no Schema/stripInaccessible check is applied.
 */
@SuppressWarnings('PMD.ApexCRUDViolation') // system-context rollup — see class doc
public with sharing class MultiTierRollupService {

    // Salesforce hierarchy fields cap around 10 levels in practice; this is a
    // defensive ceiling against runaway loops, not an expected depth.
    private static final Integer MAX_DEPTH = 10;

    private static final Map<String, Integer> SEVERITY_RANK = new Map<String, Integer>{
        'Low' => 0, 'Medium' => 1, 'High' => 2, 'Critical' => 3
    };

    private static Risk_Rollup_Setting__mdt settingsCache;

    /** Async entry point — call from triggers. Bulk-safe. */
    public static void enqueueRollup(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) return;
        System.enqueueJob(new MultiTierRollupQueueable(accountIds));
    }

    /**
     * Synchronous entry point — walks up from startIds, recomputing each
     * ancestor level until nothing changes or MAX_DEPTH is hit.
     */
    public static void rollupFromAccounts(Set<Id> startIds) {
        if (startIds == null || startIds.isEmpty()) return;

        Risk_Rollup_Setting__mdt settings = getSettings();
        Set<Id> currentLevel = new Set<Id>(startIds);
        Integer depth = 0;

        // SOQL-in-loop by necessity, not oversight: this is a bottom-up
        // hierarchy walk where each level's query depends on the PREVIOUS
        // level's results (which accounts are the next level's children) —
        // there's no way to know the full set up front without walking it.
        // Bounded by MAX_DEPTH (10, see its own comment above) — worst case
        // 2 queries x 10 levels = 20 SOQL calls, well inside the 100-per-
        // transaction governor limit, not an unbounded record-count risk.
        while (!currentLevel.isEmpty() && depth < MAX_DEPTH) {
            depth++;

            Map<Id, Account> currentAccounts = new Map<Id, Account>([
                SELECT Id, Name, ParentId, Risk_Tier__c, Risk_Score__c,
                       Relationship_Type_To_Parent__c, Cascading_Risk_Tier__c,
                       Cascading_Risk_Source__c, Cascading_Risk_Driver__c,
                       Sub_Tier_Supplier_Count__c, Cascading_Risk_Score__c,
                       Cascading_Risk_Flag__c
                FROM   Account
                WHERE  Id IN :currentLevel
            ]);
            if (currentAccounts.isEmpty()) break;

            Map<Id, List<Account>> childrenByParent = new Map<Id, List<Account>>();
            for (Account c : [
                SELECT Id, Name, ParentId, Risk_Tier__c, Risk_Score__c,
                       Relationship_Type_To_Parent__c, Cascading_Risk_Tier__c,
                       Cascading_Risk_Source__c, Cascading_Risk_Driver__c,
                       Sub_Tier_Supplier_Count__c, Cascading_Risk_Score__c,
                       Cascading_Risk_Flag__c
                FROM   Account
                WHERE  ParentId IN :currentLevel
            ]) {
                if (!childrenByParent.containsKey(c.ParentId)) {
                    childrenByParent.put(c.ParentId, new List<Account>());
                }
                childrenByParent.get(c.ParentId).add(c);
            }

            List<Account> toUpdate = new List<Account>();
            List<Audit_Log__c> auditsToInsert = new List<Audit_Log__c>();
            Set<Id> nextLevel = new Set<Id>();

            for (Account acc : currentAccounts.values()) {
                RollupResult result = computeEffective(acc, childrenByParent.get(acc.Id), settings);

                Boolean tierChanged  = result.tier != acc.Cascading_Risk_Tier__c;
                Boolean countChanged = result.count != normalizeCount(acc.Sub_Tier_Supplier_Count__c);
                Boolean scoreChanged = result.score != acc.Cascading_Risk_Score__c;
                Boolean flagChanged  = result.flag != (acc.Cascading_Risk_Flag__c == true);

                if (!tierChanged && !scoreChanged && !flagChanged
                    && result.source == acc.Cascading_Risk_Source__c
                    && result.driverId == acc.Cascading_Risk_Driver__c
                    && !countChanged) {
                    continue; // nothing changed at this node — short-circuit, don't propagate
                }

                toUpdate.add(new Account(
                    Id                             = acc.Id,
                    Cascading_Risk_Tier__c          = result.tier,
                    Cascading_Risk_Source__c        = result.source,
                    Cascading_Risk_Driver__c        = result.driverId,
                    Sub_Tier_Supplier_Count__c      = result.count,
                    Cascading_Risk_Score__c         = result.score,
                    Cascading_Risk_Flag__c          = result.flag,
                    Cascading_Risk_Last_Computed__c = DateTime.now()
                ));

                if (tierChanged || flagChanged) {
                    auditsToInsert.add(new Audit_Log__c(
                        Event_Type__c        = 'Cascading_Risk_Updated',
                        Related_Object__c    = 'Supplier',
                        Related_Record_Id__c = acc.Id,
                        Event_DateTime__c    = DateTime.now(),
                        Actor_Type__c        = 'System',
                        Original_Value__c    = describe(acc.Cascading_Risk_Tier__c, acc.Cascading_Risk_Score__c, acc.Cascading_Risk_Flag__c == true),
                        New_Value__c         = describe(result.tier, result.score, result.flag),
                        Reason__c            = result.source,
                        Source_System__c     = 'Salesforce'
                    ));
                }

                // Re-walk upward whenever ANYTHING changed — a new sub-supplier
                // with no tier/score yet still needs its count to bubble all the
                // way to the root, even though it doesn't move anyone's tier.
                if ((tierChanged || countChanged || scoreChanged || flagChanged) && acc.ParentId != null) {
                    nextLevel.add(acc.ParentId);
                }
            }

            if (!toUpdate.isEmpty())      logFailures('update', Database.update(toUpdate, false), toUpdate);
            if (!auditsToInsert.isEmpty()) Database.insert(auditsToInsert, false);

            currentLevel = nextLevel;
        }
    }

    // ── Effective tier + score computation for a single node ───────────────

    private static RollupResult computeEffective(Account acc, List<Account> children, Risk_Rollup_Setting__mdt settings) {
        RollupResult best = new RollupResult();
        best.tier     = acc.Risk_Tier__c;
        // NOT acc.Id: Account.Cascading_Risk_Driver__c is a self-referencing
        // lookup, and Account enforces anti-circular-reference checking on
        // ANY self-lookup (not just the native ParentId Hierarchy field) —
        // writing acc.Id here throws CIRCULAR_DEPENDENCY: Hierarchy Constraint
        // Violation. Semantically correct anyway: when a node's own risk is
        // the worst thing in its subtree, there's nothing external to drill
        // through to, so the driver is null (not a self-pointing lookup).
        best.driverId = null;
        best.source   = String.isNotBlank(acc.Risk_Tier__c)
            ? (acc.Name + ' — ' + acc.Risk_Tier__c + ' risk')
            : null;
        best.count = 0;

        Integer bestRank = rank(acc.Risk_Tier__c);

        if (children != null) {
            for (Account child : children) {
                String childEffectiveTier = String.isNotBlank(child.Cascading_Risk_Tier__c)
                    ? child.Cascading_Risk_Tier__c : child.Risk_Tier__c;
                Integer childRank = rank(childEffectiveTier);

                if (childRank > bestRank) {
                    bestRank      = childRank;
                    best.tier     = childEffectiveTier;
                    best.driverId = child.Cascading_Risk_Driver__c != null
                        ? child.Cascading_Risk_Driver__c : child.Id;
                    best.source   = String.isNotBlank(child.Cascading_Risk_Source__c)
                        ? child.Cascading_Risk_Source__c
                        : (child.Name + ' — ' + childEffectiveTier + ' risk');
                }

                best.count += 1 + normalizeCount(child.Sub_Tier_Supplier_Count__c);
            }
        }

        if (bestRank < 0) {
            best.tier     = null;
            best.driverId = null;
            best.source   = null;
        }

        computeScore(best, acc, children, settings);

        return best;
    }

    /**
     * New Score = (Own Score x Own_Score_Weight__c) + (avg of relationship-weighted
     * sub-supplier contributions x Sub_Supplier_Weight__c). No sub-suppliers (or none
     * of them have scored yet) -> score = own score only, formula not applied. Capped
     * at 100. Flag fires only when propagation (not the supplier's own score) is what
     * crossed the threshold.
     */
    private static void computeScore(RollupResult best, Account acc, List<Account> children, Risk_Rollup_Setting__mdt settings) {
        Decimal ownScore = acc.Risk_Score__c;

        Decimal contributionSum = 0;
        Integer contributionCount = 0;
        if (children != null) {
            for (Account child : children) {
                Decimal childEffectiveScore = child.Cascading_Risk_Score__c != null
                    ? child.Cascading_Risk_Score__c : child.Risk_Score__c;
                if (childEffectiveScore == null) continue; // no data from this child yet

                Decimal weight = relationshipWeight(child.Relationship_Type_To_Parent__c, settings);
                contributionSum += childEffectiveScore * weight;
                contributionCount++;
            }
        }

        if (contributionCount == 0) {
            best.score = ownScore; // no sub-suppliers (or none scored yet) — own score only
        } else {
            Decimal avgContribution = contributionSum / contributionCount;
            Decimal blended = ((ownScore == null ? 0 : ownScore) * settings.Own_Score_Weight__c)
                + (avgContribution * settings.Sub_Supplier_Weight__c);
            best.score = (blended > 100 ? 100 : blended).setScale(2, System.RoundingMode.HALF_UP);
        }

        best.flag = best.score != null
            && best.score >= settings.Cascading_Risk_Threshold__c
            && (ownScore == null || best.score > ownScore);
    }

    private static Decimal relationshipWeight(String relationshipType, Risk_Rollup_Setting__mdt settings) {
        if (relationshipType == 'Sole Source') return settings.Sole_Source_Weight__c;
        if (relationshipType == 'Secondary')    return settings.Secondary_Weight__c;
        return settings.Preferred_Weight__c; // 'Preferred' and blank both fall back to neutral
    }

    private static Risk_Rollup_Setting__mdt getSettings() {
        if (settingsCache != null) return settingsCache;

        Risk_Rollup_Setting__mdt found;
        try {
            found = Risk_Rollup_Setting__mdt.getInstance('Default');
        } catch (Exception e) {
            found = null;
        }

        // Defensive fallback (matches the formula's documented defaults) so scoring
        // still works if the CMDT record isn't deployed yet.
        settingsCache = found != null ? found : new Risk_Rollup_Setting__mdt(
            Own_Score_Weight__c         = 0.7,
            Sub_Supplier_Weight__c      = 0.3,
            Sole_Source_Weight__c       = 1.5,
            Preferred_Weight__c         = 1.0,
            Secondary_Weight__c         = 0.8,
            Cascading_Risk_Threshold__c = 70
        );
        return settingsCache;
    }

    /**
     * allOrNone=false lets one bad record in a batch not block the rest, but
     * that also means failures are silent unless something inspects the
     * results — surface them to the debug log so a partial failure (a
     * validation rule, FLS, anything) doesn't look identical to "this
     * account was never in the rollup at all".
     */
    private static void logFailures(String operation, Database.SaveResult[] results, List<Account> attempted) {
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                List<String> errors = new List<String>();
                for (Database.Error e : results[i].getErrors()) errors.add(e.getStatusCode() + ': ' + e.getMessage());
                System.debug(LoggingLevel.ERROR, 'MultiTierRollupService ' + operation
                    + ' failed for Account ' + attempted[i].Id + ' — ' + String.join(errors, '; '));
            }
        }
    }

    private static String describe(String tier, Decimal score, Boolean flag) {
        return 'tier=' + (tier == null ? '—' : tier)
            + '; score=' + (score == null ? '—' : String.valueOf(score))
            + '; flagged=' + flag;
    }

    private static Integer rank(String tier) {
        return (tier == null || !SEVERITY_RANK.containsKey(tier)) ? -1 : SEVERITY_RANK.get(tier);
    }

    private static Integer normalizeCount(Decimal count) {
        return count == null ? 0 : count.intValue();
    }

    private class RollupResult {
        String  tier;
        String  source;
        Id      driverId;
        Integer count;
        Decimal score;
        Boolean flag;
    }
}