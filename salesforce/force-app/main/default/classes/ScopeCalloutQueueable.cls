/**
 * ScopeCalloutQueueable
 * ═══════════════════════════════════════════════════════════════════════════
 * Async orchestrator for RAG-driven checklist seeding. Replaces the static
 * ComplianceRuleEngineService.generateChecklist() path.
 *
 * Why async: Apex cannot make callouts synchronously from a trigger, so
 * AccountTriggerHandler.afterInsert() (via ScopeOnboardingService) enqueues
 * this job. It implements Database.AllowsCallouts.
 *
 * Per supplier it:
 *   1. Calls /scope (ScopeService) with the supplier's attributes
 *   2. Seeds one Compliance_Assessment__c (Status = Pending) per checklist item
 *      — idempotent via upsert on the Requirement_Key__c external id
 *   3. Writes the risk tier/score/domains back onto the Account
 *   4. Records an Audit_Log__c entry (the RAG risk summary)
 *
 * Callout-then-DML ordering: all callouts run first and results are buffered;
 * DML happens once at the end (you cannot call out after DML in a transaction).
 *
 * Downstream: the Azure document pipeline (AIExtractionQueueable → … →
 * ComplianceEvaluationQueueable) later evaluates uploaded documents against the
 * Pending assessments seeded here.
 */
public without sharing class ScopeCalloutQueueable
        implements Queueable, Database.AllowsCallouts {

    private final Set<Id> supplierIds;

    public ScopeCalloutQueueable(Set<Id> supplierIds) {
        this.supplierIds = supplierIds;
    }

    public void execute(QueueableContext ctx) {
        if (supplierIds == null || supplierIds.isEmpty()) return;

        Map<Id, Account> accounts = new Map<Id, Account>([
            SELECT Id, Name, Industry, Industry__c, Vendor_Type__c,
                   Engagement_Type__c, Annual_Spend_Est__c, BillingState,
                   BillingCountry, Country_of_Origin__c, Onboarding_Status__c,
                   Material_Type__c, Service_Category__c, Checklist_Seeded_By_Caller__c
            FROM   Account
            WHERE  Id IN :supplierIds
        ]);

        Map<Id, Supplier_Profile__c> profiles = new Map<Id, Supplier_Profile__c>();
        for (Supplier_Profile__c sp : [
            SELECT Id, Account__c, Commodity_Category__c, Strategic_Region__c,
                   Supplier_Tier__c, Criticality__c, Direct_or_Indirect__c
            FROM   Supplier_Profile__c
            WHERE  Account__c IN :supplierIds
        ]) {
            profiles.put(sp.Account__c, sp);
        }

        // ── Phase 1: callouts only (no DML yet) ───────────────────────────────
        Map<Id, ScopeService.ScopeResponse> responses =
            new Map<Id, ScopeService.ScopeResponse>();
        for (Id accId : accounts.keySet()) {
            try {
                responses.put(accId,
                    ScopeService.getScope(buildRequest(accounts.get(accId), profiles.get(accId))));
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    '[ScopeCalloutQueueable] /scope failed for ' + accId + ': ' + e.getMessage());
                IntegrationErrorLogger.log(accId, 'Onboarding Scope (/scope)', e.getMessage());
            }
        }

        // ── Phase 2: build records from responses ─────────────────────────────
        List<Compliance_Assessment__c> toUpsert = new List<Compliance_Assessment__c>();
        List<Account>                  accUpdates = new List<Account>();
        List<Audit_Log__c>             audits    = new List<Audit_Log__c>();

        for (Id accId : responses.keySet()) {
            ScopeService.ScopeResponse resp = responses.get(accId);
            Account acc = accounts.get(accId);
            String  tier = normaliseTier(resp.riskTier);
            String  severity = tierToSeverity(tier);

            // Skip re-deriving the checklist when the caller already persisted
            // a human-curated one for this account (e.g. VendorPortalController.
            // submitAndScreen() after the user removed suggested documents on
            // the P1 preview, or SubSupplierController.inviteSubSupplier()'s
            // copied subset) — see Checklist_Seeded_By_Caller__c. Risk tier/
            // score/domains below are still computed and written either way.
            Boolean seedChecklist = (acc.Checklist_Seeded_By_Caller__c != true);

            List<String> domains = new List<String>();
            if (seedChecklist && resp.checklist != null) {
                for (ScopeService.ChecklistItem item : resp.checklist) {
                    toUpsert.add(new Compliance_Assessment__c(
                        Name                   = abbreviate(item.document, 'Requirement', 80),
                        Supplier__c            = accId,
                        Requirement_Key__c     = ((String) accId) + '__SCOPE_' + item.domain,
                        Requirement_Label__c   = item.document,
                        Status__c              = 'Pending',
                        Severity__c            = severity,
                        Evaluated_By__c        = 'Auto',
                        Evaluation_DateTime__c = DateTime.now(),
                        Reason_Code__c         = 'Missing Document',
                        Reason_Detail__c       = buildJustification(item)
                    ));
                    if (String.isNotBlank(item.domain)) domains.add(item.domain);
                }
            } else if (resp.checklist != null) {
                // Still contribute domains (for Risk_Domains__c) even when the
                // checklist rows themselves aren't (re)seeded.
                for (ScopeService.ChecklistItem item : resp.checklist) {
                    if (String.isNotBlank(item.domain)) domains.add(item.domain);
                }
            }

            accUpdates.add(new Account(
                Id                    = accId,
                Risk_Tier__c          = tier,
                Profile_Risk_Tier__c  = tier,
                Risk_Score__c         = tierToScore(tier),
                Risk_Domains__c       = String.join(domains, ', '),
                Risk_Last_Computed__c = DateTime.now(),
                Onboarding_Status__c  = acc.Onboarding_Status__c == 'Draft'
                                            ? 'In Review' : acc.Onboarding_Status__c
            ));

            audits.add(new Audit_Log__c(
                Event_Type__c        = 'Checklist_Generated',
                Related_Object__c    = 'Supplier',
                Related_Record_Id__c = accId,
                Event_DateTime__c    = DateTime.now(),
                Actor_Type__c        = 'System',
                Source_System__c     = 'Other',
                New_Value__c         = abbreviate(resp.riskSummary, '', 131072)
            ));
        }

        // ── Phase 3: DML (partial-success; one bad record won't block the rest)
        if (!toUpsert.isEmpty()) {
            Database.upsert(toUpsert, Compliance_Assessment__c.Requirement_Key__c, false);
        }
        if (!accUpdates.isEmpty()) {
            Database.update(accUpdates, false);
        }
        if (!audits.isEmpty()) {
            Database.insert(audits, false);
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    @TestVisible
    static ScopeService.ScopeRequest buildRequest(Account acc, Supplier_Profile__c profile) {
        ScopeService.ScopeRequest req = new ScopeService.ScopeRequest();
        req.supplierId = acc.Id;
        req.legalName  = acc.Name;
        req.country    = String.isNotBlank(acc.Country_of_Origin__c)
                            ? acc.Country_of_Origin__c : acc.BillingCountry;
        // Build the SAME enriched commodity context the console uses
        // (VendorPortalController.buildScopeContext) so the persisted checklist
        // matches the Screen-1 preview — otherwise a sparse query returns only
        // the baseline (finance/general) domains.
        String industry = String.isNotBlank(acc.Industry) ? acc.Industry
                          : String.isNotBlank(acc.Industry__c) ? acc.Industry__c
                          : acc.Vendor_Type__c;
        req.commodity = buildScopeContext(
            industry, acc.Engagement_Type__c,
            acc.Annual_Spend_Est__c == null ? null : String.valueOf(acc.Annual_Spend_Est__c));

        // Same materialDomains resolution the live P1 preview uses (VendorPortalController.
        // generateChecklist) — without this, the trigger-seeded checklist that actually
        // gets persisted (and shown in the supplier portal) silently drops any domains
        // contributed by material type / service category, diverging from what was
        // previewed and emailed at submit time.
        req.materialType    = acc.Material_Type__c;
        req.serviceCategory = acc.Service_Category__c;
        req.materialDomains = VendorPortalController.resolveMaterialDomains(
            acc.Material_Type__c, acc.Service_Category__c);

        List<String> j = new List<String>();
        if (String.isNotBlank(acc.BillingCountry)) j.add(acc.BillingCountry);
        if (String.isNotBlank(acc.BillingState))   j.add(acc.BillingState);
        if (profile != null && String.isNotBlank(profile.Strategic_Region__c)) {
            j.add(profile.Strategic_Region__c);
        }
        req.jurisdictions = j;
        return req;
    }

    // Mirror of VendorPortalController.buildScopeContext — keep in sync so the
    // trigger-seeded checklist matches the console preview.
    @TestVisible
    static String buildScopeContext(String industry, String engagementType, String annualSpend) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(industry))       parts.add(industry);
        if (String.isNotBlank(engagementType)) parts.add('engagement: ' + engagementType);
        if (String.isNotBlank(annualSpend)) {
            String cleaned = annualSpend.replaceAll('[^0-9.]', '');
            parts.add('annual spend ' + (String.isNotBlank(cleaned) ? cleaned : annualSpend) + ' USD');
        }
        return String.join(parts, '; ');
    }

    static String buildJustification(ScopeService.ChecklistItem item) {
        String base   = item.justification != null ? item.justification : '';
        String clause = String.isNotBlank(item.justificationClauseId)
                            ? '\n\n[clause: ' + item.justificationClauseId + ']' : '';
        return abbreviate(base + clause, '', 4000);
    }

    static String abbreviate(String value, String fallback, Integer max) {
        if (String.isBlank(value)) return fallback;
        return value.length() > max ? value.left(max) : value;
    }

    static String normaliseTier(String tier) {
        if (tier == 'Critical' || tier == 'High' || tier == 'Medium' || tier == 'Low') {
            return tier;
        }
        return 'Low';
    }
    static String tierToSeverity(String tier) {
        return tier; // Severity__c shares the same Critical/High/Medium/Low value set
    }
    static Decimal tierToScore(String tier) {
        if (tier == 'Critical') return 85;
        if (tier == 'High')     return 60;
        if (tier == 'Medium')   return 35;
        return 10;
    }
}