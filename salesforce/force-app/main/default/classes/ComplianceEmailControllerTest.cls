/**
 * ComplianceEmailControllerTest — the document-request email preview/send and
 * the targeted renewal / compliance-break alert.
 */
@IsTest
private class ComplianceEmailControllerTest {

    @IsTest
    static void preview_splitsRequiredFromAdditionalAndLabelsStatus() {
        Account a = TestDataFactory.supplier('Email Co');
        TestDataFactory.contact(a.Id, 'contact@emailco.example');
        TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Pending', 'Critical');
        Compliance_Assessment__c low = TestDataFactory.assessment(a.Id, 'ISO', 'ISO 9001', 'Compliant', 'Low');
        low.Compliance_Document__c = TestDataFactory.complianceDoc(a.Id, 'ISO 9001', 'Pending').Id; update low;
        Compliance_Assessment__c rejected = TestDataFactory.assessment(a.Id, 'TAX', 'Tax Clearance', 'Non-Compliant', 'Medium');
        rejected.Compliance_Document__c = TestDataFactory.complianceDoc(a.Id, 'Tax Clearance', 'Pending').Id; update rejected;
        TestDataFactory.screeningRow(a.Id, 'Sanctions', 'Compliant');

        ComplianceEmailController.EmailPreview p = ComplianceEmailController.getEmailPreview(a.Id);
        System.assertEquals('Email Co', p.accountName);
        System.assertEquals('contact@emailco.example', p.toEmail);
        System.assertEquals(1, p.requiredDocs.size(), 'Critical/High are required');
        System.assertEquals(2, p.additionalDocs.size(), 'screening rows are excluded');
        System.assertEquals('Pending Upload', p.requiredDocs[0].statusLabel);
        Map<String, String> labels = new Map<String, String>();
        for (ComplianceEmailController.DocRow r : p.additionalDocs) labels.put(r.requirementLabel, r.statusLabel);
        System.assertEquals('Approved', labels.get('ISO 9001'));
        System.assertEquals('Rejected – Resubmission Required', labels.get('Tax Clearance'));
        System.assertEquals(true, p.hasRequiredDocs);

        String msg;
        try { ComplianceEmailController.getEmailPreview(null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
    }

    @IsTest
    static void sendComplianceEmail_buildsAndSends() {
        Account a = TestDataFactory.supplier('Send Co');
        TestDataFactory.contact(a.Id, 'contact@sendco.example');
        TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Pending', 'High');
        TestDataFactory.assessment(a.Id, 'ISO', 'ISO 9001', 'Pending', 'Low');
        Test.startTest();
        ComplianceEmailController.sendComplianceEmail(a.Id, ' contact@sendco.example ', 'Please prioritise the insurance certificate.');
        Integer invocations = Limits.getEmailInvocations();
        Test.stopTest();
        System.assertEquals(1, invocations, 'exactly one send');
        System.assertNotEquals(null, [SELECT Supplier_Portal_Token__c FROM Account WHERE Id = :a.Id].Supplier_Portal_Token__c,
            'the email carries the supplier\'s portal link');

        String msg;
        try { ComplianceEmailController.sendComplianceEmail(a.Id, ' ', null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');
        msg = null;
        try { ComplianceEmailController.sendComplianceEmail(null, 'x@y.z', null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
    }

    @IsTest
    static void renewalAlert_expiryAndBreakVariants() {
        Account a = TestDataFactory.supplier('Renew Co', null, 'Approved');
        TestDataFactory.contact(a.Id, 'contact@renewco.example');
        Compliance_Assessment__c expired = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'At Risk', 'High');
        expired.Reason_Code__c = 'Expired'; expired.Valid_Until__c = Date.today().addDays(-3); update expired;
        Compliance_Assessment__c expiring = TestDataFactory.assessment(a.Id, 'ISO', 'ISO 9001', 'At Risk', 'Medium');
        expiring.Reason_Code__c = 'Expired'; expiring.Valid_Until__c = Date.today().addDays(10); update expiring;
        Compliance_Assessment__c flagged = TestDataFactory.assessment(a.Id, 'TAX', 'Tax Clearance', 'Non-Compliant', 'High');
        flagged.Reason_Detail__c = 'Clearance number does not validate.'; update flagged;

        Test.startTest();
        ComplianceEmailController.sendRenewalAlert(a.Id, expired.Id);
        ComplianceEmailController.sendRenewalAlert(a.Id, expiring.Id);
        ComplianceEmailController.sendRenewalAlert(a.Id, flagged.Id);
        Integer invocations = Limits.getEmailInvocations();
        Test.stopTest();
        System.assertEquals(3, invocations);

        Account draft = TestDataFactory.supplier('Not Onboarded Co');
        Compliance_Assessment__c d = TestDataFactory.assessment(draft.Id, 'COI', 'Certificate of Insurance', 'At Risk', 'High');
        String msg;
        try { ComplianceEmailController.sendRenewalAlert(draft.Id, d.Id); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');

        Account noContact = TestDataFactory.supplier('No Contact Co', null, 'Reviewed');
        Compliance_Assessment__c n = TestDataFactory.assessment(noContact.Id, 'COI', 'Certificate of Insurance', 'At Risk', 'High');
        msg = null;
        try { ComplianceEmailController.sendRenewalAlert(noContact.Id, n.Id); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');
        msg = null;
        try { ComplianceEmailController.sendRenewalAlert(a.Id, null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
    }
}
