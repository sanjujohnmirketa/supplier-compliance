/**
 * MultiTierRollupQueueable — async wrapper around MultiTierRollupService.
 * Enqueued by AccountTriggerHandler whenever a supplier's own Risk_Tier__c
 * changes or it's re-parented, so the walk up the ParentId chain happens
 * outside the triggering DML transaction (bulk-safe, no callouts needed).
 */
public class MultiTierRollupQueueable implements Queueable {

    private Set<Id> accountIds;

    public MultiTierRollupQueueable(Set<Id> accountIds) {
        this.accountIds = accountIds;
    }

    public void execute(QueueableContext context) {
        MultiTierRollupService.rollupFromAccounts(accountIds);
    }
}