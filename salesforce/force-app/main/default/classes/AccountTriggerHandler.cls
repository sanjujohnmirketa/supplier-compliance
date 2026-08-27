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
            // Entering its first stage counts as "entering a stage" — see
            // Stage_Entered_DateTime__c and the matching beforeUpdate logic.
            acc.Stage_Entered_DateTime__c = System.now();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // BEFORE UPDATE
    // Use for: enforcing field immutability, cross-field validation.
    // ═════════════════════════════════════════════════════════════════════════
    public void beforeUpdate(List<SObject> newList, Map<Id, SObject> oldMap) {
        // Refresh Stage_Entered_DateTime__c whenever Onboarding_Status__c
        // actually changes, so "days in this stage" (P2/A1 queues) reflects
        // time in the CURRENT stage, not total time since the record was
        // created (that's CreatedDate/Onboarding_Started_Date__c already).
        for (Account acc : (List<Account>) newList) {
            if (!isSupplier(acc)) continue;
            Account old = (Account) oldMap.get(acc.Id);
            if (acc.Onboarding_Status__c != old.Onboarding_Status__c) {
                acc.Stage_Entered_DateTime__c = System.now();
            }
        }
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

        // A newly created sub-supplier changes its parent's descendant count —
        // enqueue a rollup starting from the parent so Sub_Tier_Supplier_Count__c
        // (and cascading tier, if the new child already has one) stays current.
        Set<Id> newParentIds = new Set<Id>();
        for (Account acc : suppliers) {
            if (acc.ParentId != null) newParentIds.add(acc.ParentId);
        }
        if (!newParentIds.isEmpty()) {
            MultiTierRollupService.enqueueRollup(newParentIds);
        }
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

        // Multi-tier cascading-risk roll-up (docs/multi-tier-risk-rollup.md):
        // Account.ParentId is a lookup hierarchy, not Master-Detail, so this
        // can't be a native Roll-Up Summary field — it has to be walked in
        // Apex.
        //
        // Two distinct triggers feed the same MultiTierRollupService, via two
        // different paths:
        //  - STRUCTURAL changes (re-parenting) — enqueued directly here. Not a
        //    "compliance status change", so it doesn't need the platform event.
        //  - Risk_Tier__c OR Risk_Score__c changing (a supplier's own compliance
        //    status moved) — publishes Supplier_Risk_Change__e instead of
        //    calling the rollup directly. SupplierRiskChangeTrigger picks it
        //    up in a fresh transaction after this one commits — real-time,
        //    not a batch job, and it sidesteps TriggerDispatcher's
        //    same-transaction recursion guard (see the class doc there) more
        //    cleanly than enqueuing here would.
        //    Both fields are watched, not just Risk_Tier__c: the cascading
        //    risk SCORE formula is sensitive to the continuous Risk_Score__c
        //    value, so a score moving from e.g. 8 to 24 (both still bucketed
        //    as 'Low', no Risk_Tier__c change) must still re-fire the rollup
        //    or Cascading_Risk_Score__c silently goes stale.
        Set<Id> structuralRollupIds = new Set<Id>();
        List<Supplier_Risk_Change__e> riskChangeEvents = new List<Supplier_Risk_Change__e>();

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

            if (acc.Risk_Tier__c != old.Risk_Tier__c || acc.Risk_Score__c != old.Risk_Score__c) {
                riskChangeEvents.add(new Supplier_Risk_Change__e(
                    Supplier_Id__c   = acc.Id,
                    Old_Risk_Tier__c = old.Risk_Tier__c,
                    New_Risk_Tier__c = acc.Risk_Tier__c
                ));
            }
            if (acc.ParentId != old.ParentId) {
                if (old.ParentId != null) structuralRollupIds.add(old.ParentId);
                if (acc.ParentId != null) structuralRollupIds.add(acc.ParentId);
            }
        }

        if (!changedSuppliers.isEmpty()) {
            ScopeOnboardingService.reEvaluate(changedSuppliers);
        }
        if (!riskChangeEvents.isEmpty()) {
            EventBus.publish(riskChangeEvents);
        }
        if (!structuralRollupIds.isEmpty()) {
            MultiTierRollupService.enqueueRollup(structuralRollupIds);
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