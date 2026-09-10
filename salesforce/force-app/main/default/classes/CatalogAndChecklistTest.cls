/**
 * CatalogAndChecklistTest — the custom-metadata catalogs (materials, domains),
 * the Flow-facing checklist JSON, and the ScreeningQueueable wrapper.
 */
@IsTest
private class CatalogAndChecklistTest {

    @IsTest
    static void catalogs_readPackagedCustomMetadata() {
        List<MaterialTypeController.MaterialTypeOption> materials = MaterialTypeController.getMaterialTypeCatalog();
        System.assert(!materials.isEmpty(), 'Material_Type__mdt ships with the package');
        Set<String> kinds = new Set<String>();
        for (MaterialTypeController.MaterialTypeOption m : materials) {
            kinds.add(m.kind);
            System.assertNotEquals(null, m.domains);
            System.assert(String.isNotBlank(m.valueKey));
        }
        System.assert(kinds.contains('Material') || kinds.contains('Service'));

        List<ComplianceDomainController.DomainOption> domains = ComplianceDomainController.getDomainCatalog();
        System.assert(!domains.isEmpty(), 'Compliance_Domain__mdt ships with the package');
        for (ComplianceDomainController.DomainOption d : domains) System.assert(String.isNotBlank(d.key));
    }

    @IsTest
    static void checklistJson_bulkInputsWithUploadState() {
        Account a = TestDataFactory.supplier('Flow Co');
        Account b = TestDataFactory.supplier('Flow Co B');
        Compliance_Assessment__c uploaded = TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'At Risk', 'High');
        Compliance_Document__c doc = TestDataFactory.complianceDocWithFile(a.Id, 'Certificate of Insurance', 'coi.pdf');
        uploaded.Compliance_Document__c = doc.Id; uploaded.Reason_Detail__c = 'needs review'; update uploaded;
        TestDataFactory.assessment(a.Id, 'ISO', 'ISO 9001', 'Pending', 'Low');
        TestDataFactory.assessment(b.Id, 'TAX', 'Tax Clearance', 'Compliant', 'Low');

        ComplianceChecklistController.FlowInput inA = new ComplianceChecklistController.FlowInput(); inA.accountId = a.Id;
        ComplianceChecklistController.FlowInput inB = new ComplianceChecklistController.FlowInput(); inB.accountId = b.Id;
        List<ComplianceChecklistController.FlowOutput> out = ComplianceChecklistController.getChecklistJSON(
            new List<ComplianceChecklistController.FlowInput>{ inA, inB });
        System.assertEquals(2, out.size());
        List<Object> itemsA = (List<Object>) JSON.deserializeUntyped(out[0].checklistJSON);
        List<Object> itemsB = (List<Object>) JSON.deserializeUntyped(out[1].checklistJSON);
        System.assertEquals(2, itemsA.size());
        System.assertEquals(1, itemsB.size());
        Map<String, Object> coi;
        for (Object o : itemsA) { Map<String, Object> m = (Map<String, Object>) o; if (m.get('assessmentId') == uploaded.Id) coi = m; }
        System.assertEquals('done', coi.get('uploadStatus'));
        System.assertEquals('complete', coi.get('aiStatus'));
        System.assertEquals('Needs Human Review', coi.get('assessmentStatus'), 'At Risk is shown as needing a human');
        System.assertEquals(true, coi.get('isMandatory'));
        System.assertEquals('COI', coi.get('documentType'));
        List<Object> files = (List<Object>) coi.get('uploadedFiles');
        System.assertEquals('coi.pdf', ((Map<String, Object>) files[0]).get('name'));
        Map<String, Object> tax = (Map<String, Object>) itemsB[0];
        System.assertEquals('pending', tax.get('uploadStatus'));
        System.assertEquals(false, tax.get('isMandatory'), 'Low severity is optional');
    }

    @IsTest
    static void screeningQueueable_successAndFailureAreBothVisible() {
        Account ok = TestDataFactory.supplier('Queue OK Co');
        Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
        Test.startTest();
        System.enqueueJob(new ScreeningQueueable(ok.Id));
        Test.stopTest();
        System.assertEquals(4, [SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :ok.Id AND Requirement_Key__c LIKE 'SCREEN%']);
    }

    @IsTest
    static void screeningQueueable_failureWritesAnAuditRow() {
        Account bad = TestDataFactory.supplier('Queue Fail Co');
        EngineCalloutMock.statusCode = 500;
        Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
        Test.startTest();
        System.enqueueJob(new ScreeningQueueable(bad.Id));
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :bad.Id]);
        Audit_Log__c log = [SELECT New_Value__c FROM Audit_Log__c WHERE Related_Record_Id__c = :bad.Id LIMIT 1];
        System.assert(log.New_Value__c.contains('screening failed'), log.New_Value__c);
    }
}
