/**
 * SupplierProfileTrigger
 *
 * Entry point for all Supplier_Profile__c trigger operations.
 * Contains exactly ONE line of logic — everything else is in
 * SupplierProfileTriggerHandler and the service layer.
 *
 * Operations handled:
 *   after insert → re-run compliance checklist for the associated Account
 *                  now that Tier/Criticality/Region/DirectIndirect are known
 *   after update → re-evaluate compliance checklist when any of the four
 *                  rule-engine profile fields change
 */
trigger SupplierProfileTrigger on Supplier_Profile__c (after insert, after update) {
    TriggerDispatcher.run(new SupplierProfileTriggerHandler());
}