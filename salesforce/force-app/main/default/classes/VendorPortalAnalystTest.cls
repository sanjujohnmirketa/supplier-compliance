/**
 * VendorPortalAnalystTest — the handoff and Analyst side of VendorPortalController:
 * assign / send back, the analyst queue and case view, per-document validation,
 * Procurement approvals and decisions, and on-demand re-assessment.
 */
@IsTest
private class VendorPortalAnalystTest {

    @TestSetup
    static void grantAccess() {
        TestDataFactory.createPersona();
    }

    @IsTest
    static void analystUsers_currentUserFirst() {
        System.runAs(TestDataFactory.persona()) {
            List<VendorPortalController.AnalystUser> users = VendorPortalController.getAnalystUsers();
            System.assert(!users.isEmpty());
            System.assertEquals(true, users[0].isMe);
            System.assert(users[0].name.endsWith('(you)'));
        }
    }

    @IsTest
    static void handoff_blockedUntilEveryUploadIsDecided() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Handoff Co', null, 'Screening');
            Compliance_Assessment__c ca = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Compliant', 'Low');
            ca.Compliance_Document__c = TestDataFactory.complianceDoc(a.Id, 'Certificate of Insurance', 'Pending').Id;
            update ca;

            String msg;
            try { VendorPortalController.assignToAnalyst(a.Id, UserInfo.getUserId(), 'please review'); }
            catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg, 'the guard must throw');

            VendorPortalController.recordProcurementDecision(ca.Id, 'Deferred', 'unsure about the insurer');
            System.assertEquals('Compliant', [SELECT Status__c FROM Compliance_Assessment__c WHERE Id = :ca.Id].Status__c,
                'Deferred does not touch the compliance verdict');

            System.assertEquals(a.Id, VendorPortalController.assignToAnalyst(a.Id, UserInfo.getUserId(), 'please review'));
            Account after = [SELECT OwnerId, Onboarding_Status__c, Analyst_Assigned_DateTime__c, Assigned_By__c, Assignment_Reason__c FROM Account WHERE Id = :a.Id];
            System.assertEquals(UserInfo.getUserId(), after.OwnerId);
            System.assertEquals('In Review', after.Onboarding_Status__c);
            System.assertNotEquals(null, after.Analyst_Assigned_DateTime__c);
            System.assertEquals('please review', after.Assignment_Reason__c);

            // Post-handoff, Procurement's own actions are refused.
            msg = null;
            try { VendorPortalController.recordProcurementDecision(ca.Id, 'Approved', 'late'); } catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg, 'the guard must throw');
            msg = null;
            try { VendorPortalController.approveDocumentAsProcurement(ca.Id, 'late', true); } catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg, 'the guard must throw');

            VendorPortalController.sendCaseBackToProcurement(a.Id, 'needs a fresh certificate');
            Account back = [SELECT OwnerId, Onboarding_Status__c, Analyst_Assigned_DateTime__c, Assignment_Reason__c FROM Account WHERE Id = :a.Id];
            System.assertEquals('Screening', back.Onboarding_Status__c);
            System.assertEquals(null, back.Analyst_Assigned_DateTime__c);
            System.assertEquals(after.Assigned_By__c, back.OwnerId, 'ownership returns to whoever handed it off');

            msg = null;
            try { VendorPortalController.assignToAnalyst(a.Id, null, null); } catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg, 'the guard must throw');
            msg = null;
            try { VendorPortalController.sendCaseBackToProcurement(null, null); } catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg);
        }
    }

    @IsTest
    static void analystQueue_mineVersusTeam() {
        System.runAs(TestDataFactory.persona()) {
            Account mine1 = TestDataFactory.supplier('Mine One', null, 'In Review');
            Account mine2 = TestDataFactory.supplier('Mine Two', null, 'In Review');
            Account done  = TestDataFactory.supplier('Done Co', null, 'Approved');
            Account closed = TestDataFactory.supplier('Closed Co', null, 'In Review');
            closed.Compliance_Case_Status__c = 'Closed - Rejected'; update closed;
            mine1.Stage_Entered_DateTime__c = DateTime.now().addDays(-6); update mine1;
            TestDataFactory.assessment(mine1.Id, 'COI', 'Certificate of Insurance', 'At Risk', 'High');
            Compliance_Assessment__c v = TestDataFactory.assessment(mine1.Id, 'ISO', 'ISO 9001', 'Compliant', 'Low');
            v.Analyst_Validated__c = true; update v;

            List<VendorPortalController.AnalystQueueRow> own  = VendorPortalController.getAnalystQueue(false);
            List<VendorPortalController.AnalystQueueRow> team = VendorPortalController.getAnalystQueue(true);
            System.assertEquals(2, own.size(), 'only In Review cases owned by me, closed ones excluded');
            System.assert(team.size() >= 2);
            VendorPortalController.AnalystQueueRow r;
            for (VendorPortalController.AnalystQueueRow x : own) if (x.id == mine1.Id) r = x;
            System.assertEquals(1, r.flags);
            System.assertEquals(2, r.docCount);
            System.assertEquals(1, r.validatedCount);
            System.assertEquals(true, r.isMine);
            System.assertEquals(true, r.isStalled, 'six days in stage is past the 5-day threshold');
            System.assertEquals('Prospective · in review', r.stageLabel);
        }
    }

    @IsTest
    static void caseForAnalyst_showsHandoffContextFilesAndHistory() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Case Co', null, 'In Review');
            a.Analyst_Assigned_DateTime__c = DateTime.now().addHours(-3);
            a.Assigned_By__c = UserInfo.getUserId();
            a.Assignment_Reason__c = 'high spend';
            a.Risk_Score__c = 62;
            update a;
            Compliance_Assessment__c ca = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Non-Compliant', 'High');
            Compliance_Document__c doc = TestDataFactory.complianceDocWithFile(a.Id, 'Certificate of Insurance', 'coi.pdf');
            ca.Compliance_Document__c = doc.Id;
            ca.Procurement_Decision__c = 'Deferred';
            ca.Procurement_Decision_Reason__c = 'insurer unknown';
            update ca;
            insert new Compliance_Document_Link__c(Compliance_Assessment__c = ca.Id, Compliance_Document__c = doc.Id, Status__c = 'Non-Compliant', Severity__c = 'High');
            TestDataFactory.audit('Procurement_Decision_Recorded', 'Compliance_Assessment', ca.Id, 'Deferred', 'insurer unknown', UserInfo.getUserId());
            TestDataFactory.audit('Analyst_Decision_Recorded', 'Compliance_Assessment', ca.Id, 'Non-Compliant', 'confirmed', UserInfo.getUserId());
            TestDataFactory.audit('Document_Uploaded', 'Compliance_Assessment', ca.Id, null, 'coi.pdf', null);

            VendorPortalController.AnalystCase c = VendorPortalController.getCaseForAnalyst(a.Id);
            System.assertEquals(true, c.hasAssignment);
            System.assertEquals('high spend', c.assignmentReason);
            System.assertNotEquals(null, c.assignedByName);
            System.assertEquals(false, c.hasApproval);
            System.assertEquals(62, c.riskScore);
            System.assertEquals(1, c.docCount);
            VendorPortalController.AnalystDoc d = c.docs[0];
            System.assertEquals(true, d.isDeferred);
            System.assertEquals(true, d.isNewSinceHandoff, 'a row modified after handoff is flagged for the analyst');
            System.assertNotEquals(null, d.versionId);
            System.assertEquals('coi.pdf', d.docTitle);
            System.assert(d.docUrl.contains(d.versionId));
            System.assertEquals(3, d.commentHistory.size());
            System.assertEquals(1, d.documentLinks.size());
            Set<String> actors = new Set<String>();
            for (VendorPortalController.ProcurementComment pc : d.commentHistory) actors.add(pc.actorName);
            System.assert(actors.contains('Analyst') && actors.contains('Procurement') && actors.contains('Supplier'));

            String msg;
            try { VendorPortalController.getCaseForAnalyst(null); } catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg);
        }
    }

    @IsTest
    static void saveDocValidation_recordsDecisionAndRecomputes() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Validate Co', null, 'In Review');
            Compliance_Assessment__c ca = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'At Risk', 'Medium');

            VendorPortalController.saveDocValidation(ca.Id, 'checked with insurer', true, 'Non-Compliant');
            Compliance_Assessment__c after = [SELECT Status__c, Analyst_Validated__c, Analyst_Comment__c, Evaluator_User__c FROM Compliance_Assessment__c WHERE Id = :ca.Id];
            System.assertEquals('Non-Compliant', after.Status__c);
            System.assertEquals(true, after.Analyst_Validated__c);
            System.assertEquals(UserInfo.getUserId(), after.Evaluator_User__c);
            System.assertEquals(1, [SELECT COUNT() FROM Audit_Log__c WHERE Related_Record_Id__c = :ca.Id AND Event_Type__c = 'Analyst_Decision_Recorded']);

            // A bare validated-toggle with no verdict is not a decision and is not logged.
            VendorPortalController.saveDocValidation(ca.Id, 'toggle only', false, null);
            System.assertEquals('Non-Compliant', [SELECT Status__c FROM Compliance_Assessment__c WHERE Id = :ca.Id].Status__c);
            System.assertEquals(1, [SELECT COUNT() FROM Audit_Log__c WHERE Related_Record_Id__c = :ca.Id AND Event_Type__c = 'Analyst_Decision_Recorded']);

            String msg;
            try { VendorPortalController.saveDocValidation(null, null, null, null); } catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg);
        }
    }

    @IsTest
    static void procurementApprovalAndDecision_preHandoff() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Approve Co', null, 'Screening');
            Compliance_Assessment__c ca = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'At Risk', 'Medium');

            VendorPortalController.approveDocumentAsProcurement(ca.Id, 'fine by procurement', true);
            System.assertEquals(true, [SELECT Analyst_Validated__c FROM Compliance_Assessment__c WHERE Id = :ca.Id].Analyst_Validated__c);

            VendorPortalController.recordProcurementDecision(ca.Id, 'Rejected', 'expired certificate');
            Compliance_Assessment__c after = [SELECT Status__c, Procurement_Decision__c FROM Compliance_Assessment__c WHERE Id = :ca.Id];
            System.assertEquals('Rejected', after.Procurement_Decision__c);
            System.assertEquals('Non-Compliant', after.Status__c, 'Procurement\'s rejection is the effective verdict');

            String msg;
            try { VendorPortalController.approveDocumentAsProcurement(null, null, true); } catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg);
        }
    }

    @IsTest
    static void reassessDocument_reRunsTheAssessment() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Reassess Co', null, 'In Review');
            Compliance_Assessment__c ca = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Non-Compliant', 'High');
            Compliance_Document__c doc = TestDataFactory.complianceDocWithFile(a.Id, 'Certificate of Insurance', 'coi.pdf');
            ca.Compliance_Document__c = doc.Id; update ca;
            Compliance_Assessment__c noDoc = TestDataFactory.assessment(a.Id, 'ISO', 'ISO 9001', 'Pending', 'Medium');

            String msg;
            try { VendorPortalController.reassessDocument(noDoc.Id); } catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg, 'the guard must throw');

            Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
            Test.startTest();
            VendorPortalController.reassessDocument(ca.Id);
            System.assert([SELECT Reason_Detail__c FROM Compliance_Assessment__c WHERE Id = :ca.Id].Reason_Detail__c.contains('Re-assessment requested'));
            Test.stopTest();

            Compliance_Assessment__c after = [SELECT Status__c, AI_Confidence__c, Valid_Until__c, Reason_Detail__c, Reason_Code__c FROM Compliance_Assessment__c WHERE Id = :ca.Id];
            System.assertEquals('Compliant', after.Status__c, 'the fresh /assess verdict replaces the old one');
            System.assertEquals(88, after.AI_Confidence__c);
            System.assertEquals(Date.newInstance(2027, 3, 1), after.Valid_Until__c);
            System.assertEquals(null, after.Reason_Code__c);
            System.assert(after.Reason_Detail__c.contains('Checks passed'));
            System.assertEquals(1, [SELECT COUNT() FROM Audit_Log__c WHERE Related_Record_Id__c = :doc.Id AND Event_Type__c = 'Compliance_Evaluated']);
            msg = null;
            try { VendorPortalController.reassessDocument(null); } catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg);
        }
    }
}
