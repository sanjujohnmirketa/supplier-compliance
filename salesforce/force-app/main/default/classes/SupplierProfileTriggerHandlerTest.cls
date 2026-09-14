/**
 * SupplierProfileTriggerHandlerTest — a new or reclassified Supplier_Profile__c
 * re-runs the /scope checklist for its supplier; a save that changes none of
 * the four rule dimensions does nothing.
 *
 * SupplierProfileTrigger ships Inactive (profile-driven re-scoping is switched
 * off in this release), so the handler is exercised directly here instead of
 * through DML — same routing code, same downstream ScopeCalloutQueueable.
 */
@IsTest
private class SupplierProfileTriggerHandlerTest {

    @TestSetup
    static void grantAccess() {
        TestDataFactory.createPersona();
    }

    @IsTest
    static void reclassificationReseedsTheChecklistOnceAndUnchangedSavesDoNothing() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Profile Co', null, 'Draft');
            Supplier_Profile__c sp = new Supplier_Profile__c(Account__c = a.Id, Supplier_Tier__c = 'Tier 1');
            insert sp;
            Supplier_Profile__c before = sp.clone(true, true, true, true);
            sp.Supplier_Tier__c = 'Tier 2';
            update sp;
            Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
            SupplierProfileTriggerHandler h = new SupplierProfileTriggerHandler();

            Test.startTest();
            h.beforeInsert(null);
            h.beforeUpdate(null, null);
            h.afterInsert(new List<Supplier_Profile__c>{ sp });                                          // profile created → seed
            h.afterUpdate(new List<Supplier_Profile__c>{ sp }, new Map<Id, SObject>{ sp.Id => before }); // Tier 1 → Tier 2 → re-evaluate
            h.afterUpdate(new List<Supplier_Profile__c>{ sp }, new Map<Id, SObject>{ sp.Id => sp });     // no rule field changed → nothing
            h.afterInsert(new List<Supplier_Profile__c>{ new Supplier_Profile__c() });                   // no account → nothing
            Integer enqueued = [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable'];
            Test.stopTest();

            System.assertEquals(2, enqueued, 'exactly the create and the reclassification enqueue a /scope run');
            Account after = [SELECT Profile_Risk_Tier__c, Risk_Domains__c, Onboarding_Status__c, Checklist_Item_Count__c FROM Account WHERE Id = :a.Id];
            System.assertEquals('Medium', after.Profile_Risk_Tier__c, '/scope ran for the profiled supplier');
            System.assert(after.Risk_Domains__c.contains('finance') && after.Risk_Domains__c.contains('quality'));
            System.assertEquals('In Review', after.Onboarding_Status__c);
            System.assertEquals(2, after.Checklist_Item_Count__c);
            System.assertEquals(2, [SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :a.Id],
                'idempotent upsert — running twice does not duplicate rows');
            System.assert([SELECT COUNT() FROM Audit_Log__c WHERE Related_Record_Id__c = :a.Id AND Event_Type__c = 'Checklist_Generated'] >= 1);
        }
    }
}
