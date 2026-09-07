/**
 * SupplierOnboardingService
 * ═══════════════════════════════════════════════════════════════════════════
 * Orchestrates the UC-01 supplier onboarding workflow.
 * Called from AccountTriggerHandler — never directly from Flow.
 *
 * CHANGES FROM PREVIOUS VERSION
 * ──────────────────────────────
 * 1. initiateOnboarding() now delegates checklist seeding to
 *    ComplianceRuleEngineService.generateChecklist() instead of
 *    calling getApplicableRules() and building assessments inline.
 *    This keeps the two classes single-responsibility.
 *
 * 2. BillingState is now passed so RULE-ST-* state rules fire correctly
 *    for suppliers in CA / WA / NY / MA.
 *
 * 3. profileMap is fetched once here and passed into generateChecklist()
 *    so the rule engine does not need its own SOQL.
 *
 * 4. Reason_Code__c bug fixed: 'Missing Document' (not 'Missing_Document').
 *
 * TRANSACTION CONTEXT
 * ───────────────────
 * Runs synchronously in the same transaction as the Account insert.
 * The flow's "Registration Saved" intermediate screen commits the
 * transaction before ComplianceChecklistController.getChecklistJSON()
 * queries Compliance_Assessment__c — so the records inserted here
 * are visible to the subsequent flow query.
 */
public with sharing class SupplierOnboardingService {

    // ── Constants ─────────────────────────────────────────────────────────────
    private static final String STATUS_DRAFT     = 'Draft';
    private static final String STATUS_IN_REVIEW = 'In Review';

    // ═════════════════════════════════════════════════════════════════════════
    // initiateOnboarding
    //
    // Called by AccountTriggerHandler.afterInsert().
    //
    // Steps:
    //   1. Bulk-fetch Supplier_Profile__c for all accounts (one SOQL)
    //   2. Delegate to ComplianceRuleEngineService.generateChecklist()
    //      which matches CMT rules and inserts Compliance_Assessment__c
    //   3. Account.Onboarding_Status__c already advanced inside generateChecklist
    // ═════════════════════════════════════════════════════════════════════════
    public static void initiateOnboarding(List<Account> suppliers) {
        if (suppliers == null || suppliers.isEmpty()) return;

        Map<Id, Supplier_Profile__c> profileMap = fetchProfiles(suppliers);

        // generateChecklist handles:
        //   - rule matching across 7 dimensions (including BillingState)
        //   - duplicate guard (won't create if assessment already exists)
        //   - bulk insert with partial-success error logging
        //   - Account.Onboarding_Status__c Draft → In Review
        ComplianceRuleEngineService.generateChecklist(
            suppliers,
            profileMap,
            false   // deltaMode = false: new onboarding, not a re-evaluation
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // reEvaluateOnSectorChange
    //
    // Called by AccountTriggerHandler.afterUpdate() when Industry__c or
    // Vendor_Type__c changes.
    //
    // Passes deltaMode = true so generateChecklist() also waives rules
    // that no longer apply under the new classification.
    // ═════════════════════════════════════════════════════════════════════════
    public static void reEvaluateOnSectorChange(List<Account> accounts) {
        if (accounts == null || accounts.isEmpty()) return;

        Map<Id, Supplier_Profile__c> profileMap = fetchProfiles(accounts);

        ComplianceRuleEngineService.generateChecklist(
            accounts,
            profileMap,
            true    // deltaMode = true: waive removed rules, add new ones
        );
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /**
     * Fetches Supplier_Profile__c for all accounts in one SOQL.
     * Returns Map<AccountId, Profile>.
     * Includes BillingState via Account in caller context — the profile
     * stores Tier/Criticality/Region/DirectIndirect.
     */
    private static Map<Id, Supplier_Profile__c> fetchProfiles(
        List<Account> accounts
    ) {
        Set<Id> accountIds = new Map<Id, Account>(accounts).keySet();

        Map<Id, Supplier_Profile__c> result =
            new Map<Id, Supplier_Profile__c>();

        for (Supplier_Profile__c sp : [
            SELECT  Id,
                    Account__c,
                    Supplier_Tier__c,
                    Criticality__c,
                    Direct_or_Indirect__c,
                    Strategic_Region__c
            FROM    Supplier_Profile__c
            WHERE   Account__c IN :accountIds
        ]) {
            result.put(sp.Account__c, sp);
        }
        return result;
    }
}