/**
 * IntelligenceDashboardControllerTest — every widget against a small seeded
 * portfolio: funnel, score histogram, HITL queue, discrepancy matrix,
 * screening feed and the existing-supplier alert list.
 */
@IsTest
private class IntelligenceDashboardControllerTest {

    @IsTest
    static void widgets_readTheSeededPortfolio() {
        Account draft    = TestDataFactory.supplier('Dash Draft', null, 'Draft');
        Account review   = TestDataFactory.supplier('Dash Review', null, 'In Review');
        Account approved = TestDataFactory.supplier('Dash Approved', null, 'Approved');
        Account reviewed = TestDataFactory.supplier('Dash Reviewed', null, 'Reviewed');
        approved.Risk_Score__c = 85; approved.Risk_Tier__c = 'Low';
        reviewed.Risk_Score__c = 22; reviewed.Risk_Tier__c = 'High';
        review.Risk_Score__c = 100;
        update new List<Account>{ approved, reviewed, review };

        // In Review: a flagged finding with a real "Concerns" section → HITL + discrepancy.
        Compliance_Assessment__c flagged = TestDataFactory.assessment(review.Id, 'COI', 'Certificate of Insurance', 'Non-Compliant', 'High');
        flagged.Reason_Detail__c = 'Coverage below the minimum.\nChecks passed:\n✓ Issuer identified\nConcerns:\n⚠ Coverage >= 1M — 500k';
        flagged.Evaluation_DateTime__c = DateTime.now().addHours(-5);
        update flagged;
        TestDataFactory.assessment(review.Id, 'ISO', 'ISO 9001', 'At Risk', 'Medium');
        Compliance_Assessment__c noConcern = TestDataFactory.assessment(review.Id, 'TAX', 'Tax Clearance', 'Non-Compliant', 'Medium');
        noConcern.Reason_Detail__c = 'Rejected by procurement'; update noConcern;
        TestDataFactory.screeningRow(review.Id, 'Sanctions', 'Compliant');

        // Approved: a break (not an expiry) + an expiring document — one alert row, break wins.
        TestDataFactory.assessment(approved.Id, 'COI', 'Certificate of Insurance', 'At Risk', 'High');
        Compliance_Assessment__c expiring = TestDataFactory.assessment(approved.Id, 'ISO', 'ISO 9001', 'Compliant', 'Low');
        expiring.Valid_Until__c = Date.today().addDays(10); update expiring;
        // Reviewed: only an expired document → 'expired' alert.
        Compliance_Assessment__c expired = TestDataFactory.assessment(reviewed.Id, 'COI', 'Certificate of Insurance', 'At Risk', 'High');
        expired.Reason_Code__c = 'Expired'; expired.Valid_Until__c = Date.today().addDays(-2); update expired;

        Test.startTest();
        List<IntelligenceDashboardController.FunnelStage> funnel = IntelligenceDashboardController.getComplianceFunnel();
        List<IntelligenceDashboardController.ScoreBucket> buckets = IntelligenceDashboardController.getScoreDistribution();
        List<IntelligenceDashboardController.HitlRow> hitl = IntelligenceDashboardController.getHitlPriorityQueue();
        List<IntelligenceDashboardController.DiscrepancyRow> gaps = IntelligenceDashboardController.getDocumentDiscrepancyMatrix();
        List<IntelligenceDashboardController.ScreeningFeedRow> feed = IntelligenceDashboardController.getRegulatorySanctionsFeed();
        List<IntelligenceDashboardController.AlertRow> alerts = IntelligenceDashboardController.getSupplierAlerts();
        Test.stopTest();

        Map<String, Integer> funnelCounts = new Map<String, Integer>();
        for (IntelligenceDashboardController.FunnelStage s : funnel) funnelCounts.put(s.label, s.count);
        System.assertEquals(5, funnel.size());
        System.assertEquals(1, funnelCounts.get('Draft'));
        System.assertEquals(1, funnelCounts.get('In Review'));
        System.assertEquals(1, funnelCounts.get('Approved'));
        System.assertEquals(1, funnelCounts.get('Reviewed'));

        System.assertEquals(10, buckets.size());
        System.assertEquals(1, buckets[8].count, '85 lands in 80-89');
        System.assertEquals(1, buckets[2].count, '22 lands in 20-29');
        System.assertEquals(1, buckets[9].count, '100 is capped into the top bucket');
        System.assertEquals('bad', buckets[2].severity);
        System.assertEquals('ok', buckets[8].severity);

        System.assert(hitl.size() >= 3, 'flagged + at-risk rows wait on a human, screening excluded');
        System.assertEquals(flagged.Id, hitl[0].assessmentId, 'oldest first');
        System.assert(hitl[0].waitHours >= 4);

        System.assertEquals(1, gaps.size(), 'only rows with a real Concerns line count');
        System.assertEquals('Certificate of Insurance', gaps[0].requirement);
        System.assertEquals(1, gaps[0].failingSupplierCount);

        System.assertEquals(1, feed.size());
        System.assertEquals('Screening — Sanctions', feed[0].checkLabel);

        System.assertEquals(2, alerts.size(), 'one row per onboarded supplier');
        System.assertEquals('break', alerts[0].reasonType);
        System.assertEquals(approved.Id, alerts[0].accountId);
        System.assertEquals('expired', alerts[1].reasonType);
        System.assertEquals(reviewed.Id, alerts[1].accountId);
        System.assert(alerts[1].reason.contains('expired'));
    }

    @IsTest
    static void alerts_emptyWhenNothingIsOnboarded() {
        TestDataFactory.supplier('Only Draft', null, 'Draft');
        System.assertEquals(0, IntelligenceDashboardController.getSupplierAlerts().size());
        System.assertEquals(0, IntelligenceDashboardController.getDocumentDiscrepancyMatrix().size());
    }
}
