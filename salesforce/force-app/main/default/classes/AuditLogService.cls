/**
 * AuditLogService — the ONLY place Audit_Log__c rows are written.
 *
 * SYSTEM CONTEXT BY DESIGN (documented CRUD/FLS scanner exception): this
 * class is without sharing and performs no Schema/stripInaccessible check
 * before its inserts. An audit entry records what a user DID; it must be
 * written even when that user holds no Create permission on Audit_Log__c,
 * otherwise a user could suppress their own audit trail simply by lacking
 * the permission. Consequently no persona permission set grants Create/
 * Edit/Delete on Audit_Log__c — only Read (for AuditReportController).
 * Every controller routes its audit rows through write() below so this
 * exception exists in exactly one class instead of being scattered.
 */
@SuppressWarnings('PMD.ApexCRUDViolation') // system-context audit sink — see class doc
public without sharing class AuditLogService {

    // Generic sink used by the controllers. allOrNone=false: a failed audit
    // write must never roll back the business transaction it describes.
    public static void write(Audit_Log__c row) {
        Database.insert(row, false);
    }

    public static void logAIExtraction(
        Id complianceDocId, String modelName, String modelVersion,
        Decimal confidence, String rawResponse, String actorType) {
        insert new Audit_Log__c(
            Event_Type__c = 'AI_Extraction',
            Related_Object__c = 'Compliance_Document',
            Related_Record_Id__c = complianceDocId,
            Event_DateTime__c = DateTime.now(),
            Actor_Type__c = actorType,
            AI_Model_Name__c = modelName,
            AI_Model_Version__c = modelVersion,
            AI_Confidence__c = confidence,
            New_Value__c = rawResponse.left(131072)
        );
    }

    public static void logAssessmentChange(
        Id assessmentId, String before, String after, String reason, String actorType) {
        insert new Audit_Log__c(
            Event_Type__c = 'Compliance_Evaluated',
            Related_Object__c = 'Compliance_Assessment',
            Related_Record_Id__c = assessmentId,
            Event_DateTime__c = DateTime.now(),
            Actor_Type__c = actorType,
            Original_Value__c = before,
            New_Value__c = after,
            Reason__c = reason
        );
    }

    public static void logDocumentReceived(
        Id complianceDocId, String accountId, String documentType, String fileName) {
        insert new Audit_Log__c(
            Event_Type__c        = 'Document_Uploaded',
            Related_Object__c    = 'Compliance_Document',
            Related_Record_Id__c = complianceDocId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'Human',
            New_Value__c         = JSON.serialize(new Map<String, String>{
                'accountId'    => accountId,
                'documentType' => documentType,
                'fileName'     => fileName
            }),
            Source_System__c     = 'Salesforce'
        );
    }

    public static void logCascadingRiskChange(
        Id accountId, String before, String after, String reason) {
        insert new Audit_Log__c(
            Event_Type__c         = 'Cascading_Risk_Updated',
            Related_Object__c     = 'Supplier',
            Related_Record_Id__c  = accountId,
            Event_DateTime__c     = DateTime.now(),
            Actor_Type__c         = 'System',
            Original_Value__c     = before,
            New_Value__c          = after,
            Reason__c             = reason,
            Source_System__c      = 'Salesforce'
        );
    }

    // CRITICAL: Never expose update or delete methods on Audit_Log__c.
    // The object CRUD on the permission set should be Create-only.
}