/**
 * MultiTierRollupBatch — nightly safety net for the multi-tier cascading-risk
 * roll-up (docs/multi-tier-risk-rollup.md section 6). The event-driven path
 * (AccountTriggerHandler -> MultiTierRollupService) covers the normal flow;
 * this job self-heals anything missed (bulk data loads that update Risk_Tier__c
 * without going through the trigger, mid-air recursion-guard skips, etc.).
 *
 * Runs the same worst-case-propagation algorithm from every non-root Supplier
 * Account (every node that has a ParentId). Starting from every edge in the
 * hierarchy recomputes every ancestor up to each root, and is a no-op (cheap)
 * for any node whose cascading tier hasn't actually changed since last run —
 * see MultiTierRollupService's short-circuit.
 *
 * Schedule via scripts/apex/schedule-multi-tier-rollup.apex.
 */
public class MultiTierRollupBatch implements Database.Batchable<SObject>, Schedulable {

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id
            FROM   Account
            WHERE  ParentId != null
              AND  RecordType.DeveloperName = 'Supplier'
        ]);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        Set<Id> ids = new Set<Id>();
        for (SObject s : scope) ids.add((Id) s.get('Id'));
        MultiTierRollupService.rollupFromAccounts(ids);
    }

    public void finish(Database.BatchableContext bc) {}

    public void execute(SchedulableContext sc) {
        Database.executeBatch(new MultiTierRollupBatch(), 50);
    }
}