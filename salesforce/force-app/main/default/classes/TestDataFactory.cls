/**
 * TestDataFactory — the handful of records every test in this package needs.
 * Suppliers are inserted with AccountTriggerHandler bypassed (the real
 * onboarding path enqueues a /scope callout that a test only wants when it
 * is specifically testing that path — those tests insert their own).
 */
@IsTest
public class TestDataFactory {

    // ── Test persona ─────────────────────────────────────────────────────
    // The packaged permission sets are what carry field-level security on the
    // package's custom fields. A freshly built org (the package build's org, a
    // scratch org) grants the running admin none of it, so USER_MODE queries
    // and stripInaccessible silently drop fields — and the running user's own
    // permissions are cached for the test run, so assigning the sets to
    // yourself changes nothing. A dedicated persona user loaded via
    // System.runAs picks them up cleanly (the pattern CrudEnforcementTest
    // proves). createPersona() runs from @TestSetup (setup-object DML only, so
    // no MIXED_DML with the test's data); every test body runs as persona().
    private static final String PERSONA_USERNAME_PREFIX = 'grace.persona.';

    public static void createPersona() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniq = String.valueOf(System.currentTimeMillis()) + String.valueOf(Math.abs(Crypto.getRandomInteger())).left(4);
        User u = new User(
            Alias             = 'grace',
            Email             = 'persona@example.com',
            EmailEncodingKey  = 'UTF-8',
            FirstName         = 'Grace',
            LastName          = 'Persona',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey      = 'en_US',
            ProfileId         = p.Id,
            TimeZoneSidKey    = 'America/New_York',
            Username          = PERSONA_USERNAME_PREFIX + uniq + '@grace.test'
        );
        insert u;

        // Object CRUD the packaged sets cannot carry (master-detail to a
        // standard object) — what the post-install guide asks an admin to grant
        // at profile level. Parent-first: a child's Read depends on its
        // parent's Read inside the same permission set.
        PermissionSet objects = new PermissionSet(Name = 'GraceTestPersonaObjects', Label = 'Vendor GRACE test persona (object CRUD)');
        insert objects;
        for (List<Schema.SObjectType> level : new List<List<Schema.SObjectType>>{
                new List<Schema.SObjectType>{ Account.SObjectType, Policy_Document__c.SObjectType, Audit_Log__c.SObjectType },
                new List<Schema.SObjectType>{ Compliance_Assessment__c.SObjectType, Compliance_Document__c.SObjectType, Supplier_Profile__c.SObjectType },
                new List<Schema.SObjectType>{ Compliance_Document_Link__c.SObjectType, Document_Extraction__c.SObjectType } }) {
            List<ObjectPermissions> ops = new List<ObjectPermissions>();
            for (Schema.SObjectType t : level) {
                ops.add(new ObjectPermissions(
                    ParentId = objects.Id, SobjectType = t.getDescribe().getName(),
                    PermissionsRead = true, PermissionsCreate = true, PermissionsEdit = true, PermissionsDelete = true));
            }
            insert ops;
        }

        List<PermissionSetAssignment> psas = new List<PermissionSetAssignment>{
            new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = objects.Id)
        };
        for (PermissionSet ps : [
            SELECT Id FROM PermissionSet
            WHERE  Name IN ('Supplier_Compliance_Access', 'Procurement_Workspace_Access',
                            'Analyst_Workspace_Access', 'Full_Supplier_Visibility')
        ]) {
            psas.add(new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id));
        }
        insert psas;
    }

    public static User persona() {
        String pattern = PERSONA_USERNAME_PREFIX + '%';
        return [SELECT Id FROM User WHERE Username LIKE :pattern ORDER BY CreatedDate DESC LIMIT 1];
    }

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
