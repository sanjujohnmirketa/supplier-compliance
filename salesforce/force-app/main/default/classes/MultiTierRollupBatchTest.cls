@IsTest
private class MultiTierRollupBatchTest {

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

    @IsTest
    static void testBatch_recomputesHierarchyAndSelfHeals() {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');

        Account parent = makeAccount('Batch Parent Co', null);
        insert parent;
        Account child = makeAccount('Batch Child Co', parent.Id);
        insert child;

        child.Risk_Tier__c = 'Critical';
        update child;

        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');

        Test.startTest();
        Database.executeBatch(new MultiTierRollupBatch(), 50);
        Test.stopTest();

        Account result = [SELECT Cascading_Risk_Tier__c FROM Account WHERE Id = :parent.Id];
        System.assertEquals('Critical', result.Cascading_Risk_Tier__c,
            'Nightly batch should recompute the parent from its child even without a trigger firing');
    }

    @IsTest
    static void testSchedulable_executesWithoutError() {
        Test.startTest();
        new MultiTierRollupBatch().execute((SchedulableContext) null);
        Test.stopTest();
        System.assert(true, 'Scheduling the batch should not throw');
    }
}