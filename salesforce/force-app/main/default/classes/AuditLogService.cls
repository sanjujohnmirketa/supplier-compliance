public without sharing class AuditLogService {

    // All insert operations use without sharing to bypass record-level restrictions
    // Audit_Log__c has create-only permission in all permission sets

    public static void logAIExtraction(
        Id complianceDocId, String modelName, String modelVersion,
        Decimal confidence, String rawResponse, String actorType) {
        insert new Audit_Log__c(
            Event_Type__c = 'Doc Extracted',
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
            Event_Type__c = 'Assessment Created',
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

    // CRITICAL: Never expose update or delete methods on Audit_Log__c.
    // The object CRUD on the permission set should be Create-only.
}