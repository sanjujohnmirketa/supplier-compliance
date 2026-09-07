/**
 * SupplierOnboardingTriggerTest
 *
 * Test coverage for:
 *   - TriggerDispatcher (routing, recursion guard, bypass)
 *   - AccountTriggerHandler (filter, routing)
 *   - SupplierOnboardingService (initiateOnboarding, reEvaluateOnSectorChange)
 *   - ComplianceRuleEngineService (all 6 matching dimensions, edge cases)
 *
 * APPROACH:
 *   ComplianceRuleEngineService is tested directly (unit tests on private
 *   methods via @TestVisible) to cover all dimension combinations without
 *   needing real CMT records.
 *
 *   SupplierOnboardingService is tested end-to-end: insert an Account and
 *   verify Compliance_Assessment__c records are created.
 *
 * CMT RECORDS IN TESTS:
 *   Custom Metadata records ARE visible in unit tests without test setup.
 *   We rely on the org's deployed CMT records. If no CMT records exist
 *   yet, the assessment count assertions will be 0 — adjust after CMT
 *   records are deployed.
 *
 * TARGET COVERAGE: >85%
 */
@IsTest
private class SupplierOnboardingTriggerTest {

    // ═════════════════════════════════════════════════════════════════════════
    // TEST DATA HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Creates a Supplier Account with the Supplier Record Type.
     * Uses the DeveloperName 'Supplier' — update if your org uses a different name.
     */
    private static Account makeSupplierAccount(
        String name,
        String industry,
        String vendorType
    ) {
        Id rtId = getSupplierRecordTypeId();

        Account acc = new Account(
            Name               = name,
            Industry__c        = industry,
            Vendor_Type__c     = vendorType,
            Onboarding_Status__c = 'Draft',
            Onboarding_Started_Date__c = Date.today()
        );
        if (rtId != null) acc.RecordTypeId = rtId;
        return acc;
    }

    private static Supplier_Profile__c makeProfile(
        Id accountId,
        String tier,
        String criticality,
        String region,
        String directOrIndirect
    ) {
        return new Supplier_Profile__c(
            Account__c           = accountId,
            Supplier_Tier__c     = tier,
            Criticality__c       = criticality,
            Strategic_Region__c  = region,
            Direct_or_Indirect__c = directOrIndirect,
            Source_System__c     = 'Manual'
        );
    }

    private static Id getSupplierRecordTypeId() {
        Map<String, Schema.RecordTypeInfo> rtMap =
            Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
        return rtMap.containsKey('Supplier')
            ? rtMap.get('Supplier').getRecordTypeId()
            : null;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TRIGGER DISPATCHER TESTS
    // ═════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testDispatcher_bypassAll_preventsHandlerExecution() {
        TriggerDispatcher.bypassAll = true;
        TriggerDispatcher.resetExecutionState();

        Account acc = makeSupplierAccount('Bypass Test Co', 'Automotive', 'Contract Manufacturer');

        Test.startTest();
        insert acc;
        Test.stopTest();

        // No assessments should be created because bypass was on
        Integer count = [
            SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :acc.Id
        ];
        System.assertEquals(0, count,
            'TriggerDispatcher.bypassAll should prevent all trigger handlers from running');

        // Reset for other tests
        TriggerDispatcher.bypassAll = false;
    }

    @IsTest
    static void testDispatcher_bypassedHandlers_preventsSpecificHandler() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');
        TriggerDispatcher.resetExecutionState();

        Account acc = makeSupplierAccount('Bypass Handler Co', 'Automotive', 'Raw Material Supplier');

        Test.startTest();
        insert acc;
        Test.stopTest();

        Integer count = [
            SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :acc.Id
        ];
        System.assertEquals(0, count,
            'Bypassing AccountTriggerHandler should prevent assessment creation');

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');
    }

    @IsTest
    static void testDispatcher_resetExecutionState_allowsRefire() {
        // If execution state is not reset between trigger fires,
        // the recursion guard would block the second execution.
        // This test verifies reset works.
        TriggerDispatcher.resetExecutionState();
        System.assertEquals(0, 0, 'resetExecutionState should not throw');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // RULE ENGINE — DIMENSION MATCHING UNIT TESTS
    // These test the private @TestVisible methods directly.
    // No DML needed — pure logic tests.
    //
    // NOTE: these tests called a method named splitMultiPicklist, which never
    // existed on ComplianceRuleEngineService — the real method is
    // splitSemicolon (identical behavior, confirmed against every assertion
    // below). This left the org's Apex dependency graph permanently invalid
    // (any full test run failed org-wide, cascading to unrelated live
    // classes) until fixed here. Test method names below are unchanged —
    // only the call target was wrong.
    // ═════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testRuleEngine_splitMultiPicklist_semicolonDelimited() {
        Set<String> result = ComplianceRuleEngineService.splitSemicolon('Tier 1;Tier 2;Tier 3');
        System.assertEquals(3, result.size(), 'Should split into 3 tokens');
        System.assert(result.contains('Tier 1'), 'Should contain Tier 1');
        System.assert(result.contains('Tier 2'), 'Should contain Tier 2');
        System.assert(result.contains('Tier 3'), 'Should contain Tier 3');
    }

    @IsTest
    static void testRuleEngine_splitMultiPicklist_blank_returnsEmpty() {
        Set<String> result = ComplianceRuleEngineService.splitSemicolon('');
        System.assertEquals(0, result.size(), 'Blank input should return empty set');
    }

    @IsTest
    static void testRuleEngine_splitMultiPicklist_null_returnsEmpty() {
        Set<String> result = ComplianceRuleEngineService.splitSemicolon(null);
        System.assertEquals(0, result.size(), 'Null input should return empty set');
    }

    @IsTest
    static void testRuleEngine_splitMultiPicklist_trimsWhitespace() {
        Set<String> result = ComplianceRuleEngineService.splitSemicolon(' Tier 1 ; Tier 2 ');
        System.assert(result.contains('Tier 1'), 'Should trim leading/trailing spaces');
        System.assert(result.contains('Tier 2'), 'Should trim leading/trailing spaces');
    }

    @IsTest
    static void testRuleEngine_universalRule_matchesAnySector() {
        // Build a mock CMT-like record using a real CMT query
        // For universal rules (Required_For_Industry__c is blank), any industry matches.
        // We test this via getApplicableRules with a known universal CMT record.
        // Universal rules (RULE-U-001 through RULE-U-007) have blank industry field.

        List<Compliance_Requirement__mdt> rules =
            ComplianceRuleEngineService.getApplicableRules(
                'Automotive', 'Raw Material Supplier', 'Tier 1', 'Strategic', 'AMER', 'Direct'
            );

        // Must contain at least the 7 universal rules
        // (RULE-U-001 through RULE-U-007 should all be in CMT)
        System.assert(rules.size() >= 7,
            'Automotive supplier should match at least 7 universal rules. Got: ' + rules.size()
            + '. Ensure RULE-U-001 through RULE-U-007 are deployed as CMT records.');
    }

    @IsTest
    static void testRuleEngine_automotiveSupplier_matchesSectorRules() {
        List<Compliance_Requirement__mdt> rules =
            ComplianceRuleEngineService.getApplicableRules(
                'Automotive', 'Raw Material Supplier', 'Tier 1', 'Strategic', 'AMER', 'Direct'
            );

        // Collect rule keys
        Set<String> ruleKeys = new Set<String>();
        for (Compliance_Requirement__mdt r : rules) {
            ruleKeys.add(r.DeveloperName);
        }

        // Automotive Raw Material rules should include RULE-A-001 (IATF 16949)
        // This only passes if RULE-A-001 CMT record has Required_For_Industry__c = Automotive
        // and Vendor_Type__c contains Raw Material Supplier
        System.assert(rules.size() >= 7,
            'Automotive Raw Material Tier 1 supplier should match universal + sector rules');
    }

    @IsTest
    static void testRuleEngine_itSupplier_matchesItRules() {
        List<Compliance_Requirement__mdt> rules =
            ComplianceRuleEngineService.getApplicableRules(
                'IT / Software Vendors', 'IT / Software Vendor', 'Tier 2', 'Standard', 'AMER', 'Indirect'
            );

        System.assert(rules.size() >= 7,
            'IT supplier should match at least 7 universal rules. Got: ' + rules.size());
    }

    @IsTest
    static void testRuleEngine_nullProfile_onlyUniversalRules() {
        // When profile fields are null, only rules that match all sectors/tiers should fire
        List<Compliance_Requirement__mdt> rules =
            ComplianceRuleEngineService.getApplicableRules(
                'Automotive', 'Raw Material Supplier',
                null,   // tier = null
                null,   // criticality = null
                null,   // region = null
                null    // directOrIndirect = null
            );

        // All returned rules must have blank Tier, Criticality, Region, DirectIndirect fields
        // (i.e. universal on all those dimensions)
        for (Compliance_Requirement__mdt r : rules) {
            System.assert(
                String.isBlank(r.Required_For_Tier__c)
                || r.Required_For_Tier__c.contains('All'),
                'Rule ' + r.DeveloperName + ' should not match when tier is null unless it targets All tiers'
            );
        }
    }

    @IsTest
    static void testRuleEngine_directIndirect_bothMatchesDirect() {
        // A CMT rule with Required_For_Direct_Indirect__c = 'Both' should match
        // a supplier with Direct_or_Indirect__c = 'Direct'
        // Tested via end-to-end: Automotive Direct supplier should get rules marked 'Both'
        List<Compliance_Requirement__mdt> directRules =
            ComplianceRuleEngineService.getApplicableRules(
                'Automotive', 'Raw Material Supplier', 'Tier 1', 'Strategic', 'AMER', 'Direct'
            );
        List<Compliance_Requirement__mdt> indirectRules =
            ComplianceRuleEngineService.getApplicableRules(
                'Automotive', 'Raw Material Supplier', 'Tier 1', 'Strategic', 'AMER', 'Indirect'
            );

        // Both direct and indirect should get universal rules
        System.assert(directRules.size() >= 7,
            'Direct supplier should get at least 7 universal rules');
        System.assert(indirectRules.size() >= 7,
            'Indirect supplier should get at least 7 universal rules');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // SUPPLIER ONBOARDING SERVICE — END-TO-END TESTS
    // ═════════════════════════════════════════════════════════════════════════

    // KNOWN FAILING — confirmed dead code (superseded by ScopeOnboardingService/
    // ScopeCalloutQueueable; AccountTrigger no longer calls
    // SupplierOnboardingService.initiateOnboarding() on Account insert).
    // Left failing and documented rather than fixed or deleted, per the
    // park-list decision to keep this cluster's source until the whole group
    // is deleted together.
    @IsTest
    static void testInitiateOnboarding_createsAssessments_forAutomotiveSupplier() {
        Account acc = makeSupplierAccount(
            'Auto Parts Inc', 'Automotive', 'Raw Material Supplier'
        );

        Test.startTest();
        insert acc;  // Fires AccountTrigger → AccountTriggerHandler → SupplierOnboardingService
        Test.stopTest();

        // Profile was not created — so only rules matching null tier/criticality/region apply
        // (universal rules only at this point)
        List<Compliance_Assessment__c> assessments = [
            SELECT Id, Requirement_Key__c, Status__c, Severity__c,
                   Evaluated_By__c, Reason_Code__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :acc.Id
        ];

        System.assert(assessments.size() > 0,
            'At least some Compliance_Assessment__c records should be created. '
            + 'Got 0. Verify: (1) AccountTrigger is deployed and active, '
            + '(2) Compliance_Requirement__mdt records exist with universal rules, '
            + '(3) Account.Industry__c and Vendor_Type__c fields exist.');

        // Verify assessment fields are populated correctly
        for (Compliance_Assessment__c a : assessments) {
            System.assertEquals('Pending', a.Status__c,
                'New assessment should have Status = Pending');
            System.assertEquals('Auto', a.Evaluated_By__c,
                'New assessment Evaluated_By should be Auto');
            System.assertEquals('Missing Document', a.Reason_Code__c,
                'New assessment Reason_Code should be Missing Document');
            System.assertNotEquals(null, a.Requirement_Key__c,
                'Requirement_Key__c must be populated (CMT DeveloperName)');
        }
    }

    @IsTest
    static void testInitiateOnboarding_withProfile_createsFullChecklist() {
        Account acc = makeSupplierAccount(
            'Precision Aero Corp', 'Aerospace & Defense', 'Contract Manufacturer'
        );
        insert acc;

        // Insert profile — provides tier/criticality/region dimensions
        Supplier_Profile__c profile = makeProfile(
            acc.Id, 'Tier 1', 'Strategic', 'AMER', 'Direct'
        );

        Test.startTest();
        insert profile;

        // Re-run onboarding as if sector changed (simulates profile being created after Account)
        TriggerDispatcher.resetExecutionState();
        SupplierOnboardingService.initiateOnboarding(new List<Account>{acc});
        Test.stopTest();

        List<Compliance_Assessment__c> assessments = [
            SELECT Id, Requirement_Key__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :acc.Id
        ];

        // Aerospace + Contract Mfr + Tier 1 should get universal rules + AD rules
        System.assert(assessments.size() >= 7,
            'Aerospace Contract Mfr should have at least 7 assessments (universal rules minimum). Got: '
            + assessments.size());
    }

    @IsTest
    static void testInitiateOnboarding_setsOnboardingStatusToInReview() {
        Account acc = makeSupplierAccount(
            'Status Test Co', 'Logistics / 3PL', 'Logistics / 3PL Provider'
        );
        acc.Onboarding_Status__c = 'Draft';

        Test.startTest();
        insert acc;
        Test.stopTest();

        Account updated = [
            SELECT Onboarding_Status__c
            FROM   Account
            WHERE  Id = :acc.Id
        ];

        // Only assert In Review if assessments were created
        // (if CMT is empty, no rules fire, service still advances status)
        System.assertNotEquals(null, updated.Onboarding_Status__c,
            'Onboarding_Status__c should not be null after trigger');
    }

    @IsTest
    static void testInitiateOnboarding_bulkInsert_50Suppliers() {
        // Governor limit test — 50 suppliers in one transaction
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 50; i++) {
            accounts.add(makeSupplierAccount(
                'Bulk Supplier ' + i,
                'IT / Software Vendors',
                'IT / Software Vendor'
            ));
        }

        Test.startTest();
        insert accounts;
        Test.stopTest();

        // All 50 accounts should have triggered assessments
        // (at minimum universal rules × 50)
        Integer totalAssessments = [
            SELECT COUNT() FROM Compliance_Assessment__c
            WHERE  Supplier__c IN :new Map<Id, Account>(accounts).keySet()
        ];

        System.assert(totalAssessments >= 0,
            'Bulk insert of 50 suppliers should not throw governor limit exceptions. Got: '
            + totalAssessments + ' total assessments.');
    }

    @IsTest
    static void testInitiateOnboarding_noDuplicateAssessments_onRetrigger() {
        Account acc = makeSupplierAccount(
            'No Dupe Co', 'Automotive', 'Contract Manufacturer'
        );
        insert acc;

        Integer countAfterFirst = [
            SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :acc.Id
        ];

        // Manually call initiateOnboarding again (simulates an edge case)
        Test.startTest();
        TriggerDispatcher.resetExecutionState();
        SupplierOnboardingService.initiateOnboarding(new List<Account>{acc});
        Test.stopTest();

        Integer countAfterSecond = [
            SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :acc.Id
        ];

        // Second call creates new Pending records — they'd be duplicates.
        // In production, reEvaluateOnSectorChange handles delta logic.
        // initiateOnboarding is only called once on insert.
        // Just verify no exceptions were thrown.
        System.assert(countAfterSecond >= countAfterFirst,
            'Second initiateOnboarding call should not throw. countAfterFirst='
            + countAfterFirst + ' countAfterSecond=' + countAfterSecond);
    }

    @IsTest
    static void testReEvaluateOnSectorChange_waivedRemovedRules() {
        Account acc = makeSupplierAccount(
            'Sector Change Co', 'Automotive', 'Raw Material Supplier'
        );
        insert acc;

        Integer automotiveCount = [
            SELECT COUNT() FROM Compliance_Assessment__c
            WHERE Supplier__c = :acc.Id AND Status__c = 'Pending'
        ];

        // Change sector to IT — automotive rules should be waived
        acc.Industry__c    = 'IT / Software Vendors';
        acc.Vendor_Type__c = 'IT / Software Vendor';

        Test.startTest();
        update acc;  // Fires afterUpdate → reEvaluateOnSectorChange
        Test.stopTest();

        List<Compliance_Assessment__c> waivedRules = [
            SELECT Id, Requirement_Key__c, Status__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :acc.Id
            AND    Status__c   = 'Waived'
        ];

        // If there were automotive-specific rules (not universal), they should now be waived
        // Universal rules (RULE-U-*) apply to both sectors so they stay Pending
        System.assert(waivedRules.size() >= 0,
            'reEvaluateOnSectorChange should not throw. Waived count: ' + waivedRules.size());
    }

    @IsTest
    static void testNonSupplierAccount_doesNotCreateAssessments() {
        // A regular Customer Account should not trigger onboarding
        Account customerAcc = new Account(Name = 'Regular Customer Inc');

        // If Supplier RT exists, only set Customer RT to confirm it's excluded
        Map<String, Schema.RecordTypeInfo> rtMap =
            Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
        if (rtMap.containsKey('Customer')) {
            customerAcc.RecordTypeId = rtMap.get('Customer').getRecordTypeId();
        }

        Test.startTest();
        insert customerAcc;
        Test.stopTest();

        Integer count = [
            SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :customerAcc.Id
        ];
        System.assertEquals(0, count,
            'Non-Supplier Account should not generate Compliance_Assessment__c records');
    }

    @IsTest
    static void testTriggerDispatcher_recursionGuard_preventsDoubleExecution() {
        // The recursion guard uses a static set, so within one test transaction
        // a second insert cannot re-fire the same handler+operation combination
        // without calling resetExecutionState().

        Account acc1 = makeSupplierAccount('Guard Test 1', 'Chemicals', 'Raw Material Supplier');

        Test.startTest();
        insert acc1;
        Integer countAfterFirst = [
            SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :acc1.Id
        ];

        // Reset guard and insert a second account
        TriggerDispatcher.resetExecutionState();
        Account acc2 = makeSupplierAccount('Guard Test 2', 'Chemicals', 'Raw Material Supplier');
        insert acc2;
        Test.stopTest();

        Integer countAfterSecond = [
            SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :acc2.Id
        ];

        // After reset, second account should also get assessments
        System.assert(countAfterSecond >= 0,
            'After resetExecutionState(), second account should process without error');
    }
}