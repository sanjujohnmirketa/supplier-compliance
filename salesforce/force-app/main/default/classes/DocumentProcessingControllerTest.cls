/**
 * DocumentProcessingControllerTest — upload/link/remove flows and the
 * DocAssessQueueable that every link enqueues (verdict writing, multi-document
 * roll-up, failure handling).
 */
@IsTest
private class DocumentProcessingControllerTest {

    @TestSetup
    static void grantAccess() {
        TestDataFactory.createPersona();
    }

    private static String B64 = TestDataFactory.base64('certificate body');

    @IsTest
    static void saveFile_internalAndToken() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Save Co', 'tok-save', 'In Review');
            String d1 = DocumentProcessingController.saveFile(a.Id, 'a.txt', B64);
            String d2 = DocumentProcessingController.saveFileByToken('tok-save', 'b.txt', B64);
            System.assertEquals(2, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :a.Id]);
            System.assertNotEquals(d1, d2);
            String msg;
            try { DocumentProcessingController.saveFile(a.Id, 'x', ''); } catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg, 'the guard must throw');
            msg = null;
            try { DocumentProcessingController.saveFileByToken('bad-token', 'x', B64); } catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg);
        }
    }

    @IsTest
    static void linkReplace_createsDocRunsAssessmentAndLogs() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Link Co', null, 'In Review');
            Compliance_Assessment__c ca = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Pending', 'Medium');
            Id cd = TestDataFactory.contentDocument('coi.pdf', 'body', a.Id);
            EngineCalloutMock.assessVerdict = 'Non-Compliant';
            EngineCalloutMock.assessSeverity = 'High';
            Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());

            Test.startTest();
            String docId = DocumentProcessingController.linkDocumentToCompliance(a.Id, cd, 'Certificate of Insurance', ca.Id, 'coi.pdf');
            Compliance_Assessment__c mid = [SELECT Status__c, Reason_Detail__c, Compliance_Document__c FROM Compliance_Assessment__c WHERE Id = :ca.Id];
            System.assertEquals('Pending', mid.Status__c);
            System.assertEquals(docId, mid.Compliance_Document__c);
            System.assert(mid.Reason_Detail__c.contains('pending AI extraction'));
            Test.stopTest();

            Compliance_Document__c doc = [SELECT Source_File__c, Status__c, Upload_Channel__c FROM Compliance_Document__c WHERE Id = :docId];
            System.assertEquals(cd, doc.Source_File__c);
            System.assertEquals('Portal', doc.Upload_Channel__c);
            System.assertEquals(1, [SELECT COUNT() FROM ContentDocumentLink WHERE ContentDocumentId = :cd AND LinkedEntityId = :docId]);

            Compliance_Assessment__c after = [SELECT Status__c, Severity__c, Reason_Code__c, Reason_Detail__c, AI_Confidence__c, Valid_Until__c FROM Compliance_Assessment__c WHERE Id = :ca.Id];
            System.assertEquals('Non-Compliant', after.Status__c);
            System.assertEquals('High', after.Severity__c);
            System.assertEquals('Rule Not Met', after.Reason_Code__c);
            System.assert(after.Reason_Detail__c.contains('Concerns:'), after.Reason_Detail__c);
            System.assert(after.Reason_Detail__c.contains('GLEIF registry: FAIL'));
            System.assertEquals(88, after.AI_Confidence__c);
            System.assertEquals(Date.newInstance(2027, 3, 1), after.Valid_Until__c);

            List<Audit_Log__c> uploads = [SELECT Reason__c, Actor_User__c FROM Audit_Log__c WHERE Related_Record_Id__c = :ca.Id AND Event_Type__c = 'Document_Uploaded'];
            System.assertEquals(1, uploads.size());
            System.assertEquals('coi.pdf', uploads[0].Reason__c, 'the history reads "Uploaded <file name>"');
            System.assertEquals(UserInfo.getUserId(), uploads[0].Actor_User__c, 'an internal upload is attributed to the user');
            Audit_Log__c ai = [SELECT AI_Model_Name__c, AI_Confidence__c FROM Audit_Log__c WHERE Related_Record_Id__c = :docId AND Event_Type__c = 'Compliance_Evaluated' LIMIT 1];
            System.assertEquals('gpt-4o', ai.AI_Model_Name__c);
            System.assertEquals(0.88, ai.AI_Confidence__c);
            System.assertNotEquals(null, [SELECT Risk_Score__c FROM Account WHERE Id = :a.Id].Risk_Score__c, 'the score is recomputed from the finding');

            Map<String, Object> status = DocumentProcessingController.getProcessingStatus(docId, ca.Id);
            System.assertEquals('Non-Compliant', status.get('assessmentStatus'));
            System.assertEquals('Pending', status.get('docStatus'));
        }
    }

    @IsTest
    static void linkReplace_reusesShellSupersedesLinksAndClearsDecision() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Replace Co', 'tok-replace', 'In Review');
            Compliance_Assessment__c ca = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Non-Compliant', 'High');
            Compliance_Document__c shell = TestDataFactory.complianceDoc(a.Id, 'Certificate of Insurance', 'Rejected');
            ca.Compliance_Document__c = shell.Id;
            ca.Procurement_Decision__c = 'Rejected'; ca.Procurement_Decision_Reason__c = 'old file';
            ca.Analyst_Validated__c = true;
            update ca;
            insert new Compliance_Document_Link__c(Compliance_Assessment__c = ca.Id, Compliance_Document__c = shell.Id, Status__c = 'Non-Compliant');
            Id cd = TestDataFactory.contentDocument('coi-v2.pdf', 'body', a.Id);
            Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());

            Test.startTest();
            String docId = DocumentProcessingController.linkDocumentToComplianceByToken('tok-replace', cd, 'Certificate of Insurance', ca.Id, 'coi-v2.pdf');
            Test.stopTest();

            System.assertEquals(shell.Id, docId, 'the requirement\'s existing document slot is reused, not duplicated');
            System.assertEquals(1, [SELECT COUNT() FROM Compliance_Document__c WHERE Account__c = :a.Id]);
            System.assertEquals('Superseded', [SELECT Status__c FROM Compliance_Document_Link__c WHERE Compliance_Assessment__c = :ca.Id LIMIT 1].Status__c);
            Compliance_Assessment__c after = [SELECT Status__c, Procurement_Decision__c, Analyst_Validated__c FROM Compliance_Assessment__c WHERE Id = :ca.Id];
            System.assertEquals(null, after.Procurement_Decision__c, 'a decision on the replaced file no longer applies');
            System.assertEquals(false, after.Analyst_Validated__c);
            System.assertEquals('Compliant', after.Status__c, 'the new file\'s own verdict lands');
        }
    }

    @IsTest
    static void linkAdd_createsJunctionAndRollsUpWorstWins() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Add Co', null, 'In Review');
            Compliance_Assessment__c ca = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Compliant', 'Low');
            Compliance_Document__c first = TestDataFactory.complianceDoc(a.Id, 'Certificate of Insurance', 'Pending');
            ca.Compliance_Document__c = first.Id; ca.Valid_Until__c = Date.today().addDays(400); update ca;
            insert new Compliance_Document_Link__c(Compliance_Assessment__c = ca.Id, Compliance_Document__c = first.Id,
                Status__c = 'Compliant', Severity__c = 'Low', Valid_Until__c = Date.today().addDays(400), Reason_Detail__c = 'first file ok');
            Id cd2 = TestDataFactory.contentDocument('coi-extra.pdf', 'body', a.Id);
            EngineCalloutMock.assessVerdict = 'Non-Compliant';
            EngineCalloutMock.assessSeverity = 'Critical';
            Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());

            Test.startTest();
            String docId = DocumentProcessingController.addDocumentToCompliance(a.Id, cd2, 'Certificate of Insurance', ca.Id, 'coi-extra.pdf');
            Test.stopTest();

            System.assertNotEquals(first.Id, docId, 'add mode always creates a fresh document shell');
            List<Compliance_Document_Link__c> links = [SELECT Status__c, Compliance_Document__c FROM Compliance_Document_Link__c WHERE Compliance_Assessment__c = :ca.Id ORDER BY CreatedDate];
            System.assertEquals(2, links.size());
            System.assertEquals('Non-Compliant', links[1].Status__c);
            Compliance_Assessment__c after = [SELECT Status__c, Severity__c, Valid_Until__c, Reason_Detail__c, Compliance_Document__c FROM Compliance_Assessment__c WHERE Id = :ca.Id];
            System.assertEquals('Non-Compliant', after.Status__c, 'worst-wins roll-up across both files');
            System.assertEquals('Critical', after.Severity__c);
            System.assertEquals(Date.newInstance(2027, 3, 1), after.Valid_Until__c, 'earliest expiry across the linked files');
            System.assert(after.Reason_Detail__c.contains('first file ok') && after.Reason_Detail__c.contains('---'));
            System.assertEquals(first.Id, after.Compliance_Document__c, 'the single-file pointer is left as it was');
        }
    }

    @IsTest
    static void link_validationAndUnmatchedUploadIsNotAssessed() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Unmatched Co');
            Id cd = TestDataFactory.contentDocument('mystery.pdf', 'body', a.Id);
            String msg;
            try { DocumentProcessingController.linkDocumentToCompliance(a.Id, null, 'X', null, 'f'); } catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg, 'the guard must throw');

            Test.startTest();
            String docId = DocumentProcessingController.linkDocumentToCompliance(a.Id, cd, 'Mystery Document; extra', null, 'mystery.pdf');
            Test.stopTest();
            Compliance_Document__c doc = [SELECT Name, Status__c FROM Compliance_Document__c WHERE Id = :docId];
            System.assertEquals('Mystery Document', doc.Name, 'the name is the part before the semicolon');
            System.assertEquals(0, [SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :a.Id],
                'an unmatched upload never invents a checklist row');
        }
    }

    @IsTest
    static void removeDocumentFromCompliance_resetsBothRecords() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Remove Co');
            Compliance_Assessment__c ca = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Compliant', 'Low');
            Compliance_Document__c doc = TestDataFactory.complianceDocWithFile(a.Id, 'Certificate of Insurance', 'coi.pdf');
            ca.Compliance_Document__c = doc.Id; update ca;

            System.assertEquals('success', DocumentProcessingController.removeDocumentFromCompliance(doc.Id, ca.Id));
            System.assertEquals(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :doc.Id]);
            Compliance_Document__c d = [SELECT Status__c, Source_File__c, Notes__c FROM Compliance_Document__c WHERE Id = :doc.Id];
            System.assertEquals('Pending', d.Status__c);
            System.assertEquals(null, d.Source_File__c);
            Compliance_Assessment__c after = [SELECT Status__c, Compliance_Document__c, Reason_Code__c FROM Compliance_Assessment__c WHERE Id = :ca.Id];
            System.assertEquals('Pending', after.Status__c);
            System.assertEquals(null, after.Compliance_Document__c);
            System.assertEquals('Missing Document', after.Reason_Code__c);
            String msg;
            try { DocumentProcessingController.removeDocumentFromCompliance('', null); } catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg);
        }
    }

    @IsTest
    static void checklistWithDocStatus_andProcessingStatus() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Status Co');
            Compliance_Assessment__c withDoc = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Non-Compliant', 'High');
            Compliance_Document__c doc = TestDataFactory.complianceDoc(a.Id, 'Certificate of Insurance', 'Rejected');
            doc.Notes__c = 'blurry scan'; update doc;
            withDoc.Compliance_Document__c = doc.Id; update withDoc;
            TestDataFactory.assessment(a.Id, 'ISO', 'ISO 9001', 'Pending', 'Medium');

            List<DocumentProcessingController.ChecklistRow> rows = DocumentProcessingController.getChecklistWithDocStatus(a.Id);
            System.assertEquals(2, rows.size());
            DocumentProcessingController.ChecklistRow r;
            for (DocumentProcessingController.ChecklistRow x : rows) if (x.assessmentId == withDoc.Id) r = x;
            System.assertEquals(true, r.hasDocument);
            System.assertEquals('Rejected', r.documentStatus);
            System.assertEquals('blurry scan', r.rejectionNote);
            System.assertEquals('COI', r.documentType, 'the key suffix is used when no CMT record maps it');

            Map<String, Object> s = DocumentProcessingController.getProcessingStatus(doc.Id, withDoc.Id);
            System.assertEquals('Rejected', s.get('docStatus'));
            System.assertEquals('Non-Compliant', s.get('assessmentStatus'));
            Map<String, Object> empty = DocumentProcessingController.getProcessingStatus(null, null);
            System.assertEquals(null, empty.get('docStatus'));
            String msg;
            try { DocumentProcessingController.getChecklistWithDocStatus(null); } catch (AuraHandledException e) { msg = e.getMessage(); }
            System.assertNotEquals(null, msg);
        }
    }

    // ── DocAssessQueueable edge paths ────────────────────────────────────
    @IsTest
    static void docAssess_engineFailureFlagsRowForHumans() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Assess Fail Co');
            Compliance_Assessment__c ca = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Pending', 'Medium');
            Compliance_Document__c doc = TestDataFactory.complianceDocWithFile(a.Id, 'Certificate of Insurance', 'coi.pdf');
            EngineCalloutMock.statusCode = 502;
            Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());

            Test.startTest();
            System.enqueueJob(new DocAssessQueueable(doc.Id, TestDataFactory.latestVersionId(doc.Source_File__c), a.Id, 'Certificate of Insurance', ca.Id));
            Test.stopTest();

            Compliance_Assessment__c after = [SELECT Status__c, Reason_Code__c, Reason_Detail__c, Compliance_Document__c FROM Compliance_Assessment__c WHERE Id = :ca.Id];
            System.assertEquals('At Risk', after.Status__c, 'a failed assessment is made visible, never left Pending');
            System.assertEquals('Other', after.Reason_Code__c);
            System.assert(after.Reason_Detail__c.contains('AI assessment failed'));
            System.assertEquals(doc.Id, after.Compliance_Document__c);
            System.assertNotEquals(null, [SELECT Last_Integration_Error__c FROM Account WHERE Id = :a.Id].Last_Integration_Error__c);
        }
    }

    @IsTest
    static void docAssess_missingFileAndDomainFallbackRow() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Assess Edge Co');
            Compliance_Assessment__c ca = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Pending', 'Medium');
            Compliance_Document__c doc = TestDataFactory.complianceDocWithFile(a.Id, 'Certificate of Insurance', 'coi.pdf');
            Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());

            Test.startTest();
            // 1. Unknown ContentVersion → the job exits without touching anything.
            System.enqueueJob(new DocAssessQueueable(doc.Id, '068000000000000AAA', a.Id, 'COI', ca.Id));
            // 2. No assessmentId → the verdict lands on a domain-keyed row so evidence is never lost.
            System.enqueueJob(new DocAssessQueueable(doc.Id, TestDataFactory.latestVersionId(doc.Source_File__c), a.Id, null));
            Test.stopTest();

            System.assertEquals('Pending', [SELECT Status__c FROM Compliance_Assessment__c WHERE Id = :ca.Id].Status__c);
            List<Compliance_Assessment__c> fallback = [SELECT Status__c, Requirement_Label__c FROM Compliance_Assessment__c
                                                       WHERE Supplier__c = :a.Id AND Requirement_Key__c = :(a.Id + '__SCOPE_finance')];
            System.assertEquals(1, fallback.size());
            System.assertEquals('Compliant', fallback[0].Status__c);
            System.assertEquals('RAG: finance', fallback[0].Requirement_Label__c);
        }
    }

    @IsTest
    static void docAssess_invocableEntryAndHelpers() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Assess Flow Co');
            Compliance_Document__c doc = TestDataFactory.complianceDocWithFile(a.Id, 'Certificate of Insurance', 'coi.pdf');
            Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());

            DocAssessQueueable.AssessInvokeRequest bad = new DocAssessQueueable.AssessInvokeRequest();
            DocAssessQueueable.AssessInvokeRequest good = new DocAssessQueueable.AssessInvokeRequest();
            good.complianceDocId = doc.Id; good.contentVersionId = TestDataFactory.latestVersionId(doc.Source_File__c);
            good.supplierId = a.Id; good.documentTypeHint = 'Certificate of Insurance';
            Test.startTest();
            DocAssessQueueable.enqueueFromEvent(null);
            DocAssessQueueable.enqueueFromEvent(new List<DocAssessQueueable.AssessInvokeRequest>{ bad, good });
            Test.stopTest();
            System.assertEquals(1, [SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :a.Id], 'only the well-formed request runs');

            System.assertEquals(null, DocAssessQueueable.parseExpiryDate(null));
            System.assertEquals(null, DocAssessQueueable.parseExpiryDate(new Map<String, Object>{ 'expiry_date' => 'not-a-date' }));
            System.assertEquals(Date.newInstance(2026, 1, 31), DocAssessQueueable.parseExpiryDate(new Map<String, Object>{ 'expiry_date' => '2026-01-31' }));
            System.assertEquals('At Risk', DocAssessQueueable.mapVerdict('Needs Analyst'));
            DocAssessQueueable.rollupRequirementStatus(null);
        }
    }
}
