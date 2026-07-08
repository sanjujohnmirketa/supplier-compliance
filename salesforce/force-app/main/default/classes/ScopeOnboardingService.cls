/**
 * ScopeOnboardingService
 * ═══════════════════════════════════════════════════════════════════════════
 * Orchestrates UC-01 supplier onboarding via the local /scope RAG service.
 * Replaces SupplierOnboardingService (which drove the static CMT rule engine).
 *
 * Called from AccountTriggerHandler. Because the checklist now comes from an
 * HTTP callout, the work is deferred to ScopeCalloutQueueable (callouts are
 * not allowed synchronously in a trigger).
 */
public with sharing class ScopeOnboardingService {

    /** after insert — seed the checklist for newly created suppliers. */
    public static void initiateOnboarding(List<Account> suppliers) {
        enqueueScope(suppliers);
    }

    /** after update — re-evaluate when classification inputs change. */
    public static void reEvaluate(List<Account> suppliers) {
        enqueueScope(suppliers);
    }

    private static void enqueueScope(List<Account> suppliers) {
        if (suppliers == null || suppliers.isEmpty()) return;
        Set<Id> ids = new Map<Id, Account>(suppliers).keySet();
        System.enqueueJob(new ScopeCalloutQueueable(ids));
    }
}