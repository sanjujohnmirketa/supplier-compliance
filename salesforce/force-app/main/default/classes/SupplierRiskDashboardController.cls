public with sharing class SupplierRiskDashboardController {

    // ═════════════════════════════════════════════════════════════════════════
    // Public DTOs — shape kept identical to the original so the LWC JS/HTML
    // needs no changes. Fields that no longer have a source in the new data
    // model are simply left null (the templates use if:true guards).
    // ═════════════════════════════════════════════════════════════════════════
    public class SupplierSnapshot {
        // Identity + classification
        @AuraEnabled public String   accountId;
        @AuraEnabled public String   supplierName;
        @AuraEnabled public String   industry;
        @AuraEnabled public String   vendorType;        // null in new arch — no Vendor_Type__c
        @AuraEnabled public String   supplierTier;
        @AuraEnabled public String   criticality;
        @AuraEnabled public String   region;
        @AuraEnabled public String   directOrIndirect;
        @AuraEnabled public String   onboardingStatus;
        @AuraEnabled public String   complianceStatus;  // null in new arch — no Compliance_Status_Rollup__c

        // Risk rollup — from Account fields
        @AuraEnabled public Decimal  riskScore;
        @AuraEnabled public String   riskTier;
        @AuraEnabled public String   riskTierVariant;
        @AuraEnabled public DateTime riskLastComputed;
        @AuraEnabled public Boolean  hasRiskData;

        // Multi-tier cascading risk (docs/multi-tier-risk-rollup.md) — worst-case
        // tier across this supplier's whole sub-tree, distinct from its own riskTier.
        // Computed by MultiTierRollupService by walking Account.ParentId.
        @AuraEnabled public String   cascadingRiskTier;
        @AuraEnabled public String   cascadingRiskTierVariant;
        @AuraEnabled public String   cascadingRiskSource;
        @AuraEnabled public String   cascadingRiskDriverId;
        @AuraEnabled public Integer  subTierSupplierCount;
        @AuraEnabled public DateTime cascadingRiskLastComputed;
        // Weighted-average blend (New Score = own*0.7 + avg(weighted sub-supplier)*0.3) —
        // a second, separate signal from cascadingRiskTier's worst-case propagation.
        @AuraEnabled public Decimal  cascadingRiskScore;
        @AuraEnabled public Boolean  cascadingRiskFlagged;

        // Compliance evaluation summary — computed live from assessments
        @AuraEnabled public Integer  totalRequirements;
        @AuraEnabled public Integer  requirementsMet;
        @AuraEnabled public Integer  requirementsFailed;
        @AuraEnabled public Integer  requirementsPending;
        @AuraEnabled public String   evaluationSummary;
        @AuraEnabled public String   remediationSteps;
        @AuraEnabled public List<String> criticalFailures;

        // Document summary
        @AuraEnabled public Integer  documentsTotal;
        @AuraEnabled public Integer  documentsValidated;
        @AuraEnabled public Integer  documentsRejected;
        @AuraEnabled public Integer  documentsPending;

        // Drill-down lists
        @AuraEnabled public List<AssessmentRow>  assessments;
        @AuraEnabled public List<DocumentRow>    documents;
        @AuraEnabled public List<RawMaterialRow> rawMaterials;
    }

    public class AssessmentRow {
        @AuraEnabled public String   assessmentId;
        @AuraEnabled public String   requirementLabel;
        @AuraEnabled public String   requirementKey;
        @AuraEnabled public String   severity;
        @AuraEnabled public String   status;
        @AuraEnabled public String   statusVariant;
        @AuraEnabled public String   reasonCode;
        @AuraEnabled public String   reasonDetail;
        @AuraEnabled public String   sourceRegulation;
        @AuraEnabled public Boolean  isCritical;
        @AuraEnabled public String   linkedDocumentId;
        @AuraEnabled public DateTime lastEvaluated;
        @AuraEnabled public Integer  aiConfidence;  // AI_Confidence__c (0-100)
    }

    // DocumentRow now wraps ContentVersion. Fields that came from
    // Document_Extraction__c JSON parsing are left null — the HTML uses
    // if:true guards so they simply don't render.
    public class DocumentRow {
        @AuraEnabled public String   documentId;        // ContentDocument Id (for navigation)
        @AuraEnabled public String   documentName;      // ContentVersion.Title
        @AuraEnabled public String   documentType;      // ContentVersion.FileType
        @AuraEnabled public String   status;            // null — no status on ContentVersion
        @AuraEnabled public String   statusVariant;

        // Extraction-derived fields — always null in new arch (no Document_Extraction__c)
        @AuraEnabled public String   validationVerdict;
        @AuraEnabled public String   validationReasoning;
        @AuraEnabled public List<String> validationIssues;
        @AuraEnabled public Boolean  forgerySignalsDetected;
        @AuraEnabled public List<String> forgerySignals;
        @AuraEnabled public String   complianceStatus;
        @AuraEnabled public String   complianceReasonDetail;
        @AuraEnabled public String   regulationCitation;
        @AuraEnabled public Boolean  isRegistryVerified;
        @AuraEnabled public Boolean  isRegistryRejected;
        @AuraEnabled public String   registryAuthority;
        @AuraEnabled public String   registryStatus;
        @AuraEnabled public Boolean  isExpired;
        @AuraEnabled public Boolean  isExpiringSoon;
        @AuraEnabled public String   issuer;
        @AuraEnabled public String   certificateNumber;
        @AuraEnabled public Date     issueDate;
        @AuraEnabled public Date     expiryDate;
        @AuraEnabled public Decimal  confidence;
        @AuraEnabled public List<FieldConfidence> fieldConfidences;
        @AuraEnabled public String   remediation;
        @AuraEnabled public DateTime uploadedAt;
    }

    public class FieldConfidence {
        @AuraEnabled public String  fieldName;
        @AuraEnabled public String  value;
        @AuraEnabled public Decimal confidence;
    }

    public class RawMaterialRow {
        @AuraEnabled public String materialName;
        @AuraEnabled public String category;
        @AuraEnabled public String complianceImpact;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Main entry point
    // ═════════════════════════════════════════════════════════════════════════
    @AuraEnabled(cacheable=true)
    public static SupplierSnapshot getSupplierSnapshot(Id accountId) {
        if (accountId == null) {
            throw new AuraHandledException('Account Id is required');
        }

        SupplierSnapshot snap = new SupplierSnapshot();
        snap.accountId = accountId;

        Account acc = loadAccount(accountId);
        if (acc == null) {
            throw new AuraHandledException('Supplier not found: ' + accountId);
        }

        populateClassification(snap, acc);
        populateRiskRollup(snap, acc);

        snap.assessments  = loadAssessments(accountId);
        snap.documents    = loadDocuments(accountId);
        snap.rawMaterials = new List<RawMaterialRow>(); // Supplier_Material__c removed in new arch

        countAssessmentsByStatus(snap);
        countDocumentsByStatus(snap);
        deriveSupplierNarrative(snap);

        return snap;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Account loader — uses standard Account.Industry (not custom Industry__c)
    // and omits fields removed in the new architecture.
    // ═════════════════════════════════════════════════════════════════════════
    private static Account loadAccount(Id accountId) {
        List<Account> accts = [
            SELECT Id, Name, Industry, BillingCountry, Country_of_Origin__c,
                   Onboarding_Status__c,
                   Risk_Score__c, Risk_Tier__c, Risk_Last_Computed__c,
                   Cascading_Risk_Tier__c, Cascading_Risk_Source__c,
                   Cascading_Risk_Driver__c, Sub_Tier_Supplier_Count__c,
                   Cascading_Risk_Last_Computed__c, Cascading_Risk_Score__c,
                   Cascading_Risk_Flag__c
            FROM   Account
            WHERE  Id = :accountId
            LIMIT  1
        ];
        return accts.isEmpty() ? null : accts[0];
    }

    private static void populateClassification(SupplierSnapshot snap, Account acc) {
        snap.supplierName     = acc.Name;
        snap.industry         = acc.Industry;           // standard field (was Industry__c)
        snap.vendorType       = null;                   // Vendor_Type__c removed in new arch
        snap.onboardingStatus = acc.Onboarding_Status__c;
        snap.complianceStatus = null;                   // Compliance_Status_Rollup__c removed

        List<Supplier_Profile__c> profiles = [
            SELECT Supplier_Tier__c, Criticality__c, Strategic_Region__c,
                   Direct_or_Indirect__c
            FROM   Supplier_Profile__c
            WHERE  Account__c = :acc.Id
            LIMIT  1
        ];
        if (!profiles.isEmpty()) {
            Supplier_Profile__c p = profiles[0];
            snap.supplierTier     = p.Supplier_Tier__c;
            snap.criticality      = p.Criticality__c;
            snap.region           = p.Strategic_Region__c;
            snap.directOrIndirect = p.Direct_or_Indirect__c;
        }
    }

    private static void populateRiskRollup(SupplierSnapshot snap, Account acc) {
        snap.riskScore        = acc.Risk_Score__c;
        snap.riskTier         = acc.Risk_Tier__c;
        snap.riskLastComputed = acc.Risk_Last_Computed__c;
        snap.hasRiskData      = (acc.Risk_Last_Computed__c != null);
        snap.riskTierVariant  = mapTierToVariant(acc.Risk_Tier__c);

        snap.cascadingRiskTier         = acc.Cascading_Risk_Tier__c;
        snap.cascadingRiskTierVariant  = mapTierToVariant(acc.Cascading_Risk_Tier__c);
        snap.cascadingRiskSource       = acc.Cascading_Risk_Source__c;
        snap.cascadingRiskDriverId     = acc.Cascading_Risk_Driver__c;
        snap.subTierSupplierCount      = acc.Sub_Tier_Supplier_Count__c == null
            ? 0 : acc.Sub_Tier_Supplier_Count__c.intValue();
        snap.cascadingRiskLastComputed = acc.Cascading_Risk_Last_Computed__c;
        snap.cascadingRiskScore        = acc.Cascading_Risk_Score__c;
        snap.cascadingRiskFlagged      = acc.Cascading_Risk_Flag__c == true;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Assessments — same Compliance_Assessment__c shape as VendorPortalController
    // ═════════════════════════════════════════════════════════════════════════
    private static List<AssessmentRow> loadAssessments(Id accountId) {
        List<AssessmentRow> rows = new List<AssessmentRow>();
        for (Compliance_Assessment__c a : [
            SELECT Id, Requirement_Key__c, Requirement_Label__c, Severity__c,
                   Status__c, Reason_Detail__c, AI_Confidence__c,
                   Compliance_Document__c, Evaluation_DateTime__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :accountId
            ORDER BY Requirement_Label__c ASC
            LIMIT  200
        ]) {
            // Skip screening rows — only show checklist/document requirements
            if (a.Requirement_Key__c != null && a.Requirement_Key__c.startsWith('SCREEN_')) continue;

            AssessmentRow row = new AssessmentRow();
            row.assessmentId     = a.Id;
            row.requirementKey   = a.Requirement_Key__c;
            row.requirementLabel = a.Requirement_Label__c;
            row.severity         = a.Severity__c;
            row.status           = a.Status__c;
            row.statusVariant    = mapStatusToVariant(a.Status__c);
            row.reasonDetail     = a.Reason_Detail__c;
            row.linkedDocumentId = a.Compliance_Document__c;
            row.lastEvaluated    = a.Evaluation_DateTime__c;
            row.isCritical       = (a.Severity__c == 'Critical');
            row.aiConfidence     = (a.AI_Confidence__c == null) ? null : Integer.valueOf(a.AI_Confidence__c);

            // Source regulation from CMT (optional — silent fail if not deployed)
            Compliance_Requirement__mdt rule = lookupRule(a.Requirement_Key__c);
            if (rule != null) row.sourceRegulation = rule.Source_Regulation__c;

            rows.add(row);
        }
        return sortAssessmentsBySeverity(rows);
    }

    private static List<AssessmentRow> sortAssessmentsBySeverity(List<AssessmentRow> rows) {
        List<AssessmentRow> critical = new List<AssessmentRow>();
        List<AssessmentRow> high     = new List<AssessmentRow>();
        List<AssessmentRow> medium   = new List<AssessmentRow>();
        List<AssessmentRow> other    = new List<AssessmentRow>();
        for (AssessmentRow r : rows) {
            if      (r.severity == 'Critical') critical.add(r);
            else if (r.severity == 'High')     high.add(r);
            else if (r.severity == 'Medium')   medium.add(r);
            else                               other.add(r);
        }
        List<AssessmentRow> sorted = new List<AssessmentRow>();
        sorted.addAll(critical);
        sorted.addAll(high);
        sorted.addAll(medium);
        sorted.addAll(other);
        return sorted;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Documents — built exclusively from checklist assessments that have a linked
    // Compliance_Document__c (same bridge as VendorPortalController.getCaseForAnalyst).
    // Unmatched / rejected uploads are intentionally excluded; only documents that
    // are part of the compliance checklist appear here.
    // ═════════════════════════════════════════════════════════════════════════
    private static List<DocumentRow> loadDocuments(Id accountId) {
        List<DocumentRow> rows = new List<DocumentRow>();

        // Only checklist assessments with an uploaded document — skip screening rows
        List<Compliance_Assessment__c> assessed = new List<Compliance_Assessment__c>();
        for (Compliance_Assessment__c a : [
            SELECT Id, Requirement_Key__c, Requirement_Label__c, Status__c, Severity__c,
                   AI_Confidence__c, Reason_Detail__c, Compliance_Document__c, Evaluation_DateTime__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :accountId AND Compliance_Document__c != null
            ORDER BY Evaluation_DateTime__c DESC
            LIMIT  50
        ]) {
            if (a.Requirement_Key__c != null && a.Requirement_Key__c.startsWith('SCREEN_')) continue;
            assessed.add(a);
        }

        if (assessed.isEmpty()) return rows;

        Set<Id> compDocIds = new Set<Id>();
        for (Compliance_Assessment__c a : assessed) compDocIds.add(a.Compliance_Document__c);

        Map<Id, Id> cdByCompDoc = new Map<Id, Id>();
        for (ContentDocumentLink l : [
            SELECT LinkedEntityId, ContentDocumentId
            FROM   ContentDocumentLink WHERE LinkedEntityId IN :compDocIds
        ]) {
            cdByCompDoc.put(l.LinkedEntityId, l.ContentDocumentId);
        }

        Set<Id> cdIds = new Set<Id>(cdByCompDoc.values());
        Map<Id, ContentVersion> cvByCd = new Map<Id, ContentVersion>();
        if (!cdIds.isEmpty()) {
            for (ContentVersion v : [
                SELECT Id, Title, FileType, CreatedDate, ContentDocumentId
                FROM   ContentVersion
                WHERE  ContentDocumentId IN :cdIds AND IsLatest = true
            ]) {
                cvByCd.put(v.ContentDocumentId, v);
            }
        }

        for (Compliance_Assessment__c a : assessed) {
            Id cdId = cdByCompDoc.get(a.Compliance_Document__c);
            ContentVersion cv = (cdId != null) ? cvByCd.get(cdId) : null;

            DocumentRow row = new DocumentRow();
            row.documentId             = cdId;
            row.documentName           = (cv != null) ? cv.Title : a.Requirement_Label__c;
            row.documentType           = a.Requirement_Label__c;
            row.status                 = a.Status__c;
            row.statusVariant          = mapStatusToVariant(a.Status__c);
            row.confidence             = (a.AI_Confidence__c != null) ? a.AI_Confidence__c / 100 : null;
            row.validationReasoning    = a.Reason_Detail__c; // AI summary from the assessment
            row.uploadedAt             = (cv != null) ? cv.CreatedDate : a.Evaluation_DateTime__c;
            row.validationIssues       = new List<String>();
            row.forgerySignals         = new List<String>();
            row.fieldConfidences       = new List<FieldConfidence>();
            row.forgerySignalsDetected = false;
            rows.add(row);
        }

        return rows;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Aggregations + supplier narrative
    // ═════════════════════════════════════════════════════════════════════════
    private static void countAssessmentsByStatus(SupplierSnapshot snap) {
        Integer met = 0, failed = 0, pending = 0;
        for (AssessmentRow r : snap.assessments) {
            if (r.status == 'Compliant')          met++;
            else if (r.status == 'Non-Compliant') failed++;
            else                                  pending++;
        }
        snap.totalRequirements   = snap.assessments.size();
        snap.requirementsMet     = met;
        snap.requirementsFailed  = failed;
        snap.requirementsPending = pending;
    }

    private static void countDocumentsByStatus(SupplierSnapshot snap) {
        Integer validated = 0, rejected = 0, pending = 0;
        for (DocumentRow d : snap.documents) {
            if (d.status == 'Compliant')          validated++;
            else if (d.status == 'Non-Compliant') rejected++;
            else if (d.status != null)            pending++;
        }
        snap.documentsTotal     = snap.documents.size();
        snap.documentsValidated = validated;
        snap.documentsRejected  = rejected;
        snap.documentsPending   = pending;
    }

    private static void deriveSupplierNarrative(SupplierSnapshot snap) {
        snap.criticalFailures = new List<String>();
        for (AssessmentRow r : snap.assessments) {
            if (r.status == 'Non-Compliant' && r.isCritical) {
                snap.criticalFailures.add(r.requirementLabel);
            }
        }

        if (snap.totalRequirements != null && snap.totalRequirements > 0) {
            String tierPhrase = snap.riskTier != null
                ? ' Risk tier: ' + snap.riskTier + '.' : '';
            String failPhrase = snap.requirementsFailed > 0
                ? ' ' + snap.requirementsFailed + ' requirement'
                  + (snap.requirementsFailed == 1 ? '' : 's')
                  + ' currently failing'
                  + (snap.criticalFailures.size() > 0
                      ? ' (including ' + snap.criticalFailures.size() + ' critical).' : '.')
                : '';
            String pendPhrase = snap.requirementsPending > 0
                ? ' ' + snap.requirementsPending + ' requirement'
                  + (snap.requirementsPending == 1 ? '' : 's')
                  + ' awaiting documents or review.'
                : '';
            snap.evaluationSummary = snap.requirementsMet + ' of '
                + snap.totalRequirements + ' requirements satisfied.'
                + failPhrase + pendPhrase + tierPhrase;
        } else {
            snap.evaluationSummary = 'No compliance requirements have been generated for this supplier yet.';
        }

        snap.remediationSteps = null; // no per-doc remediation in new arch
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═════════════════════════════════════════════════════════════════════════
    private static String mapTierToVariant(String tier) {
        if (tier == 'Critical') return 'error';
        if (tier == 'High')     return 'warning';
        if (tier == 'Medium')   return 'warning';
        if (tier == 'Low')      return 'success';
        return 'inverse';
    }

    private static String mapStatusToVariant(String status) {
        if (status == 'Compliant')     return 'success';
        if (status == 'Non-Compliant') return 'error';
        if (status == 'Waived')        return 'inverse';
        return 'warning';
    }

    private static Compliance_Requirement__mdt lookupRule(String key) {
        if (String.isBlank(key)) return null;
        try { return Compliance_Requirement__mdt.getInstance(key); }
        catch (Exception e) { return null; }
    }
}