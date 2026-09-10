/**
 * PolicyDocumentControllerTest — policy corpus upload/reupload/delete and the
 * two-phase PolicyIngestQueueable (inline resolve, failed, still-processing,
 * submit failure) plus the engine-side delete.
 */
@IsTest
private class PolicyDocumentControllerTest {

    private static String B64 = TestDataFactory.base64('# Policy\nAll suppliers must carry liability cover.');

    // A record with a file behind it but no in-flight ingest job — the upload
    // path enqueues one, which would run at Test.stopTest against the row the
    // test has just deleted.
    private static Id ingestedDoc() {
        Policy_Document__c pd = new Policy_Document__c(Status__c = 'Ingested', Domain__c = 'finance');
        insert pd;
        pd.Source_File__c = TestDataFactory.contentDocument('policy.md', 'policy body', pd.Id);
        update pd;
        return pd.Id;
    }

    @IsTest
    static void upload_ingestsInlineAndListsRealFileName() {
        Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
        Test.startTest();
        Id pdId = PolicyDocumentController.uploadPolicyDocument('policy.md', B64, null);
        Test.stopTest();

        Policy_Document__c pd = [SELECT Status__c, Domain__c, Chunk_Count__c, Corpus_Version__c, Ingested_Date__c, Ingest_Job_Id__c, Source_File__c
                                 FROM Policy_Document__c WHERE Id = :pdId];
        System.assertEquals('Ingested', pd.Status__c);
        System.assertEquals('finance', pd.Domain__c, 'auto-detect resolves to the engine\'s domain');
        System.assertEquals(12, pd.Chunk_Count__c);
        System.assertEquals('v3', pd.Corpus_Version__c);
        System.assertNotEquals(null, pd.Ingested_Date__c);
        System.assertEquals(null, pd.Ingest_Job_Id__c);
        System.assertNotEquals(null, pd.Source_File__c);
        System.assertEquals(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :pdId]);
        System.assertEquals(1, [SELECT COUNT() FROM Audit_Log__c WHERE Related_Record_Id__c = :pdId AND Event_Type__c = 'Document_Uploaded' AND Related_Object__c = 'Policy_Document']);

        List<PolicyDocumentController.PolicyDocumentRow> rows = PolicyDocumentController.getPolicyDocuments();
        System.assertEquals(1, rows.size());
        System.assertEquals('policy.md', rows[0].name, 'the list shows the uploaded file name, not the auto-number');
        System.assertEquals(12, rows[0].chunkCount);
        System.assertEquals(pd.Source_File__c, rows[0].sourceFileContentDocumentId);
    }

    @IsTest
    static void upload_engineFailedStatusIsRecorded() {
        EngineCalloutMock.policyStatus = 'failed';
        Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
        Test.startTest();
        Id pdId = PolicyDocumentController.uploadPolicyDocument('bad.md', B64, 'quality');
        Test.stopTest();
        Policy_Document__c pd = [SELECT Status__c, Failure_Reason__c, Domain__c FROM Policy_Document__c WHERE Id = :pdId];
        System.assertEquals('Failed', pd.Status__c);
        System.assertEquals('bad parse', pd.Failure_Reason__c);
        System.assertEquals('quality', pd.Domain__c, 'an explicit domain override is kept');
    }

    @IsTest
    static void upload_stillProcessingFallsBackToPollChain() {
        EngineCalloutMock.policyStatus = 'processing';
        Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
        Test.startTest();
        Id pdId = PolicyDocumentController.uploadPolicyDocument('big.pdf', B64, null);
        Test.stopTest();
        Integer statusChecks = 0;
        for (String ep : EngineCalloutMock.requests) if (ep.contains('/policy/ingest/status/')) statusChecks++;
        System.assert(statusChecks >= 5, 'every inline attempt is used before the async poll chain takes over: ' + statusChecks);
        Policy_Document__c pd = [SELECT Status__c, Ingest_Job_Id__c, Failure_Reason__c FROM Policy_Document__c WHERE Id = :pdId];
        // The async poll chain ran to its MAX_STACK_DEPTH ceiling with the
        // engine still 'processing' — reported on the record, never polled forever.
        System.assertEquals('Failed', pd.Status__c);
        System.assert(pd.Failure_Reason__c.contains('longer than expected'), pd.Failure_Reason__c);
        System.assertEquals(null, pd.Ingest_Job_Id__c, 'the job handle is released once the poll gives up');
    }

    @IsTest
    static void upload_submitFailureMarksDocumentFailed() {
        EngineCalloutMock.statusCode = 500;
        Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
        Test.startTest();
        Id pdId = PolicyDocumentController.uploadPolicyDocument('down.md', B64, null);
        Test.stopTest();
        Policy_Document__c pd = [SELECT Status__c, Failure_Reason__c FROM Policy_Document__c WHERE Id = :pdId];
        System.assertEquals('Failed', pd.Status__c);
        System.assert(pd.Failure_Reason__c.contains('HTTP 500'), pd.Failure_Reason__c);

        String msg;
        try { PolicyDocumentController.uploadPolicyDocument('', B64, null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');
    }

    @IsTest
    static void reupload_versionsTheSameFileAndResetsIngestState() {
        Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
        Test.startTest();
        Id pdId = PolicyDocumentController.uploadPolicyDocument('policy.md', B64, null);
        Test.stopTest();
        Id contentDocId = [SELECT Source_File__c FROM Policy_Document__c WHERE Id = :pdId].Source_File__c;

        PolicyDocumentController.reuploadPolicyDocument(pdId, 'policy-v2.md', TestDataFactory.base64('v2 body'));
        Policy_Document__c pd = [SELECT Status__c, Source_File__c, Chunk_Count__c, Corpus_Version__c, Ingested_Date__c FROM Policy_Document__c WHERE Id = :pdId];
        System.assertEquals('Processing', pd.Status__c);
        System.assertEquals(contentDocId, pd.Source_File__c, 'a new version of the SAME file keeps history');
        System.assertEquals(null, pd.Chunk_Count__c);
        System.assertEquals(null, pd.Ingested_Date__c);
        System.assertEquals(2, [SELECT COUNT() FROM ContentVersion WHERE ContentDocumentId = :contentDocId]);
        System.assertEquals(2, [SELECT COUNT() FROM Audit_Log__c WHERE Related_Record_Id__c = :pdId AND Event_Type__c = 'Document_Uploaded']);

        // A record that never got a file (legacy) receives one on reupload.
        Policy_Document__c bare = new Policy_Document__c(Status__c = 'Processing', Domain__c = 'Auto-Detect');
        insert bare;
        PolicyDocumentController.reuploadPolicyDocument(bare.Id, 'late.md', B64);
        System.assertNotEquals(null, [SELECT Source_File__c FROM Policy_Document__c WHERE Id = :bare.Id].Source_File__c);

        String msg;
        try { PolicyDocumentController.reuploadPolicyDocument(null, 'x', B64); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
        // A well-formed Id that no longer resolves (deleted by someone else).
        Id gone = Id.valueOf(Policy_Document__c.SObjectType.getDescribe().getKeyPrefix() + '000000000000');
        msg = null;
        try { PolicyDocumentController.reuploadPolicyDocument(gone, 'x.md', B64); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');
    }

    @IsTest
    static void delete_removesEngineChunksThenTheRecord() {
        Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
        Id pdId = ingestedDoc();

        Test.startTest();
        PolicyDocumentController.deletePolicyDocument(pdId);
        PolicyDocumentController.deletePolicyDocument(pdId);   // already gone — silent, not an error
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Policy_Document__c WHERE Id = :pdId]);
        Boolean engineDeleteCalled = false;
        for (String ep : EngineCalloutMock.requests) if (ep.contains('/policy/delete')) engineDeleteCalled = true;
        System.assert(engineDeleteCalled, 'the engine-side chunks are deleted first');
        System.assertEquals(1, [SELECT COUNT() FROM Audit_Log__c WHERE Related_Record_Id__c = :pdId AND Event_Type__c = 'Status_Changed']);

        String msg;
        try { PolicyDocumentController.deletePolicyDocument(null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
    }

    @IsTest
    static void delete_engineFailureDoesNotBlockTheSalesforceDelete() {
        Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
        Id pdId = ingestedDoc();
        EngineCalloutMock.statusCode = 503;
        Test.startTest();
        PolicyDocumentController.deletePolicyDocument(pdId);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Policy_Document__c WHERE Id = :pdId], 'the user\'s intent still succeeds');
    }
}
