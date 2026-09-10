/**
 * TestDataFactory — the handful of records every test in this package needs.
 * Suppliers are inserted with AccountTriggerHandler bypassed (the real
 * onboarding path enqueues a /scope callout that a test only wants when it
 * is specifically testing that path — those tests insert their own).
 */
@IsTest
public class TestDataFactory {

    public static Id supplierRecordTypeId() {
        Map<String, Schema.RecordTypeInfo> rtMap =
            Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
        return rtMap.containsKey('Supplier') ? rtMap.get('Supplier').getRecordTypeId() : null;
    }

    public static Account supplier(String name) {
        return supplier(name, null, 'Draft');
    }

    public static Account supplier(String name, String token, String status) {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');
        Account a = new Account(
            Name                      = name,
            RecordTypeId              = supplierRecordTypeId(),
            Supplier_Portal_Token__c  = token,
            Onboarding_Status__c      = status,
            Industry                  = 'Manufacturing',
            BillingCountry            = 'Germany',
            Supplier_Contact_Email__c = slug(name) + '@example.com',
            Risk_Domains__c           = 'finance, general'
        );
        insert a;
        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');
        return a;
    }

    public static Account subSupplier(String name, Id parentId) {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');
        Account a = new Account(
            Name = name, RecordTypeId = supplierRecordTypeId(), ParentId = parentId,
            Onboarding_Status__c = 'Draft', Supplier_Tier__c = 'Tier 2',
            Supplier_Contact_Email__c = slug(name) + '@example.com', BillingCountry = 'France'
        );
        insert a;
        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');
        return a;
    }

    public static Compliance_Assessment__c assessment(Id supplierId, String keySuffix, String label, String status, String severity) {
        Compliance_Assessment__c ca = new Compliance_Assessment__c(
            Supplier__c            = supplierId,
            Requirement_Key__c     = String.valueOf(supplierId) + '__' + keySuffix,
            Requirement_Label__c   = label,
            Status__c              = status,
            Severity__c            = severity,
            Evaluation_DateTime__c = System.now()
        );
        insert ca;
        return ca;
    }

    public static Compliance_Assessment__c screeningRow(Id supplierId, String category, String status) {
        Compliance_Assessment__c ca = new Compliance_Assessment__c(
            Supplier__c            = supplierId,
            Requirement_Key__c     = 'SCREEN_' + category.toUpperCase() + '_' + String.valueOf(supplierId).right(12),
            Requirement_Label__c   = 'Screening — ' + category,
            Status__c              = status,
            Severity__c            = 'Low',
            Reason_Detail__c       = 'Screening detail',
            Evaluation_DateTime__c = System.now()
        );
        insert ca;
        return ca;
    }

    public static Id contentDocument(String title, String body, Id linkTo) {
        ContentVersion cv = new ContentVersion(
            Title = title, PathOnClient = title, VersionData = Blob.valueOf(body), Origin = 'H');
        insert cv;
        Id cdId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].ContentDocumentId;
        if (linkTo != null) {
            insert new ContentDocumentLink(
                ContentDocumentId = cdId, LinkedEntityId = linkTo, ShareType = 'V', Visibility = 'AllUsers');
        }
        return cdId;
    }

    public static Id latestVersionId(Id contentDocumentId) {
        return [SELECT Id FROM ContentVersion WHERE ContentDocumentId = :contentDocumentId AND IsLatest = true LIMIT 1].Id;
    }

    public static Compliance_Document__c complianceDoc(Id accountId, String type, String status) {
        Compliance_Document__c d = new Compliance_Document__c(
            Name = type.left(80), Account__c = accountId, Document_Type__c = type, Status__c = status);
        insert d;
        return d;
    }

    // A Compliance_Document__c with a real file behind it, linked the same way
    // DocumentProcessingController links an upload (CDL to the doc + to the Account).
    public static Compliance_Document__c complianceDocWithFile(Id accountId, String type, String fileName) {
        Compliance_Document__c d = complianceDoc(accountId, type, 'Pending');
        Id cdId = contentDocument(fileName, 'file body for ' + fileName, accountId);
        insert new ContentDocumentLink(ContentDocumentId = cdId, LinkedEntityId = d.Id, ShareType = 'V', Visibility = 'AllUsers');
        d.Source_File__c = cdId;
        update d;
        return d;
    }

    public static Contact contact(Id accountId, String email) {
        Contact c = new Contact(AccountId = accountId, FirstName = 'Test', LastName = 'Contact', Email = email);
        insert c;
        return c;
    }

    public static Audit_Log__c audit(String eventType, String relatedObject, Id relatedId, String newValue, String reason, Id actorUser) {
        Audit_Log__c row = new Audit_Log__c(
            Event_Type__c        = eventType,
            Related_Object__c    = relatedObject,
            Related_Record_Id__c = relatedId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = actorUser == null ? 'System' : 'User',
            Actor_User__c        = actorUser,
            Source_System__c     = 'Other',
            New_Value__c         = newValue,
            Reason__c            = reason
        );
        insert row;
        return row;
    }

    public static String base64(String s) {
        return EncodingUtil.base64Encode(Blob.valueOf(s));
    }

    public static String slug(String s) {
        return s.toLowerCase().replaceAll('[^a-z0-9]', '');
    }
}
