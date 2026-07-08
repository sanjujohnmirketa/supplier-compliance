public with sharing class ComplianceChecklistController {

    public class FlowInput {
        @InvocableVariable(required=true)
        public Id accountId;
    }

    public class FlowOutput {
        @InvocableVariable
        public String checklistJSON;
    }

    public class ChecklistDisplayItem {
        @InvocableVariable public String documentType;
        @InvocableVariable public String requirementLabel;
        @InvocableVariable public String severity;
        @InvocableVariable public Boolean isMandatory;
        @InvocableVariable public String regulation;
        @InvocableVariable public String assessmentId;
        // Persisted upload + AI state (so a refresh restores what was uploaded/assessed)
        public String complianceDocId;
        public String uploadStatus;                  // pending | done
        public List<Map<String, String>> uploadedFiles;
        public String aiStatus;                       // null | processing | complete
        public String assessmentStatus;               // Compliant | Non-Compliant | Needs Human Review | Pending
        public String reasonDetail;
    }

    private static String mapAssessmentStatus(String s) {
        if (s == 'At Risk') return 'Needs Human Review';
        return s;   // Compliant | Non-Compliant | Pending pass through
    }

    @InvocableMethod(label='Get Compliance Checklist JSON')
    public static List<FlowOutput> getChecklistJSON(List<FlowInput> inputs) {
        List<FlowOutput> results = new List<FlowOutput>();

        // Build a map of CMT DeveloperName → Document_Type__c so each checklist
        // row carries the canonical document type string (e.g. "IATF 16949 Certificate")
        // rather than the internal requirement key (e.g. "RULE_A_001").
        // AuthoritativeVerificationService and DocumentProcessingController both
        // depend on Document_Type__c matching the Compliance_Verification_Source__mdt value.
        Map<String, String> devNameToDocType = new Map<String, String>();
        for (Compliance_Requirement__mdt cmt : [
            SELECT DeveloperName, Document_Type__c
            FROM   Compliance_Requirement__mdt
        ]) {
            if (String.isNotBlank(cmt.Document_Type__c)) {
                devNameToDocType.put(cmt.DeveloperName, cmt.Document_Type__c);
            }
        }

        for (FlowInput inp : inputs) {
            List<Compliance_Assessment__c> assessments = [
                SELECT Id, Requirement_Key__c, Requirement_Label__c,
                       Severity__c, Status__c, Reason_Detail__c, Compliance_Document__c
                FROM Compliance_Assessment__c
                WHERE Supplier__c = :inp.accountId
                ORDER BY Severity__c ASC, Requirement_Label__c ASC
            ];

            // Filenames for any uploaded compliance documents (so a refresh shows them).
            Set<Id> compDocIds = new Set<Id>();
            for (Compliance_Assessment__c a : assessments) {
                if (a.Compliance_Document__c != null) compDocIds.add(a.Compliance_Document__c);
            }
            Map<Id, String> fileByDoc = new Map<Id, String>();
            if (!compDocIds.isEmpty()) {
                for (ContentDocumentLink cdl : [
                    SELECT LinkedEntityId, ContentDocument.Title
                    FROM   ContentDocumentLink
                    WHERE  LinkedEntityId IN :compDocIds
                ]) {
                    if (!fileByDoc.containsKey(cdl.LinkedEntityId)) {
                        fileByDoc.put(cdl.LinkedEntityId, cdl.ContentDocument.Title);
                    }
                }
            }

            List<ChecklistDisplayItem> items = new List<ChecklistDisplayItem>();
            for (Compliance_Assessment__c a : assessments) {
                ChecklistDisplayItem item = new ChecklistDisplayItem();
                // ── Restore upload + AI state from the persisted records ──
                Boolean uploaded = a.Compliance_Document__c != null;
                Boolean assessed = String.isNotBlank(a.Status__c) && a.Status__c != 'Pending';
                item.complianceDocId  = a.Compliance_Document__c;
                item.uploadStatus     = uploaded ? 'done' : 'pending';
                item.aiStatus         = assessed ? 'complete' : (uploaded ? 'processing' : null);
                item.assessmentStatus = assessed ? mapAssessmentStatus(a.Status__c) : null;
                item.reasonDetail     = a.Reason_Detail__c;
                if (uploaded && fileByDoc.containsKey(a.Compliance_Document__c)) {
                    item.uploadedFiles = new List<Map<String, String>>{
                        new Map<String, String>{ 'name' => fileByDoc.get(a.Compliance_Document__c) }
                    };
                }
                // Requirement_Key__c is stored as "{accountId}__{CMT DeveloperName}"
                // (double-underscore separator) to satisfy the External ID uniqueness
                // constraint per supplier. Strip the prefix to get the DeveloperName.
                String cmtDevName = (a.Requirement_Key__c != null && a.Requirement_Key__c.contains('__'))
                    ? a.Requirement_Key__c.substringAfter('__')
                    : a.Requirement_Key__c;
                item.documentType     = devNameToDocType.containsKey(cmtDevName)
                    ? devNameToDocType.get(cmtDevName)
                    : cmtDevName;
                item.requirementLabel = a.Requirement_Label__c;
                item.severity         = a.Severity__c;
                item.isMandatory      = a.Severity__c != 'Low';
                item.assessmentId     = a.Id;
                items.add(item);
            }
            FlowOutput out = new FlowOutput();
            out.checklistJSON = JSON.serialize(items);
            results.add(out);
        }
        return results;
    }
}