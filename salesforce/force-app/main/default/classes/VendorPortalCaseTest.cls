/**
 * VendorPortalCaseTest — the case side of VendorPortalController: the supplier
 * snapshot (internal + token), documents, checklist edits, the comment thread,
 * decisions, case close, activity and the co-pilot.
 */
@IsTest
private class VendorPortalCaseTest {

    // ── snapshot ─────────────────────────────────────────────────────────
    @IsTest
    static void snapshot_reflectsChecklistDocumentsAndThread() {
        Account a = TestDataFactory.supplier('Snapshot Co', 'tok-snapshot', 'In Review');
        a.Risk_Tier__c = 'High'; a.HITL_Threshold__c = 'Medium'; update a;
        Compliance_Assessment__c pending = TestDataFactory.assessment(a.Id, 'ISO', 'ISO 9001 Certificate', 'Pending', 'Medium');
        Compliance_Assessment__c withDoc = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Non-Compliant', 'High');
        TestDataFactory.screeningRow(a.Id, 'Sanctions', 'Compliant');

        Compliance_Document__c doc = TestDataFactory.complianceDocWithFile(a.Id, 'Certificate of Insurance', 'coi.pdf');
        withDoc.Compliance_Document__c = doc.Id;
        withDoc.Procurement_Decision__c = 'Rejected';
        withDoc.Procurement_Decision_Reason__c = 'Coverage too low';
        withDoc.Procurement_Decision_DateTime__c = DateTime.now().addHours(-2);
        update withDoc;
        insert new Compliance_Document_Link__c(
            Compliance_Assessment__c = withDoc.Id, Compliance_Document__c = doc.Id,
            Status__c = 'Non-Compliant', Severity__c = 'High', Reason_Detail__c = 'Below minimum',
            Valid_Until__c = Date.today().addDays(90), AI_Confidence__c = 77);
        // Thread: the decision, then the supplier's reply (newer than the decision).
        TestDataFactory.audit('Procurement_Decision_Recorded', 'Compliance_Assessment', withDoc.Id, 'Rejected', 'Coverage too low', UserInfo.getUserId());
        TestDataFactory.audit('Document_Uploaded', 'Compliance_Assessment', withDoc.Id, null, 'coi.pdf', null);
        TestDataFactory.audit('Supplier_Comment_Added', 'Compliance_Assessment', withDoc.Id, 'Comment', 'Renewed policy attached', null);

        Test.startTest();
        VendorPortalController.SupplierSnapshot s  = VendorPortalController.getSupplierSnapshot(a.Id);
        VendorPortalController.SupplierSnapshot st = VendorPortalController.getSupplierSnapshotByToken('tok-snapshot');
        Test.stopTest();

        System.assertEquals(a.Id, st.accountId, 'the token path resolves to the same supplier');
        System.assertEquals(3, s.assessedCount);
        System.assertEquals(2, s.docsTotal, 'screening rows are not checklist items');
        System.assertEquals(1, s.docsUploaded);
        System.assertEquals(1, s.docCount, 'one file stored on the Account');
        System.assertEquals(true, s.routedToAnalyst, 'High tier above a Medium threshold routes to an analyst');
        System.assertEquals(false, s.isAssignedToAnalyst);
        System.assertEquals(false, s.isSubSupplier);
        System.assertEquals('Low', s.recommendedHitl);
        System.assert(s.domains.contains('finance'));

        VendorPortalController.AssessmentSummary row;
        for (VendorPortalController.AssessmentSummary x : s.assessments) if (x.assessmentId == withDoc.Id) row = x;
        System.assertEquals(true, row.uploaded);
        System.assertEquals(true, row.rejected);
        System.assertEquals('bad', row.badgeClass);
        System.assertEquals(doc.Source_File__c, row.contentDocumentId, 'the real ContentDocumentId is exposed for the decision buttons');
        System.assertEquals(1, row.documentLinks.size());
        System.assertEquals(77, row.documentLinks[0].aiConfidence);
        System.assertNotEquals(null, row.documentLinks[0].versionId);
        System.assertEquals(3, row.procurementComments.size(), 'decision + upload + reply form one thread');
        System.assertEquals(true, row.pendingReReview, 'a supplier reply newer than the rejection flags the row for re-review');
        Integer supplierEntries = 0;
        for (VendorPortalController.ProcurementComment c : row.procurementComments) if (c.isSupplierComment) supplierEntries++;
        System.assertEquals(2, supplierEntries, 'the guest upload and the reply are attributed to the supplier');

        String msg;
        try { VendorPortalController.getSupplierSnapshot(null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
    }

    // ── documents ────────────────────────────────────────────────────────
    @IsTest
    static void documents_listRemoveAndOwnership() {
        Account a = TestDataFactory.supplier('Docs Co', 'tok-docs', 'In Review');
        Account other = TestDataFactory.supplier('Other Co');
        Id mine  = TestDataFactory.contentDocument('mine.pdf', 'body', a.Id);
        Id theirs = TestDataFactory.contentDocument('theirs.pdf', 'body', other.Id);
        Compliance_Document__c cd = TestDataFactory.complianceDoc(a.Id, 'Certificate of Insurance', 'Pending');
        insert new ContentDocumentLink(ContentDocumentId = mine, LinkedEntityId = cd.Id, ShareType = 'V', Visibility = 'AllUsers');
        Compliance_Assessment__c ca = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Compliant', 'Low');
        ca.Compliance_Document__c = cd.Id; update ca;

        List<VendorPortalController.CaseDocument> docs = VendorPortalController.getCaseDocuments(a.Id);
        System.assertEquals(1, docs.size());
        System.assertEquals('mine.pdf', docs[0].title);
        System.assert(docs[0].previewUrl.contains(docs[0].versionId));
        System.assertEquals(0, VendorPortalController.getCaseDocuments(null).size());

        String msg;
        try { VendorPortalController.removeSupplierDocumentByToken('tok-docs', theirs); }
        catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');
        System.assertEquals(1, [SELECT COUNT() FROM ContentDocument WHERE Id = :theirs]);

        Test.startTest();
        VendorPortalController.removeSupplierDocumentByToken('tok-docs', mine);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM ContentDocument WHERE Id = :mine], 'the file is deleted');
        Compliance_Assessment__c reset = [SELECT Status__c, Compliance_Document__c FROM Compliance_Assessment__c WHERE Id = :ca.Id];
        System.assertEquals('Pending', reset.Status__c);
        System.assertEquals(null, reset.Compliance_Document__c);

        msg = null;
        try { VendorPortalController.removeSupplierDocument(a.Id, null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
    }

    @IsTest
    static void publicDocumentUrl_boundedAndOwnershipChecked() {
        Account a = TestDataFactory.supplier('Share Co', 'tok-share', 'In Review');
        Account other = TestDataFactory.supplier('Other Share Co');
        Id mine   = TestDataFactory.contentDocument('share.pdf', 'body', a.Id);
        Id theirs = TestDataFactory.contentDocument('other.pdf', 'body', other.Id);

        String msg;
        try { VendorPortalController.generatePublicDocumentUrlByToken('tok-share', theirs); }
        catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');
        msg = null;
        try { VendorPortalController.generatePublicDocumentUrl(null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);

        // ContentDistribution needs Content Deliveries enabled in the org; the
        // method either returns a URL or wraps the platform refusal — both are
        // the contract, neither is a crash.
        Test.startTest();
        try {
            String url = VendorPortalController.generatePublicDocumentUrlByToken('tok-share', mine);
            System.assertNotEquals(null, url);
            String again = VendorPortalController.generatePublicDocumentUrl(mine);
            System.assertEquals(url, again, 'an existing distribution is reused');
            System.assertEquals(1, [SELECT COUNT() FROM ContentDistribution WHERE ContentVersionId = :TestDataFactory.latestVersionId(mine)]);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Failed to generate public document URL'), e.getMessage());
        }
        Test.stopTest();
    }

    // ── checklist edits ──────────────────────────────────────────────────
    @IsTest
    static void checklist_addRemoveAndPostHandoffLock() {
        Account a = TestDataFactory.supplier('Checklist Co', 'tok-check', 'In Review');
        String id1 = VendorPortalController.addRequirementFromDocument(a.Id, 'Fire Safety Certificate', null);
        String id2 = VendorPortalController.addRequirementFromDocument(a.Id, 'Fire Safety Certificate', null);
        System.assertEquals(id1, id2, 're-adding the same document upserts');
        Compliance_Assessment__c row = [SELECT Requirement_Key__c, Status__c FROM Compliance_Assessment__c WHERE Id = :id1];
        System.assert(row.Requirement_Key__c.startsWith('USERADD_'));
        System.assertEquals('Pending', row.Status__c);
        System.assertEquals(2, [SELECT COUNT() FROM Audit_Log__c WHERE Related_Record_Id__c = :id1 AND Event_Type__c = 'Compliance_Evaluated'], 'each promotion is audited, even an idempotent re-add');

        String id3 = VendorPortalController.addRequirementFromDocumentByToken('tok-check', 'Export Licence', 'CUSTOM_KEY_' + a.Id);
        System.assertEquals('CUSTOM_KEY_' + a.Id, [SELECT Requirement_Key__c FROM Compliance_Assessment__c WHERE Id = :id3].Requirement_Key__c);
        Id id4 = VendorPortalController.addChecklistRequirement(a.Id, 'Tax Clearance');
        System.assertEquals(3, [SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :a.Id]);

        VendorPortalController.removeChecklistRequirement(id4);
        System.assertEquals(2, [SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :a.Id]);

        String msg;
        try { VendorPortalController.addRequirementFromDocument(a.Id, ' ', null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
        msg = null;
        try { VendorPortalController.removeChecklistRequirement(null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);

        // Post-handoff: Procurement can no longer edit the checklist.
        a.Analyst_Assigned_DateTime__c = DateTime.now(); update a;
        msg = null;
        try { VendorPortalController.addChecklistRequirement(a.Id, 'Late addition'); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');
        msg = null;
        try { VendorPortalController.removeChecklistRequirement(id1); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');
    }

    // ── comment thread ───────────────────────────────────────────────────
    @IsTest
    static void supplierComments_internalAndTokenScoped() {
        Account a = TestDataFactory.supplier('Comment Co', 'tok-comment', 'In Review');
        Account other = TestDataFactory.supplier('Other Comment Co');
        Compliance_Assessment__c mine = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Non-Compliant', 'High');
        Compliance_Assessment__c theirs = TestDataFactory.assessment(other.Id, 'COI', 'Certificate of Insurance', 'Pending', 'Low');

        VendorPortalController.addSupplierComment(mine.Id, 'Please see the attached renewal.');
        VendorPortalController.addSupplierCommentByToken('tok-comment', mine.Id, 'Second note');
        System.assertEquals(2, [SELECT COUNT() FROM Audit_Log__c WHERE Related_Record_Id__c = :mine.Id AND Event_Type__c = 'Supplier_Comment_Added']);

        String msg;
        try { VendorPortalController.addSupplierComment(mine.Id, '  '); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');
        Boolean blocked = false;
        try { VendorPortalController.addSupplierCommentByToken('tok-comment', theirs.Id, 'not mine'); }
        catch (Exception e) { blocked = true; }
        System.assert(blocked, 'a guest cannot comment on another supplier\'s requirement');
        System.assertEquals(0, [SELECT COUNT() FROM Audit_Log__c WHERE Related_Record_Id__c = :theirs.Id]);
        msg = null;
        try { VendorPortalController.addSupplierCommentByToken('tok-comment', null, 'x'); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
    }

    // ── decisions, outcomes, activity ────────────────────────────────────
    @IsTest
    static void decisionsOutcomesAndActivity() {
        Account a = TestDataFactory.supplier('Decision Co', null, 'In Review');
        a.Analyst_Assigned_DateTime__c = DateTime.now(); update a;

        VendorPortalController.saveDecision(a.Id, 'LOW', 'Auto-approve', 'clean record');
        Account after = [SELECT Risk_Tier__c, Onboarding_Status__c, Analyst_Assigned_DateTime__c FROM Account WHERE Id = :a.Id];
        System.assertEquals('Low', after.Risk_Tier__c);
        System.assertEquals('Approved', after.Onboarding_Status__c);
        System.assertEquals(null, after.Analyst_Assigned_DateTime__c, 'a LOW decision releases the case from the analyst');

        VendorPortalController.saveDecision(a.Id, 'HIGH', 'Needs analyst', null);
        System.assertEquals('High', [SELECT Risk_Tier__c FROM Account WHERE Id = :a.Id].Risk_Tier__c);

        System.assertEquals(a.Id, VendorPortalController.setReviewOutcome(a.Id, 'ready', 'good to go'));
        System.assertEquals('Reviewed', [SELECT Onboarding_Status__c FROM Account WHERE Id = :a.Id].Onboarding_Status__c);
        VendorPortalController.setReviewOutcome(a.Id, 'failed', null);
        System.assertEquals('Rejected', [SELECT Onboarding_Status__c FROM Account WHERE Id = :a.Id].Onboarding_Status__c);
        VendorPortalController.saveCopilotFeedback(a.Id, 'accepted', 'summary was accurate');

        List<VendorPortalController.ActivityRow> rows = VendorPortalController.getCaseActivity(a.Id);
        System.assert(rows.size() >= 5, 'every decision is an activity row: ' + rows.size());
        Set<String> titles = new Set<String>();
        for (VendorPortalController.ActivityRow r : rows) titles.add(r.title);
        System.assert(titles.contains('Analyst decision recorded'));
        System.assert(titles.contains('Status changed'));
        System.assertEquals(0, VendorPortalController.getCaseActivity(null).size());

        String msg;
        try { VendorPortalController.saveDecision(null, 'LOW', 'x', 'y'); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
        msg = null;
        try { VendorPortalController.setReviewOutcome(null, 'ready', null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
        msg = null;
        try { VendorPortalController.saveCopilotFeedback(null, 'x', null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
    }

    @IsTest
    static void closeCase_directOnboardGatesOnApprovals() {
        Account a = TestDataFactory.supplier('Close Co', 'tok-close', 'In Review');
        Compliance_Assessment__c c1 = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Compliant', 'Low');
        Compliance_Assessment__c c2 = TestDataFactory.assessment(a.Id, 'ISO', 'ISO 9001', 'Compliant', 'Low');
        TestDataFactory.screeningRow(a.Id, 'Sanctions', 'Compliant');
        c1.Procurement_Decision__c = 'Approved'; c2.Procurement_Decision__c = 'Deferred';
        update new List<Compliance_Assessment__c>{ c1, c2 };

        String msg;
        try { VendorPortalController.onboardSupplierDirectly(a.Id, 'all good'); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');

        c2.Procurement_Decision__c = 'Approved'; update c2;
        VendorPortalController.onboardSupplierDirectly(a.Id, 'all good');
        Account closed = [SELECT Compliance_Case_Status__c, Onboarding_Status__c, Case_Closed_By__c, Closing_Remarks__c FROM Account WHERE Id = :a.Id];
        System.assertEquals('Closed - Compliant', closed.Compliance_Case_Status__c);
        System.assertEquals('Approved', closed.Onboarding_Status__c);
        System.assertEquals(UserInfo.getUserId(), closed.Case_Closed_By__c);
        System.assertEquals('all good', closed.Closing_Remarks__c);
        VendorPortalController.SupplierSnapshot s = VendorPortalController.getSupplierSnapshotByToken('tok-close');
        System.assertEquals(true, s.isCaseClosed);
        System.assertEquals(1, [SELECT COUNT() FROM Audit_Log__c WHERE Related_Record_Id__c = :a.Id AND Event_Type__c = 'Case_Closed']);

        Account empty = TestDataFactory.supplier('Empty Co');
        msg = null;
        try { VendorPortalController.onboardSupplierDirectly(empty.Id, null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');
        msg = null;
        try { VendorPortalController.onboardSupplierDirectly(null, null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);

        Account b = TestDataFactory.supplier('Analyst Close Co', null, 'In Review');
        VendorPortalController.closeComplianceCase(b.Id, 'analyst sign-off');
        System.assertEquals('Closed - Compliant', [SELECT Compliance_Case_Status__c FROM Account WHERE Id = :b.Id].Compliance_Case_Status__c);
    }

    // ── co-pilot ─────────────────────────────────────────────────────────
    @IsTest
    static void copilot_groundedAskAndDraft() {
        Account a = TestDataFactory.supplier('Copilot Co', null, 'In Review');
        Compliance_Assessment__c uploaded = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Compliant', 'Low');
        uploaded.Compliance_Document__c = TestDataFactory.complianceDoc(a.Id, 'Certificate of Insurance', 'Pending').Id;
        update uploaded;
        TestDataFactory.assessment(a.Id, 'ISO', 'ISO 9001', 'Pending', 'Medium');
        TestDataFactory.screeningRow(a.Id, 'Sanctions', 'Compliant');
        Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());

        Test.startTest();
        CopilotService.CopilotResponse r = VendorPortalController.askCopilot(a.Id, 'What is missing?');
        String draft = VendorPortalController.copilotDraftComment(a.Id, 'Certificate of Insurance', 'Coverage OK', 'looks fine');
        Test.stopTest();
        System.assert(r.answer.contains('1 of 2'));
        System.assertEquals(1, r.blockers.size());
        System.assertEquals('The supplier has uploaded 1 of 2 required documents.', draft);

        String msg;
        try { VendorPortalController.askCopilot(a.Id, ' '); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
        msg = null;
        try { VendorPortalController.copilotDraftComment(null, null, null, null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
    }

    @IsTest
    static void copilot_surfacesEngineFailure() {
        Account a = TestDataFactory.supplier('Copilot Fail Co');
        EngineCalloutMock.statusCode = 503;
        Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
        String m1; String m2;
        try { VendorPortalController.askCopilot(a.Id, 'anything'); } catch (AuraHandledException e) { m1 = e.getMessage(); }
        try { VendorPortalController.copilotDraftComment(a.Id, 'x', 'y', 'z'); } catch (AuraHandledException e) { m2 = e.getMessage(); }
        System.assertNotEquals(null, m1, 'the guard must throw');
        System.assertNotEquals(null, m2, 'the guard must throw');
    }
}
