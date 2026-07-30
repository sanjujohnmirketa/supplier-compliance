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
        if (String.isNotBlank(evt.Supplier_Id__c)) {
            try {
                supplierIds.add((Id) evt.Supplier_Id__c);
            } catch (Exception e) {
                // Malformed Id on the event payload — skip it rather than fail the batch.
            }
        }
    }

    if (!supplierIds.isEmpty()) {
        MultiTierRollupService.rollupFromAccounts(supplierIds);
    }
}