/**
 * AccountTrigger
 *
 * Entry point for all Account trigger operations.
 * Contains exactly ONE line of logic — everything else
 * is in AccountTriggerHandler and the service layer.
 *
 * Operations handled:
 *   after insert  → SupplierOnboardingService.initiateOnboarding()
 *   after update  → SupplierOnboardingService.reEvaluateOnSectorChange()
 *   before insert → AccountTriggerHandler.beforeInsert() (defaulting)
 *   before update → AccountTriggerHandler.beforeUpdate() (field validation)
 */
trigger AccountTrigger on Account (before insert, before update, after insert, after update) {
    TriggerDispatcher.run(new AccountTriggerHandler());
}