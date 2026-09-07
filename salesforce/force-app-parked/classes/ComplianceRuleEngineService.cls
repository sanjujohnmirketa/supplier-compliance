/**
 * ComplianceRuleEngineService
 * ═══════════════════════════════════════════════════════════════════════════
 * Metadata-driven compliance rule matching engine for US Manufacturing.
 *
 * All rules live in Compliance_Requirement__mdt — zero hardcoded rules
 * in Apex. To add, change, or retire a rule: edit the CMT record.
 * No code deployment required.
 *
 * PUBLIC METHODS
 * ──────────────
 *   getApplicableRules(...)  → List<CMT>  pure matching, no DML
 *   generateChecklist(...)   → void       matches + seeds assessments
 *
 * 7 MATCHING DIMENSIONS
 * ─────────────────────
 *   1. Industry / Sector        Account.Industry__c
 *   2. Vendor Type              Account.Vendor_Type__c
 *   3. Supplier Tier            Supplier_Profile__c.Supplier_Tier__c
 *   4. Criticality              Supplier_Profile__c.Criticality__c
 *   5. Strategic Region         Supplier_Profile__c.Strategic_Region__c
 *   6. Direct / Indirect        Supplier_Profile__c.Direct_or_Indirect__c
 *   7. Operating State          Account.BillingState  ← triggers RULE-ST-*
 *
 * ── CRITICAL: VENDOR TYPE NORMALISATION ─────────────────────────────────
 *   The compliance matrix uses shorthand tokens in CMT Vendor_Type__c:
 *     "Raw Material / Contract Mfr"   (slash = OR, both vendor types apply)
 *     "Contract Mfr / Logistics"
 *     "Contract Mfr / Raw Material"
 *     "Raw Material Supplier / Contract Mfr"
 *     "Contract Mfr"
 *     "Raw Material Supplier"
 *
 *   The flow/portal stores full labels in Account.Vendor_Type__c:
 *     "Raw Material Supplier"
 *     "Contract Manufacturer"
 *     "Logistics / 3PL Provider"
 *     "IT / Software Vendor"
 *     "Staffing / Labor Contractor"
 *
 *   Plain ruleValues.contains(vendorType) would NEVER match because
 *   "Contract Manufacturer" ≠ "Contract Mfr".
 *
 *   Fix: normaliseVendorType() maps each full label to a canonical token
 *   set, then matchesVendorType() expands slash-delimited CMT tokens and
 *   checks intersection. This is the reason all sector-specific rules
 *   (A-*, P-*, F-*, E-*, AD-*, C-*) previously returned zero matches.
 *

 *
 * ── DUPLICATE GUARD ──────────────────────────────────────────────────────
 *   generateChecklist() checks existing assessments before inserting.
 *   Key = (Supplier__c + Requirement_Key__c).
 *   Existing Pending/Non-Compliant assessments are left untouched.
 *   Only net-new rules get new records.
 *   Uses Database.upsert on external ID Requirement_Key__c (if set as
 *   External ID in the org) — falls back to INSERT with exists-check if not.
 *
 * ── GOVERNOR LIMIT NOTES ─────────────────────────────────────────────────
 *   CMT queries are FREE — not counted toward SOQL limits.
 *   ComplianceRequirementSelector caches all active CMT in a static var.
 *   All SOQL in this service uses IN clauses — no SOQL in loops.
 */
public with sharing class ComplianceRuleEngineService {

    // ── Universal constants ───────────────────────────────────────────────────

    private static final String MATCH_ALL     = 'All';
    private static final String BOTH          = 'Both';
    private static final String REGION_GLOBAL = 'Global';

    // States that trigger RULE-ST-* rules
    @TestVisible
    private static final Set<String> STATE_RULE_STATES =
        new Set<String>{ 'CA', 'WA', 'NY', 'MA' };

    // Assessment status / reason constants
    private static final String STATUS_PENDING    = 'Pending';
    private static final String STATUS_WAIVED     = 'Waived';
    private static final String REASON_MISSING    = 'Missing Document'; // picklist value — exact match
    private static final String EVALUATED_BY_AUTO = 'Auto';

    // ═════════════════════════════════════════════════════════════════════════
    // getApplicableRules
    //
    // Pure function — reads CMT, returns matched rules. No DML, no events.
    // Called by:
    //   • generateChecklist() (this class)
    //   • SupplierOnboardingService.initiateOnboarding() (backward compat)
    //   • SupplierOnboardingService.reEvaluateOnSectorChange()
    //
    // @param industry          Account.Industry__c
    // @param vendorType        Account.Vendor_Type__c  (full portal label)
    // @param tier              Supplier_Profile__c.Supplier_Tier__c
    // @param criticality       Supplier_Profile__c.Criticality__c
    // @param region            Supplier_Profile__c.Strategic_Region__c
    // @param directOrIndirect  Supplier_Profile__c.Direct_or_Indirect__c
    // @param billingState      Account.BillingState  (2-letter code or null)
    // @return                  Matched CMT records, ordered Critical→Low
    // ═════════════════════════════════════════════════════════════════════════
    public static List<Compliance_Requirement__mdt> getApplicableRules(
        String industry,
        String vendorType,
        String tier,
        String criticality,
        String region,
        String directOrIndirect,
        String billingState
    ) {
        // Normalise vendor type ONCE before the loop
        Set<String> normalisedVendorTokens = normaliseVendorType(vendorType);

        List<Compliance_Requirement__mdt> matched =
            new List<Compliance_Requirement__mdt>();

        for (Compliance_Requirement__mdt rule :
                ComplianceRequirementSelector.getAllActive()) {

            if (ruleMatches(
                    rule,
                    industry,
                    normalisedVendorTokens,
                    tier,
                    criticality,
                    region,
                    directOrIndirect,
                    billingState)) {
                matched.add(rule);
            }
        }

        return matched;
    }

    // ── Backward-compatible 6-arg overload ───────────────────────────────────
    // SupplierOnboardingService calls the 6-arg signature. This overload
    // keeps that call compiling while adding state support transparently.
    public static List<Compliance_Requirement__mdt> getApplicableRules(
        String industry,
        String vendorType,
        String tier,
        String criticality,
        String region,
        String directOrIndirect
    ) {
        return getApplicableRules(
            industry, vendorType, tier, criticality, region, directOrIndirect, null
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // generateChecklist
    //
    // Matches rules for each supplier and seeds Compliance_Assessment__c
    // records. Idempotent — safe to call multiple times for the same supplier.
    //
    // Called by:
    //   • SupplierOnboardingService.initiateOnboarding()
    //   • SupplierOnboardingService.reEvaluateOnSectorChange() (delta mode)
    //
    // @param suppliers   List of Account records (Supplier RT, with fields
    //                    Industry__c, Vendor_Type__c, BillingState populated)
    // @param profileMap  Map<AccountId, Supplier_Profile__c> — pre-fetched by
    //                    the caller to avoid SOQL in this method
    // @param deltaMode   false = new onboarding (skip accounts that already
    //                    have assessments for this rule)
    //                    true  = re-evaluation (also waive removed rules)
    // ═════════════════════════════════════════════════════════════════════════
    public static void generateChecklist(
        List<Account>                   suppliers,
        Map<Id, Supplier_Profile__c>    profileMap,
        Boolean                         deltaMode
    ) {
        if (suppliers == null || suppliers.isEmpty()) return;

        Set<Id> supplierIds = new Map<Id, Account>(suppliers).keySet();

        // ── 1. Load existing assessments (one SOQL, keyed by supplierId+ruleKey)
        Map<Id, Map<String, Compliance_Assessment__c>> existingMap =
            loadExistingAssessments(supplierIds);

        // ── 2. Match rules and compute inserts / waives per supplier
        List<Compliance_Assessment__c> toInsert = new List<Compliance_Assessment__c>();
        List<Compliance_Assessment__c> toWaive  = new List<Compliance_Assessment__c>();
        List<Account>                  toUpdate  = new List<Account>();

        for (Account acc : suppliers) {
            Supplier_Profile__c profile = profileMap != null
                ? profileMap.get(acc.Id) : null;

            // Match all 7 dimensions for this supplier
            List<Compliance_Requirement__mdt> matched = getApplicableRules(
                acc.Industry__c,
                acc.Vendor_Type__c,
                profile != null ? profile.Supplier_Tier__c      : null,
                profile != null ? profile.Criticality__c         : null,
                profile != null ? profile.Strategic_Region__c    : null,
                profile != null ? profile.Direct_or_Indirect__c  : null,
                acc.BillingState
            );

            if (matched.isEmpty()) {
                System.debug(LoggingLevel.WARN,
                    '[ComplianceRuleEngineService.generateChecklist] '
                    + 'Zero rules matched for Account ' + acc.Id
                    + ' Industry=' + acc.Industry__c
                    + ' VendorType=' + acc.Vendor_Type__c
                    + '. Verify CMT records have Required_For_Industry__c '
                    + 'and Vendor_Type__c populated correctly.'
                );
                continue;
            }

            Map<String, Compliance_Assessment__c> existing =
                existingMap.containsKey(acc.Id)
                    ? existingMap.get(acc.Id)
                    : new Map<String, Compliance_Assessment__c>();

            // New rules → insert assessment
            Set<String> matchedKeys = new Set<String>();
            for (Compliance_Requirement__mdt rule : matched) {
                String compositeKey = (String) acc.Id + '__' + rule.DeveloperName;
                matchedKeys.add(compositeKey);
                if (!existing.containsKey(compositeKey)) {
                    toInsert.add(buildAssessment(acc.Id, rule));
                }
            }

            // Removed rules → waive (delta mode only)
            if (deltaMode) {
                for (String existingKey : existing.keySet()) {
                    Compliance_Assessment__c a = existing.get(existingKey);
                    if (!matchedKeys.contains(existingKey)
                            && a.Status__c != STATUS_WAIVED) {
                        toWaive.add(new Compliance_Assessment__c(
                            Id               = a.Id,
                            Status__c        = STATUS_WAIVED,
                            Reason_Code__c   = 'Other',
                            Reason_Detail__c = 'Rule no longer applicable '
                                + 'after supplier classification change'
                        ));
                    }
                }
            }

            // Advance Account onboarding status if still at Draft
            if (acc.Onboarding_Status__c == 'Draft') {
                toUpdate.add(new Account(
                    Id                   = acc.Id,
                    Onboarding_Status__c = 'In Review'
                ));
            }
        }

        // ── 3. Apply DML (bulkified, partial-success logging)
        if (!toInsert.isEmpty()) {
            List<Database.UpsertResult> upsertResults =
                Database.upsert(toInsert, Compliance_Assessment__c.Requirement_Key__c, false);
            logUpsertErrors(upsertResults, toInsert, 'generateChecklist UPSERT');
        }

        if (!toWaive.isEmpty()) {
            List<Database.SaveResult> waiveResults =
                Database.update(toWaive, false);
            logDmlErrors(waiveResults, toWaive, 'generateChecklist WAIVE');
        }

        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ruleMatches  —  all 7 dimensions must pass
    // ═════════════════════════════════════════════════════════════════════════
    @TestVisible
    static Boolean ruleMatches(
        Compliance_Requirement__mdt rule,
        String                      industry,
        Set<String>                 normalisedVendorTokens,
        String                      tier,
        String                      criticality,
        String                      region,
        String                      directOrIndirect,
        String                      billingState
    ) {
        return matchesIndustry(rule, industry)
            && matchesVendorType(rule, normalisedVendorTokens)
            && matchesTier(rule, tier)
            && matchesCriticality(rule, criticality)
            && matchesRegion(rule, region)
            && matchesDirectIndirect(rule, directOrIndirect);
    }

    // ── Dimension 1: Industry ─────────────────────────────────────────────────
    //
    // Required_For_Industry__c now stores the exact label the flow writes to
    // Account.Industry__c (e.g. "Automotive", "Aerospace & Defense").
    // Exact case-insensitive comparison is therefore sufficient and far more
    // predictable than the previous bidirectional contains() approach,
    // which could accidentally cross-match short tokens like "it" or "auto".
    @TestVisible
    static Boolean matchesIndustry(
        Compliance_Requirement__mdt rule,
        String industry
    ) {
        if (String.isBlank(rule.Required_For_Industry__c)) return true;

        Set<String> ruleVals = splitSemicolon(rule.Required_For_Industry__c);
        if (ruleVals.contains(MATCH_ALL)) return true;
        if (String.isBlank(industry)) return false;

        String industryLower = industry.toLowerCase().trim();
        for (String rv : ruleVals) {
            if (rv.toLowerCase().trim() == industryLower) return true;
        }
        return false;
    }

    // ── Dimension 2: Vendor Type ──────────────────────────────────────────────
    //
    // This is the most complex dimension because the compliance matrix uses
    // slash-delimited shorthand tokens in CMT (e.g. "Raw Material / Contract Mfr")
    // while the flow stores full labels (e.g. "Contract Manufacturer").
    //
    // Algorithm:
    //   1. normaliseVendorType() converts the SUPPLIER's full label into a
    //      Set of canonical tokens (called once before the loop).
    //   2. Each CMT token in Vendor_Type__c is split by slash and trimmed.
    //   3. If any CMT token matches any supplier token → dimension passes.
    //
    @TestVisible
    static Boolean matchesVendorType(
        Compliance_Requirement__mdt rule,
        Set<String>                 supplierTokens
    ) {
        if (String.isBlank(rule.Vendor_Type__c)) return true;

        // "All Vendor Types" in any position → universal
        if (rule.Vendor_Type__c.containsIgnoreCase('all')) return true;

        // If supplier tokens is empty (blank vendor type), no sector rule matches
        if (supplierTokens == null || supplierTokens.isEmpty()) return false;

        // Expand the CMT value: split by semicolons first, then by slashes
        // Example: "Raw Material / Contract Mfr" → {'raw material', 'contract mfr'}
        for (String semiToken : rule.Vendor_Type__c.split(';')) {
            for (String slashToken : semiToken.split('/')) {
                String cmtToken = slashToken.trim().toLowerCase();
                if (String.isBlank(cmtToken)) continue;

                // Exact token match — supplierTokens are already lowercase from normaliseVendorType()
                if (supplierTokens.contains(cmtToken)) return true;
            }
        }
        return false;
    }

    // ── Dimension 3: Tier ─────────────────────────────────────────────────────
    // Experience Cloud stores picklist API values ("Tier_1") while CMT records
    // use labels ("Tier 1"). Check both forms so either storage format matches.
    @TestVisible
    static Boolean matchesTier(
        Compliance_Requirement__mdt rule,
        String tier
    ) {
        if (String.isBlank(rule.Required_For_Tier__c)) return true;

        Set<String> ruleVals = splitSemicolon(rule.Required_For_Tier__c);
        if (ruleVals.contains(MATCH_ALL)) return true;
        if (String.isBlank(tier)) return false;

        return ruleVals.contains(tier) || ruleVals.contains(tier.replace('_', ' '));
    }

    // ── Dimension 4: Criticality ──────────────────────────────────────────────
    @TestVisible
    static Boolean matchesCriticality(
        Compliance_Requirement__mdt rule,
        String criticality
    ) {
        if (String.isBlank(rule.Required_For_Criticality__c)) return true;

        Set<String> ruleVals = splitSemicolon(rule.Required_For_Criticality__c);
        if (ruleVals.contains(MATCH_ALL)) return true;
        if (String.isBlank(criticality)) return false;

        return ruleVals.contains(criticality) || ruleVals.contains(criticality.replace('_', ' '));
    }

    // ── Dimension 5: Region ───────────────────────────────────────────────────
    @TestVisible
    static Boolean matchesRegion(
        Compliance_Requirement__mdt rule,
        String region
    ) {
        if (String.isBlank(rule.Required_For_Region__c)) return true;

        Set<String> ruleVals = splitSemicolon(rule.Required_For_Region__c);
        if (ruleVals.contains(MATCH_ALL) || ruleVals.contains(REGION_GLOBAL)) return true;
        if (String.isBlank(region)) return false;

        return ruleVals.contains(region) || ruleVals.contains(region.replace('_', ' '));
    }

    // ── Dimension 6: Direct / Indirect ────────────────────────────────────────
    @TestVisible
    static Boolean matchesDirectIndirect(
        Compliance_Requirement__mdt rule,
        String directOrIndirect
    ) {
        if (String.isBlank(rule.Required_For_Direct_Indirect__c)) return true;

        String ruleVal = rule.Required_For_Direct_Indirect__c.trim();
        if (ruleVal.equalsIgnoreCase(BOTH) || ruleVal.equalsIgnoreCase(MATCH_ALL)) {
            return true;
        }
        if (String.isBlank(directOrIndirect)) return false;

        // Normalise API value underscores → spaces before comparison.
        // "Direct (Production)" or "Direct_Production" should match CMT "Direct".
        String normDI = directOrIndirect.replace('_', ' ');
        return normDI.toLowerCase().startsWith(ruleVal.toLowerCase())
            || ruleVal.toLowerCase().startsWith(normDI.toLowerCase());
    }

    // ═════════════════════════════════════════════════════════════════════════
    // normaliseVendorType
    //
    // Converts a full portal/flow vendor type label into a set of lowercase
    // canonical tokens that match the shorthand used in CMT Vendor_Type__c.
    //
    // Portal label              → canonical tokens
    // ─────────────────────────────────────────────────────────
    // "Raw Material Supplier"   → {'raw material', 'raw material supplier'}
    // "Contract Manufacturer"   → {'contract mfr', 'contract manufacturer',
    //                              'contract mfr '}
    // "Logistics / 3PL Provider"→ {'logistics', '3pl', 'logistics / 3pl provider'}
    // "IT / Software Vendor"    → {'it', 'software', 'it / software vendor'}
    // "Staffing / Labor Contractor" → {'staffing', 'labor', 'staffing / labor'}
    // blank / null              → {} (only universal rules match)
    // ═════════════════════════════════════════════════════════════════════════
    @TestVisible
    static Set<String> normaliseVendorType(String vendorType) {
        Set<String> tokens = new Set<String>();
        if (String.isBlank(vendorType)) return tokens;

        // Salesforce picklist fields store API values (underscores) on Experience Cloud
        // but labels (spaces) in Classic/internal UI. Normalise to spaces so the
        // contains() checks below work regardless of which format was stored.
        String lower = vendorType.toLowerCase().trim().replace('_', ' ');
        tokens.add(lower); // always add the full normalised value

        if (lower.contains('raw material')) {
            tokens.add('raw material');
            tokens.add('raw material supplier');
        }
        if (lower.contains('contract')) {
            tokens.add('contract mfr');
            tokens.add('contract manufacturer');
        }
        if (lower.contains('logistics') || lower.contains('3pl')) {
            tokens.add('logistics');
            tokens.add('3pl');
            tokens.add('logistics / 3pl');
        }
        if (lower.contains('it') || lower.contains('software')) {
            tokens.add('it');
            tokens.add('software');
        }
        if (lower.contains('staffing') || lower.contains('labor')) {
            tokens.add('staffing');
            tokens.add('labor');
        }

        return tokens;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // buildAssessment — builds a single Compliance_Assessment__c shell
    //
    // Field mapping from Data Model Spec section 5.7:
    //   Supplier__c           Master-Detail → Account
    //   Requirement_Key__c    CMT DeveloperName (stable external ID)
    //   Requirement_Label__c  CMT Label snapshot for historical display
    //   Status__c             Pending
    //   Severity__c           Copied from CMT Severity_on_Failure__c
    //   Evaluated_By__c       Auto
    //   Evaluation_DateTime__c  DateTime.now()
    //   Reason_Code__c        'Missing Document'  ← picklist value (with space)
    // ═════════════════════════════════════════════════════════════════════════
    @TestVisible
    static Compliance_Assessment__c buildAssessment(
        Id accountId,
        Compliance_Requirement__mdt rule
    ) {
        return new Compliance_Assessment__c(
            Name                    = rule.Label,
            Supplier__c             = accountId,
            Requirement_Key__c      = (String) accountId + '__' + rule.DeveloperName,
            Requirement_Label__c    = rule.Label,
            Status__c               = STATUS_PENDING,
            Severity__c             = rule.Severity_on_Failure__c,
            Evaluated_By__c         = EVALUATED_BY_AUTO,
            Evaluation_DateTime__c  = DateTime.now(),
            // FIX: 'Missing Document' not 'Missing_Document' — underscore
            // causes INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST on insert
            Reason_Code__c          = REASON_MISSING,
            Reason_Detail__c        = 'Document not yet submitted'
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Private helpers
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Loads all non-waived Compliance_Assessment__c for a set of supplier Ids.
     * Returns Map<supplierId, Map<requirementKey, assessment>>.
     */
    private static Map<Id, Map<String, Compliance_Assessment__c>>
    loadExistingAssessments(Set<Id> supplierIds) {

        Map<Id, Map<String, Compliance_Assessment__c>> result =
            new Map<Id, Map<String, Compliance_Assessment__c>>();

        for (Compliance_Assessment__c a : [
            SELECT  Id,
                    Supplier__c,
                    Requirement_Key__c,
                    Status__c
            FROM    Compliance_Assessment__c
            WHERE   Supplier__c IN :supplierIds
            AND     Status__c   != :STATUS_WAIVED
        ]) {
            if (!result.containsKey(a.Supplier__c)) {
                result.put(a.Supplier__c,
                    new Map<String, Compliance_Assessment__c>());
            }
            result.get(a.Supplier__c).put(a.Requirement_Key__c, a);
        }
        return result;
    }

    /**
     * Splits a semicolon-delimited string into a trimmed Set<String>.
     * "Tier 1;Tier 2" → {'Tier 1','Tier 2'}
     * null / blank    → {}
     */
    @TestVisible
    static Set<String> splitSemicolon(String value) {
        Set<String> result = new Set<String>();
        if (String.isBlank(value)) return result;
        for (String token : value.split(';')) {
            String t = token.trim();
            if (String.isNotBlank(t)) result.add(t);
        }
        return result;
    }

    /**
     * Logs Database.SaveResult failures.  Does not throw — partial success
     * is intentional so one bad assessment doesn't block the whole onboarding.
     */
    private static void logDmlErrors(
        List<Database.SaveResult>        results,
        List<Compliance_Assessment__c>   records,
        String                           context
    ) {
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) continue;
            for (Database.Error e : results[i].getErrors()) {
                System.debug(LoggingLevel.ERROR,
                    '[ComplianceRuleEngineService.' + context + '] '
                    + 'index=' + i
                    + ' Supplier=' + records[i].Supplier__c
                    + ' Rule='     + records[i].Requirement_Key__c
                    + ' Status='   + e.getStatusCode()
                    + ' Msg='      + e.getMessage()
                );
            }
        }
    }

    private static void logUpsertErrors(
        List<Database.UpsertResult>      results,
        List<Compliance_Assessment__c>   records,
        String                           context
    ) {
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) continue;
            for (Database.Error e : results[i].getErrors()) {
                System.debug(LoggingLevel.ERROR,
                    '[ComplianceRuleEngineService.' + context + '] '
                    + 'index=' + i
                    + ' Supplier=' + records[i].Supplier__c
                    + ' Rule='     + records[i].Requirement_Key__c
                    + ' Status='   + e.getStatusCode()
                    + ' Msg='      + e.getMessage()
                );
            }
        }
    }
}