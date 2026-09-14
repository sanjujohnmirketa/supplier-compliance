/**
 * ComplianceExpiryBatchTest — the scheduled safety net flags Compliant
 * documents inside the 30-day window (or already lapsed) on onboarded
 * suppliers only, leaves everything else alone, and can be scheduled.
 */
@IsTest
private class ComplianceExpiryBatchTest {

    @TestSetup
    static void grantAccess() {
        TestDataFactory.createPersona();
    }

    @IsTest
    static void flagsExpiringAndExpiredOnOnboardedSuppliersOnly() {
        System.runAs(TestDataFactory.persona()) {
            Account approved = TestDataFactory.supplier('Expiry Approved', null, 'Approved');
            Account draft    = TestDataFactory.supplier('Expiry Draft', null, 'Draft');
            Compliance_Assessment__c soon    = TestDataFactory.assessment(approved.Id, 'COI', 'Certificate of Insurance', 'Compliant', 'Low');
            Compliance_Assessment__c lapsed  = TestDataFactory.assessment(approved.Id, 'ISO', 'ISO 9001', 'Compliant', 'Low');
            Compliance_Assessment__c later   = TestDataFactory.assessment(approved.Id, 'TAX', 'Tax Clearance', 'Compliant', 'Low');
            Compliance_Assessment__c screen  = TestDataFactory.screeningRow(approved.Id, 'Sanctions', 'Compliant');
            Compliance_Assessment__c notOnboarded = TestDataFactory.assessment(draft.Id, 'COI', 'Certificate of Insurance', 'Compliant', 'Low');
            soon.Valid_Until__c = Date.today().addDays(10);
            lapsed.Valid_Until__c = Date.today().addDays(-5);
            later.Valid_Until__c = Date.today().addDays(60);
            screen.Valid_Until__c = Date.today().addDays(5);
            notOnboarded.Valid_Until__c = Date.today().addDays(5);
            update new List<Compliance_Assessment__c>{ soon, lapsed, later, screen, notOnboarded };

            Test.startTest();
            Database.executeBatch(new ComplianceExpiryBatch(), 100);
            Test.stopTest();

            Map<Id, Compliance_Assessment__c> after = new Map<Id, Compliance_Assessment__c>([
                SELECT Status__c, Reason_Code__c, Reason_Detail__c FROM Compliance_Assessment__c]);
            System.assertEquals('At Risk', after.get(soon.Id).Status__c);
            System.assertEquals('Expired', after.get(soon.Id).Reason_Code__c);
            System.assert(after.get(soon.Id).Reason_Detail__c.contains('expires'), after.get(soon.Id).Reason_Detail__c);
            System.assertEquals('At Risk', after.get(lapsed.Id).Status__c);
            System.assert(after.get(lapsed.Id).Reason_Detail__c.contains('expired'), after.get(lapsed.Id).Reason_Detail__c);
            System.assertEquals('Compliant', after.get(later.Id).Status__c, 'outside the window');
            System.assertEquals('Compliant', after.get(screen.Id).Status__c, 'screening rows are never flagged');
            System.assertEquals('Compliant', after.get(notOnboarded.Id).Status__c, 'only onboarded suppliers are swept');
        }
    }

    @IsTest
    static void isIdempotentAndSchedulable() {
        System.runAs(TestDataFactory.persona()) {
            Account approved = TestDataFactory.supplier('Expiry Again', null, 'Reviewed');
            Compliance_Assessment__c already = TestDataFactory.assessment(approved.Id, 'COI', 'Certificate of Insurance', 'At Risk', 'Low');
            already.Reason_Code__c = 'Expired'; already.Reason_Detail__c = 'first run'; already.Valid_Until__c = Date.today().addDays(-1);
            update already;

            Test.startTest();
            String jobId = System.schedule('ComplianceExpiryBatchTest ' + System.now().getTime(), '0 0 0 1 1 ? 2099', new ComplianceExpiryBatch());
            Database.executeBatch(new ComplianceExpiryBatch(), 100);
            Test.stopTest();

            System.assertNotEquals(null, jobId);
            System.assertEquals('first run', [SELECT Reason_Detail__c FROM Compliance_Assessment__c WHERE Id = :already.Id].Reason_Detail__c,
                'an already-flagged row is left alone on later runs');
        }
    }
}
