@isTest
private class ScreeningPersistTest {

    // Mock the /verify callout so the test runs offline and deterministically.
    private class VerifyMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(JSON.serialize(new Map<String, Object>{
                'legalName' => 'Acme Test Components Ltd',
                'signal'    => 'review',
                'results'   => new List<Object>{
                    new Map<String, Object>{
                        'authority' => 'GLEIF', 'category' => 'Financials',
                        'status' => 'Verified', 'summary' => 'LEI ISSUED — active'
                    },
                    new Map<String, Object>{
                        'authority' => 'OpenSanctions', 'category' => 'Sanctions',
                        'status' => 'Flag', 'summary' => 'Possible denied-party match'
                    },
                    new Map<String, Object>{
                        'authority' => 'RMI', 'category' => 'Conflict Minerals',
                        'status' => 'NotConfigured', 'summary' => 'Smelter list has no public API'
                    }
                }
            }));
            return res;
        }
    }

    @isTest
    static void persistsScreeningAndFoldsIntoSummary() {
        Account a = new Account(Name = 'Acme Test Components Ltd', Industry = 'Automotive',
                                BillingCountry = 'Germany', Risk_Domains__c = 'finance, trade, conflict');
        insert a;

        Test.setMock(HttpCalloutMock.class, new VerifyMock());

        Test.startTest();
        VendorPortalController.ScreeningPersistResult r =
            VendorPortalController.runScreeningAndPersist(a.Id);
        Test.stopTest();

        // 1. Returns the three screening rows + a manual-verification summary row.
        System.assertEquals('review', r.signal, 'signal');
        System.assertEquals(4, r.results.size(), 'three results + manual-check summary');
        Map<String, String> verdictByLabel = new Map<String, String>();
        Boolean hasManualRow = false;
        for (VendorPortalController.ScreeningRowDTO row : r.results) {
            verdictByLabel.put(row.label.split(' · ')[0], row.status);
            if (row.label == 'Manual verification required') {
                hasManualRow = true;
                System.assert(row.detail.contains('Conflict Minerals'),
                    'manual note names the un-automatable authority');
            }
        }
        System.assertEquals('Compliant', verdictByLabel.get('Financials'), 'Verified -> Compliant');
        System.assertEquals('Non-Compliant', verdictByLabel.get('Sanctions'), 'Flag -> Non-Compliant');
        System.assertEquals('Needs Analyst', verdictByLabel.get('Conflict Minerals'), 'NotConfigured -> Needs Analyst');
        System.assert(hasManualRow, 'a manual-verification summary row is present');

        // 2. Persisted as assessment rows (3 screening + 1 manual summary).
        Integer persisted = [SELECT COUNT() FROM Compliance_Assessment__c
                             WHERE Supplier__c = :a.Id AND Requirement_Key__c LIKE 'SCREEN%'];
        System.assertEquals(4, persisted, 'screening + manual rows persisted');

        // 3. Folded into the supplier snapshot's AI summaries.
        VendorPortalController.SupplierSnapshot s = VendorPortalController.getSupplierSnapshot(a.Id);
        System.assert(s.assessedCount >= 4, 'snapshot AI summaries include screening + manual rows');
    }

    @isTest
    static void reScreenReplacesPriorRows() {
        Account a = new Account(Name = 'Acme Test Components Ltd', Industry = 'Automotive',
                                BillingCountry = 'Germany', Risk_Domains__c = 'finance');
        insert a;
        // Simulate a PRIOR screening run by pre-creating stale screening rows.
        // (A second live callout in the same transaction would hit the
        // callout-after-DML limit — in production each screening is its own
        // transaction; here we just prove the delete-then-insert replaces.)
        insert new List<Compliance_Assessment__c>{
            new Compliance_Assessment__c(Supplier__c = a.Id,
                Requirement_Key__c = 'SCREEN_STALE_ONE', Requirement_Label__c = 'Screening — Stale',
                Status__c = 'Needs Analyst'),
            new Compliance_Assessment__c(Supplier__c = a.Id,
                Requirement_Key__c = 'SCREEN_STALE_TWO', Requirement_Label__c = 'Screening — Stale 2',
                Status__c = 'Needs Analyst')
        };

        Test.setMock(HttpCalloutMock.class, new VerifyMock());
        Test.startTest();
        VendorPortalController.runScreeningAndPersist(a.Id);   // one live run replaces the stale rows
        Test.stopTest();

        // The 2 stale rows are gone, replaced by the fresh ones (3 results +
        // 1 manual-verification summary = 4) — no accumulation.
        Integer persisted = [SELECT COUNT() FROM Compliance_Assessment__c
                             WHERE Supplier__c = :a.Id AND Requirement_Key__c LIKE 'SCREEN%'];
        System.assertEquals(4, persisted, 'stale screening rows replaced, not accumulated');
    }
}