/**
 * SupplierRiskChangeTrigger — subscribes to Supplier_Risk_Change__e, published
 * by AccountTriggerHandler whenever a supplier's own Risk_Tier__c changes.
 *
 * This is the real-time (not batch) path the cascading risk SCORE feature is
 * built around: platform event delivery already runs after the publishing
 * transaction commits, in its own fresh transaction, so it can drive
 * MultiTierRollupService directly with no recursion-guard concerns.
 *
 * Bulk-safe: collects every event's Supplier_Id__c in this delivery batch
 * (platform events can deliver up to 2,000 at once) into one Set and makes a
 * single rollup call.
 */
trigger SupplierRiskChangeTrigger on Supplier_Risk_Change__e (after insert) {

    Set<Id> supplierIds = new Set<Id>();
    for (Supplier_Risk_Change__e evt : Trigger.new) {
        // instanceOf Id validates the payload without throwing — a malformed
        // Id on the event is skipped rather than failing the whole batch.
        if (String.isNotBlank(evt.Supplier_Id__c) && evt.Supplier_Id__c instanceOf Id) {
            supplierIds.add((Id) evt.Supplier_Id__c);
        }
    }

    if (!supplierIds.isEmpty()) {
        MultiTierRollupService.rollupFromAccounts(supplierIds);
    }
}