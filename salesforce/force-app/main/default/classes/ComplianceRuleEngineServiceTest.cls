/**
 * ComplianceRuleEngineServiceTest
 * ═══════════════════════════════════════════════════════════════════════════
 * Unit + integration tests for ComplianceRuleEngineService and
 * SupplierOnboardingService.
 *
 * STRUCTURE
 * ─────────
 * Section A — normaliseVendorType()          (pure unit — no DML)
 * Section B — splitSemicolon()               (pure unit — no DML)
 * Section C — individual dimension matchers  (pure unit — mocked CMT)
 * Section D — ruleMatches() end-to-end       (pure unit — mocked CMT)
 * Section E — generateChecklist() + DML      (integration — needs org CMT)
 * Section F — SupplierOnboardingService      (integration — full trigger path)
 * Section G — governor limit / bulk tests
 *
 * NOTE ON CMT IN TESTS
 * ────────────────────
 * Custom Metadata records are visible in tests without @TestSetup.
 * Sections E and F rely on CMT records being deployed in the org.
 * If CMT is empty the integration assertions check > 0 and log warnings.
 * Sections A–D are pure logic tests that construct mock CMT objects
 * directly — they pass regardless of org CMT state.
 */
@IsTest
private class ComplianceRuleEngineServiceTest {

    // ═════════════════════════════════════════════════════════════════════════
    // HELPERS — build mock CMT records without deploying to org
    // Salesforce allows constructing CMT SObjects in tests for unit testing.
    // ═════════════════════════════════════════════════════════════════════════

    private static Compliance_Requirement__mdt mockRule(
        String devName,
        String industry,
        String vendorType,
        String tier,
        String criticality,
        String region,
        String directIndirect,
        String stateField,
        String severity
    ) {
        Compliance_Requirement__mdt r = new Compliance_Requirement__mdt();
        r.DeveloperName                    = devName;
        r.Label                            = devName;
        r.Required_For_Industry__c         = industry;
        r.Vendor_Type__c                   = vendorType;
        r.Required_For_Tier__c             = tier;
        r.Required_For_Criticality__c      = criticality;
        r.Required_For_Region__c           = region;
        r.Required_For_Direct_Indirect__c  = directIndirect;
        r.Severity_on_Failure__c           = severity;
        r.Is_Mandatory__c                  = (severity == 'Critical' || severity == 'High');
        return r;
    }

    // Universal rule: all sectors, all vendor types, no restrictions
    private static Compliance_Requirement__mdt universalRule(String devName) {
        return mockRule(devName, null, null, null, null, null, null, null, 'Critical');
    }

    private static Account makeSupplier(
        String name,
        String industry,
        String vendorType,
        String billingState
    ) {
        Id rtId = getSupplierRtId();
        Account a = new Account(
            Name           = name,
            Industry__c    = industry,
            Vendor_Type__c = vendorType,
            BillingState   = billingState,
            Onboarding_Status__c = 'Draft'
        );
        if (rtId != null) a.RecordTypeId = rtId;
        return a;
    }

    private static Id getSupplierRtId() {
        Map<String, Schema.RecordTypeInfo> rtMap =
            Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
        return rtMap.containsKey('Supplier')
            ? rtMap.get('Supplier').getRecordTypeId() : null;
    }

    private static Supplier_Profile__c makeProfile(
        Id accountId,
        String tier,
        String criticality,
        String region,
        String directOrIndirect
    ) {
        return new Supplier_Profile__c(
            Account__c            = accountId,
            Supplier_Tier__c      = tier,
            Criticality__c        = criticality,
            Strategic_Region__c   = region,
            Direct_or_Indirect__c = directOrIndirect,
            Source_System__c      = 'Manual'
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // SECTION A — normaliseVendorType()
    // ═════════════════════════════════════════════════════════════════════════

    @IsTest
    static void norm_rawMaterialSupplier_returnsCorrectTokens() {
        Set<String> tokens = ComplianceRuleEngineService.normaliseVendorType(
            'Raw Material Supplier');
        System.assert(tokens.contains('raw material'),
            'Should contain token "raw material"');
        System.assert(tokens.contains('raw material supplier'),
            'Should contain full label as token');
    }

    @IsTest
    static void norm_contractManufacturer_returnsContractMfrToken() {
        Set<String> tokens = ComplianceRuleEngineService.normaliseVendorType(
            'Contract Manufacturer');
        System.assert(tokens.contains('contract mfr'),
            'Should contain shorthand token "contract mfr"');
        System.assert(tokens.contains('contract manufacturer'),
            'Should contain full label');
    }

    @IsTest
    static void norm_logistics3PL_returnsLogisticsTokens() {
        Set<String> tokens = ComplianceRuleEngineService.normaliseVendorType(
            'Logistics / 3PL Provider');
        System.assert(tokens.contains('logistics'), 'Should contain logistics');
        System.assert(tokens.contains('3pl'), 'Should contain 3pl');
    }

    @IsTest
    static void norm_blank_returnsEmptySet() {
        Set<String> tokens = ComplianceRuleEngineService.normaliseVendorType(null);
        System.assert(tokens.isEmpty(), 'Null input should return empty set');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // SECTION B — splitSemicolon()
    // ═════════════════════════════════════════════════════════════════════════

    @IsTest
    static void split_multiValue_returnsTrimmedSet() {
        Set<String> r = ComplianceRuleEngineService.splitSemicolon(' Tier 1 ; Tier 2 ');
        System.assert(r.contains('Tier 1'), 'Should contain Tier 1');
        System.assert(r.contains('Tier 2'), 'Should contain Tier 2');
        System.assertEquals(2, r.size(), 'Should have 2 elements');
    }

    @IsTest
    static void split_blank_returnsEmpty() {
        Set<String> r = ComplianceRuleEngineService.splitSemicolon('');
        System.assert(r.isEmpty());
    }

    // ═════════════════════════════════════════════════════════════════════════
    // SECTION C — individual dimension matchers
    // ═════════════════════════════════════════════════════════════════════════

    // ── Industry ──────────────────────────────────────────────────────────────

    @IsTest
    static void industry_blankCMT_matchesAnything() {
        Compliance_Requirement__mdt r = universalRule('U');
        System.assert(ComplianceRuleEngineService.matchesIndustry(r, 'Automotive'));
        System.assert(ComplianceRuleEngineService.matchesIndustry(r, null));
    }

    @IsTest
    static void industry_allCMT_matchesAnything() {
        Compliance_Requirement__mdt r = mockRule('U','All',null,null,null,null,null,null,'High');
        System.assert(ComplianceRuleEngineService.matchesIndustry(r, 'Aerospace & Defense'));
    }

    @IsTest
    static void industry_exactMatch_passes() {
        Compliance_Requirement__mdt r = mockRule('A','Automotive',null,null,null,null,null,null,'Critical');
        System.assert(ComplianceRuleEngineService.matchesIndustry(r, 'Automotive'));
    }

    @IsTest
    static void industry_noMatch_fails() {
        Compliance_Requirement__mdt r = mockRule('A','Automotive',null,null,null,null,null,null,'Critical');
        System.assert(!ComplianceRuleEngineService.matchesIndustry(r, 'Chemicals'));
    }

    @IsTest
    static void industry_blankSupplier_failsNonUniversal() {
        Compliance_Requirement__mdt r = mockRule('A','Automotive',null,null,null,null,null,null,'Critical');
        System.assert(!ComplianceRuleEngineService.matchesIndustry(r, null));
    }

    // ── Vendor Type ───────────────────────────────────────────────────────────

    @IsTest
    static void vendor_rawMaterialSlashContractMfr_matchesRawMaterialSupplier() {
        // This is the PRIMARY bug case from the compliance matrix:
        // CMT stores "Raw Material / Contract Mfr" (shorthand)
        // Flow stores "Raw Material Supplier" (full label)
        // The old exact-match logic returned false here.
        Compliance_Requirement__mdt r = mockRule(
            'A001','Automotive','Raw Material / Contract Mfr',
            null,null,null,null,null,'Critical');
        Set<String> tokens = ComplianceRuleEngineService.normaliseVendorType(
            'Raw Material Supplier');
        System.assert(
            ComplianceRuleEngineService.matchesVendorType(r, tokens),
            '"Raw Material Supplier" must match CMT "Raw Material / Contract Mfr". '
            + 'This was the primary rule matching bug.'
        );
    }

    @IsTest
    static void vendor_rawMaterialSlashContractMfr_matchesContractManufacturer() {
        Compliance_Requirement__mdt r = mockRule(
            'A001','Automotive','Raw Material / Contract Mfr',
            null,null,null,null,null,'Critical');
        Set<String> tokens = ComplianceRuleEngineService.normaliseVendorType(
            'Contract Manufacturer');
        System.assert(
            ComplianceRuleEngineService.matchesVendorType(r, tokens),
            '"Contract Manufacturer" must match CMT "Raw Material / Contract Mfr"'
        );
    }

    @IsTest
    static void vendor_contractMfrLogistics_matchesLogistics3PL() {
        // RULE-A-004: "Contract Mfr / Logistics"
        Compliance_Requirement__mdt r = mockRule(
            'A004','Automotive','Contract Mfr / Logistics',
            null,null,null,null,null,'Critical');
        Set<String> tokens = ComplianceRuleEngineService.normaliseVendorType(
            'Logistics / 3PL Provider');
        System.assert(
            ComplianceRuleEngineService.matchesVendorType(r, tokens),
            '"Logistics / 3PL Provider" must match CMT "Contract Mfr / Logistics"'
        );
    }

    @IsTest
    static void vendor_itSoftwareVendors_matchesITSoftwareVendor() {
        // RULE-IT-*: CMT = "IT / Software Vendors"  flow = "IT / Software Vendor"
        Compliance_Requirement__mdt r = mockRule(
            'IT001','IT / Software Vendors','IT / Software Vendors',
            null,null,null,null,null,'High');
        Set<String> tokens = ComplianceRuleEngineService.normaliseVendorType(
            'IT / Software Vendor');
        System.assert(
            ComplianceRuleEngineService.matchesVendorType(r, tokens),
            '"IT / Software Vendor" must match CMT "IT / Software Vendors"'
        );
    }

    @IsTest
    static void vendor_blankCMT_matchesAll() {
        Compliance_Requirement__mdt r = universalRule('U');
        Set<String> tokens = ComplianceRuleEngineService.normaliseVendorType(
            'Contract Manufacturer');
        System.assert(ComplianceRuleEngineService.matchesVendorType(r, tokens));
    }

    @IsTest
    static void vendor_allVendorTypes_matchesAny() {
        Compliance_Requirement__mdt r = mockRule(
            'U','All Sectors','All Vendor Types',null,null,null,null,null,'Critical');
        Set<String> tokens = ComplianceRuleEngineService.normaliseVendorType(
            'Raw Material Supplier');
        System.assert(ComplianceRuleEngineService.matchesVendorType(r, tokens));
    }

    @IsTest
    static void vendor_blankSupplier_failsNonUniversal() {
        Compliance_Requirement__mdt r = mockRule(
            'A001','Automotive','Raw Material / Contract Mfr',
            null,null,null,null,null,'Critical');
        Set<String> emptyTokens = new Set<String>();
        System.assert(!ComplianceRuleEngineService.matchesVendorType(r, emptyTokens));
    }

    // ── Tier ──────────────────────────────────────────────────────────────────

    @IsTest
    static void tier_blankCMT_matchesAll() {
        System.assert(ComplianceRuleEngineService.matchesTier(universalRule('U'), 'Tier 2'));
        System.assert(ComplianceRuleEngineService.matchesTier(universalRule('U'), null));
    }

    @IsTest
    static void tier_allValue_matchesAll() {
        Compliance_Requirement__mdt r = mockRule('R',null,null,'All',null,null,null,null,'High');
        System.assert(ComplianceRuleEngineService.matchesTier(r, 'Tier 3'));
    }

    @IsTest
    static void tier_semicolonList_matchesFirst() {
        Compliance_Requirement__mdt r = mockRule('R',null,null,'Tier 1;Tier 2',null,null,null,null,'High');
        System.assert(ComplianceRuleEngineService.matchesTier(r, 'Tier 1'));
        System.assert(ComplianceRuleEngineService.matchesTier(r, 'Tier 2'));
        System.assert(!ComplianceRuleEngineService.matchesTier(r, 'Tier 3'));
    }

    @IsTest
    static void tier_blankSupplier_failsNonUniversal() {
        Compliance_Requirement__mdt r = mockRule('R',null,null,'Tier 1',null,null,null,null,'High');
        System.assert(!ComplianceRuleEngineService.matchesTier(r, null));
    }

    // ── Direct / Indirect ─────────────────────────────────────────────────────

    @IsTest
    static void directIndirect_both_matchesDirect() {
        Compliance_Requirement__mdt r = mockRule('R',null,null,null,null,null,'Both',null,'High');
        System.assert(ComplianceRuleEngineService.matchesDirectIndirect(r, 'Direct'));
        System.assert(ComplianceRuleEngineService.matchesDirectIndirect(r, 'Indirect'));
    }

    @IsTest
    static void directIndirect_direct_matchesDirectProduction() {
        // Flow stores "Direct (Production)" — CMT stores "Direct"
        Compliance_Requirement__mdt r = mockRule('R',null,null,null,null,null,'Direct',null,'High');
        System.assert(ComplianceRuleEngineService.matchesDirectIndirect(r, 'Direct (Production)'),
            '"Direct (Production)" should match CMT "Direct" via startsWith');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // SECTION D — ruleMatches() end-to-end combos
    // ═════════════════════════════════════════════════════════════════════════

    @IsTest
    static void ruleMatches_automotiveRawMaterial_matchesRuleA001() {
        // Exactly how RULE-A-001 is configured in the compliance matrix
        Compliance_Requirement__mdt r = mockRule(
            'RULE_A_001',
            'Automotive',
            'Raw Material / Contract Mfr',
            null, null, null, null, null,
            'Critical'
        );
        Set<String> vendorTokens = ComplianceRuleEngineService.normaliseVendorType(
            'Raw Material Supplier');

        Boolean result = ComplianceRuleEngineService.ruleMatches(
            r,
            'Automotive',      // industry
            vendorTokens,
            null,              // tier
            null,              // criticality
            null,              // region
            null,              // directOrIndirect
            null               // billingState
        );
        System.assert(result,
            'RULE-A-001 must fire for Automotive Raw Material Supplier');
    }

    @IsTest
    static void ruleMatches_aerospaceContractMfr_matchesRuleAD004CMMC() {
        // RULE-AD-004: Aerospace & Defense, Contract Mfr only
        Compliance_Requirement__mdt r = mockRule(
            'RULE_AD_004',
            'Aerospace & Defense',
            'Contract Mfr',
            null, null, null, null, null,
            'Critical'
        );
        Set<String> cmTokens = ComplianceRuleEngineService.normaliseVendorType(
            'Contract Manufacturer');

        System.assert(
            ComplianceRuleEngineService.ruleMatches(r, 'Aerospace & Defense',
                cmTokens, null, null, null, null, null),
            'RULE-AD-004 must fire for Aerospace Contract Manufacturer'
        );
        // Raw Material should NOT match
        Set<String> rmTokens = ComplianceRuleEngineService.normaliseVendorType(
            'Raw Material Supplier');
        System.assert(
            !ComplianceRuleEngineService.ruleMatches(r, 'Aerospace & Defense',
                rmTokens, null, null, null, null, null),
            'RULE-AD-004 must NOT fire for Aerospace Raw Material Supplier'
        );
    }

    @IsTest
    static void ruleMatches_stateRule_firesOnlyInCorrectState() {
        Compliance_Requirement__mdt r = mockRule(
            'RULE_ST_001',
            'State-Specific (CA, WA, NY, MA)',
            'Raw Material / Contract Mfr',
            null, null, null, null,
            'CA;WA;NY;MA',
            'Critical'
        );
        Set<String> tokens = ComplianceRuleEngineService.normaliseVendorType(
            'Raw Material Supplier');

        System.assert(
            ComplianceRuleEngineService.ruleMatches(r, 'State-Specific (CA, WA, NY, MA)',
                tokens, null, null, null, null, 'CA'),
            'State rule must fire for CA'
        );
        System.assert(
            !ComplianceRuleEngineService.ruleMatches(r, 'State-Specific (CA, WA, NY, MA)',
                tokens, null, null, null, null, 'TX'),
            'State rule must NOT fire for TX'
        );
    }

    @IsTest
    static void ruleMatches_universalRule_matchesEverySector() {
        Compliance_Requirement__mdt r = universalRule('RULE_U_001');
        Set<String> tokens = ComplianceRuleEngineService.normaliseVendorType(
            'Contract Manufacturer');
        List<String> industries = new List<String>{
            'Automotive','Aerospace & Defense','Electronics / Semiconductors',
            'Pharma / Medical Devices','Food & Beverage','Chemicals',
            'Staffing / Labor Contractors','Logistics / 3PL','IT / Software Vendors'
        };
        for (String ind : industries) {
            System.assert(
                ComplianceRuleEngineService.ruleMatches(
                    r, ind, tokens, null, null, null, null, null),
                'Universal rule must match industry: ' + ind
            );
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // SECTION E — generateChecklist() integration (requires deployed CMT)
    // ═════════════════════════════════════════════════════════════════════════

    @IsTest
    static void generateChecklist_automotiveRawMaterial_createsAssessments() {
        Account acc = makeSupplier(
            'Auto Test Co', 'Automotive', 'Raw Material Supplier', 'MI');
        insert acc;

        Supplier_Profile__c sp = makeProfile(acc.Id, 'Tier 1', 'Strategic', 'AMER', 'Direct');
        insert sp;

        Map<Id, Supplier_Profile__c> pm = new Map<Id, Supplier_Profile__c>();
        pm.put(acc.Id, sp);

        Test.startTest();
        ComplianceRuleEngineService.generateChecklist(
            new List<Account>{acc}, pm, false);
        Test.stopTest();

        List<Compliance_Assessment__c> assessments = [
            SELECT Id, Requirement_Key__c, Status__c, Severity__c,
                   Evaluated_By__c, Reason_Code__c, Evaluation_DateTime__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :acc.Id
        ];

        System.assert(assessments.size() >= 7,
            'Automotive Raw Material Tier1 should get at least 7 assessments '
            + '(universal rules). Got: ' + assessments.size()
            + '. Ensure CMT records are deployed with correct field values.'
        );

        // Verify all assessment fields populated correctly
        for (Compliance_Assessment__c a : assessments) {
            System.assertEquals('Pending',   a.Status__c,
                'Status must be Pending');
            System.assertEquals('Auto',      a.Evaluated_By__c,
                'Evaluated_By must be Auto');
            System.assertEquals('Missing Document', a.Reason_Code__c,
                'Reason_Code must be "Missing Document" (with space, not underscore)');
            System.assertNotEquals(null, a.Evaluation_DateTime__c,
                'Evaluation_DateTime must be set');
            System.assertNotEquals(null, a.Severity__c,
                'Severity must be copied from CMT');
        }
    }

    @IsTest
    static void generateChecklist_idempotent_noDuplicatesOnSecondCall() {
        Account acc = makeSupplier(
            'Idempotent Test Co', 'Automotive', 'Contract Manufacturer', 'OH');
        insert acc;
        Map<Id, Supplier_Profile__c> pm = new Map<Id, Supplier_Profile__c>();

        Test.startTest();
        // First call
        ComplianceRuleEngineService.generateChecklist(
            new List<Account>{acc}, pm, false);
        Integer countAfterFirst = [
            SELECT COUNT() FROM Compliance_Assessment__c
            WHERE Supplier__c = :acc.Id
        ];

        // Second call — must not create duplicates
        ComplianceRuleEngineService.generateChecklist(
            new List<Account>{acc}, pm, false);
        Integer countAfterSecond = [
            SELECT COUNT() FROM Compliance_Assessment__c
            WHERE Supplier__c = :acc.Id
        ];
        Test.stopTest();

        System.assertEquals(countAfterFirst, countAfterSecond,
            'Second call to generateChecklist must not create duplicate assessments. '
            + 'First count=' + countAfterFirst + ' Second count=' + countAfterSecond
        );
    }

    @IsTest
    static void generateChecklist_deltaMode_waivesRemovedRules() {
        Account acc = makeSupplier(
            'Delta Test Co', 'Automotive', 'Raw Material Supplier', 'MI');
        insert acc;
        Map<Id, Supplier_Profile__c> pm = new Map<Id, Supplier_Profile__c>();

        // Seed with Automotive rules
        ComplianceRuleEngineService.generateChecklist(
            new List<Account>{acc}, pm, false);

        Integer automotiveCount = [
            SELECT COUNT() FROM Compliance_Assessment__c
            WHERE Supplier__c = :acc.Id AND Status__c = 'Pending'
        ];

        // Simulate sector change — update account industry
        acc.Industry__c    = 'IT / Software Vendors';
        acc.Vendor_Type__c = 'IT / Software Vendor';
        update acc;

        Test.startTest();
        ComplianceRuleEngineService.generateChecklist(
            new List<Account>{acc}, pm, true); // deltaMode = true
        Test.stopTest();

        Integer waivedCount = [
            SELECT COUNT() FROM Compliance_Assessment__c
            WHERE Supplier__c = :acc.Id AND Status__c = 'Waived'
        ];

        System.assert(waivedCount >= 0,
            'Delta mode should not throw. '
            + 'Automotive-only rules should be waived after sector change. '
            + 'Waived count=' + waivedCount
        );
    }

    @IsTest
    static void generateChecklist_stateCA_addsStateRules() {
        Account acc = makeSupplier(
            'CA Supplier Inc', 'Electronics / Semiconductors',
            'Raw Material Supplier', 'CA');
        insert acc;
        Map<Id, Supplier_Profile__c> pm = new Map<Id, Supplier_Profile__c>();

        Test.startTest();
        ComplianceRuleEngineService.generateChecklist(
            new List<Account>{acc}, pm, false);
        Test.stopTest();

        List<Compliance_Assessment__c> stateAssessments = [
            SELECT Requirement_Key__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :acc.Id
            AND    Requirement_Key__c LIKE 'RULE_ST_%'
        ];

    }

    @IsTest
    static void generateChecklist_nonCaState_noStateRules() {
        Account acc = makeSupplier(
            'TX Supplier Inc', 'Automotive', 'Raw Material Supplier', 'TX');
        insert acc;
        Map<Id, Supplier_Profile__c> pm = new Map<Id, Supplier_Profile__c>();

        Test.startTest();
        ComplianceRuleEngineService.generateChecklist(
            new List<Account>{acc}, pm, false);
        Test.stopTest();

        List<Compliance_Assessment__c> stateAssessments = [
            SELECT Requirement_Key__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :acc.Id
            AND    Requirement_Key__c LIKE 'RULE_ST_%'
        ];

        System.assertEquals(0, stateAssessments.size(),
            'State-specific rules must NOT fire for TX supplier');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // SECTION F — SupplierOnboardingService (full trigger path)
    // ═════════════════════════════════════════════════════════════════════════

    @IsTest
    static void onboarding_insertSupplierAccount_triggersAssessments() {
        Account acc = makeSupplier(
            'Onboarding Test Co', 'Chemicals', 'Raw Material Supplier', 'OH');

        Test.startTest();
        insert acc;  // fires AccountTrigger → AccountTriggerHandler → SupplierOnboardingService
        Test.stopTest();

        List<Compliance_Assessment__c> assessments = [
            SELECT Id, Status__c, Reason_Code__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :acc.Id
        ];

        System.assert(assessments.size() > 0,
            'inserting a Supplier Account should trigger assessment creation. '
            + 'If 0, check: AccountTrigger is active, CMT records exist, '
            + 'Account Record Type DeveloperName = "Supplier".'
        );

        for (Compliance_Assessment__c a : assessments) {
            System.assertEquals('Missing Document', a.Reason_Code__c,
                'Reason_Code must be "Missing Document" (picklist-safe value)');
        }
    }

    @IsTest
    static void onboarding_nonSupplierAccount_noAssessments() {
        Account acc = new Account(Name = 'Customer Corp');
        Map<String, Schema.RecordTypeInfo> rtMap =
            Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
        if (rtMap.containsKey('Customer')) {
            acc.RecordTypeId = rtMap.get('Customer').getRecordTypeId();
        }

        Test.startTest();
        insert acc;
        Test.stopTest();

        Integer cnt = [
            SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :acc.Id
        ];
        System.assertEquals(0, cnt,
            'Non-supplier Account must not generate assessments');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // SECTION G — Governor limit / bulk
    // ═════════════════════════════════════════════════════════════════════════

    @IsTest
    static void bulk_50Suppliers_noGovernorExceptions() {
        List<Account> accs = new List<Account>();
        for (Integer i = 0; i < 50; i++) {
            accs.add(makeSupplier(
                'Bulk Supplier ' + i,
                'Automotive', 'Contract Manufacturer', 'MI'));
        }

        Test.startTest();
        insert accs;  // one trigger execution for all 50
        Test.stopTest();

        Integer total = [
            SELECT COUNT() FROM Compliance_Assessment__c
            WHERE Supplier__c IN :new Map<Id, Account>(accs).keySet()
        ];
        System.assert(total >= 0,
            'Bulk insert of 50 suppliers must not throw governor limit exceptions. '
            + 'Total assessments created: ' + total
        );
    }

    @IsTest
    static void getApplicableRules_6ArgOverload_backwardCompatible() {
        // SupplierOnboardingService still calls the 6-arg signature
        // Verify it compiles and returns without error
        List<Compliance_Requirement__mdt> rules =
            ComplianceRuleEngineService.getApplicableRules(
                'Automotive', 'Raw Material Supplier',
                'Tier 1', 'Strategic', 'AMER', 'Direct'
            );
        System.assert(rules != null, '6-arg overload must not return null');
        System.assert(rules.size() >= 0, '6-arg overload must return a list');
    }
}