/**
 * CrudEnforcementTest
 * ═══════════════════════════════════════════════════════════════════════════
 * Proves the CRUD/FLS model end to end AS THE REAL PERSONAS (System.runAs),
 * not as the admin the other tests run as:
 *
 *  1. A licensed user holding exactly what the post-install guide grants
 *     (the three packaged permission sets + profile-level CRUD on the
 *     master-detail objects that 2GP cannot package) can use every internal
 *     entry point.
 *  2. A licensed user WITHOUT those grants is refused by the guards.
 *  3. The Experience Cloud guest user (zero object permissions by design)
 *     still works through the token path, and is refused when calling a
 *     non-token entry point directly — the IDOR the split closes.
 *  4. AuditLogService.write records the audit row even when the caller has
 *     no Create permission on Audit_Log__c (the documented system-context
 *     sink), so a user cannot suppress their own audit trail.
 */
@IsTest
private class CrudEnforcementTest {

    // ── Setup helpers ─────────────────────────────────────────────────────
    // All setup-object DML (User / PermissionSet / assignments) is done inside
    // System.runAs(admin) blocks; all data DML outside them — the standard
    // way to keep a test clear of MIXED_DML_OPERATION.

    private static User makeUser(String alias) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniq = alias + String.valueOf(System.currentTimeMillis()).right(8);
        User u = new User(
            Alias             = alias.left(8),
            Email             = uniq + '@example.com',
            EmailEncodingKey  = 'UTF-8',
            LastName          = 'CrudTest ' + alias,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey      = 'en_US',
            ProfileId         = p.Id,
            TimeZoneSidKey    = 'America/New_York',
            Username          = uniq + '@crud-enforcement.test'
        );
        insert u;
        return u;
    }

    // Exactly what the post-install guide asks a subscriber admin to grant.
    private static void grantPersona(User u) {
        List<PermissionSet> packaged = [
            SELECT Id FROM PermissionSet
            WHERE  Name IN ('Procurement_Workspace_Access', 'Analyst_Workspace_Access',
                            'Supplier_Compliance_Access', 'Full_Supplier_Visibility')
        ];
        System.assertEquals(4, packaged.size(), 'all four packaged permission sets must exist');

        // Profile-level object CRUD on the M-D objects, as a temp permission set.
        // A master-detail child's Read depends on its parent's Read INSIDE THE
        // SAME permission set (FIELD_INTEGRITY_EXCEPTION otherwise), so the
        // rows are inserted parent-first: Account → its children → grandchildren.
        PermissionSet md = new PermissionSet(
            Name = 'CrudEnforcementTestMD', Label = 'CRUD Enforcement Test (M-D objects)');
        insert md;
        for (List<Schema.SObjectType> level : new List<List<Schema.SObjectType>>{
                new List<Schema.SObjectType>{ Account.SObjectType },
                new List<Schema.SObjectType>{ Compliance_Assessment__c.SObjectType,
                                              Compliance_Document__c.SObjectType,
                                              Supplier_Profile__c.SObjectType },
                new List<Schema.SObjectType>{ Compliance_Document_Link__c.SObjectType,
                                              Document_Extraction__c.SObjectType } }) {
            List<ObjectPermissions> ops = new List<ObjectPermissions>();
            for (Schema.SObjectType t : level) {
                ops.add(new ObjectPermissions(
                    ParentId = md.Id, SobjectType = t.getDescribe().getName(),
                    PermissionsRead = true, PermissionsCreate = true,
                    PermissionsEdit = true, PermissionsDelete = true));
            }
            insert ops;
        }

        List<PermissionSetAssignment> psas = new List<PermissionSetAssignment>();
        for (PermissionSet ps : packaged) {
            psas.add(new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id));
        }
        psas.add(new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = md.Id));
        insert psas;
    }

    // Same bypass VendorPortalControllerTest uses: the real onboarding flow
    // enqueues a /scope callout that has no business in this test.
    private static Account makeSupplier(String name, String token) {
        TriggerDispatcher.bypassedHandlers.add('AccountTriggerHandler');
        Map<String, Schema.RecordTypeInfo> rtMap =
            Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
        Account a = new Account(Name = name, Supplier_Portal_Token__c = token);
        if (rtMap.containsKey('Supplier')) a.RecordTypeId = rtMap.get('Supplier').getRecordTypeId();
        insert a;
        TriggerDispatcher.bypassedHandlers.remove('AccountTriggerHandler');
        insert new Compliance_Assessment__c(
            Supplier__c          = a.Id,
            Requirement_Key__c   = a.Id + '__CRUD_TEST',
            Requirement_Label__c = 'Certificate of Insurance',
            Status__c            = 'Pending'
        );
        return a;
    }

    // ── 1. Persona with the packaged grants can use the app ───────────────
    @IsTest
    static void personaWithPackagedGrantsCanUseInternalEntryPoints() {
        User admin = new User(Id = UserInfo.getUserId());
        User persona;
        System.runAs(admin) {
            persona = makeUser('crudok');
            grantPersona(persona);
        }
        Account supplier = makeSupplier('CRUD Persona Supplier', null);

        System.runAs(persona) {
            Test.startTest();
            VendorPortalController.SupplierSnapshot snap = VendorPortalController.getSupplierSnapshot(supplier.Id);
            System.assertEquals(supplier.Id, snap.accountId);
            System.assertEquals(1, snap.assessments.size(), 'FLS must let the persona read the checklist fields');
            System.assertNotEquals(null, VendorPortalController.getScreeningQueue());
            System.assertNotEquals(null, VendorPortalController.getCaseDocuments(supplier.Id));
            System.assertNotEquals(null, VendorPortalController.getAnalystQueue(true));
            System.assertNotEquals(null, VendorPortalController.getCaseForAnalyst(supplier.Id));
            System.assertNotEquals(null, DocumentProcessingController.getChecklistWithDocStatus(supplier.Id));
            System.assertNotEquals(null, PolicyDocumentController.getPolicyDocuments());
            System.assertNotEquals(null, AuditReportController.getAuditReport('{}'));
            System.assertNotEquals(null, IntelligenceDashboardController.getComplianceFunnel());
            System.assertNotEquals(null, IntelligenceDashboardController.getSupplierAlerts());
            System.assertNotEquals(null, SupplierRiskDashboardController.getSupplierSnapshot(supplier.Id));
            System.assertNotEquals(null, SubSupplierController.getSubSuppliers(supplier.Id));
            System.assertNotEquals(null, SubSupplierController.getRequirementsForParent(supplier.Id));
            // A write path with a stripInaccessible'd DML + audit sink.
            VendorPortalController.saveDecision(supplier.Id, 'LOW', 'Auto-approve', 'crud-test');
            Test.stopTest();
        }
        System.assertEquals('Low', [SELECT Risk_Tier__c FROM Account WHERE Id = :supplier.Id].Risk_Tier__c);
    }

    // ── 2. Licensed user without the grants is refused ────────────────────
    @IsTest
    static void userWithoutPersonaGrantsIsRefused() {
        User admin = new User(Id = UserInfo.getUserId());
        User noPerms;
        System.runAs(admin) { noPerms = makeUser('crudnp'); }
        Account supplier = makeSupplier('CRUD Blocked Supplier', null);

        System.runAs(noPerms) {
            Boolean blocked = false;
            try { VendorPortalController.getSupplierSnapshot(supplier.Id); }
            catch (AuraHandledException e) { blocked = true; }
            System.assert(blocked, 'getSupplierSnapshot must refuse a user with no access to the checklist objects');

            blocked = false;
            try { PolicyDocumentController.getPolicyDocuments(); }
            catch (AuraHandledException e) { blocked = true; }
            System.assert(blocked, 'getPolicyDocuments must refuse a user with no Policy_Document__c access');

            blocked = false;
            try { DocumentProcessingController.linkDocumentToCompliance(supplier.Id, null, 'X', null, 'f'); }
            catch (AuraHandledException e) { blocked = true; }
            System.assert(blocked, 'linkDocumentToCompliance must refuse before touching any record');

            blocked = false;
            try { SubSupplierController.getSubSuppliers(supplier.Id); }
            catch (AuraHandledException e) { blocked = true; }
            System.assert(blocked, 'getSubSuppliers must refuse a user with no checklist access');
        }
    }

    // ── 3. Guest: token path works, direct entry refused ──────────────────
    @IsTest
    static void guestTokenPathWorksAndDirectEntryIsRefused() {
        List<User> guests = [
            SELECT Id FROM User
            WHERE  Profile.UserType = 'Guest' AND Profile.Name = 'Supplier Portal Profile' AND IsActive = true
            LIMIT  1
        ];
        if (guests.isEmpty()) return; // portal site not present in this org (e.g. a scratch org)

        String token = 'crud-test-' + String.valueOf(System.currentTimeMillis());
        Account supplier = makeSupplier('CRUD Guest Supplier', token);

        System.runAs(guests[0]) {
            Test.startTest();
            System.assertEquals(false, Schema.sObjectType.Account.isAccessible(),
                'precondition: the guest user holds no Account permission');

            VendorPortalController.SupplierSnapshot snap = VendorPortalController.getSupplierSnapshotByToken(token);
            System.assertEquals(supplier.Id, snap.accountId, 'the token path must keep working for the guest');
            System.assertNotEquals(null, SubSupplierController.getSubSuppliersByToken(token));
            System.assertNotEquals(null, SubSupplierController.getRequirementsForParentByToken(token));

            Boolean blocked = false;
            try { VendorPortalController.getSupplierSnapshot(supplier.Id); }
            catch (AuraHandledException e) { blocked = true; }
            System.assert(blocked, 'a guest calling the non-token entry point directly must be refused');

            blocked = false;
            try { SubSupplierController.getSubSuppliers(supplier.Id); }
            catch (AuraHandledException e) { blocked = true; }
            System.assert(blocked, 'a guest calling getSubSuppliers with a raw Id must be refused');
            Test.stopTest();
        }
    }

    // ── 4. Audit sink is system-context by design ─────────────────────────
    @IsTest
    static void auditSinkWritesRegardlessOfCallerPermissions() {
        User admin = new User(Id = UserInfo.getUserId());
        User noPerms;
        System.runAs(admin) { noPerms = makeUser('crudal'); }

        System.runAs(noPerms) {
            System.assertEquals(false, Schema.sObjectType.Audit_Log__c.isCreateable(),
                'precondition: the caller must NOT hold Create on Audit_Log__c');
            AuditLogService.write(new Audit_Log__c(
                Event_Type__c     = 'Status_Changed',
                Related_Object__c = 'Supplier',
                Event_DateTime__c = DateTime.now(),
                Actor_Type__c     = 'User',
                Source_System__c  = 'Other',
                New_Value__c      = 'crud-enforcement-test'
            ));
        }
        // Tests never see org data, so the only Audit_Log__c row in this
        // transaction is the one written above.
        System.assertEquals(1, [SELECT COUNT() FROM Audit_Log__c],
            'the audit row must be recorded even though the actor cannot create Audit_Log__c');
    }
}
