/**
 * AuditReportTest — AuditReportController filters + CSV export, the
 * AuditReportPDF Visualforce controller, and AuditLogService's typed writers.
 */
@IsTest
private class AuditReportTest {

    @TestSetup
    static void grantAccess() {
        TestDataFactory.createPersona();
    }

    private static String filterJson(String dateFrom, String dateTo, String supplierName, List<String> eventTypes, String actorType, String requirementKey) {
        AuditReportController.AuditFilter f = new AuditReportController.AuditFilter();
        f.dateFrom = dateFrom; f.dateTo = dateTo; f.supplierName = supplierName;
        f.eventTypes = eventTypes; f.actorType = actorType; f.requirementKey = requirementKey;
        return JSON.serialize(f);
    }

    @IsTest
    static void report_appliesEveryFilter() {
        System.runAs(TestDataFactory.persona()) {
            Account acme = TestDataFactory.supplier('Acme Audit Co');
            Account other = TestDataFactory.supplier('Unrelated Co');
            Compliance_Assessment__c ca = TestDataFactory.assessment(acme.Id, 'ISO_9001', 'ISO 9001', 'Compliant', 'Low');
            Compliance_Document__c doc = TestDataFactory.complianceDoc(acme.Id, 'ISO 9001', 'Pending');
            TestDataFactory.audit('Status_Changed', 'Supplier', acme.Id, 'Submitted', null, UserInfo.getUserId());
            TestDataFactory.audit('Compliance_Evaluated', 'Compliance_Assessment', ca.Id, 'Compliant', 'AI verdict', null);
            TestDataFactory.audit('Document_Uploaded', 'Compliance_Document', doc.Id, 'file', null, null);
            TestDataFactory.audit('Status_Changed', 'Supplier', other.Id, 'Submitted', null, null);

            String today = String.valueOf(Date.today());
            String yesterday = String.valueOf(Date.today().addDays(-1));

            List<AuditReportController.AuditRow> all = AuditReportController.getAuditReport(filterJson(null, null, null, null, null, null));
            System.assert(all.size() >= 4);

            List<AuditReportController.AuditRow> acmeRows = AuditReportController.getAuditReport(filterJson(yesterday, today, 'Acme Audit', null, null, null));
            System.assertEquals(3, acmeRows.size(), 'supplier filter expands to the supplier\'s documents and assessments');
            for (AuditReportController.AuditRow r : acmeRows) System.assertNotEquals(other.Id, r.relatedRecordId);

            List<AuditReportController.AuditRow> byType = AuditReportController.getAuditReport(filterJson(null, null, 'Acme Audit', new List<String>{ 'Compliance_Evaluated' }, 'System', null));
            System.assertEquals(1, byType.size());
            System.assertEquals('AI verdict', byType[0].reason);
            System.assertEquals('System', byType[0].actorName, 'no user → actor type shown');

            List<AuditReportController.AuditRow> byKey = AuditReportController.getAuditReport(filterJson(null, null, null, null, null, 'ISO_9001'));
            System.assertEquals(1, byKey.size());
            System.assertEquals(ca.Id, byKey[0].relatedRecordId);

            List<AuditReportController.AuditRow> byKeyAndSupplier = AuditReportController.getAuditReport(filterJson(null, null, 'Acme Audit', null, null, 'ISO_9001'));
            System.assertEquals(3, byKeyAndSupplier.size());

            AuditReportController.AuditRow userRow;
            for (AuditReportController.AuditRow r : all) if (r.relatedRecordId == acme.Id) userRow = r;
            System.assertEquals(UserInfo.getName(), userRow.actorName, 'a user actor is resolved to their name');
            System.assert(String.isNotBlank(userRow.eventDateTime));
        }
    }

    @IsTest
    static void export_writesCsvFile() {
        System.runAs(TestDataFactory.persona()) {
            Account acme = TestDataFactory.supplier('CSV Co');
            TestDataFactory.audit('Status_Changed', 'Supplier', acme.Id, 'He said "hi"\nnew line', 'why', UserInfo.getUserId());
            Id contentDocId = AuditReportController.exportToCSV(filterJson(null, null, 'CSV Co', null, null, null));
            ContentVersion cv = [SELECT Title, VersionData FROM ContentVersion WHERE ContentDocumentId = :contentDocId LIMIT 1];
            System.assert(cv.Title.startsWith('Audit_Report_'));
            String csv = cv.VersionData.toString();
            System.assert(csv.startsWith('"Audit ID"'));
            System.assert(csv.contains('"He said ""hi"" new line"'), 'quotes are doubled and line breaks flattened: ' + csv);
        }
    }

    @IsTest
    static void pdfController_readsUrlParametersAndSummarises() {
        System.runAs(TestDataFactory.persona()) {
            Account acme = TestDataFactory.supplier('PDF Co');
            TestDataFactory.audit('Status_Changed', 'Supplier', acme.Id, 'x'.repeat(500), 'r'.repeat(200), UserInfo.getUserId());

            Test.setCurrentPage(Page.AuditReportPDF);
            ApexPages.currentPage().getParameters().put('supplierName', 'PDF Co');
            ApexPages.currentPage().getParameters().put('eventTypes', 'Status_Changed,Manual_Override');
            ApexPages.currentPage().getParameters().put('actorType', 'User');
            ApexPages.currentPage().getParameters().put('dateFrom', String.valueOf(Date.today().addDays(-1)));
            AuditReportPDFController ctrl = new AuditReportPDFController();
            System.assertEquals(1, ctrl.totalRecords);
            System.assert(ctrl.filterSummary.contains('Supplier: PDF Co') && ctrl.filterSummary.contains('Events:'));
            System.assertEquals('Status_Changed, Manual_Override', ctrl.eventTypesLabel);
            System.assertEquals(401, ctrl.rows[0].newValue.length(), 'long values are truncated with an ellipsis');
            System.assertEquals(151, ctrl.rows[0].reason.length());

            Test.setCurrentPage(Page.AuditReportPDF);
            AuditReportPDFController unfiltered = new AuditReportPDFController();
            System.assertEquals('All records (no filters applied)', unfiltered.filterSummary);
            System.assertEquals('All', unfiltered.eventTypesLabel);
        }
    }

    @IsTest
    static void auditLogService_typedWriters() {
        System.runAs(TestDataFactory.persona()) {
            Account a = TestDataFactory.supplier('Sink Co');
            Compliance_Assessment__c ca = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Pending', 'Low');
            Compliance_Document__c doc = TestDataFactory.complianceDoc(a.Id, 'Certificate of Insurance', 'Pending');
            AuditLogService.logAIExtraction(doc.Id, 'gpt-4o', '2024-08', 0.91, '{"raw":true}', 'AI');
            AuditLogService.logAssessmentChange(ca.Id, 'Pending', 'Compliant', 'analyst confirmed', 'Human');
            AuditLogService.logDocumentReceived(doc.Id, a.Id, 'Certificate of Insurance', 'coi.pdf');
            AuditLogService.logCascadingRiskChange(a.Id, 'Low', 'High', 'sub-supplier flagged');
            System.assertEquals(1, [SELECT COUNT() FROM Audit_Log__c WHERE Event_Type__c = 'AI_Extraction' AND AI_Model_Name__c = 'gpt-4o']);
            List<Audit_Log__c> changed = [SELECT Original_Value__c, New_Value__c, Reason__c FROM Audit_Log__c
                                          WHERE Event_Type__c = 'Compliance_Evaluated' AND Related_Record_Id__c = :ca.Id];
            System.assertEquals(1, changed.size());
            System.assertEquals('Pending', changed[0].Original_Value__c);
            System.assertEquals('Compliant', changed[0].New_Value__c);
            System.assertEquals(1, [SELECT COUNT() FROM Audit_Log__c WHERE Event_Type__c = 'Document_Uploaded' AND Related_Record_Id__c = :doc.Id]);
            List<Audit_Log__c> cascade = [SELECT New_Value__c, Original_Value__c FROM Audit_Log__c
                                          WHERE Event_Type__c = 'Cascading_Risk_Updated' AND Related_Record_Id__c = :a.Id];
            System.assertEquals(1, cascade.size());
            System.assertEquals('High', cascade[0].New_Value__c);
            System.assertEquals('Low', cascade[0].Original_Value__c);
        }
    }
}
