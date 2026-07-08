/**
 * AccountTriggerHandler
 *
 * Handles all Account trigger operations by routing to the appropriate
 * service class. Contains ZERO business logic — only routing decisions
 * (which records are suppliers, which fields changed).
 *
 * Service classes called:
 *   SupplierOnboardingService — all supplier onboarding logic
 *
 * Field constants are declared here so the filter conditions are
 * in one place and don't scatter across service classes.
 */
public class AccountTriggerHandler implements ITriggerHandler {

    // ── Record Type filter ────────────────────────────────────────────────────
    // Cache the Supplier Record Type Id once per transaction.
    // Uses lazy initialisation — only fetches if the handler actually runs.
    private static Id supplierRecordTypeId {
        get {
            if (supplierRecordTypeId == null) {
                // Safe: throws a clear error if the RT doesn't exist,
                // rather than silently processing all accounts.
                Map<String, Schema.RecordTypeInfo> rtMap =
                    Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
                if (rtMap.containsKey('Supplier')) {
                    supplierRecordTypeId = rtMap.get('Supplier').getRecordTypeId();
                }
                // If 'Supplier' RT doesn't exist in this org, supplierRecordTypeId
                // remains null and all accounts will be processed — acceptable
                // during initial setup before the RT is created.
            }
            return supplierRecordTypeId;
        }
        private set;
    }

    // ── Fields that, when changed, require re-evaluation of compliance rules ──
    // These are the 6 rule engine trigger inputs from the onboarding flow.
    private static final Set<String> RULE_ENGINE_TRIGGER_FIELDS = new Set<String>{
        'Industry__c',       // Sector — drives which sector rules apply
        'Vendor_Type__c'     // Vendor type — drives which sub-rules apply
        // Supplier_Tier__c, Criticality__c, Direct_or_Indirect__c,
        // Strategic_Region__c live on Supplier_Profile__c — changes to those
        // are handled by SupplierProfileTriggerHandler.
    };

    // ═════════════════════════════════════════════════════════════════════════
    // BEFORE INSERT
    // Use for: setting defaults that can't be set in the Flow (e.g.
    // RecordType-conditional defaults, cross-field defaulting).
    // ═════════════════════════════════════════════════════════════════════════
    public void beforeInsert(List<SObject> newList) {
        List<Account> suppliers = filterSuppliers((List<Account>) newList);
        if (suppliers.isEmpty()) return;

        // Default Onboarding_Status__c to Draft if not already set by the flow.
        // The flow sets it explicitly, but this guard handles API / import inserts.
        for (Account acc : suppliers) {
            if (String.isBlank(acc.Onboarding_Status__c)) {
                acc.Onboarding_Status__c = 'Draft';
            }
            if (acc.Onboarding_Started_Date__c == null) {
                acc.Onboarding_Started_Date__c = Date.today();
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // BEFORE UPDATE
    // Use for: enforcing field immutability, cross-field validation.
    // ═════════════════════════════════════════════════════════════════════════
    public void beforeUpdate(List<SObject> newList, Map<Id, SObject> oldMap) {
        // No before-update logic required for Phase 1.
        // Placeholder for Phase 2: e.g. prevent changing Industry__c
        // after supplier is Approved.
    }

    // ═════════════════════════════════════════════════════════════════════════
    // AFTER INSERT — The critical path for UC-01
    //
    // This is what makes the compliance checklist appear in the onboarding flow.
    //
    // Sequence:
    //   1. Filter to Supplier record type only
    //   2. Call SupplierOnboardingService.initiateOnboarding()
    //      which reads Supplier_Profile__c, matches CMT rules,
    //      and inserts Compliance_Assessment__c records (one per rule)
    //
    // IMPORTANT TIMING NOTE:
    //   This fires synchronously when the flow's Create Account element
    //   commits. The flow has an intermediate "Registration Saved" screen
    //   that forces the commit BEFORE calling getChecklistJSON().
    //   So by the time ComplianceChecklistController queries
    //   Compliance_Assessment__c, these records exist.
    // ═════════════════════════════════════════════════════════════════════════
    public void afterInsert(List<SObject> newList) {
        List<Account> suppliers = filterSuppliers((List<Account>) newList);
        if (suppliers.isEmpty()) return;

        // Checklist now comes from the local /scope RAG service (async callout),
        // replacing the static CMT rule engine (SupplierOnboardingService).
        ScopeOnboardingService.initiateOnboarding(suppliers);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // AFTER UPDATE — Re-evaluate when sector/vendor type changes
    //
    // If a Procurement Manager corrects Industry__c or Vendor_Type__c
    // after initial onboarding, the compliance checklist must be refreshed:
    //  - New rules that now apply → new Compliance_Assessment__c records
    //  - Old rules that no longer apply → existing assessments set to Waived
    // ═════════════════════════════════════════════════════════════════════════
    public void afterUpdate(List<SObject> newList, Map<Id, SObject> oldMap) {
        List<Account> changedSuppliers = new List<Account>();

        for (Account acc : (List<Account>) newList) {
            if (!isSupplier(acc)) continue;

            Account old = (Account) oldMap.get(acc.Id);
            Boolean ruleInputChanged = false;

            for (String fieldName : RULE_ENGINE_TRIGGER_FIELDS) {
                if (acc.get(fieldName) != old.get(fieldName)) {
                    ruleInputChanged = true;
                    break;
                }
            }

            if (ruleInputChanged) {
                changedSuppliers.add(acc);
            }
        }

        if (!changedSuppliers.isEmpty()) {
            ScopeOnboardingService.reEvaluate(changedSuppliers);
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /**
     * Filters a list of Accounts to Supplier record type only.
     * If the Supplier RT doesn't exist yet, returns all accounts
     * (safe during initial org setup).
     */
    private List<Account> filterSuppliers(List<Account> accounts) {
        if (supplierRecordTypeId == null) return accounts;

        List<Account> result = new List<Account>();
        for (Account acc : accounts) {
            if (acc.RecordTypeId == supplierRecordTypeId) {
                result.add(acc);
            }
        }
        return result;
    }

    /**
     * Returns true if a single Account is the Supplier record type.
     */
    private Boolean isSupplier(Account acc) {
        return supplierRecordTypeId == null || acc.RecordTypeId == supplierRecordTypeId;
    }
}