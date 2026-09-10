/**
 * VendorPortalIntakeTest — the Procurement intake side of VendorPortalController:
 * checklist preview (/scope), request/resend document emails, submit paths,
 * the supplier editor, the screening queue, routing, and the portal token.
 */
@IsTest
private class VendorPortalIntakeTest {

    private static List<String> twoDocs() {
        return new List<String>{ 'Certificate of Insurance', 'ISO 9001 Certificate' };
    }

    // ── generateChecklist ────────────────────────────────────────────────
    @IsTest
    static void generateChecklist_requiresEveryIntakeField() {
        Boolean threw = false;
        try {
            VendorPortalController.generateChecklist('', 'Germany', '', 'Direct', '', 'buyer', '', null, null);
        } catch (AuraHandledException e) { threw = true; }
        System.assert(threw, 'missing intake fields must be rejected before any callout');
    }

    @IsTest
    static void generateChecklist_previewsScopeResponse() {
        Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
        Test.startTest();
        VendorPortalController.ChecklistResult r = VendorPortalController.generateChecklist(
            'Acme Metals', 'Germany', 'Manufacturing', 'Direct', '$1,200,000', 'buyer@corp.com',
            'sales@acme.example', null, null);
        Test.stopTest();
        System.assertEquals('ai', r.source);
        System.assertEquals('Medium', r.riskTier);
        System.assertEquals('Medium', r.recommendedHitl);
        System.assertEquals(2, r.items.size());
        System.assert(r.domains.contains('finance') && r.domains.contains('quality'));
        System.assertEquals(2, r.riskReasons.size());
        System.assertEquals(false, r.noPolicyMatch);
    }

    @IsTest
    static void generateChecklist_surfacesEngineFailure() {
        EngineCalloutMock.statusCode = 500;
        Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
        String msg;
        try {
            VendorPortalController.generateChecklist('Acme', 'Germany', 'Manufacturing', 'Direct', '1', 'b', 's@a.com', null, null);
        } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the engine failure must surface as a handled error');
        System.assertEquals('Medium', VendorPortalController.recommendHitl('Medium'));
        System.assertEquals('Low', VendorPortalController.recommendHitl('Critical'));
    }

    // ── requestDocumentsFromSupplier ─────────────────────────────────────
    @IsTest
    static void requestDocuments_validatesInput() {
        String m1; String m2; String m3;
        try { VendorPortalController.requestDocumentsFromSupplier(null, '', 'DE', 'b', 'M', 'D', '1', 'f', 's@a.com', 'Medium', twoDocs(), null, null); }
        catch (AuraHandledException e) { m1 = e.getMessage(); }
        try { VendorPortalController.requestDocumentsFromSupplier(null, 'Acme', 'DE', 'b', 'M', 'D', '1', 'f', 'not-an-email', 'Medium', twoDocs(), null, null); }
        catch (AuraHandledException e) { m2 = e.getMessage(); }
        try { VendorPortalController.requestDocumentsFromSupplier(null, 'Acme', 'DE', 'b', 'M', 'D', '1', 'f', 's@a.com', 'Medium', new List<String>(), null, null); }
        catch (AuraHandledException e) { m3 = e.getMessage(); }
        System.assertNotEquals(null, m1, 'the guard must throw');
        System.assertNotEquals(null, m2, 'the guard must throw');
        System.assertNotEquals(null, m3, 'the guard must throw');
    }

    @IsTest
    static void requestDocuments_persistsCuratedChecklistAndEmails() {
        Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
        Test.startTest();
        String accId = VendorPortalController.requestDocumentsFromSupplier(
            null, 'Acme Request Co', 'Germany', 'buyer@corp.com', 'Manufacturing', 'Direct',
            '$1,200,000', 'finance, quality', 'sales@acme.example', 'Medium', twoDocs(), null, null);
        // Same name + email → dedups onto the same record instead of a second Account.
        String again = VendorPortalController.requestDocumentsFromSupplier(
            null, 'Acme Request Co', 'Germany', 'buyer@corp.com', 'Manufacturing', 'Direct',
            '$1,200,000', 'finance, quality', 'sales@acme.example', 'Medium', twoDocs(), null, null);
        Test.stopTest();

        System.assertEquals(accId, again, 'a re-request must reuse the existing supplier');
        Account a = [SELECT Name, Onboarding_Status__c, Checklist_Seeded_By_Caller__c, Annual_Spend_Est__c,
                            Checklist_Item_Count__c, Supplier_Portal_Token__c, Supplier_Contact_Email__c
                     FROM Account WHERE Id = :accId];
        System.assertEquals('Acme Request Co', a.Name);
        System.assertEquals(true, a.Checklist_Seeded_By_Caller__c);
        System.assertEquals(1200000, a.Annual_Spend_Est__c);
        System.assertEquals(2, a.Checklist_Item_Count__c);
        System.assertNotEquals(null, a.Supplier_Portal_Token__c, 'the request email mints the portal token');
        System.assertEquals(2, [SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :accId
                                AND Requirement_Key__c LIKE '%__SCOPE_%'],
            'the curated list is persisted verbatim (idempotent on re-request)');
        System.assertEquals(1, [SELECT COUNT() FROM Supplier_Profile__c WHERE Account__c = :accId]);
        System.assert([SELECT COUNT() FROM Audit_Log__c WHERE Related_Record_Id__c = :accId
                       AND Event_Type__c = 'Status_Changed'] >= 2, 'each request is audited');
    }

    @IsTest
    static void resendDocumentRequestEmail_readsPersistedChecklist() {
        Account a = TestDataFactory.supplier('Resend Co');
        TestDataFactory.assessment(a.Id, 'COI', 'Certificate of Insurance', 'Pending', 'Medium');
        TestDataFactory.assessment(a.Id, 'MAN', 'Manual verification required', 'Pending', 'Low');
        TestDataFactory.screeningRow(a.Id, 'Sanctions', 'Compliant');

        Test.startTest();
        VendorPortalController.resendDocumentRequestEmail(a.Id);
        Test.stopTest();

        Audit_Log__c log = [SELECT New_Value__c FROM Audit_Log__c WHERE Related_Record_Id__c = :a.Id
                            AND Event_Type__c = 'Status_Changed' ORDER BY CreatedDate DESC LIMIT 1];
        System.assert(log.New_Value__c.contains('Requested 1 document'),
            'screening and manual-verification rows are excluded from the request: ' + log.New_Value__c);

        Account noEmail = TestDataFactory.supplier('No Email Co');
        noEmail.Supplier_Contact_Email__c = null; update noEmail;
        String msg;
        try { VendorPortalController.resendDocumentRequestEmail(noEmail.Id); }
        catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');

        Account noDocs = TestDataFactory.supplier('No Docs Co');
        msg = null;
        try { VendorPortalController.resendDocumentRequestEmail(noDocs.Id); }
        catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');
        msg = null;
        try { VendorPortalController.resendDocumentRequestEmail(null); }
        catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
    }

    // ── submit paths ─────────────────────────────────────────────────────
    @IsTest
    static void submitAndScreen_persistsChecklistAndRunsScreening() {
        Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
        Test.startTest();
        String accId = VendorPortalController.submitAndScreen(
            'Screen Me Ltd', 'Germany', 'buyer', 'Manufacturing', 'Direct', '500000',
            'finance', 'ops@screenme.example', 'Low', twoDocs(), null, null);
        String again = VendorPortalController.submitAndScreen(
            'Screen Me Ltd', 'Germany', 'buyer', 'Manufacturing', 'Direct', '500000',
            'finance', 'ops@screenme.example', 'Low', twoDocs(), null, null);
        Test.stopTest();

        System.assertEquals(accId, again, 'double-submit must update, not duplicate');
        Account a = [SELECT Onboarding_Status__c, HITL_Threshold__c, Checklist_Seeded_By_Caller__c FROM Account WHERE Id = :accId];
        System.assertEquals('Low', a.HITL_Threshold__c);
        System.assertEquals(true, a.Checklist_Seeded_By_Caller__c);
        // ScreeningQueueable ran at stopTest: 3 results + the manual-verification row.
        System.assertEquals(4, [SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :accId AND Requirement_Key__c LIKE 'SCREEN%']);
        System.assertEquals(2, [SELECT COUNT() FROM Compliance_Assessment__c WHERE Supplier__c = :accId AND Requirement_Key__c LIKE '%__SCOPE_%']);

        String msg;
        try { VendorPortalController.submitAndScreen('', 'DE', 'b', 'M', 'D', '1', 'f', 'e@x.com', 'Low', twoDocs(), null, null); }
        catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');
    }

    @IsTest
    static void saveDraftThenSubmitForReview_upsertsSameRecord() {
        Test.setMock(HttpCalloutMock.class, new EngineCalloutMock());
        Test.startTest();
        String id1 = VendorPortalController.saveDraft(null, 'Draft Co', 'Germany', 'buyer', 'Manufacturing',
            'Direct', '100', 'finance', 'd@draft.example', 'Medium');
        String id2 = VendorPortalController.submitForReview(id1, 'Draft Co', 'Germany', 'buyer', 'Manufacturing',
            'Direct', 'abc', 'finance', 'd@draft.example', 'Medium');
        Test.stopTest();
        System.assertEquals(id1, id2);
        Account a = [SELECT Onboarding_Status__c, Annual_Spend_Est__c FROM Account WHERE Id = :id1];
        System.assertEquals('In Review', a.Onboarding_Status__c);
        System.assertEquals(100, a.Annual_Spend_Est__c, 'an unparseable spend on update leaves the prior value');
        String msg;
        try { VendorPortalController.saveDraft(null, '  ', 'DE', 'b', 'M', 'D', '1', 'f', 'e', 'Low'); }
        catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
    }

    // ── supplier editor ──────────────────────────────────────────────────
    @IsTest
    static void supplierEditor_roundTripsWithoutBlankingHiddenFields() {
        Account a = TestDataFactory.supplier('Edit Me GmbH');
        a.Requested_By__c = 'original-buyer'; a.HITL_Threshold__c = 'High'; update a;

        VendorPortalController.SupplierEditDetails d = VendorPortalController.getSupplierEditDetails(a.Id);
        System.assertEquals('Edit Me GmbH', d.supplierName);
        System.assertEquals('', d.annualSpend);

        VendorPortalController.updateSupplierDetails(a.Id, 'Edited GmbH', 'France', 'Manufacturing',
            'Direct', '2,500.50', 'new@edited.example', null, null);
        Account after = [SELECT Name, BillingCountry, Annual_Spend_Est__c, Supplier_Contact_Email__c,
                                Requested_By__c, HITL_Threshold__c, Onboarding_Status__c
                         FROM Account WHERE Id = :a.Id];
        System.assertEquals('Edited GmbH', after.Name);
        System.assertEquals('France', after.BillingCountry);
        System.assertEquals(2500.50, after.Annual_Spend_Est__c);
        System.assertEquals('original-buyer', after.Requested_By__c, 'fields the editor does not expose are preserved');
        System.assertEquals('High', after.HITL_Threshold__c);
        System.assertEquals('Draft', after.Onboarding_Status__c);

        String msg;
        try { VendorPortalController.getSupplierEditDetails(null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
        msg = null;
        try { VendorPortalController.updateSupplierDetails(null, 'x', null, null, null, null, null, null, null); }
        catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
    }

    @IsTest
    static void resolveMaterialDomains_readsCatalog() {
        System.assertEquals(0, VendorPortalController.resolveMaterialDomains(null, '').size());
        List<Material_Type__mdt> cat = [SELECT Value_Key__c, Domains__c FROM Material_Type__mdt WHERE Active__c = true AND Domains__c != null LIMIT 1];
        if (cat.isEmpty()) return;
        List<String> domains = VendorPortalController.resolveMaterialDomains(cat[0].Value_Key__c, null);
        System.assert(!domains.isEmpty(), 'an active catalog entry resolves to its domains');
        System.assert(cat[0].Domains__c.contains(domains[0]));
    }

    // ── screening queue + routing ────────────────────────────────────────
    @IsTest
    static void screeningQueue_bucketsAndKpis() {
        Account draft    = TestDataFactory.supplier('Queue Draft', null, 'Draft');
        Account review   = TestDataFactory.supplier('Queue Review', null, 'In Review');
        Account approved = TestDataFactory.supplier('Queue Approved', null, 'Approved');
        Account closed   = TestDataFactory.supplier('Queue Closed', null, 'Approved');
        closed.Compliance_Case_Status__c = 'Closed - Compliant'; update closed;
        review.Risk_Tier__c = 'High'; review.HITL_Threshold__c = 'Medium'; update review;
        TestDataFactory.assessment(review.Id, 'COI', 'Certificate of Insurance', 'Non-Compliant', 'High');
        TestDataFactory.assessment(review.Id, 'ISO', 'ISO 9001', 'Pending', 'Medium');
        approved.Risk_Tier__c = 'Low'; update approved;

        VendorPortalController.ScreeningQueue q = VendorPortalController.getScreeningQueue();
        System.assertEquals(3, q.total, 'closed cases leave the queue');
        System.assertEquals(1, q.prospective);
        System.assertEquals(1, q.approved);
        System.assert(q.needsReview >= 1);
        System.assertEquals(1, q.autoCleared);
        System.assertNotEquals(null, q.avgTimeToOnboardDays);
        Map<Id, VendorPortalController.SupplierRow> byId = new Map<Id, VendorPortalController.SupplierRow>();
        for (VendorPortalController.SupplierRow r : q.rows) byId.put(r.id, r);
        System.assertEquals('Draft', byId.get(draft.Id).stageLabel);
        System.assertEquals('Flagged - Needs Review', byId.get(review.Id).stageLabel);
        System.assertEquals('Needs analyst', byId.get(review.Id).routing);
        System.assertEquals(1, byId.get(review.Id).flags);
        System.assertEquals(2, byId.get(review.Id).docsTotal);
        System.assertEquals(0, byId.get(review.Id).docsUploaded);
        System.assertEquals('Onboarded', byId.get(approved.Id).aiStatus);

        System.assertEquals('Needs analyst', VendorPortalController.routeDecision('Critical', 'High'));
        System.assertEquals('Auto-approve', VendorPortalController.routeDecision('Low', null));
        System.assertEquals('Pending', VendorPortalController.routeDecision('', 'Low'));
    }

    // ── portal token ─────────────────────────────────────────────────────
    @IsTest
    static void portalToken_mintedOnceAndVerified() {
        Account a = TestDataFactory.supplier('Token Co');
        String url1 = VendorPortalController.generateSupplierPortalUrl(a.Id);
        String url2 = VendorPortalController.generateSupplierPortalUrl(a.Id);
        System.assertEquals(url1, url2, 'the token is durable — same link on every send');
        System.assert(url1.contains('?token='));
        String token = [SELECT Supplier_Portal_Token__c FROM Account WHERE Id = :a.Id].Supplier_Portal_Token__c;
        System.assert(url1.endsWith(token));
        System.assertEquals(String.valueOf(a.Id), VendorPortalController.resolveSupplierToken(' ' + token + ' '));
        System.assertEquals(a.Id, VendorPortalController.verifyPortalTokenId(token));

        String msg;
        try { VendorPortalController.verifyPortalTokenId('no-such-token'); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');
        msg = null;
        try { VendorPortalController.verifyPortalTokenId(' '); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg, 'the guard must throw');
        msg = null;
        try { VendorPortalController.generateSupplierPortalUrl(null); } catch (AuraHandledException e) { msg = e.getMessage(); }
        System.assertNotEquals(null, msg);
    }
}
