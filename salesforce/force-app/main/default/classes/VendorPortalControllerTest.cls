@IsTest
private class VendorPortalControllerTest {

    private static Id getSupplierRecordTypeId() {
        Map<String, Schema.RecordTypeInfo> rtMap =
            Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
        return rtMap.containsKey('Supplier') ? rtMap.get('Supplier').getRecordTypeId() : null;
    }

    // Bypassed so the real onboarding flow (ScopeOnboardingService -> async
    // /scope callout) doesn't fire — irrelevant noise for these tests, and
    // callouts aren't allowed in test context without a mock.
    private static Account makeSupplier(String name) {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');
        Account a = new Account(Name = name, RecordTypeId = getSupplierRecordTypeId());
        insert a;
        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');
        return a;
    }

    private static Compliance_Assessment__c makeAssessment(Id supplierId, String key) {
        return new Compliance_Assessment__c(
            Supplier__c          = supplierId,
            Requirement_Key__c   = key,
            Requirement_Label__c = 'Certificate of Insurance',
            Status__c            = 'Compliant'
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // recordProcurementDecision — Procurement's own Approve/Reject checkpoint,
    // separate from the AI/Analyst compliance verdict (Status__c).
    // ═════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testRecordProcurementDecision_approved_writesFieldsAndAudit() {
        Account supplier = makeSupplier('Decision Test Supplier');
        Compliance_Assessment__c ca = makeAssessment(supplier.Id, 'DECISION_TEST_1');
        insert ca;

        Test.startTest();
        VendorPortalController.recordProcurementDecision(ca.Id, 'Approved', 'Looks complete and valid.');
        Test.stopTest();

        Compliance_Assessment__c result = [
            SELECT Procurement_Decision__c, Procurement_Decision_Reason__c,
                   Procurement_Decision_By__c, Procurement_Decision_DateTime__c,
                   Status__c
            FROM   Compliance_Assessment__c WHERE Id = :ca.Id
        ];
        System.assertEquals('Approved', result.Procurement_Decision__c);
        System.assertEquals('Looks complete and valid.', result.Procurement_Decision_Reason__c);
        System.assertEquals(UserInfo.getUserId(), result.Procurement_Decision_By__c);
        System.assertNotEquals(null, result.Procurement_Decision_DateTime__c);
        System.assertEquals('Compliant', result.Status__c,
            'Procurement\'s decision must never touch the AI/Analyst compliance verdict');

        Integer auditCount = [
            SELECT COUNT() FROM Audit_Log__c
            WHERE Event_Type__c = 'Procurement_Decision_Recorded' AND Related_Record_Id__c = :ca.Id
        ];
        System.assertEquals(1, auditCount, 'A Procurement_Decision_Recorded audit record should be written');
    }

    @IsTest
    static void testRecordProcurementDecision_rejected_writesFields() {
        Account supplier = makeSupplier('Decision Test Supplier 2');
        Compliance_Assessment__c ca = makeAssessment(supplier.Id, 'DECISION_TEST_2');
        insert ca;

        Test.startTest();
        VendorPortalController.recordProcurementDecision(ca.Id, 'Rejected', 'Certificate has expired.');
        Test.stopTest();

        Compliance_Assessment__c result = [
            SELECT Procurement_Decision__c, Procurement_Decision_Reason__c
            FROM   Compliance_Assessment__c WHERE Id = :ca.Id
        ];
        System.assertEquals('Rejected', result.Procurement_Decision__c);
        System.assertEquals('Certificate has expired.', result.Procurement_Decision_Reason__c);
    }

    @IsTest
    static void testRecordProcurementDecision_blankReason_throws() {
        Account supplier = makeSupplier('Decision Test Supplier 3');
        Compliance_Assessment__c ca = makeAssessment(supplier.Id, 'DECISION_TEST_3');
        insert ca;

        Boolean threw = false;
        try {
            VendorPortalController.recordProcurementDecision(ca.Id, 'Approved', '   ');
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'A blank reason must be rejected');
    }

    @IsTest
    static void testRecordProcurementDecision_invalidDecisionValue_throws() {
        Account supplier = makeSupplier('Decision Test Supplier 4');
        Compliance_Assessment__c ca = makeAssessment(supplier.Id, 'DECISION_TEST_4');
        insert ca;

        Boolean threw = false;
        try {
            VendorPortalController.recordProcurementDecision(ca.Id, 'Maybe', 'Not sure yet.');
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Only Approved/Rejected should be accepted');
    }

    @IsTest
    static void testRecordProcurementDecision_nullAssessmentId_throws() {
        Boolean threw = false;
        try {
            VendorPortalController.recordProcurementDecision(null, 'Approved', 'reason');
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'A null assessment Id must be rejected');
    }
}