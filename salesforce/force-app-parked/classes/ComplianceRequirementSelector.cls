/**
 * ComplianceRequirementSelector
 *
 * Single place for all Compliance_Requirement__mdt queries.
 * Uses a transaction-scoped static cache — CMT records are loaded once
 * per transaction regardless of how many times methods are called.
 *
 * CMT queries do NOT count toward SOQL governor limits,
 * but we still cache to avoid redundant deserialisation overhead.
 */
public with sharing class ComplianceRequirementSelector {

    // Transaction-scope caches
    private static List<Compliance_Requirement__mdt> allActiveCache;
    private static Map<String, Compliance_Requirement__mdt> devNameMapCache;

    // ─── getAllActive ──────────────────────────────────────────────────────────
    /**
     * Returns all active Compliance_Requirement__mdt records
     * (Effective_To__c is null or in the future; Effective_From__c is null or in the past).
     * Result is cached for the transaction lifetime.
     */
    public static List<Compliance_Requirement__mdt> getAllActive() {
        if (allActiveCache == null) {
            Date today = Date.today();
            List<Compliance_Requirement__mdt> all = [
                SELECT  DeveloperName,
                        Label,
                        Rule_ID__c,
                        Document_Type__c,
                        Governing_Body__c,
                        Human_Review_Required__c,
                        Penalty__c,
                        Regulation_Standard__c,
                        Vendor_Type__c,
                        Is_Mandatory__c,
                        Renewal_Frequency_Days__c,
                        Required_For_Industry__c,
                        Required_For_Tier__c,
                        Required_For_Criticality__c,
                        Required_For_Region__c,
                        Required_For_Direct_Indirect__c,
                        Severity_on_Failure__c,
                        Effective_From__c,
                        Effective_To__c,
                        Source_Regulation__c
                FROM    Compliance_Requirement__mdt
                ORDER BY Label ASC
            ];
            // CMT SOQL does not support OR (disjunctions), so filter dates in Apex
            allActiveCache = new List<Compliance_Requirement__mdt>();
            for (Compliance_Requirement__mdt r : all) {
                Boolean notExpired    = r.Effective_To__c   == null || r.Effective_To__c   >= today;
                Boolean alreadyActive = r.Effective_From__c == null || r.Effective_From__c <= today;
                if (notExpired && alreadyActive) {
                    allActiveCache.add(r);
                }
            }
        }
        return allActiveCache;
    }

    // ─── getMapByDeveloperName ─────────────────────────────────────────────────
    /**
     * Returns a Map<DeveloperName, CMT record> for fast lookup by key.
     * Used by DocumentProcessingController.getChecklistJSON() to join
     * CMT data onto Compliance_Assessment__c records.
     */
    public static Map<String, Compliance_Requirement__mdt> getMapByDeveloperName() {
        if (devNameMapCache == null) {
            devNameMapCache = new Map<String, Compliance_Requirement__mdt>();
            for (Compliance_Requirement__mdt r : getAllActive()) {
                devNameMapCache.put(r.DeveloperName, r);
            }
        }
        return devNameMapCache;
    }

    // ─── getByRuleId ──────────────────────────────────────────────────────────
    /**
     * Convenience: look up a single rule by its Rule_ID__c value (e.g. "RULE-U-001").
     */
    public static Compliance_Requirement__mdt getByRuleId(String ruleId) {
        for (Compliance_Requirement__mdt r : getAllActive()) {
            if (r.Rule_ID__c == ruleId) return r;
        }
        return null;
    }

    // ─── clearCache (for tests only) ─────────────────────────────────────────
    @TestVisible
    private static void clearCache() {
        allActiveCache  = null;
        devNameMapCache = null;
    }
}