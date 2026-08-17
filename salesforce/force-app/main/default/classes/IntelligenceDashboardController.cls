/**
 * IntelligenceDashboardController
 * ═══════════════════════════════════════════════════════════════════════════
 * Backs the new "Compliance Intelligence Dashboard" tab (Task 8) — one method
 * per widget, each querying real, already-existing data rather than adding
 * new fields. Mirrors the design confirmed in the published mockup
 * (https://claude.ai/code/artifact/2b2f46b1-83ab-4582-b7ad-79b9aeaab755), with
 * the "Compliance Risk Tolerance" hero widget dropped per explicit direction —
 * this dashboard is the 5 grid widgets plus a new compliance-break/expiry
 * alert widget, no separate Command Center screen.
 */
public with sharing class IntelligenceDashboardController {

    // ═════════════════════════════════════════════════════════════════════════
    // Widget 1 — Compliance Funnel: suppliers by onboarding stage.
    // ═════════════════════════════════════════════════════════════════════════
    public class FunnelStage {
        @AuraEnabled public String label;
        @AuraEnabled public Integer count;
    }

    @AuraEnabled(cacheable=true)
    public static List<FunnelStage> getComplianceFunnel() {
        Map<String, Integer> counts = new Map<String, Integer>{
            'Draft' => 0, 'Screening' => 0, 'In Review' => 0, 'Approved' => 0, 'Reviewed' => 0
        };
        for (AggregateResult ar : [
            SELECT Onboarding_Status__c st, COUNT(Id) c
            FROM   Account
            WHERE  RecordType.DeveloperName = 'Supplier'
            GROUP BY Onboarding_Status__c
        ]) {
            String status = (String) ar.get('st');
            if (counts.containsKey(status)) counts.put(status, (Integer) ar.get('c'));
        }
        List<FunnelStage> stages = new List<FunnelStage>();
        for (String label : new List<String>{ 'Draft', 'Screening', 'In Review', 'Approved', 'Reviewed' }) {
            FunnelStage s = new FunnelStage();
            s.label = label;
            s.count = counts.get(label);
            stages.add(s);
        }
        return stages;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Widget 2 — Score Distribution: Risk_Score__c histogram across all
    // suppliers with a computed score (Risk_Last_Computed__c populated).
    // ═════════════════════════════════════════════════════════════════════════
    public class ScoreBucket {
        @AuraEnabled public String rangeLabel;
        @AuraEnabled public Integer count;
        @AuraEnabled public String severity; // ok | warn | bad — for the bar color
    }

    @AuraEnabled(cacheable=true)
    public static List<ScoreBucket> getScoreDistribution() {
        // 10 buckets of width 10 (0-9, 10-19 ... 90-100).
        Integer[] bucketCounts = new Integer[10];
        for (Integer i = 0; i < 10; i++) bucketCounts[i] = 0;

        for (Account a : [
            SELECT Risk_Score__c
            FROM   Account
            WHERE  RecordType.DeveloperName = 'Supplier'
              AND  Risk_Score__c != null
        ]) {
            Integer idx = Integer.valueOf(Math.min(9, Math.floor(a.Risk_Score__c / 10)));
            bucketCounts[idx] = bucketCounts[idx] + 1;
        }

        List<ScoreBucket> buckets = new List<ScoreBucket>();
        for (Integer i = 0; i < 10; i++) {
            ScoreBucket b = new ScoreBucket();
            b.rangeLabel = (i * 10) + '-' + (i * 10 + 9);
            b.count = bucketCounts[i];
            b.severity = i >= 7 ? 'bad' : (i >= 5 ? 'warn' : 'ok');
            buckets.add(b);
        }
        return buckets;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Widget 3 — HITL Priority Queue: flagged findings waiting on a human,
    // oldest first. Mirrors VendorPortalController's flag definition
    // (Non-Compliant / At Risk — hyphenated/spaced, matching Status__c's
    // actual stored values), scoped to non-screening checklist rows.
    // ═════════════════════════════════════════════════════════════════════════
    public class HitlRow {
        @AuraEnabled public Id     assessmentId;
        @AuraEnabled public String supplierName;
        @AuraEnabled public Id     supplierId;
        @AuraEnabled public String requirementLabel;
        @AuraEnabled public String status;
        @AuraEnabled public String severity;
        @AuraEnabled public Decimal waitHours;
    }

    @AuraEnabled(cacheable=true)
    public static List<HitlRow> getHitlPriorityQueue() {
        List<HitlRow> rows = new List<HitlRow>();
        for (Compliance_Assessment__c a : [
            SELECT Id, Supplier__c, Supplier__r.Name, Requirement_Label__c,
                   Status__c, Severity__c, Evaluation_DateTime__c
            FROM   Compliance_Assessment__c
            WHERE  Status__c IN ('Non-Compliant', 'At Risk')
              AND  (NOT Requirement_Key__c LIKE 'SCREEN_%')
              AND  Evaluation_DateTime__c != null
            ORDER BY Evaluation_DateTime__c ASC
            LIMIT  25
        ]) {
            HitlRow r = new HitlRow();
            r.assessmentId     = a.Id;
            r.supplierId       = a.Supplier__c;
            r.supplierName     = a.Supplier__r.Name;
            r.requirementLabel = a.Requirement_Label__c;
            r.status           = a.Status__c;
            r.severity         = a.Severity__c;
            r.waitHours        = ((Decimal) (DateTime.now().getTime() - a.Evaluation_DateTime__c.getTime()))
                                    / (1000 * 60 * 60);
            rows.add(r);
        }
        return rows;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Widget 4 — Document Discrepancy Matrix: which clause requirements are
    // failing, and how many suppliers each one affects. Parsed from the
    // "Clause checks:" section DocAssessQueueable.buildDetail() writes into
    // Reason_Detail__c (same labeled-section format the LWCs already parse —
    // no new field needed, this reuses the existing structured-summary text).
    // ═════════════════════════════════════════════════════════════════════════
    public class DiscrepancyRow {
        @AuraEnabled public String  requirement;
        @AuraEnabled public Integer failingSupplierCount;
    }

    @AuraEnabled(cacheable=true)
    public static List<DiscrepancyRow> getDocumentDiscrepancyMatrix() {
        Map<String, Set<Id>> failingSuppliersByRequirement = new Map<String, Set<Id>>();

        for (Compliance_Assessment__c a : [
            SELECT Supplier__c, Reason_Detail__c
            FROM   Compliance_Assessment__c
            WHERE  Status__c = 'Non-Compliant'
              AND  (NOT Requirement_Key__c LIKE 'SCREEN_%')
            LIMIT  500
        ]) {
            if (String.isBlank(a.Reason_Detail__c)) continue;
            for (String line : a.Reason_Detail__c.split('\n')) {
                String trimmed = line.trim();
                if (trimmed.startsWithIgnoreCase('[FAIL]')) {
                    String requirement = trimmed.substring(6).trim();
                    if (String.isBlank(requirement)) continue;
                    if (!failingSuppliersByRequirement.containsKey(requirement)) {
                        failingSuppliersByRequirement.put(requirement, new Set<Id>());
                    }
                    failingSuppliersByRequirement.get(requirement).add(a.Supplier__c);
                }
            }
        }

        List<DiscrepancyRow> rows = new List<DiscrepancyRow>();
        for (String requirement : failingSuppliersByRequirement.keySet()) {
            DiscrepancyRow r = new DiscrepancyRow();
            r.requirement = requirement;
            r.failingSupplierCount = failingSuppliersByRequirement.get(requirement).size();
            rows.add(r);
        }
        rows.sort(new DiscrepancyComparator());
        return rows;
    }

    private class DiscrepancyComparator implements Comparator<DiscrepancyRow> {
        public Integer compare(DiscrepancyRow a, DiscrepancyRow b) {
            return b.failingSupplierCount - a.failingSupplierCount;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Widget 5 — Regulatory & Sanctions Feed: latest screening runs, real
    // Screening — Sanctions / Screening — Media rows (Compliance_Assessment__c
    // with Requirement_Key__c starting 'SCREEN_').
    // ═════════════════════════════════════════════════════════════════════════
    public class ScreeningFeedRow {
        @AuraEnabled public String  supplierName;
        @AuraEnabled public String  checkLabel;
        @AuraEnabled public String  status;
        @AuraEnabled public String  detail;
        @AuraEnabled public DateTime evaluatedDate;
    }

    @AuraEnabled(cacheable=true)
    public static List<ScreeningFeedRow> getRegulatorySanctionsFeed() {
        List<ScreeningFeedRow> rows = new List<ScreeningFeedRow>();
        for (Compliance_Assessment__c a : [
            SELECT Supplier__r.Name, Requirement_Label__c, Status__c,
                   Reason_Detail__c, Evaluation_DateTime__c
            FROM   Compliance_Assessment__c
            WHERE  Requirement_Key__c LIKE 'SCREEN_%'
              AND  Evaluation_DateTime__c != null
            ORDER BY Evaluation_DateTime__c DESC
            LIMIT  15
        ]) {
            ScreeningFeedRow r = new ScreeningFeedRow();
            r.supplierName  = a.Supplier__r.Name;
            r.checkLabel    = a.Requirement_Label__c;
            r.status        = a.Status__c;
            r.detail        = a.Reason_Detail__c;
            r.evaluatedDate = a.Evaluation_DateTime__c;
            rows.add(r);
        }
        return rows;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Widget 6 — Existing-supplier alerts: compliance breaks + expiring
    // documents on suppliers that are already Approved. This is the
    // dashboard-embedded version of the Task 7 alert concept — a supplier
    // list with a "View supplier" button that routes to the NATIVE Account
    // record page (no custom drilldown screen), per explicit direction.
    // ═════════════════════════════════════════════════════════════════════════
    public class AlertRow {
        @AuraEnabled public Id     accountId;
        @AuraEnabled public Id     assessmentId; // the flagged Compliance_Assessment__c — needed to trigger a
                                                   // specific renewal alert (ComplianceEmailController.sendRenewalAlert)
        @AuraEnabled public String supplierName;
        @AuraEnabled public String riskTier;
        @AuraEnabled public String reason;      // human-readable: what broke / what's expiring
        @AuraEnabled public String reasonType;  // 'break' | 'expiring' | 'expired' — drives the badge color
    }

    @AuraEnabled(cacheable=true)
    public static List<AlertRow> getSupplierAlerts() {
        Map<Id, AlertRow> alertsByAccount = new Map<Id, AlertRow>();

        Map<Id, String> approvedSupplierNames = new Map<Id, String>();
        Map<Id, String> approvedSupplierTiers = new Map<Id, String>();
        for (Account a : [
            SELECT Id, Name, Risk_Tier__c
            FROM   Account
            WHERE  RecordType.DeveloperName = 'Supplier'
              AND  Onboarding_Status__c IN ('Approved', 'Reviewed')
        ]) {
            approvedSupplierNames.put(a.Id, a.Name);
            approvedSupplierTiers.put(a.Id, a.Risk_Tier__c);
        }
        if (approvedSupplierNames.isEmpty()) return new List<AlertRow>();

        // Compliance breaks — a Non-Compliant/At Risk finding on a supplier
        // that's already past onboarding (Approved/Reviewed), not a
        // first-time rejection during initial review. Excludes rows
        // ComplianceExpiryBatch itself flagged (Reason_Code__c='Expired') —
        // those are a DIFFERENT alert type (below) and must not double-count
        // as a generic "break" just because the batch also sets Status__c=
        // At Risk to make them visible elsewhere (HITL queue).
        for (Compliance_Assessment__c a : [
            SELECT Id, Supplier__c, Requirement_Label__c, Status__c, Reason_Code__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c IN :approvedSupplierNames.keySet()
              AND  Status__c IN ('Non-Compliant', 'At Risk')
              AND  Reason_Code__c != 'Expired'
              AND  (NOT Requirement_Key__c LIKE 'SCREEN_%')
        ]) {
            if (alertsByAccount.containsKey(a.Supplier__c)) continue; // one alert row per supplier, first cause wins
            AlertRow r = new AlertRow();
            r.accountId    = a.Supplier__c;
            r.assessmentId = a.Id;
            r.supplierName = approvedSupplierNames.get(a.Supplier__c);
            r.riskTier     = approvedSupplierTiers.get(a.Supplier__c);
            r.reason       = 'New ' + (a.Status__c == 'Non-Compliant' ? 'Non-Compliant' : 'At Risk')
                              + ' finding — ' + a.Requirement_Label__c;
            r.reasonType   = 'break';
            alertsByAccount.put(a.Supplier__c, r);
        }

        // Expiring / expired documents — Valid_Until__c within 30 days or past.
        Date warnThreshold = Date.today().addDays(30);
        for (Compliance_Assessment__c a : [
            SELECT Id, Supplier__c, Requirement_Label__c, Valid_Until__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c IN :approvedSupplierNames.keySet()
              AND  Valid_Until__c != null
              AND  Valid_Until__c <= :warnThreshold
              AND  (NOT Requirement_Key__c LIKE 'SCREEN_%')
        ]) {
            if (alertsByAccount.containsKey(a.Supplier__c)) continue;
            Boolean expired = a.Valid_Until__c < Date.today();
            AlertRow r = new AlertRow();
            r.accountId    = a.Supplier__c;
            r.assessmentId = a.Id;
            r.supplierName = approvedSupplierNames.get(a.Supplier__c);
            r.riskTier     = approvedSupplierTiers.get(a.Supplier__c);
            r.reason       = a.Requirement_Label__c + (expired
                                ? ' — expired ' + a.Valid_Until__c.format()
                                : ' — expires ' + a.Valid_Until__c.format());
            r.reasonType   = expired ? 'expired' : 'expiring';
            alertsByAccount.put(a.Supplier__c, r);
        }

        List<AlertRow> rows = alertsByAccount.values();
        rows.sort(new AlertSeverityComparator());
        return rows;
    }

    // break/expired surface above expiring — matches the badge severity
    // ordering in the dashboard (red > amber).
    private class AlertSeverityComparator implements Comparator<AlertRow> {
        public Integer compare(AlertRow a, AlertRow b) {
            Map<String, Integer> rank = new Map<String, Integer>{ 'break' => 0, 'expired' => 1, 'expiring' => 2 };
            Integer ra = rank.containsKey(a.reasonType) ? rank.get(a.reasonType) : 3;
            Integer rb = rank.containsKey(b.reasonType) ? rank.get(b.reasonType) : 3;
            return ra - rb;
        }
    }
}