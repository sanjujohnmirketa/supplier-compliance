/**
 * SubSupplierControllerTest — Tier-1 supplier inviting sub-suppliers: the
 * requirement picker, the sub-supplier list, and the invite flow (account,
 * contact, copied checklist, portal link, email, audit) on both entry points.
 */
@IsTest
private class SubSupplierControllerTest {

    @TestSetup
    static void grantAccess() {
        TestDataFactory.createPersona();
    }

    @IsTest
    static void requirementsForParent_internalAndToken() {
        System.runAs(TestDataFactory.persona()) {
            Account parent = TestDataFactory.supplier('Parent Co', 'tok-parent', 'Approved');
            TestDataFactory.assessment(parent.Id, 'COI', 'Certificate of Insurance', 'Compliant', 'Critical');
            Compliance_Assessment__c noSev = TestDataFactory.assessment(parent.Id, 'ISO', 'ISO 9001', 'Pending', 'Low');
            noSev.Severity__c = null; update noSev;

            List<SubSupplierController.RequirementRow> rows = SubSupplierController.getRequirementsForParent(parent.Id);
            System.assertEquals(2, rows.size());
            Map<String, SubSupplierController.RequirementRow> byLabel = new Map<String, SubSupplierController.RequirementRow>();
            for (SubSupplierController.RequirementRow r : rows) byLabel.put(r.label, r);
            System.assertEquals('vc-sev-crit', byLabel.get('Certificate of Insurance').severityBadge);
            System.assertEquals('Medium', byLabel.get('ISO 9001').severity, 'a blank severity defaults to Medium');
            System.assertEquals(2, SubSupplierController.getRequirementsForParentByToken('tok-parent').size());
            System.assertEquals(0, SubSupplierController.getRequirementsForParent(null).size());
        }
    }

    @IsTest
    static void subSuppliers_listWithCountsAndBadges() {
        System.runAs(TestDataFactory.persona()) {
            Account parent = TestDataFactory.supplier('Parent List Co', 'tok-list', 'Approved');
            Account c1 = TestDataFactory.subSupplier('Child Approved', parent.Id);
            c1.Onboarding_Status__c = 'Approved'; update c1;
            Account c2 = TestDataFactory.subSupplier('Child Rejected', parent.Id);
            c2.Onboarding_Status__c = 'Rejected'; c2.Country_of_Origin__c = 'Spain'; update c2;
            TestDataFactory.assessment(c1.Id, 'COI', 'Certificate of Insurance', 'Compliant', 'Low');
            TestDataFactory.assessment(c1.Id, 'ISO', 'ISO 9001', 'Pending', 'Low');

            List<SubSupplierController.SubSupplierRow> rows = SubSupplierController.getSubSuppliers(parent.Id);
            System.assertEquals(2, rows.size());
            Map<Id, SubSupplierController.SubSupplierRow> byId = new Map<Id, SubSupplierController.SubSupplierRow>();
            for (SubSupplierController.SubSupplierRow r : rows) byId.put(r.accountId, r);
            System.assertEquals(2, byId.get(c1.Id).docCount);
            System.assertEquals('vc-badge ok', byId.get(c1.Id).badgeClass);
            System.assertEquals('France', byId.get(c1.Id).country);
            System.assertEquals('Spain', byId.get(c2.Id).country, 'country of origin wins over billing country');
            System.assertEquals('vc-badge bad', byId.get(c2.Id).badgeClass);
            System.assertEquals('Tier 2', byId.get(c2.Id).tier);
            System.assert(byId.get(c2.Id).ageLabel.endsWith('ago'));
            System.assertEquals(2, SubSupplierController.getSubSuppliersByToken('tok-list').size());
            System.assertEquals(0, SubSupplierController.getSubSuppliers(null).size());
        }
    }

    @IsTest
    static void invite_validatesBeforeTouchingRecords() {
        System.runAs(TestDataFactory.persona()) {
            Account parent = TestDataFactory.supplier('Parent Validate Co');
            String msg;
            try { SubSupplierController.inviteSubSupplier(parent.Id, '', '', '', '', '', '', '', '', '', '', ''); }
            catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg, 'the guard must throw');
            msg = null;
            try { SubSupplierController.inviteSubSupplier(parent.Id, 'Sub', 'A', 'B', 'not-an-email', '', 'Manufacturing', 'France', 'Tier 2', '', '', ''); }
            catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg, 'the guard must throw');
            System.assertEquals(0, [SELECT COUNT() FROM Account WHERE ParentId = :parent.Id]);
        }
    }

    @IsTest
    static void invite_createsHierarchyContactChecklistAndEmail() {
        System.runAs(TestDataFactory.persona()) {
            Account parent = TestDataFactory.supplier('Parent Invite Co', 'tok-invite', 'Approved');
            Compliance_Assessment__c r1 = TestDataFactory.assessment(parent.Id, 'COI', 'Certificate of Insurance', 'Compliant', 'High');
            Compliance_Assessment__c r2 = TestDataFactory.assessment(parent.Id, 'ISO', 'ISO 9001', 'Compliant', 'Medium');
            TestDataFactory.assessment(parent.Id, 'TAX', 'Tax Clearance', 'Compliant', 'Low');
            Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());

            Test.startTest();
            SubSupplierController.InviteResult res = SubSupplierController.inviteSubSupplier(
                parent.Id, 'Sub Parts SARL', 'Ann', 'Lee', 'ann@subparts.example', '+33 1 23', 'Manufacturing',
                'France', 'Tier 2', 'Welcome aboard', '14', r1.Id + ', ' + r2.Id);
            // Re-inviting the same email updates the same sub-supplier — no duplicate Account/Contact.
            SubSupplierController.InviteResult again = SubSupplierController.inviteSubSupplierByToken(
                'tok-invite', 'Sub Parts SARL', 'Ann', 'Lee', 'ann@subparts.example', null, 'Manufacturing',
                'France', 'Tier 2', null, null, null);
            Test.stopTest();

            System.assertEquals(res.accountId, again.accountId);
            System.assertEquals(res.contactId, again.contactId);
            Account child = [SELECT ParentId, Supplier_Tier__c, Onboarding_Status__c, Checklist_Seeded_By_Caller__c,
                                    Checklist_Item_Count__c, Country_of_Origin__c, Industry, Supplier_Contact_Email__c
                             FROM Account WHERE Id = :res.accountId];
            System.assertEquals(parent.Id, child.ParentId);
            System.assertEquals('Tier 2', child.Supplier_Tier__c);
            System.assertEquals('Manufacturing', child.Industry);
            System.assertEquals('ann@subparts.example', child.Supplier_Contact_Email__c);
            System.assertEquals(2, child.Checklist_Item_Count__c, 'the curated subset freezes the checklist size');
            System.assertEquals(2, [SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :res.accountId AND Status__c = 'Pending'],
                'only the selected requirements are copied');
            System.assertEquals(1, [SELECT COUNT() FROM Contact WHERE AccountId = :res.accountId]);
            System.assertEquals(1, [SELECT COUNT() FROM Supplier_Profile__c WHERE Account__c = :res.accountId]);
            System.assert(String.isNotBlank(res.portalUrl) && res.portalUrl.contains('?token='));
            System.assert([SELECT COUNT() FROM Audit_Log__c WHERE Related_Record_Id__c = :res.accountId AND Event_Type__c = 'Status_Changed'] >= 2);
            System.assertEquals(1, [SELECT COUNT() FROM Account WHERE ParentId = :parent.Id]);

            String msg;
            try { SubSupplierController.inviteSubSupplierByToken('bad-token', 'X', 'A', 'B', 'a@b.co', null, 'M', 'FR', 'Tier 2', null, null, null); }
            catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg, 'the guard must throw');
        }
    }

}
