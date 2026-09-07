/**
 * SupplierProfileTriggerHandler
 *
 * Handles Supplier_Profile__c trigger operations.
 * Contains ZERO business logic — only routing decisions
 * (which profile fields changed, which accounts to re-evaluate).
 *
 * WHY THIS EXISTS
 * ───────────────
 * Supplier_Tier__c, Criticality__c, Direct_or_Indirect__c, and
 * Strategic_Region__c live on Supplier_Profile__c, not Account.
 * The compliance rule engine needs these four fields to determine
 * which documents are required (Tier 1 vs Tier 2, Critical vs Non-Critical,
 * Direct vs Indirect, etc.).
 *
 * When procurement creates only an Account record first (no profile yet),
 * AccountTrigger.afterInsert seeds the checklist with only the universal
 * rules (those with no dimension filter on profile fields).
 * Profile-specific rules are skipped because profile is null.
 *
 * This handler fills that gap:
 *   - afterInsert:  profile was just created → add the rules that now match
 *   - afterUpdate:  a profile dimension changed → re-evaluate and waive
 *                   rules that no longer apply, add rules that now apply
 *
 * Service classes called:
 *   SupplierOnboardingService.initiateOnboarding()        (afterInsert)
 *   SupplierOnboardingService.reEvaluateOnSectorChange()  (afterUpdate)
 */
// Explicit without sharing (Apex's own default when undeclared — no behavior
// change): must re-evaluate the linked Account/checklist regardless of which
// user's edit fired the trigger.
//
// SYSTEM CONTEXT BY DESIGN (documented CRUD/FLS scanner exception): trigger
// handlers run inside the platform's DML pipeline; the user whose edit fired
// the trigger may hold no Read on Account or the checklist rows this handler
// must re-evaluate, and the re-evaluation must happen regardless. No Schema/
// stripInaccessible check is applied to the SOQL in this class.
public without sharing class SupplierProfileTriggerHandler implements ITriggerHandler {

    // ── Fields that, when changed, require re-evaluation of compliance rules ──
    // These are the four rule engine inputs that live on Supplier_Profile__c
    // (the other three — Industry__c, Vendor_Type__c, BillingState — live on Account).
    private static final Set<String> PROFILE_RULE_FIELDS = new Set<String>{
        'Supplier_Tier__c',
        'Criticality__c',
        'Direct_or_Indirect__c',
        'Strategic_Region__c'
    };

    // ═════════════════════════════════════════════════════════════════════════
    // BEFORE INSERT / BEFORE UPDATE  (no-ops for this object)
    // ═════════════════════════════════════════════════════════════════════════
    public void beforeInsert(List<SObject> newList) {}

    public void beforeUpdate(List<SObject> newList, Map<Id, SObject> oldMap) {}

    // ═════════════════════════════════════════════════════════════════════════
    // AFTER INSERT
    //
    // A Supplier_Profile__c was just created for an Account that may already
    // have a partial compliance checklist (seeded when the Account was inserted,
    // before the profile existed).
    //
    // Re-run initiateOnboarding() with deltaMode=false:
    //   - The now-populated profile fields will match profile-specific CMT rules
    //   - Assessments for universal rules (already created) are skipped
    //     by the composite-key duplicate guard in generateChecklist()
    //   - Only net-new rules produce new Compliance_Assessment__c records
    // ═════════════════════════════════════════════════════════════════════════
    public void afterInsert(List<SObject> newList) {
        Set<Id> accountIds = collectAccountIds((List<Supplier_Profile__c>) newList);
        if (accountIds.isEmpty()) return;

        reEvaluateAccounts(accountIds, false);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // AFTER UPDATE
    //
    // One or more of the four profile rule fields changed — the supplier's
    // compliance profile has been reclassified (e.g. Tier 1 → Tier 2).
    //
    // Re-run reEvaluateOnSectorChange() with deltaMode=true:
    //   - Rules that no longer match are Waived
    //   - Rules that newly match produce new Compliance_Assessment__c records
    // ═════════════════════════════════════════════════════════════════════════
    public void afterUpdate(List<SObject> newList, Map<Id, SObject> oldMap) {
        Set<Id> accountIds = new Set<Id>();

        for (Supplier_Profile__c sp : (List<Supplier_Profile__c>) newList) {
            if (sp.Account__c == null) continue;

            Supplier_Profile__c old = (Supplier_Profile__c) oldMap.get(sp.Id);
            for (String field : PROFILE_RULE_FIELDS) {
                if (sp.get(field) != old.get(field)) {
                    accountIds.add(sp.Account__c);
                    break;
                }
            }
        }

        if (accountIds.isEmpty()) return;
        reEvaluateAccounts(accountIds, true);
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /**
     * Fetches Account records for the given IDs (Supplier RT only) and
     * delegates to the appropriate SupplierOnboardingService method.
     *
     * @param accountIds  Accounts whose compliance checklists need refreshing
     * @param deltaMode   false = insert (only add new rules)
     *                    true  = update (waive removed rules + add new ones)
     */
    private static void reEvaluateAccounts(Set<Id> accountIds, Boolean deltaMode) {
        List<Account> accounts = [
            SELECT Id,
                   Industry__c,
                   Vendor_Type__c,
                   BillingState,
                   Onboarding_Status__c,
                   RecordType.DeveloperName
            FROM   Account
            WHERE  Id IN :accountIds
            AND    RecordType.DeveloperName = 'Supplier'
        ];
        if (accounts.isEmpty()) return;

        // Re-run the /scope RAG checklist now that profile dimensions
        // (Tier / Criticality / Region / Direct-Indirect) are known.
        if (deltaMode) {
            ScopeOnboardingService.reEvaluate(accounts);
        } else {
            ScopeOnboardingService.initiateOnboarding(accounts);
        }
    }

    /**
     * Extracts the non-null Account__c values from a list of profiles.
     */
    private static Set<Id> collectAccountIds(List<Supplier_Profile__c> profiles) {
        Set<Id> ids = new Set<Id>();
        for (Supplier_Profile__c sp : profiles) {
            if (sp.Account__c != null) ids.add(sp.Account__c);
        }
        return ids;
    }
}