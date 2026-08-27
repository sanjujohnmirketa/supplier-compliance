@IsTest
private class MultiTierRollupServiceTest {

    private static Id getSupplierRecordTypeId() {
        Map<String, Schema.RecordTypeInfo> rtMap =
            Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
        return rtMap.containsKey('Supplier') ? rtMap.get('Supplier').getRecordTypeId() : null;
    }

    private static Account makeAccount(String name, Id parentId) {
        Account a = new Account(Name = name, ParentId = parentId);
        Id rt = getSupplierRecordTypeId();
        if (rt != null) a.RecordTypeId = rt;
        return a;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Pure algorithm tests — trigger side-effects bypassed so these exercise
    // MultiTierRollupService directly (no callouts, no async involved).
    // ═════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testRollup_worstCasePropagatesUpThreeTiers() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');

        Account t1 = makeAccount('T1 Parent Co', null);
        insert t1;
        Account t2 = makeAccount('T2 Mid Co', t1.Id);
        insert t2;
        Account t3 = makeAccount('T3 SteelMax Inc', t2.Id);
        insert t3;

        t1.Risk_Tier__c = 'Low';
        t2.Risk_Tier__c = 'Low';
        t3.Risk_Tier__c = 'Critical';
        update new List<Account>{ t1, t2, t3 };

        Test.startTest();
        MultiTierRollupService.rollupFromAccounts(new Set<Id>{ t3.Id });
        Test.stopTest();

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');

        Map<Id, Account> results = new Map<Id, Account>([
            SELECT Id, Cascading_Risk_Tier__c, Cascading_Risk_Source__c,
                   Cascading_Risk_Driver__c, Sub_Tier_Supplier_Count__c
            FROM   Account
            WHERE  Id IN :new List<Id>{ t1.Id, t2.Id, t3.Id }
        ]);

        System.assertEquals('Critical', results.get(t1.Id).Cascading_Risk_Tier__c,
            'T1 cascading risk should reflect the T3 Critical descendant');
        System.assertEquals(t3.Id, results.get(t1.Id).Cascading_Risk_Driver__c,
            'T1 should point at the T3 account as the driver');
        System.assertEquals('Critical', results.get(t2.Id).Cascading_Risk_Tier__c);
        System.assertEquals('Critical', results.get(t3.Id).Cascading_Risk_Tier__c,
            'A leaf with no children has its own tier as its cascading tier');
        System.assertEquals(2, results.get(t1.Id).Sub_Tier_Supplier_Count__c.intValue(),
            'T1 has 2 descendants: T2 and T3');
        System.assertEquals(1, results.get(t2.Id).Sub_Tier_Supplier_Count__c.intValue());
        System.assertEquals(0, results.get(t3.Id).Sub_Tier_Supplier_Count__c.intValue());

        Integer auditCount = [
            SELECT COUNT() FROM Audit_Log__c WHERE Event_Type__c = 'Cascading_Risk_Updated'
        ];
        System.assert(auditCount > 0, 'A Cascading_Risk_Updated audit record should be written');
    }

    @IsTest
    static void testRollup_ownRiskWorseThanChildren_staysOwn() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');

        Account parent = makeAccount('Own Worse Parent', null);
        insert parent;
        Account child = makeAccount('Own Worse Child', parent.Id);
        insert child;

        parent.Risk_Tier__c = 'High';
        child.Risk_Tier__c  = 'Low';
        update new List<Account>{ parent, child };

        Test.startTest();
        MultiTierRollupService.rollupFromAccounts(new Set<Id>{ child.Id });
        Test.stopTest();

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');

        Account result = [
            SELECT Cascading_Risk_Tier__c, Cascading_Risk_Driver__c
            FROM   Account WHERE Id = :parent.Id
        ];
        System.assertEquals('High', result.Cascading_Risk_Tier__c,
            'Parent own risk (High) outranks child (Low), so cascading = own');
        System.assertEquals(null, result.Cascading_Risk_Driver__c,
            'When own risk is the worst, there is no external driver to point to -- '
            + 'must be null, not the parent\'s own Id (a self-referencing lookup on '
            + 'Account throws CIRCULAR_DEPENDENCY: Hierarchy Constraint Violation)');
    }

    @IsTest
    static void testRollup_repeatedCall_isIdempotent() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');

        Account parent = makeAccount('Shortcircuit Parent', null);
        insert parent;
        Account child = makeAccount('Shortcircuit Child', parent.Id);
        insert child;

        child.Risk_Tier__c = 'Medium';
        update child;

        Test.startTest();
        MultiTierRollupService.rollupFromAccounts(new Set<Id>{ child.Id });
        // Calling again with the same input should be a no-op, not throw
        // or double-log — this exercises the short-circuit path.
        MultiTierRollupService.rollupFromAccounts(new Set<Id>{ child.Id });
        Test.stopTest();

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');

        Account result = [SELECT Cascading_Risk_Tier__c FROM Account WHERE Id = :parent.Id];
        System.assertEquals('Medium', result.Cascading_Risk_Tier__c);
    }

    @IsTest
    static void testRollup_multipleSiblings_worstSiblingWinsAndAllAreCounted() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');

        Account parent = makeAccount('Fanout Parent', null);
        insert parent;
        Account childLow      = makeAccount('Sibling Low', parent.Id);
        Account childCritical = makeAccount('Sibling Critical', parent.Id);
        Account childHigh     = makeAccount('Sibling High', parent.Id);
        insert new List<Account>{ childLow, childCritical, childHigh };

        parent.Risk_Tier__c        = 'Low';
        childLow.Risk_Tier__c      = 'Low';
        childCritical.Risk_Tier__c = 'Critical';
        childHigh.Risk_Tier__c     = 'High';
        update new List<Account>{ parent, childLow, childCritical, childHigh };

        Test.startTest();
        MultiTierRollupService.rollupFromAccounts(
            new Set<Id>{ childLow.Id, childCritical.Id, childHigh.Id });
        Test.stopTest();

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');

        Account result = [
            SELECT Cascading_Risk_Tier__c, Cascading_Risk_Driver__c, Sub_Tier_Supplier_Count__c
            FROM   Account WHERE Id = :parent.Id
        ];
        System.assertEquals('Critical', result.Cascading_Risk_Tier__c,
            'The worst sibling (Critical) should win over High and Low');
        System.assertEquals(childCritical.Id, result.Cascading_Risk_Driver__c,
            'The Critical sibling specifically should be recorded as the driver, not High or Low');
        System.assertEquals(3, result.Sub_Tier_Supplier_Count__c.intValue(),
            'All three siblings should be counted, not just the worst one');
    }

    @IsTest
    static void testRollup_countOnlyChange_stillPropagatesToGrandparent() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');

        Account t1 = makeAccount('Count T1', null);
        insert t1;
        Account t2 = makeAccount('Count T2', t1.Id);
        insert t2;

        Test.startTest();
        // Establish a baseline chain with no tier data yet.
        MultiTierRollupService.rollupFromAccounts(new Set<Id>{ t2.Id });

        // A brand-new T3 leaf under T2 has no Risk_Tier__c yet — this changes
        // T2's Sub_Tier_Supplier_Count__c but NOT its Cascading_Risk_Tier__c.
        // That count change must still bubble up to T1.
        Account t3 = makeAccount('Count T3 (no tier yet)', t2.Id);
        insert t3;
        MultiTierRollupService.rollupFromAccounts(new Set<Id>{ t2.Id });
        Test.stopTest();

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');

        Account result = [SELECT Sub_Tier_Supplier_Count__c FROM Account WHERE Id = :t1.Id];
        System.assertEquals(2, result.Sub_Tier_Supplier_Count__c.intValue(),
            'T1 should count both T2 and the new tier-less T3 as descendants, '
            + 'even though the new leaf did not change anyone\'s Cascading_Risk_Tier__c');
    }

    @IsTest
    static void testRollup_emptyAndNullInput_noException() {
        MultiTierRollupService.rollupFromAccounts(new Set<Id>());
        MultiTierRollupService.rollupFromAccounts(null);
        System.assert(true, 'Empty/null input should be a no-op, not throw');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Trigger-wiring test — the real path: updating a child's Risk_Tier__c
    // through AccountTriggerHandler publishes Supplier_Risk_Change__e, which
    // SupplierRiskChangeTrigger picks up (delivered synchronously at
    // Test.stopTest() per platform event test semantics) and drives the
    // rollup up to the parent. Structural changes (re-parenting) still go
    // through the direct MultiTierRollupQueueable path unchanged.
    // ═════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testAccountTrigger_riskTierChange_publishesEventAndPropagatesToParent() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');

        Account parent = makeAccount('Event Parent', null);
        insert parent;
        Account child = makeAccount('Event Child', parent.Id);
        insert child;

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');
        TriggerDispatcher.resetExecutionState();

        child.Risk_Tier__c = 'High';

        Test.startTest();
        update child; // AccountTriggerHandler.afterUpdate should publish Supplier_Risk_Change__e
        Test.stopTest(); // platform event delivery (and SupplierRiskChangeTrigger) runs here

        Account result = [SELECT Cascading_Risk_Tier__c FROM Account WHERE Id = :parent.Id];
        System.assertEquals('High', result.Cascading_Risk_Tier__c,
            'Updating a child Risk_Tier__c should publish Supplier_Risk_Change__e and, via '
            + 'SupplierRiskChangeTrigger, propagate the rollup up to the parent');
    }

    @IsTest
    static void testAccountTrigger_reParenting_stillUsesDirectQueueable() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');

        Account oldParent = makeAccount('Old Parent', null);
        insert oldParent;
        Account newParent = makeAccount('New Parent', null);
        insert newParent;
        Account child = makeAccount('Reparented Child', oldParent.Id);
        insert child;

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');
        TriggerDispatcher.resetExecutionState();

        child.Risk_Tier__c = 'Critical';
        update child; // sets up cascading data on the child before it moves

        TriggerDispatcher.resetExecutionState();
        child.ParentId = newParent.Id;

        Test.startTest();
        update child; // structural change — direct enqueueRollup, not the platform event
        Test.stopTest();

        Account newParentResult = [SELECT Cascading_Risk_Tier__c FROM Account WHERE Id = :newParent.Id];
        System.assertEquals('Critical', newParentResult.Cascading_Risk_Tier__c,
            'Re-parenting should recompute the NEW parent via the direct structural path');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Cascading risk SCORE formula: New Score = (Own*0.7) + (avg of
    // relationship-weighted sub-supplier contributions * 0.3), per
    // Risk_Rollup_Setting__mdt.Default (deployed alongside this class).
    // ═════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testScore_singleChildDefaultWeight_blendsCorrectly() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');

        Account parent = makeAccount('Score Parent', null);
        insert parent;
        Account child = makeAccount('Score Child', parent.Id); // Relationship_Type_To_Parent__c blank -> Preferred (1.0x)
        insert child;

        parent.Risk_Score__c = 40;
        child.Risk_Score__c  = 100;
        update new List<Account>{ parent, child };

        Test.startTest();
        MultiTierRollupService.rollupFromAccounts(new Set<Id>{ child.Id });
        Test.stopTest();

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');

        Account result = [
            SELECT Cascading_Risk_Score__c, Cascading_Risk_Flag__c FROM Account WHERE Id = :parent.Id
        ];
        System.assertEquals(58.00, result.Cascading_Risk_Score__c,
            'New Score = (40*0.7) + (100*1.0(avg) *0.3) = 28 + 30 = 58');
        System.assertEquals(false, result.Cascading_Risk_Flag__c,
            '58 is below the default threshold of 70');
    }

    @IsTest
    static void testScore_soleSourceWeight_appliesMultiplier() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');

        Account parent = makeAccount('SoleSource Parent', null);
        insert parent;
        Account child = makeAccount('SoleSource Child', parent.Id);
        child.Relationship_Type_To_Parent__c = 'Sole Source';
        insert child;

        parent.Risk_Score__c = 30;
        child.Risk_Score__c  = 80;
        update new List<Account>{ parent, child };

        Test.startTest();
        MultiTierRollupService.rollupFromAccounts(new Set<Id>{ child.Id });
        Test.stopTest();

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');

        Account result = [SELECT Cascading_Risk_Score__c FROM Account WHERE Id = :parent.Id];
        System.assertEquals(57.00, result.Cascading_Risk_Score__c,
            'New Score = (30*0.7) + (80*1.5=120(avg) *0.3) = 21 + 36 = 57');
    }

    @IsTest
    static void testScore_capsAt100_andFlagsOnlyWhenPropagationDriven() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');

        Account parent = makeAccount('Cap Parent', null);
        insert parent;
        Account child = makeAccount('Cap Child', parent.Id);
        child.Relationship_Type_To_Parent__c = 'Sole Source';
        insert child;

        parent.Risk_Score__c = 90;
        child.Risk_Score__c  = 100;
        update new List<Account>{ parent, child };

        Test.startTest();
        MultiTierRollupService.rollupFromAccounts(new Set<Id>{ child.Id });
        Test.stopTest();

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');

        Account result = [
            SELECT Cascading_Risk_Score__c, Cascading_Risk_Flag__c FROM Account WHERE Id = :parent.Id
        ];
        System.assertEquals(100.00, result.Cascading_Risk_Score__c,
            'Raw blend = (90*0.7) + (150(avg)*0.3) = 63 + 45 = 108, capped to 100');
        System.assertEquals(true, result.Cascading_Risk_Flag__c,
            '100 >= threshold(70) AND 100 > own score(90) -- propagation specifically drove this over the line');
    }

    @IsTest
    static void testScore_ownScoreAloneAboveThreshold_doesNotFlag() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');

        Account parent = makeAccount('AlreadyBad Parent', null);
        insert parent;
        Account child = makeAccount('AlreadyBad Child', parent.Id);
        insert child;

        parent.Risk_Score__c = 100; // already bad on its own, well above threshold
        child.Risk_Score__c  = 0;   // sub-supplier is perfectly clean
        update new List<Account>{ parent, child };

        Test.startTest();
        MultiTierRollupService.rollupFromAccounts(new Set<Id>{ child.Id });
        Test.stopTest();

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');

        Account result = [
            SELECT Cascading_Risk_Score__c, Cascading_Risk_Flag__c FROM Account WHERE Id = :parent.Id
        ];
        System.assertEquals(70.00, result.Cascading_Risk_Score__c,
            'New Score = (100*0.7) + (0*0.3) = 70 -- at threshold, but pulled DOWN from the own score of 100');
        System.assertEquals(false, result.Cascading_Risk_Flag__c,
            'Blended score (70) is >= threshold but is NOT greater than the parent\'s own score (100) -- '
            + 'the clean sub-supplier diluted it, propagation did not drive this. '
            + 'Cascading_Risk_Flag__c must stay distinct from ordinary non-compliance');
    }

    @IsTest
    static void testScore_multipleSiblings_averagesWeightedContributions() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');

        Account parent = makeAccount('Avg Parent', null);
        insert parent;
        Account childA = makeAccount('Avg Child A', parent.Id);
        Account childB = makeAccount('Avg Child B', parent.Id);
        insert new List<Account>{ childA, childB };

        parent.Risk_Score__c = 20;
        childA.Risk_Score__c = 100;
        childB.Risk_Score__c = 0;
        update new List<Account>{ parent, childA, childB };

        Test.startTest();
        MultiTierRollupService.rollupFromAccounts(new Set<Id>{ childA.Id, childB.Id });
        Test.stopTest();

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');

        Account result = [SELECT Cascading_Risk_Score__c FROM Account WHERE Id = :parent.Id];
        System.assertEquals(29.00, result.Cascading_Risk_Score__c,
            'avg(100,0) = 50 -> New Score = (20*0.7) + (50*0.3) = 14 + 15 = 29');
    }

    @IsTest
    static void testScore_noSubSuppliers_isOwnScoreOnly() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');

        Account leaf = makeAccount('Leaf Only', null);
        insert leaf;
        leaf.Risk_Score__c = 45;
        update leaf;

        Test.startTest();
        MultiTierRollupService.rollupFromAccounts(new Set<Id>{ leaf.Id });
        Test.stopTest();

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');

        Account result = [SELECT Cascading_Risk_Score__c FROM Account WHERE Id = :leaf.Id];
        System.assertEquals(45.00, result.Cascading_Risk_Score__c,
            'No formula applied when there are no sub-suppliers -- score = own score only');
    }

    @IsTest
    static void testScore_threeTierChain_t1BlendsFromT2sUpdatedScoreNotT3Directly() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');

        Account t1 = makeAccount('Score T1', null);
        insert t1;
        Account t2 = makeAccount('Score T2', t1.Id);
        insert t2;
        Account t3 = makeAccount('Score T3', t2.Id);
        insert t3;

        t1.Risk_Score__c = 0;
        t2.Risk_Score__c = 0;
        t3.Risk_Score__c = 100;
        update new List<Account>{ t1, t2, t3 };

        Test.startTest();
        MultiTierRollupService.rollupFromAccounts(new Set<Id>{ t3.Id });
        Test.stopTest();

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');

        Map<Id, Account> results = new Map<Id, Account>([
            SELECT Id, Cascading_Risk_Score__c
            FROM   Account WHERE Id IN :new List<Id>{ t1.Id, t2.Id, t3.Id }
        ]);

        System.assertEquals(100.00, results.get(t3.Id).Cascading_Risk_Score__c,
            'T3 is a leaf -- own score only');
        System.assertEquals(30.00, results.get(t2.Id).Cascading_Risk_Score__c,
            'T2 = (0*0.7) + (100*0.3) = 30');
        System.assertEquals(9.00, results.get(t1.Id).Cascading_Risk_Score__c,
            'T1 must blend from T2\'s UPDATED score (30), not T3\'s raw 100 directly: '
            + '(0*0.7) + (30*0.3) = 9 -- T2 is the shock absorber. If T1 saw T3 directly '
            + 'it would compute (0*0.7)+(100*0.3)=30 instead.');
    }

    @IsTest
    static void testAccountTrigger_riskScoreChangeAlone_stillPublishesEventAndRecomputes() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');

        Account parent = makeAccount('ScoreOnly Parent', null);
        insert parent;
        Account child = makeAccount('ScoreOnly Child', parent.Id);
        insert child;

        // Establish a baseline: Risk_Tier__c is already 'Low' and stays 'Low'
        // for the rest of this test — only Risk_Score__c moves.
        parent.Risk_Score__c = 0;
        parent.Risk_Tier__c  = 'Low';
        child.Risk_Score__c  = 8;
        child.Risk_Tier__c   = 'Low';
        update new List<Account>{ parent, child };

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');
        TriggerDispatcher.resetExecutionState();

        // Score moves 8 -> 24: still bucketed as 'Low', Risk_Tier__c does NOT
        // change. Before the fix, this would silently fail to re-fire the
        // rollup and Cascading_Risk_Score__c would go stale.
        child.Risk_Score__c = 24;

        Test.startTest();
        update child; // Risk_Tier__c unchanged -- only Risk_Score__c changed
        Test.stopTest();

        Account result = [SELECT Cascading_Risk_Score__c FROM Account WHERE Id = :parent.Id];
        System.assertEquals(7.20, result.Cascading_Risk_Score__c,
            'New Score = (0*0.7) + (24*0.3) = 7.2 -- a Risk_Score__c-only change (no '
            + 'Risk_Tier__c change) must still publish Supplier_Risk_Change__e and recompute, '
            + 'or this would still show the stale value from when child scored 8');
    }
}