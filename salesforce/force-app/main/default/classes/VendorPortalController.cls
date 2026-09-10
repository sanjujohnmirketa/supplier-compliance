/**
 * VendorPortalController
 * ═══════════════════════════════════════════════════════════════════════════
 * CRUD/FLS model (AppExchange security review):
 *
 *  • Internal entry points (@AuraEnabled methods called by the Procurement,
 *    Analyst and Vendor consoles) check the running user's object permissions
 *    with literal Schema.sObjectType.X.isAccessible/isCreateable/isUpdateable/
 *    isDeletable guards before any SOQL/DML, and route fire-and-forget writes
 *    through Security.stripInaccessible so field-level security is enforced
 *    too. Audit rows are written only via AuditLogService (system context by
 *    design — see that class).
 *
 *  • without sharing is deliberate and retained: Account OWD is Private and
 *    every custom object is ControlledByParent, but the Procurement and
 *    Analyst queues must show cases owned by other users. WITH USER_MODE
 *    would also enforce record sharing and silently hide those cases, so it
 *    is only used on custom-metadata queries (which have no sharing).
 *
 *  • Guest-portal paths (*ByToken methods) are the documented exception: the
 *    Experience Cloud guest user holds NO object permissions by design — the
 *    supplier's durable portal token IS the authorization, re-verified on
 *    every call by verifyPortalTokenId(). Those wrappers delegate to private
 *    *Impl methods that run in system context. The internal entry points
 *    share the same *Impl after passing their guards, so a guest calling an
 *    internal entry point directly now fails the guard (closing the
 *    direct-call path) while the token path keeps working. The *Impl,
 *    verifyPortalTokenId, documentBelongsToSupplier and
 *    generateSupplierPortalUrl SOQL/DML sites are therefore intentionally
 *    unchecked and are listed in the review's false-positive document.
 */
public without sharing class VendorPortalController {

    private static final String NO_ACCESS =
        'You do not have permission to perform this action.';

    // ═════════════════════════════════════════════════════════════════════════
    // DTOs returned to the intake LWC
    // ═════════════════════════════════════════════════════════════════════════
    public class ChecklistResult {
        @AuraEnabled public String  riskTier;
        @AuraEnabled public String  riskSummary;
        @AuraEnabled public String  source;               // 'existing' (reused) | 'ai'
        @AuraEnabled public String  recommendedHitl;       // AI-set HITL threshold (read-only in UI)
        @AuraEnabled public List<String> domains;          // domain KEYS that were triggered
        @AuraEnabled public List<ChecklistItemDTO> items;  // required documents
        @AuraEnabled public List<String> riskReasons;      // why this tier (bullets)
        @AuraEnabled public List<String> notes;            // e.g. no-policy-match explanation
        @AuraEnabled public Boolean noPolicyMatch;         // true → only baseline applied
    }

    // AI-recommended human-in-the-loop threshold from the detected risk tier:
    // High/Critical suppliers get a tighter (Low) review threshold so anything
    // above Low routes to an analyst; otherwise Medium. Set by the backend,
    // shown read-only — the procurement user does not pick it.
    @TestVisible
    static String recommendHitl(String riskTier) {
        return (riskTier == 'High' || riskTier == 'Critical') ? 'Low' : 'Medium';
    }
    public class ChecklistItemDTO {
        @AuraEnabled public String document;
        @AuraEnabled public String domain;
        @AuraEnabled public String clauseId;
        @AuraEnabled public String justification;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Generate Checklist — synchronous /scope callout (no record created yet).
    // The procurement user previews the AI-detected domains + required documents
    // before committing the supplier. Throws the exact backend error so the LWC
    // can surface it (e.g. local service down / tunnel stale).
    // ═════════════════════════════════════════════════════════════════════════
    // materialType / serviceCategory are optional fine-tuning inputs (requested by
    // procurement: sharpen domain selection beyond the industry/engagement blend
    // alone). NOT an overload — LWC's generated Apex proxy binds to one method
    // name and overload resolution by parameter count is unreliable there,  so the
    // existing signature is extended directly. Pass null/blank from any existing
    // caller for identical behavior to before these params existed.
    @AuraEnabled
    public static ChecklistResult generateChecklist(
        String supplierName,
        String country,
        String industry,
        String engagementType,
        String annualSpend,
        String requestedBy,
        String supplierEmail,
        String materialType,
        String serviceCategory
    ) {
        // All intake fields are required — partial context makes /scope retrieval
        // non-deterministic (different docs/domains for sparse input).
        List<String> missing = new List<String>();
        if (String.isBlank(supplierName))   missing.add('Legal entity name');
        if (String.isBlank(country))        missing.add('Country / HQ');
        if (String.isBlank(requestedBy))    missing.add('Requested by');
        if (String.isBlank(industry))       missing.add('Industry');
        if (String.isBlank(engagementType)) missing.add('Engagement type');
        if (String.isBlank(annualSpend))    missing.add('Annual spend');
        if (String.isBlank(supplierEmail))  missing.add('Supplier contact email');
        if (!missing.isEmpty()) {
            throw new AuraHandledException(
                'Complete all fields before generating the checklist: ' + String.join(missing, ', ') + '.');
        }

        // NOTE: generateChecklist is a live PREVIEW. It always (re)generates from
        // the CURRENT inputs — country/industry/engagement/spend — so changing any
        // of them re-runs /scope and the checklist reflects the change. (The old
        // name-only reuse cache was removed: it returned a stale checklist whenever
        // a supplier with the same name existed, ignoring the new inputs.)
        ScopeService.ScopeRequest req = new ScopeService.ScopeRequest();
        req.supplierId = 'PREVIEW';                 // not persisted yet
        req.legalName  = supplierName.trim();
        req.country    = country;
        // Enrich the retrieval context so engagement type + spend actually carry
        // weight in /scope (otherwise only Industry reaches the embedding query).
        req.commodity  = buildScopeContext(industry, engagementType, annualSpend);
        req.jurisdictions = new List<String>();
        if (String.isNotBlank(country)) req.jurisdictions.add(country);
        // Optional fine-tuning inputs — additive, sharpen the same query rather
        // than replacing the industry/engagement blend above.
        if (String.isNotBlank(materialType))     req.materialType    = materialType;
        if (String.isNotBlank(serviceCategory))  req.serviceCategory = serviceCategory;
        req.materialDomains = resolveMaterialDomains(materialType, serviceCategory);

        ScopeService.ScopeResponse resp;
        try {
            resp = ScopeService.getScope(req);
        } catch (Exception e) {
            // Surface the precise backend failure (matches the no-silent-failure rule)
            throw new AuraHandledException('Checklist generation failed: ' + e.getMessage());
        }

        ChecklistResult out = new ChecklistResult();
        out.source      = 'ai';
        out.riskTier    = resp.riskTier;
        out.recommendedHitl = recommendHitl(resp.riskTier);
        out.riskSummary = resp.riskSummary;
        out.riskReasons = (resp.riskReasons != null) ? resp.riskReasons : new List<String>();
        out.notes       = (resp.notes != null) ? resp.notes : new List<String>();
        out.noPolicyMatch = (resp.noPolicyMatch == true);
        out.items       = new List<ChecklistItemDTO>();
        Set<String> domains = new Set<String>();

        if (resp.checklist != null) {
            for (ScopeService.ChecklistItem item : resp.checklist) {
                ChecklistItemDTO d = new ChecklistItemDTO();
                d.document      = item.document;
                d.domain        = item.domain;
                d.clauseId      = item.justificationClauseId;
                d.justification = item.justification;
                out.items.add(d);
                if (String.isNotBlank(item.domain)) domains.add(item.domain);
            }
        }
        out.domains = new List<String>(domains);
        return out;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Request to supplier — persist the supplier (with contact email) and email
    // the required-document list to the supplier contact.
    // ═════════════════════════════════════════════════════════════════════════
    @AuraEnabled
    public static String requestDocumentsFromSupplier(
        String accountId,
        String supplierName,
        String country,
        String requestedBy,
        String industry,
        String engagementType,
        String annualSpend,
        String riskDomains,
        String supplierEmail,
        String hitlThreshold,
        List<String> documents,
        String materialType,
        String serviceCategory
    ) {
        if (String.isBlank(supplierName)) {
            throw new AuraHandledException('Supplier legal entity name is required.');
        }
        if (String.isBlank(supplierEmail) || !Pattern.matches('^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$', supplierEmail)) {
            throw new AuraHandledException('A valid supplier contact email is required to send the request.');
        }
        if (documents == null || documents.isEmpty()) {
            throw new AuraHandledException('Generate the checklist before requesting documents.');
        }
        if (!Schema.sObjectType.Account.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }

        // DEDUP: reuse an existing supplier (by name + email) so re-requesting
        // documents doesn't spawn a duplicate account.
        if (String.isBlank(accountId)) {
            String nm = supplierName.trim();
            List<Account> dupes = [SELECT Id FROM Account
                WHERE RecordType.DeveloperName = 'Supplier' AND Name = :nm
                  AND Supplier_Contact_Email__c = :supplierEmail
                ORDER BY CreatedDate DESC LIMIT 1];
            if (!dupes.isEmpty()) accountId = dupes[0].Id;
        }
        // Persist the supplier so the request is tied to a record.
        // checklistCurated=true: `documents` is the Procurement user's post-edit
        // checklist — written verbatim below instead of letting the trigger-fired
        // ScopeCalloutQueueable re-derive (and potentially resurrect removed
        // items) from /scope.
        String accId = upsertSupplier(
            accountId, supplierName, country, requestedBy,
            industry, engagementType, annualSpend, riskDomains,
            supplierEmail, hitlThreshold, 'In Review',
            materialType, serviceCategory, true
        );
        persistCuratedChecklist(accId, documents);

        sendDocumentRequestEmail(accId, supplierName, supplierEmail, documents);
        return accId;
    }

    // Persists the Procurement user's already-curated document list (post
    // add/remove edits on the P1 preview) as the supplier's ACTUAL checklist —
    // the same Compliance_Assessment__c shape ScopeCalloutQueueable creates,
    // so the portal/analyst/procurement screens render it identically. Called
    // instead of relying on the trigger-fired /scope re-derivation, which has
    // no idea what the user removed (see Checklist_Seeded_By_Caller__c).
    // Idempotent via upsert on Requirement_Key__c, same as ScopeCalloutQueueable,
    // so re-submitting an existing supplier with an edited list updates cleanly
    // rather than duplicating rows.
    private static void persistCuratedChecklist(Id accId, List<String> documents) {
        if (accId == null || documents == null || documents.isEmpty()) return;
        if (!Schema.sObjectType.Compliance_Assessment__c.isCreateable()
                || !Schema.sObjectType.Compliance_Assessment__c.isUpdateable()
                || !Schema.sObjectType.Account.isAccessible()
                || !Schema.sObjectType.Account.isUpdateable()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        // TEMP DIAGNOSTIC (investigating a report of items silently dropped
        // between P1 preview and the persisted checklist) — captures the exact
        // list this method received and every per-record upsert outcome, since
        // Database.upsert's return value was previously discarded entirely, so
        // a partial failure (allOrNone=false) had zero visibility anywhere.
        // Remove once the live repro confirms/rules out a DML-level cause.
        System.debug(LoggingLevel.ERROR, '[persistCuratedChecklist] accId=' + accId
            + ' received ' + documents.size() + ' document(s): ' + JSON.serialize(documents));
        List<Compliance_Assessment__c> toUpsert = new List<Compliance_Assessment__c>();
        List<String> labelsInOrder = new List<String>();
        Set<String> keysUsedThisBatch = new Set<String>();
        for (String label : documents) {
            if (String.isBlank(label)) continue;
            // Requirement_Key__c is the upsert external ID (255-char field) — two
            // labels sharing a long common prefix used to collide on the old
            // 60-char-prefix-only key and silently overwrite each other via
            // upsert. Slug the full label (not just the first 60 chars) and,
            // since normalization can still collide two DIFFERENT labels onto
            // the same slug, disambiguate with a running counter whenever a key
            // repeats within this same batch.
            String baseKey = ((String) accId) + '__SCOPE_'
                + label.trim().toUpperCase().replaceAll('[^A-Z0-9]', '_').left(200);
            String key = baseKey;
            Integer dupSuffix = 2;
            while (keysUsedThisBatch.contains(key)) {
                key = baseKey.left(250) + '_' + dupSuffix;
                dupSuffix++;
            }
            keysUsedThisBatch.add(key);
            toUpsert.add(new Compliance_Assessment__c(
                Name                   = abbreviateLabel(label, 'Requirement', 80),
                Supplier__c            = accId,
                Requirement_Key__c     = key,
                Requirement_Label__c   = label.trim(),
                Status__c              = 'Pending',
                Severity__c            = 'Medium',
                Evaluated_By__c        = 'Auto',
                Evaluation_DateTime__c = DateTime.now(),
                Reason_Code__c         = 'Missing Document'
            ));
            labelsInOrder.add(label.trim());
        }
        if (!toUpsert.isEmpty()) {
            Database.UpsertResult[] results =
                Database.upsert(toUpsert, Compliance_Assessment__c.Requirement_Key__c, false);
            for (Integer i = 0; i < results.size(); i++) {
                Database.UpsertResult r = results[i];
                if (!r.isSuccess()) {
                    String errMsg = '';
                    for (Database.Error e : r.getErrors()) errMsg += e.getStatusCode() + ': ' + e.getMessage() + '; ';
                    System.debug(LoggingLevel.ERROR, '[persistCuratedChecklist] FAILED for "'
                        + labelsInOrder[i] + '": ' + errMsg);
                    AuditLogService.write(new Audit_Log__c(
                        Event_Type__c        = 'Integration_Error',
                        Related_Object__c    = 'Supplier',
                        Related_Record_Id__c = accId,
                        Event_DateTime__c    = DateTime.now(),
                        Actor_Type__c        = 'System',
                        Source_System__c     = 'Salesforce',
                        New_Value__c         = '[persistCuratedChecklist] Checklist item "' + labelsInOrder[i]
                            + '" failed to save: ' + errMsg
                    ));
                }
            }
        }

        // Freeze N (checklist size) for RiskScoreService's per-document scoring
        // — same rule as ScopeCalloutQueueable's own Checklist_Item_Count__c
        // write: only set once, on the checklist's first generation, so a
        // later edit (add/remove a document) doesn't silently reweight every
        // already-scored document.
        List<Account> accForCount = [SELECT Id, Checklist_Item_Count__c FROM Account WHERE Id = :accId LIMIT 1];
        if (!accForCount.isEmpty() && accForCount[0].Checklist_Item_Count__c == null && !labelsInOrder.isEmpty()) {
            update Security.stripInaccessible(AccessType.UPDATABLE, new List<Account>{
                new Account(Id = accId, Checklist_Item_Count__c = labelsInOrder.size())
            }).getRecords();
        }
    }

    private static String abbreviateLabel(String value, String fallback, Integer max) {
        if (String.isBlank(value)) return fallback;
        return value.length() > max ? value.left(max) : value;
    }

    // Shared by requestDocumentsFromSupplier and submitAndScreen — one place that
    // generates the portal link, sends the checklist email, and audits the
    // request, so both entry points behave identically instead of duplicating
    // (and risking drifting) the same logic.
    private static void sendDocumentRequestEmail(
        String accId, String supplierName, String supplierEmail, List<String> documents
    ) {
        // Generate a personal portal URL for this supplier (stable: same token on re-send).
        String portalUrl = null;
        try { portalUrl = generateSupplierPortalUrl(accId); }
        catch (Exception e) { System.debug(LoggingLevel.WARN, 'Portal URL generation failed for ' + accId + ': ' + e.getMessage()); }

        Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
        msg.setToAddresses(new List<String>{ supplierEmail });
        msg.setSubject('Required compliance documents — ' + supplierName + ' onboarding');
        msg.setPlainTextBody(buildRequestBody(supplierName, documents, portalUrl));
        msg.setSaveAsActivity(false);

        // Send as the org's Supplier Compliance Team identity, not the running
        // user — without this, Salesforce defaults the sender to whoever clicked
        // "Email supplier" (matches the pattern already used by the sub-supplier
        // invite email in SubSupplierController.cls).
        if (!Schema.sObjectType.OrgWideEmailAddress.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        List<OrgWideEmailAddress> orgEmails = [SELECT Id FROM OrgWideEmailAddress LIMIT 1];
        if (!orgEmails.isEmpty()) msg.setOrgWideEmailAddressId(orgEmails[0].Id);

        Messaging.SendEmailResult[] results =
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ msg }, false);

        if (results != null && !results.isEmpty() && !results[0].isSuccess()) {
            String err = results[0].getErrors().isEmpty()
                ? 'Unknown error' : results[0].getErrors()[0].getMessage();
            throw new AuraHandledException('Email send failed: ' + err);
        }

        AuditLogService.write(new Audit_Log__c(
            Event_Type__c        = 'Status_Changed',
            Related_Object__c    = 'Supplier',
            Related_Record_Id__c = accId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'User',
            Source_System__c     = 'Other',
            New_Value__c         = 'Requested ' + documents.size()
                + ' document(s) from ' + supplierEmail
        ));
    }

    // Resends the document-request email (with the supplier's portal link) for
    // an EXISTING supplier, without touching any other field — reuses the same
    // sendDocumentRequestEmail helper requestDocumentsFromSupplier/submitAndScreen
    // already call, so the email/template/portal-link logic is never duplicated.
    // The checklist is read fresh from the supplier's current, persisted
    // requirements (not re-submitted), so this reflects whatever Procurement
    // has added/removed since the original request.
    @AuraEnabled
    public static void resendDocumentRequestEmail(Id accountId) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        if (!Schema.sObjectType.Account.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        Account a = [SELECT Id, Name, Supplier_Contact_Email__c FROM Account WHERE Id = :accountId LIMIT 1];
        if (String.isBlank(a.Supplier_Contact_Email__c)) {
            throw new AuraHandledException('This supplier has no contact email on file — use Edit to add one first.');
        }
        List<String> documents = new List<String>();
        for (Compliance_Assessment__c x : [
            SELECT Requirement_Label__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :accountId
            AND    Requirement_Label__c != null
            AND    (NOT Requirement_Label__c LIKE 'Screening — %')
            AND    (NOT Requirement_Label__c LIKE '%Manual verification%')
            ORDER BY Requirement_Label__c
        ]) {
            documents.add(x.Requirement_Label__c);
        }
        if (documents.isEmpty()) {
            throw new AuraHandledException('This supplier has no checklist items to request yet.');
        }
        sendDocumentRequestEmail(accountId, a.Name, a.Supplier_Contact_Email__c, documents);
    }

    private static String buildRequestBody(String supplierName, List<String> documents) {
        return buildRequestBody(supplierName, documents, null);
    }

    private static String buildRequestBody(String supplierName, List<String> documents, String portalUrl) {
        String body = 'Hello,\n\n'
            + 'As part of onboarding ' + supplierName + ' as an approved supplier, '
            + 'please provide the following compliance documents:\n\n';
        Integer i = 1;
        for (String doc : documents) {
            body += '  ' + i + '. ' + doc + '\n';
            i++;
        }
        if (String.isNotBlank(portalUrl)) {
            body += '\nUpload your documents directly via your personal supplier portal:\n'
                 + portalUrl + '\n'
                 + '\nThe portal shows your required checklist, upload status, and compliance results in real time.\n';
        } else {
            body += '\nPlease reply to this email with the documents attached, or upload them '
                 + 'via the supplier portal link provided by your procurement contact.\n';
        }
        body += '\nThank you,\nSupplier Compliance Team';
        return body;
    }

    // Build a richer commodity/context string for /scope retrieval so engagement
    // type and annual spend influence which policy domains are grounded.
    private static String buildScopeContext(String industry, String engagementType, String annualSpend) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(industry))       parts.add(industry);
        if (String.isNotBlank(engagementType)) parts.add('engagement: ' + engagementType);
        if (String.isNotBlank(annualSpend)) {
            String cleaned = annualSpend.replaceAll('[^0-9.]', '');
            parts.add('annual spend ' + (String.isNotBlank(cleaned) ? cleaned : annualSpend) + ' USD');
        }
        return String.join(parts, '; ');
    }

    private static String domainFromKey(String key) {
        if (String.isBlank(key)) return null;
        Integer i = key.indexOf('__SCOPE_');
        return i >= 0 ? key.substring(i + 8) : null;
    }

    // Resolves the selected material type / service category to their guaranteed
    // compliance domains via Material_Type__mdt (MaterialTypeController's catalog)
    // — sent to /scope as ScopeRequest.materialDomains so the engine no longer
    // needs its own hardcoded material-to-domain dict. A new Custom Metadata
    // record (any industry's material) takes effect here with no code change.
    // Public: also called by ScopeCalloutQueueable so the trigger-seeded checklist
    // resolves domains identically to this screen's live preview.
    public static List<String> resolveMaterialDomains(String materialType, String serviceCategory) {
        Set<String> domains = new Set<String>();
        if (String.isBlank(materialType) && String.isBlank(serviceCategory)) {
            return new List<String>();
        }
        // Custom metadata has no CRUD/sharing model (WITH USER_MODE is rejected
        // at runtime for it); the describe check is the applicable guard.
        if (!Schema.sObjectType.Material_Type__mdt.isAccessible()) throw new AuraHandledException(NO_ACCESS);
        for (Material_Type__mdt m : [
            SELECT Domains__c
            FROM   Material_Type__mdt
            WHERE  Active__c = true
              AND  Value_Key__c IN :new List<String>{
                       String.isNotBlank(materialType)    ? materialType    : '',
                       String.isNotBlank(serviceCategory) ? serviceCategory : ''
                   }
        ]) {
            if (String.isNotBlank(m.Domains__c)) {
                for (String d : m.Domains__c.split(',')) {
                    String trimmed = d.trim();
                    if (String.isNotBlank(trimmed)) domains.add(trimmed);
                }
            }
        }
        return new List<String>(domains);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Source documents (Screen 3) — files uploaded against the supplier, for the
    // inline document viewer.
    // ═════════════════════════════════════════════════════════════════════════
    public class CaseDocument {
        @AuraEnabled public String versionId;
        @AuraEnabled public String contentDocumentId;   // for remove
        @AuraEnabled public String title;
        @AuraEnabled public String fileType;
        @AuraEnabled public String previewUrl;
        @AuraEnabled public String createdLabel;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Run screening (Screen 3) — live registry due diligence via /verify
    // (GLEIF identity + OpenSanctions sanctions/PEP + conflict-minerals gate).
    // ═════════════════════════════════════════════════════════════════════════
    // Plain helper (NO AuraHandledException) so other server-side methods can
    // reuse it without nesting Aura-only exceptions (which blow up off-Aura).
    private static ScreeningService.VerifyResponse doScreen(Id accountId) {
        // Plain NoAccessException on purpose (no AuraHandledException here —
        // see the note above); both callers wrap and re-throw it.
        if (!Schema.sObjectType.Account.isAccessible()) throw new NoAccessException();
        Account a = [
            SELECT Name, Industry, BillingCountry, Country_of_Origin__c, Risk_Domains__c
            FROM   Account WHERE Id = :accountId LIMIT 1
        ];
        ScreeningService.VerifyRequest req = new ScreeningService.VerifyRequest();
        req.legalName = a.Name;
        req.country   = String.isNotBlank(a.Country_of_Origin__c) ? a.Country_of_Origin__c : a.BillingCountry;
        req.commodity = a.Industry;
        req.domains   = new List<String>();
        if (String.isNotBlank(a.Risk_Domains__c)) {
            for (String d : a.Risk_Domains__c.split(',')) {
                String t = d.trim();
                if (String.isNotBlank(t)) req.domains.add(t);
            }
        }
        return ScreeningService.verify(req);
    }

    @AuraEnabled(cacheable=false)
    public static ScreeningService.VerifyResponse runScreening(Id accountId) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        try {
            return doScreen(accountId);
        } catch (Exception e) {
            throw new AuraHandledException('Screening failed: ' + e.getMessage());
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Run screening AND persist results — each /verify result becomes a
    // Compliance_Assessment__c row so it folds into the supplier's AI summary
    // (the same panel that shows document assessments) and survives refresh.
    // ═════════════════════════════════════════════════════════════════════════
    public class ScreeningRowDTO {
        @AuraEnabled public String label;       // authority / category
        @AuraEnabled public String status;      // mapped verdict
        @AuraEnabled public String detail;      // summary text
        @AuraEnabled public String badgeClass;  // ok | warn | bad | neutral
    }
    public class ScreeningPersistResult {
        @AuraEnabled public String signal;              // clear | review | flag
        @AuraEnabled public List<ScreeningRowDTO> results;
    }

    // Map a /verify result status → a compliance verdict + UI badge.
    private static String screenVerdict(String status) {
        String t = (status == null) ? '' : status.toLowerCase();
        if (t == 'flag')      return 'Non-Compliant';
        if (t == 'review')    return 'Needs Analyst';
        if (t == 'verified' || t == 'clear') return 'Compliant';
        if (t == 'notconfigured' || t == 'notfound') return 'Needs Analyst';
        return 'Needs Analyst';
    }

    @AuraEnabled
    public static ScreeningPersistResult runScreeningAndPersist(Id accountId) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        if (!Schema.sObjectType.Compliance_Assessment__c.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isCreateable()
                || !Schema.sObjectType.Compliance_Assessment__c.isDeletable()) {
            throw new AuraHandledException(NO_ACCESS);
        }

        ScreeningService.VerifyResponse resp;
        try {
            resp = doScreen(accountId);   // plain helper — no nested AuraHandledException
        } catch (Exception e) {
            throw new AuraHandledException('Screening failed: ' + e.getMessage());
        }

        ScreeningPersistResult out = new ScreeningPersistResult();
        out.signal  = (resp == null) ? null : resp.signal;
        out.results = new List<ScreeningRowDTO>();

        List<Compliance_Assessment__c> toUpsert = new List<Compliance_Assessment__c>();
        // Collect the authorities that need MANUAL analyst verification (no public
        // API) so we can surface them as prose in the AI summary on handoff.
        List<String> manualChecks = new List<String>();
        if (resp != null && resp.results != null) {
            for (ScreeningService.VerifyResult r : resp.results) {
                String label   = String.isNotBlank(r.category) ? r.category
                                 : (String.isNotBlank(r.authority) ? r.authority : 'Screening');
                String verdict = screenVerdict(r.status);

                ScreeningRowDTO row = new ScreeningRowDTO();
                row.label      = label + (String.isNotBlank(r.authority) ? (' · ' + r.authority) : '');
                row.status     = verdict;
                row.detail     = r.summary;
                row.badgeClass = statusBadge(verdict);
                out.results.add(row);

                // A NotConfigured / Review status = no automatable source → the
                // analyst must verify on the named portal. Record it for the note.
                String st = (r.status == null) ? '' : r.status.toLowerCase();
                if (st == 'notconfigured' || st == 'review' || st == 'notfound') {
                    String auth = String.isNotBlank(r.authority) ? r.authority : label;
                    manualChecks.add(label + ' (' + auth + ')');
                }

                // Requirement_Key__c is UNIQUE across the whole object, so the
                // key must be scoped per-supplier (account id suffix) or two
                // suppliers' 'SCREEN_SANCTIONS' rows would collide.
                String acc15 = String.valueOf(accountId).right(12);
                Compliance_Assessment__c ca = new Compliance_Assessment__c();
                ca.Supplier__c         = accountId;
                ca.Requirement_Key__c  = 'SCREEN_' + label.toUpperCase().replaceAll('[^A-Z0-9]', '_') + '_' + acc15;
                ca.Requirement_Label__c = 'Screening — ' + label;
                ca.Status__c           = verdict;
                ca.Severity__c         = (verdict == 'Non-Compliant') ? 'High'
                                         : (verdict == 'Needs Analyst' ? 'Medium' : 'Low');
                // Clean prose only — the Status__c badge already conveys the verdict,
                // so we don't prepend an ugly "[Screening · NotConfigured]" tag.
                ca.Reason_Detail__c    = String.isBlank(r.summary)
                                         ? 'No detail returned by the screening source.'
                                         : r.summary.trim();
                ca.Evaluation_DateTime__c = System.now();
                toUpsert.add(ca);
            }
        }

        // Add a "Manual verification required" summary row, written as prose, that
        // tells the analyst which governing-body portals must be checked by hand
        // (no public API). This rides along into the AI summary on handoff.
        if (!manualChecks.isEmpty()) {
            String prose = 'These checks have no automatable public API and must be '
                + 'verified manually on the issuing authority\'s portal before sign-off: '
                + String.join(manualChecks, '; ') + '.';
            ScreeningRowDTO mrow = new ScreeningRowDTO();
            mrow.label = 'Manual verification required';
            mrow.status = 'Needs Analyst';
            mrow.detail = prose;
            mrow.badgeClass = 'warn';
            out.results.add(mrow);

            Compliance_Assessment__c mca = new Compliance_Assessment__c();
            mca.Supplier__c          = accountId;
            mca.Requirement_Key__c   = 'SCREEN_MANUAL_CHECKS_' + String.valueOf(accountId).right(12);
            mca.Requirement_Label__c = 'Screening — Manual verification required';
            mca.Status__c            = 'Needs Analyst';
            mca.Severity__c          = 'Medium';
            mca.Reason_Detail__c     = prose;
            mca.Evaluation_DateTime__c = System.now();
            toUpsert.add(mca);
        }

        // Re-screening refreshes the same rows: delete prior screening rows then
        // insert. Filter in Apex (underscore is a LIKE wildcard, so we match the
        // 'SCREEN' prefix in SOQL and confirm the 'SCREEN_' prefix in Apex).
        if (!toUpsert.isEmpty()) {
            List<Compliance_Assessment__c> priorScreening = new List<Compliance_Assessment__c>();
            for (Compliance_Assessment__c ex : [
                SELECT Id, Requirement_Key__c FROM Compliance_Assessment__c
                WHERE Supplier__c = :accountId AND Requirement_Key__c LIKE 'SCREEN%'
            ]) {
                if (ex.Requirement_Key__c != null && ex.Requirement_Key__c.startsWith('SCREEN_')) {
                    priorScreening.add(ex);
                }
            }
            if (!priorScreening.isEmpty()) delete priorScreening;
            insert Security.stripInaccessible(AccessType.CREATABLE, toUpsert).getRecords();
        }
        return out;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Co-pilot Q&A — grounded chat over the case (findings + screening + policy)
    // ═════════════════════════════════════════════════════════════════════════
    @AuraEnabled
    public static CopilotService.CopilotResponse askCopilot(Id accountId, String question) {
        if (accountId == null || String.isBlank(question)) {
            throw new AuraHandledException('A supplier and a question are required.');
        }
        if (!Schema.sObjectType.Account.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        Account a = [SELECT Name, Industry, Industry__c FROM Account WHERE Id = :accountId LIMIT 1];
        // Ground the answer in the supplier's assessment state, but SEPARATE
        // "documents actually uploaded" from "checklist items still missing", so
        // the co-pilot doesn't report un-uploaded checklist rows as shared files.
        List<String> uploaded = new List<String>();
        List<String> missing  = new List<String>();
        List<String> screening = new List<String>();
        for (Compliance_Assessment__c x : [
            SELECT Requirement_Label__c, Status__c, Severity__c, Reason_Detail__c,
                   Compliance_Document__c, Requirement_Key__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :accountId
            ORDER BY Requirement_Label__c
            LIMIT  80
        ]) {
            String label = x.Requirement_Label__c;
            String st = String.isBlank(x.Status__c) ? 'Pending' : x.Status__c;
            String detail = String.isNotBlank(x.Reason_Detail__c) ? (' — ' + x.Reason_Detail__c.left(180)) : '';
            Boolean isScreening = (x.Requirement_Key__c != null && x.Requirement_Key__c.startsWith('SCREEN_'));
            if (isScreening) {
                screening.add('- ' + label + ': ' + st + detail);
            } else if (x.Compliance_Document__c != null) {
                // A document WAS uploaded for this requirement.
                uploaded.add('- ' + label + ' [' + st + ']' + detail);
            } else {
                // Checklist item with NO document uploaded yet.
                missing.add('- ' + label);
            }
        }
        List<String> ctx = new List<String>();
        ctx.add('DOCUMENTS UPLOADED BY SUPPLIER (' + uploaded.size() + '):');
        ctx.add(uploaded.isEmpty() ? '(none uploaded yet)' : String.join(uploaded, '\n'));
        ctx.add('\nREQUIRED DOCUMENTS STILL MISSING / NOT UPLOADED (' + missing.size() + '):');
        ctx.add(missing.isEmpty() ? '(none — all required documents received)' : String.join(missing, '\n'));
        if (!screening.isEmpty()) {
            ctx.add('\nSCREENING RESULTS:');
            ctx.add(String.join(screening, '\n'));
        }
        String context = String.join(ctx, '\n');
        if (context.length() > 6000) context = context.left(6000);
        String industry = String.isNotBlank(a.Industry) ? a.Industry : a.Industry__c;
        try {
            return CopilotService.ask(question, a.Name, context, null, null, industry);
        } catch (Exception e) {
            throw new AuraHandledException('Co-pilot failed: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=false)
    public static List<CaseDocument> getCaseDocuments(Id accountId) {
        if (!Schema.sObjectType.ContentDocumentLink.isAccessible()
                || !Schema.sObjectType.ContentVersion.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        return getCaseDocumentsImpl(accountId);
    }

    // Shared with the token-verified guest path (getSupplierSnapshotImpl) —
    // system context by design, guarded by the caller; see the class header.
    @SuppressWarnings('PMD.ApexCRUDViolation') // guest token path — see class header
    private static List<CaseDocument> getCaseDocumentsImpl(Id accountId) {
        List<CaseDocument> out = new List<CaseDocument>();
        if (accountId == null) return out;
        Set<Id> cdIds = new Set<Id>();
        for (ContentDocumentLink l : [
            SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :accountId
        ]) {
            cdIds.add(l.ContentDocumentId);
        }
        if (cdIds.isEmpty()) return out;
        for (ContentVersion v : [
            SELECT Id, Title, FileType, CreatedDate, ContentDocumentId
            FROM   ContentVersion
            WHERE  ContentDocumentId IN :cdIds AND IsLatest = true
            ORDER BY CreatedDate DESC
            LIMIT  50
        ]) {
            CaseDocument f = new CaseDocument();
            f.versionId         = v.Id;
            f.contentDocumentId = v.ContentDocumentId;
            f.title             = v.Title;
            f.fileType          = v.FileType;
            f.previewUrl        = '/sfc/servlet.shepherd/version/download/' + v.Id;
            f.createdLabel      = v.CreatedDate.format('MMM d, h:mm a');
            out.add(f);
        }
        return out;
    }

    // Remove an uploaded document from a supplier (Procurement). Deletes the
    // ContentDocument (file + all links) and clears any assessment row that
    // pointed at it, so the checklist item returns to "not uploaded".
    @AuraEnabled
    public static void removeSupplierDocument(Id accountId, Id contentDocumentId) {
        if (!Schema.sObjectType.ContentDocumentLink.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isUpdateable()
                || !Schema.sObjectType.ContentDocument.isDeletable()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        removeSupplierDocumentImpl(accountId, contentDocumentId);
    }

    // Shared with removeSupplierDocumentByToken (guest: token-verified and
    // ownership-checked first) — system context by design, see class header.
    @SuppressWarnings('PMD.ApexCRUDViolation') // guest token path — see class header
    private static void removeSupplierDocumentImpl(Id accountId, Id contentDocumentId) {
        if (contentDocumentId == null) throw new AuraHandledException('No document selected.');
        // Clear assessment rows that referenced this file (via its Compliance_Document__c).
        Set<Id> compDocIds = new Set<Id>();
        for (ContentDocumentLink l : [
            SELECT LinkedEntityId FROM ContentDocumentLink WHERE ContentDocumentId = :contentDocumentId
        ]) {
            // Compliance_Document__c links (not the Account link) — reset their assessments.
            if (String.valueOf(l.LinkedEntityId).startsWith('a')) compDocIds.add(l.LinkedEntityId);
        }
        if (!compDocIds.isEmpty()) {
            List<Compliance_Assessment__c> toReset = [
                SELECT Id FROM Compliance_Assessment__c WHERE Compliance_Document__c IN :compDocIds
            ];
            for (Compliance_Assessment__c a : toReset) {
                a.Status__c        = 'Pending';
                a.Reason_Detail__c = 'Document removed — awaiting re-upload.';
                a.Compliance_Document__c = null;
            }
            if (!toReset.isEmpty()) update toReset;
        }
        // Delete the file itself (removes all CDLs with it).
        delete [SELECT Id FROM ContentDocument WHERE Id = :contentDocumentId];
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Promote an unmatched/rejected document into the checklist — the procurement
    // user decides a document the AI couldn't map is in fact relevant, so we
    // create a tracked requirement for it. It then flows forward into the
    // supplier snapshot, the submission summary, and the analyst handoff like any
    // other required document.
    // ═════════════════════════════════════════════════════════════════════════
    @AuraEnabled
    public static String addRequirementFromDocument(Id accountId, String documentTitle, String requirementKey) {
        if (!Schema.sObjectType.Compliance_Assessment__c.isCreateable()
                || !Schema.sObjectType.Compliance_Assessment__c.isUpdateable()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        return addRequirementFromDocumentImpl(accountId, documentTitle, requirementKey);
    }

    // Shared with addRequirementFromDocumentByToken (guest, token-verified) —
    // system context by design, see class header.
    @SuppressWarnings('PMD.ApexCRUDViolation') // guest token path — see class header
    private static String addRequirementFromDocumentImpl(Id accountId, String documentTitle, String requirementKey) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        if (String.isBlank(documentTitle)) throw new AuraHandledException('No document specified.');

        String label = documentTitle.trim();
        // Build a stable, unique requirement key (per supplier) so re-adding the
        // same document upserts rather than duplicating.
        String acc15 = String.valueOf(accountId).left(15);
        String key = (String.isNotBlank(requirementKey) && !requirementKey.startsWith('SCREEN_'))
            ? requirementKey
            : 'USERADD_' + label.toUpperCase().replaceAll('[^A-Z0-9]', '_').left(40) + '_' + acc15;

        Compliance_Assessment__c ca = new Compliance_Assessment__c();
        ca.Supplier__c          = accountId;
        ca.Requirement_Key__c   = key;
        ca.Requirement_Label__c = label;
        // Pending: a procurement-added requirement still needs AI/analyst validation.
        ca.Status__c            = 'Pending';
        ca.Severity__c          = 'Medium';
        ca.Reason_Detail__c     = 'Added to the checklist by Procurement — was not auto-matched to a required document. Pending validation.';
        ca.Evaluation_DateTime__c = System.now();
        upsert ca Requirement_Key__c;

        // Audit the human action so the trail shows who promoted the document.
        try {
            AuditLogService.logAssessmentChange(
                ca.Id, null,
                'Added "' + label + '" to the checklist',
                'Procurement promoted an unmatched document into the checklist',
                'Human');
        } catch (Exception ignored) { IntegrationErrorLogger.log(ca.Supplier__c, 'VendorPortalController', 'Audit_Log__c write failed (addRequirementFromDocument): ' + ignored.getMessage()); }

        return ca.Id;
    }

    // Removes a required document from a supplier's PERSISTED checklist
    // (post-submit — the Account record page's checklist, as opposed to the
    // pre-submit preview on the intake screen, which is edited purely as
    // local LWC state before anything is saved). This is a genuine delete —
    // if the requirement had an uploaded/linked document, that Compliance_
    // Document__c stays (the file itself isn't destroyed), only the
    // requirement tracking row goes away, so it stops appearing on the
    // supplier portal checklist immediately (getSupplierSnapshot's query is
    // simply narrower next time it runs).
    @AuraEnabled
    public static void removeChecklistRequirement(Id assessmentId) {
        if (assessmentId == null) throw new AuraHandledException('No checklist item selected.');
        if (!Schema.sObjectType.Compliance_Assessment__c.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isDeletable()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        Compliance_Assessment__c ca = [
            SELECT Id, Requirement_Label__c, Supplier__c
            FROM   Compliance_Assessment__c
            WHERE  Id = :assessmentId
            LIMIT  1
        ];
        assertNotHandedOff(ca.Supplier__c);

        try {
            AuditLogService.logAssessmentChange(
                ca.Id, ca.Requirement_Label__c, null,
                'Procurement removed a required document from the checklist',
                'Human');
        } catch (Exception ignored) { IntegrationErrorLogger.log(ca.Supplier__c, 'VendorPortalController', 'Audit_Log__c write failed (removeChecklistRequirement): ' + ignored.getMessage()); }

        delete ca;
    }

    // Adds a NEW required document to a supplier's PERSISTED checklist (post-
    // submit) — this is the record-page equivalent of adding a document on
    // the intake screen's preview. Thin wrapper over addRequirementFromDocument
    // (requirementKey left blank so a fresh USERADD_ key is generated) so both
    // entry points share one implementation.
    @AuraEnabled
    public static Id addChecklistRequirement(Id accountId, String documentLabel) {
        assertNotHandedOff(accountId);
        return addRequirementFromDocument(accountId, documentLabel, null);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Supplier snapshot — everything Documents & Screening (P3) needs to render
    // an EXISTING record in one call: supplier detail, the persisted checklist /
    // AI state, the documents stored in Salesforce, and the past AI summaries
    // (one per assessed requirement, with verdict + severity + reason).
    // ═════════════════════════════════════════════════════════════════════════
    public class SupplierSnapshot {
        @AuraEnabled public Id       accountId;
        @AuraEnabled public String   name;
        @AuraEnabled public String   industry;
        @AuraEnabled public String   country;
        @AuraEnabled public String   riskTier;
        @AuraEnabled public String   recommendedHitl;   // AI-set oversight (read-only)
        @AuraEnabled public String   onboardingStatus;
        @AuraEnabled public List<String> domains;
        @AuraEnabled public List<CaseDocument> documents;       // stored in SF, picked up on open
        @AuraEnabled public List<AssessmentSummary> assessments; // past AI summaries
        @AuraEnabled public Integer  docCount;
        @AuraEnabled public Integer  assessedCount;
        // Checklist coverage — SAME definition as getScreeningQueue's
        // docsUploaded/docsTotal (Screening rows excluded, "uploaded" means
        // Compliance_Document__c is linked regardless of AI verdict). Added
        // here so P3's "Documents on file" strip and the Supplier Portal can
        // show actual checklist progress instead of a raw ContentDocument
        // count, which included superseded/unmatched files and never matched
        // the checklist size next to it.
        @AuraEnabled public Integer  docsUploaded;
        @AuraEnabled public Integer  docsTotal;
        // Multi-tier cascading risk (docs/multi-tier-risk-rollup.md) — computed
        // by MultiTierRollupService, distinct from this supplier's own riskTier.
        @AuraEnabled public Decimal  riskScore;             // this supplier's own score (0-100)
        @AuraEnabled public String   cascadingRiskTier;     // worst tier across self + all descendants
        @AuraEnabled public String   cascadingRiskSource;   // which descendant is driving it
        @AuraEnabled public Id       cascadingRiskDriverId; // drill-through target for cascadingRiskSource
        @AuraEnabled public Integer  subTierSupplierCount;  // # of descendants (any depth)
        // Weighted-average blend (New Score = own*0.7 + avg(weighted sub-supplier)*0.3) —
        // a second, separate signal from cascadingRiskTier's worst-case propagation.
        @AuraEnabled public Decimal  cascadingRiskScore;
        @AuraEnabled public Boolean  cascadingRiskFlagged;
        // True when this Account was invited as someone else's sub-supplier
        // (Account.ParentId set) — the portal uses this to show a restricted,
        // single-tab view instead of the full Tier-1 experience (no "My
        // sub-suppliers" tab, no other supplier's data reachable).
        @AuraEnabled public Boolean  isSubSupplier;
        // Segregation of duties (Three Lines of Defense): routedToAnalyst is
        // TRUE once the risk tier exceeds the HITL threshold (routeDecision()
        // says 'Needs analyst'), even BEFORE assignToAnalyst() has actually
        // run — lets the Procurement Console proactively greyed-out its
        // approve action instead of only rejecting it after the fact.
        // isAssignedToAnalyst is TRUE only once the handoff has genuinely
        // happened (Analyst_Assigned_DateTime__c set) — the same signal
        // approveDocumentAsProcurement enforces server-side.
        @AuraEnabled public Boolean  routedToAnalyst;
        @AuraEnabled public Boolean  isAssignedToAnalyst;

        // Case close (VendorPortalController.closeComplianceCase) — once true,
        // the portal shows a closed/approved banner instead of the live
        // in-progress checklist view. Documents stay visible, read-only.
        @AuraEnabled public Boolean  isCaseClosed;
        @AuraEnabled public String   closingRemarks;
        @AuraEnabled public DateTime caseClosedDateTime;
    }

    public class AssessmentSummary {
        @AuraEnabled public Id     assessmentId;   // Compliance_Assessment__c Id — needed to call approveDocumentAsProcurement/saveDocValidation
        @AuraEnabled public String requirementKey;
        @AuraEnabled public String requirementLabel;
        @AuraEnabled public String status;        // Compliant | Non-Compliant | Needs Analyst | Pending
        @AuraEnabled public String severity;
        @AuraEnabled public String reasonCode;    // Missing_Document | Expired | Rule_Not_Met | Other —
                                                    // 'Expired' (set by ComplianceExpiryBatch) distinguishes
                                                    // "this was fine, now it's stale" from a real AI rejection,
                                                    // so the portal can offer Renew instead of a generic upload.
        @AuraEnabled public String reason;        // AI summary / reason detail
        // The Analyst's own comment (Analyst_Comment__c) — previously only
        // ever returned to the Analyst's own console (AnalystDoc.analystComment
        // below); when the Analyst marks a document Non-Compliant, the
        // supplier had no way to see WHY beyond the AI's own summary. Surfaced
        // here (and rendered in scSupplierPortal) so an Analyst rejection
        // gives the supplier the same explanation a Procurement rejection
        // already does via procurementDecisionReason.
        @AuraEnabled public String analystComment;
        @AuraEnabled public String validUntil;    // key date if extracted
        @AuraEnabled public String evaluatedLabel;
        @AuraEnabled public String badgeClass;    // ok | warn | bad | neutral (UI hint)
        @AuraEnabled public Boolean uploaded;     // a document IS linked to this requirement
        @AuraEnabled public String documentTitle; // the linked document's title (for the rejected list)
        // The uploaded file's real ContentDocumentId — scProcurementConsole.js
        // matches this against storedDocs to resolve Approve/Reject/Defer's
        // target file (see its own comment on why NOT to fuzzy-match
        // documentTitle, which is the requirement's label, not the filename).
        // Previously this field didn't exist on the DTO at all, so that match
        // always fell through to the fragile title-fuzzy-match fallback —
        // silently hiding the decision buttons whenever it missed.
        @AuraEnabled public String contentDocumentId;
        @AuraEnabled public Boolean rejected;     // uploaded but failed/unmatched → "Rejected" section
        @AuraEnabled public Integer aiConfidence; // AI engine's 0-100 confidence in this assessment
        @AuraEnabled public Boolean approved;     // Analyst_Validated__c — gates supplier-visible summary on the portal
        @AuraEnabled public String  procurementDecision;       // Procurement_Decision__c — Approved | Rejected | Deferred | null
        @AuraEnabled public String  procurementDecisionReason; // Procurement_Decision_Reason__c
        // Supplier-facing replacement for a Deferred document's status — the
        // internal word "Deferred" is never shown to the supplier (see
        // getSupplierSnapshot's isSupplierRunningUser() block). Null for
        // every other decision state; the LWC falls back to its normal
        // status/verdict display when this is blank.
        @AuraEnabled public String  supplierStatusOverride;
        // Full history of Procurement's Approve/Reject comments on this
        // requirement (newest first) — reuses the existing Audit_Log__c trail
        // already written by recordProcurementDecision, so re-deciding after a
        // document replacement keeps every prior comment visible with its
        // timestamp instead of only showing the latest one.
        @AuraEnabled public List<ProcurementComment> procurementComments;
        // WFL-03: true once the supplier has responded to a rejection — either
        // by re-uploading a new file (which clears Procurement_Decision__c,
        // making a fresh rejection look identical to "never reviewed" without
        // this flag) or by leaving a reply comment with no new file (decision
        // stays 'Rejected' but a newer Supplier_Comment_Added entry exists).
        // Computed in getSupplierSnapshot, not stored — distinguishes "waiting
        // on the supplier" from "the supplier already responded, look again."
        @AuraEnabled public Boolean pendingReReview;
        // internal only — not sent to the client, used to compute pendingReReview
        // after the comment-log loop below has run.
        public transient Datetime procurementDecisionDateTime;
        // Multi-document-per-requirement: every file individually linked to
        // this requirement via Compliance_Document_Link__c, each with its OWN
        // verdict/summary — empty when the requirement still uses the single
        // Compliance_Document__c pointer (never had a second file added).
        // The UI renders these as distinct sub-rows so a requirement with
        // multiple documents shows each one's own finding, not one blended
        // summary — status/reason/documentTitle above stay the ROLLED-UP
        // requirement-level view (worst-wins, see DocAssessQueueable.
        // rollupRequirementStatus) for anything that only reads the single-
        // document shape.
        @AuraEnabled public List<LinkedDocument> documentLinks;
    }

    public class LinkedDocument {
        @AuraEnabled public Id     docLinkId;      // Compliance_Document_Link__c Id
        @AuraEnabled public String documentTitle;  // the linked Compliance_Document__c's title
        @AuraEnabled public String status;         // this FILE's own verdict — Compliant | Non-Compliant | At Risk | Pending
        @AuraEnabled public String severity;
        @AuraEnabled public String reason;         // this file's own AI summary
        @AuraEnabled public String validUntil;
        @AuraEnabled public Integer aiConfidence;
        @AuraEnabled public String versionId;        // ContentVersion Id — preview/download
        @AuraEnabled public String contentDocumentId;
        @AuraEnabled public String fileType;
        @AuraEnabled public String badgeClass;
    }

    public class ProcurementComment {
        @AuraEnabled public String decision;   // Approved | Rejected | Deferred | null (plain reply)
        @AuraEnabled public String reason;
        @AuraEnabled public String actorName;
        @AuraEnabled public String dateLabel;   // Event_DateTime__c, formatted
        // WFL-04: distinguishes a Procurement decision from the supplier's own
        // reply in the SAME combined, dated thread — the LWC uses this to
        // style/attribute each entry rather than inferring it from `decision`
        // being blank (which is also true for old rows with no value at all).
        @AuraEnabled public Boolean isSupplierComment;
    }

    @AuraEnabled(cacheable=false)
    public static SupplierSnapshot getSupplierSnapshot(Id accountId) {
        if (!Schema.sObjectType.Account.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isAccessible()
                || !Schema.sObjectType.Compliance_Document_Link__c.isAccessible()
                || !Schema.sObjectType.ContentDocumentLink.isAccessible()
                || !Schema.sObjectType.ContentVersion.isAccessible()
                || !Schema.sObjectType.Audit_Log__c.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        return getSupplierSnapshotImpl(accountId);
    }

    // Shared with getSupplierSnapshotByToken (guest, token-verified) — system
    // context by design, see class header.
    @SuppressWarnings('PMD.ApexCRUDViolation') // guest token path — see class header
    private static SupplierSnapshot getSupplierSnapshotImpl(Id accountId) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');

        Account a = [
            SELECT Id, Name, Industry, BillingCountry, Country_of_Origin__c,
                   Risk_Tier__c, Risk_Score__c, Risk_Domains__c, Onboarding_Status__c,
                   Cascading_Risk_Tier__c, Cascading_Risk_Source__c,
                   Cascading_Risk_Driver__c, Sub_Tier_Supplier_Count__c,
                   Cascading_Risk_Score__c, Cascading_Risk_Flag__c, ParentId,
                   HITL_Threshold__c, Analyst_Assigned_DateTime__c,
                   Compliance_Case_Status__c, Closing_Remarks__c, Case_Closed_DateTime__c
            FROM   Account WHERE Id = :accountId LIMIT 1
        ];

        SupplierSnapshot s = new SupplierSnapshot();
        s.accountId            = a.Id;
        s.name                 = a.Name;
        s.industry             = a.Industry;
        s.country              = String.isNotBlank(a.Country_of_Origin__c) ? a.Country_of_Origin__c : a.BillingCountry;
        s.riskTier             = a.Risk_Tier__c;
        s.recommendedHitl      = recommendHitl(a.Risk_Tier__c);
        s.onboardingStatus     = a.Onboarding_Status__c;
        s.riskScore            = a.Risk_Score__c;
        s.cascadingRiskTier    = a.Cascading_Risk_Tier__c;
        s.cascadingRiskSource  = a.Cascading_Risk_Source__c;
        s.cascadingRiskDriverId = a.Cascading_Risk_Driver__c;
        s.subTierSupplierCount = a.Sub_Tier_Supplier_Count__c == null ? 0 : a.Sub_Tier_Supplier_Count__c.intValue();
        s.cascadingRiskScore   = a.Cascading_Risk_Score__c;
        s.cascadingRiskFlagged = (a.Cascading_Risk_Flag__c == true);
        s.isCaseClosed         = (a.Compliance_Case_Status__c == 'Closed - Compliant'
                                   || a.Compliance_Case_Status__c == 'Closed - Rejected');
        s.closingRemarks       = a.Closing_Remarks__c;
        s.caseClosedDateTime   = a.Case_Closed_DateTime__c;
        s.isSubSupplier        = (a.ParentId != null);
        s.isAssignedToAnalyst  = (a.Analyst_Assigned_DateTime__c != null);
        s.routedToAnalyst      = ('Needs analyst' == routeDecision(a.Risk_Tier__c, a.HITL_Threshold__c));
        s.cascadingRiskFlagged = a.Cascading_Risk_Flag__c == true;

        s.domains = new List<String>();
        if (String.isNotBlank(a.Risk_Domains__c)) {
            for (String d : a.Risk_Domains__c.split(',')) {
                String t = d.trim();
                if (String.isNotBlank(t)) s.domains.add(t);
            }
        }

        // Documents stored in Salesforce (ContentDocumentLink → ContentVersion).
        s.documents = getCaseDocumentsImpl(accountId);
        s.docCount  = s.documents.size();

        // Past AI summaries — one row per assessed requirement.
        s.assessments = new List<AssessmentSummary>();
        Integer docsUploaded = 0, docsTotal = 0;
        List<Compliance_Assessment__c> assessmentRows = [
            SELECT Id, Requirement_Key__c, Requirement_Label__c, Status__c, Severity__c,
                   Reason_Code__c, Reason_Detail__c, Valid_Until__c, Evaluation_DateTime__c,
                   AI_Confidence__c, Analyst_Validated__c, Analyst_Comment__c,
                   Procurement_Decision__c, Procurement_Decision_Reason__c,
                   Procurement_Decision_DateTime__c, LastModifiedDate,
                   Compliance_Document__c,
                   Compliance_Document__r.Document_Type__c,
                   Compliance_Document__r.Source_File__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :accountId
            ORDER BY Requirement_Label__c
            LIMIT  100
        ];
        // Resolve each linked Compliance_Document__c's real ContentDocumentId —
        // same ContentDocumentLink lookup pattern as getDocumentLinksByAssessment/
        // getCaseForAnalyst — so the client can match the uploaded FILE (not just
        // fuzzy-match the requirement's label) and correctly show Approve/Reject/Defer.
        Set<Id> snapCompDocIds = new Set<Id>();
        for (Compliance_Assessment__c x : assessmentRows) {
            if (x.Compliance_Document__c != null) snapCompDocIds.add(x.Compliance_Document__c);
        }
        Map<Id, Id> snapCdByComp = new Map<Id, Id>();
        if (!snapCompDocIds.isEmpty()) {
            for (ContentDocumentLink cdl : [SELECT LinkedEntityId, ContentDocumentId
                                             FROM ContentDocumentLink WHERE LinkedEntityId IN :snapCompDocIds]) {
                snapCdByComp.put(cdl.LinkedEntityId, cdl.ContentDocumentId);
            }
        }
        for (Compliance_Assessment__c x : assessmentRows) {
            AssessmentSummary as1 = new AssessmentSummary();
            as1.assessmentId     = x.Id;
            as1.approved         = (x.Analyst_Validated__c == true);
            // linkDocumentToCompliance clears these whenever the linked document
            // is replaced, so a non-blank value here always reflects a decision
            // made on the CURRENTLY linked document — no separate staleness
            // check needed.
            as1.procurementDecision       = x.Procurement_Decision__c;
            as1.procurementDecisionReason = x.Procurement_Decision_Reason__c;
            as1.procurementDecisionDateTime = x.Procurement_Decision_DateTime__c;
            as1.procurementComments = new List<ProcurementComment>();
            // Case 1 — supplier re-uploaded: DocumentProcessingController's
            // re-upload update clears Procurement_Decision__c to null AND
            // bumps LastModifiedDate, so a NEWLY-cleared decision with a file
            // modified after the last recorded decision means the supplier
            // responded, not that this was never reviewed. Case 2 (a reply
            // comment with no new file, decision still 'Rejected') is folded
            // in after the comment-log loop below, once those timestamps exist.
            as1.pendingReReview = (x.Procurement_Decision__c == null
                && x.Procurement_Decision_DateTime__c != null
                && x.LastModifiedDate > x.Procurement_Decision_DateTime__c);
            as1.requirementKey   = x.Requirement_Key__c;
            as1.requirementLabel = x.Requirement_Label__c;
            as1.status           = String.isBlank(x.Status__c) ? 'Pending' : x.Status__c;
            as1.severity         = x.Severity__c;
            as1.reasonCode       = x.Reason_Code__c;
            as1.reason           = x.Reason_Detail__c;
            as1.analystComment   = x.Analyst_Comment__c;
            as1.validUntil       = x.Valid_Until__c == null ? null : x.Valid_Until__c.format();
            as1.evaluatedLabel   = x.Evaluation_DateTime__c == null
                                   ? null : x.Evaluation_DateTime__c.format('MMM d, h:mm a');
            as1.badgeClass       = statusBadge(as1.status);
            // Checklist tick / rejected derivation: a document linked → "uploaded";
            // uploaded + Non-Compliant → "rejected" (goes to the Rejected section).
            as1.uploaded = (x.Compliance_Document__c != null);
            if (as1.uploaded && x.Compliance_Document__r != null) {
                as1.documentTitle = String.isNotBlank(x.Compliance_Document__r.Document_Type__c)
                    ? x.Compliance_Document__r.Document_Type__c
                    : x.Compliance_Document__r.Source_File__c;
            }
            if (as1.uploaded && snapCdByComp.containsKey(x.Compliance_Document__c)) {
                as1.contentDocumentId = snapCdByComp.get(x.Compliance_Document__c);
            }
            as1.rejected = as1.uploaded && (as1.status == 'Non-Compliant');
            as1.aiConfidence = (x.AI_Confidence__c == null) ? null : Integer.valueOf(x.AI_Confidence__c);
            as1.documentLinks = new List<LinkedDocument>();
            s.assessments.add(as1);
            // Same rule getScreeningQueue uses for docsUploaded/docsTotal —
            // Screening rows excluded, "uploaded" = a document is linked.
            if (x.Requirement_Key__c == null || !x.Requirement_Key__c.startsWith('SCREEN_')) {
                docsTotal++;
                if (as1.uploaded) docsUploaded++;
            }
        }
        s.assessedCount = s.assessments.size();
        s.docsUploaded  = docsUploaded;
        s.docsTotal     = docsTotal;

        // Multi-document-per-requirement: bulk-attach every linked document's
        // OWN verdict/summary, keyed by parent assessment — a requirement
        // only has more than one of these once "add another file" has been
        // used on it, so this is empty (no extra query cost) for the common
        // single-document case.
        attachDocumentLinks(s.assessments);

        // Bulk-attach Procurement's full comment history (newest first) from the
        // Audit_Log__c trail recordProcurementDecision already writes — one
        // query for every assessment instead of per-row, then grouped in memory.
        Set<String> assessmentIdStrs = new Set<String>();
        for (AssessmentSummary row : s.assessments) assessmentIdStrs.add(row.assessmentId);
        if (!assessmentIdStrs.isEmpty()) {
            Map<Id, AssessmentSummary> byId = new Map<Id, AssessmentSummary>();
            for (AssessmentSummary row : s.assessments) byId.put(row.assessmentId, row);

            // Format in the ORG's timezone explicitly (not the calling user's) —
            // DateTime.format() with no timezone arg uses the running user's own
            // timezone, which is why the same comment showed a different clock
            // time to an internal Salesforce user vs. a Guest portal visitor
            // (each defaults to their own timezone). One fixed zone keeps the
            // timestamp identical everywhere.
            String orgTz = [SELECT TimeZoneSidKey FROM Organization LIMIT 1].TimeZoneSidKey;

            // Deferred entries are an internal note for whichever Analyst the
            // case is later assigned to — never surfaced to the supplier,
            // regardless of which auth path (logged-in portal user or Guest
            // token) they're calling through.
            Boolean hideDeferred = isSupplierRunningUser();
            for (Audit_Log__c log : [
                SELECT Related_Record_Id__c, New_Value__c, Reason__c, Event_DateTime__c,
                       Event_Type__c, Actor_User__c
                FROM   Audit_Log__c
                WHERE  Related_Object__c = 'Compliance_Assessment'
                AND    Related_Record_Id__c IN :assessmentIdStrs
                AND    Event_Type__c IN ('Procurement_Decision_Recorded', 'Supplier_Comment_Added', 'Document_Uploaded')
                ORDER BY Event_DateTime__c DESC
            ]) {
                Boolean isUpload = (log.Event_Type__c == 'Document_Uploaded');
                // An upload has no Actor_User__c when it came from the guest/
                // portal side (see linkDocumentToCompliance) — same convention
                // every other entry in this thread uses to decide Supplier vs
                // Procurement.
                Boolean isSupplierComment = (log.Event_Type__c == 'Supplier_Comment_Added')
                    || (isUpload && log.Actor_User__c == null);
                if (hideDeferred && log.New_Value__c == 'Deferred') continue;
                AssessmentSummary row = byId.get((Id) log.Related_Record_Id__c);
                if (row == null) continue;
                ProcurementComment c = new ProcurementComment();
                // Uploads never carry a real Approved/Rejected/Deferred value —
                // 'Uploaded' is just a label for the small badge next to it.
                c.decision  = isSupplierComment ? null : (isUpload ? 'Uploaded' : log.New_Value__c);
                // The actual uploaded file's name — Reason__c already holds it
                // for Document_Uploaded rows (see linkDocumentToCompliance).
                c.reason    = isUpload ? ('Uploaded ' + log.Reason__c) : log.Reason__c;
                // Fixed team-level labels, not the acting user's real name —
                // Guest/portal sessions can't safely resolve User.Name (Salesforce
                // masks it for Guest Users), which is why the portal showed a
                // garbled placeholder like "User1780...". A team-level label
                // avoids that entirely and matches everywhere.
                c.actorName = isSupplierComment ? 'Supplier' : 'Procurement';
                c.isSupplierComment = isSupplierComment;
                c.dateLabel = log.Event_DateTime__c == null
                    ? null : log.Event_DateTime__c.format('MMM d, yyyy h:mm a', orgTz);
                row.procurementComments.add(c);
                // WFL-03 case 2 — supplier replied without a new file: the
                // decision is still 'Rejected' (no re-upload cleared it), but a
                // Supplier_Comment_Added entry newer than the decision itself
                // means the supplier has already spoken, so it's no longer
                // simply "waiting on the supplier."
                if (isSupplierComment && row.procurementDecision == 'Rejected'
                    && row.procurementDecisionDateTime != null
                    && log.Event_DateTime__c > row.procurementDecisionDateTime) {
                    row.pendingReReview = true;
                }
            }
        }
        // Supplier-facing status override for a Deferred document — never
        // shows the internal "Deferred" word (see the earlier UX call: the
        // supplier sees "Pending review", plain and non-alarming). Applied
        // AFTER the comment loop above so it doesn't depend on comment
        // visibility — the row's own procurementDecision field already
        // carries this regardless of whether the reason text was included.
        if (isSupplierRunningUser()) {
            for (AssessmentSummary row : s.assessments) {
                if (row.procurementDecision == 'Deferred') {
                    row.supplierStatusOverride = 'Pending review';
                }
            }
        }
        return s;
    }

    private static String statusBadge(String status) {
        String t = (status == null) ? '' : status.toLowerCase();
        if (t.contains('non-compliant') || t.contains('fail')) return 'bad';
        if (t.contains('needs') || t.contains('review'))       return 'warn';
        if (t.contains('compliant') || t.contains('clear'))    return 'ok';
        return 'neutral';
    }

    // getSupplierSnapshot-specific attach: fills each AssessmentSummary's
    // documentLinks from the shared bulk fetch above.
    private static void attachDocumentLinks(List<AssessmentSummary> assessments) {
        Set<Id> ids = new Set<Id>();
        for (AssessmentSummary a : assessments) if (a.assessmentId != null) ids.add(a.assessmentId);
        Map<Id, List<LinkedDocument>> byAssessment = getDocumentLinksByAssessment(ids);
        for (AssessmentSummary a : assessments) {
            if (byAssessment.containsKey(a.assessmentId)) {
                a.documentLinks = byAssessment.get(a.assessmentId);
            }
        }
    }

    // Multi-document-per-requirement: bulk-fetches every Compliance_Document_Link__c
    // row for the given assessment Ids, mapped to the per-file LinkedDocument
    // DTO, grouped by parent assessment. Shared by getSupplierSnapshot and
    // getCaseForAnalyst so both consoles render the same per-file data.
    @SuppressWarnings('PMD.ApexCRUDViolation') // shared with the guest token path — see class header
    private static Map<Id, List<LinkedDocument>> getDocumentLinksByAssessment(Set<Id> assessmentIds) {
        Map<Id, List<LinkedDocument>> out = new Map<Id, List<LinkedDocument>>();
        if (assessmentIds == null || assessmentIds.isEmpty()) return out;

        List<Compliance_Document_Link__c> links = [
            SELECT Id, Compliance_Assessment__c, Status__c, Severity__c, Reason_Detail__c,
                   Valid_Until__c, AI_Confidence__c,
                   Compliance_Document__c, Compliance_Document__r.Document_Type__c,
                   Compliance_Document__r.Source_File__c
            FROM   Compliance_Document_Link__c
            WHERE  Compliance_Assessment__c IN :assessmentIds
            AND    Status__c != 'Superseded'
            ORDER BY CreatedDate ASC
        ];
        if (links.isEmpty()) return out;

        Set<Id> compDocIds = new Set<Id>();
        for (Compliance_Document_Link__c l : links) if (l.Compliance_Document__c != null) compDocIds.add(l.Compliance_Document__c);

        // Same ContentVersion resolution pattern used elsewhere (getCaseForAnalyst) —
        // Compliance Document → ContentDocumentId → latest ContentVersion.
        Map<Id, Id> cdByComp = new Map<Id, Id>();
        if (!compDocIds.isEmpty()) {
            for (ContentDocumentLink cdl : [SELECT LinkedEntityId, ContentDocumentId
                                             FROM ContentDocumentLink WHERE LinkedEntityId IN :compDocIds]) {
                cdByComp.put(cdl.LinkedEntityId, cdl.ContentDocumentId);
            }
        }
        Map<Id, ContentVersion> cvByCd = new Map<Id, ContentVersion>();
        if (!cdByComp.values().isEmpty()) {
            for (ContentVersion v : [SELECT Id, Title, FileType, ContentDocumentId
                                     FROM ContentVersion
                                     WHERE ContentDocumentId IN :cdByComp.values() AND IsLatest = true]) {
                cvByCd.put(v.ContentDocumentId, v);
            }
        }

        for (Compliance_Document_Link__c l : links) {
            LinkedDocument ld = new LinkedDocument();
            ld.docLinkId  = l.Id;
            ld.status     = String.isBlank(l.Status__c) ? 'Pending' : l.Status__c;
            ld.severity   = l.Severity__c;
            ld.reason     = l.Reason_Detail__c;
            ld.validUntil = l.Valid_Until__c == null ? null : l.Valid_Until__c.format();
            ld.aiConfidence = (l.AI_Confidence__c == null) ? null : Integer.valueOf(l.AI_Confidence__c);
            ld.badgeClass = statusBadge(ld.status);
            if (l.Compliance_Document__r != null) {
                ld.documentTitle = String.isNotBlank(l.Compliance_Document__r.Document_Type__c)
                    ? l.Compliance_Document__r.Document_Type__c
                    : l.Compliance_Document__r.Source_File__c;
            }
            if (l.Compliance_Document__c != null && cdByComp.containsKey(l.Compliance_Document__c)) {
                Id cdId = cdByComp.get(l.Compliance_Document__c);
                ContentVersion v = cvByCd.get(cdId);
                if (v != null) {
                    ld.versionId         = v.Id;
                    ld.contentDocumentId = cdId;
                    ld.fileType          = v.FileType;
                }
            }
            if (!out.containsKey(l.Compliance_Assessment__c)) out.put(l.Compliance_Assessment__c, new List<LinkedDocument>());
            out.get(l.Compliance_Assessment__c).add(ld);
        }
        return out;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Assign-to-analyst — list real assignable users (incl. the current admin)
    // and route a supplier to the chosen analyst so it appears in their queue.
    // ═════════════════════════════════════════════════════════════════════════
    public class AnalystUser {
        @AuraEnabled public Id     id;
        @AuraEnabled public String name;
        @AuraEnabled public String role;   // profile / title for context
        @AuraEnabled public Boolean isMe;
    }

    @AuraEnabled(cacheable=true)
    public static List<AnalystUser> getAnalystUsers() {
        Id me = UserInfo.getUserId();
        if (!Schema.sObjectType.User.isAccessible()) throw new AuraHandledException(NO_ACCESS);
        List<AnalystUser> out = new List<AnalystUser>();
        // Active internal users — current user first, so "assign to me" is one click.
        for (User u : [
            SELECT Id, Name, Title, Profile.Name
            FROM   User
            WHERE  IsActive = true AND UserType = 'Standard'
            ORDER BY Name
            LIMIT  50
        ]) {
            AnalystUser a = new AnalystUser();
            a.id   = u.Id;
            a.name = (u.Id == me) ? (u.Name + ' (you)') : u.Name;
            a.role = String.isNotBlank(u.Title) ? u.Title
                     : (u.Profile != null ? u.Profile.Name : 'User');
            a.isMe = (u.Id == me);
            out.add(a);
        }
        // Float the current user to the top.
        for (Integer i = 0; i < out.size(); i++) {
            if (out[i].isMe) { AnalystUser m = out.remove(i); out.add(0, m); break; }
        }
        return out;
    }

    @AuraEnabled
    public static String assignToAnalyst(Id accountId, Id analystUserId, String note) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        if (analystUserId == null) throw new AuraHandledException('Choose an analyst to assign.');
        if (!Schema.sObjectType.Compliance_Assessment__c.isAccessible()
                || !Schema.sObjectType.Account.isUpdateable()) {
            throw new AuraHandledException(NO_ACCESS);
        }

        // WFL-05 — every checklist item is mandatory: block handoff while any
        // UPLOADED document still has no Procurement decision (Approved/
        // Rejected/Deferred). Server-side twin of the client-side gate on P4's
        // "Assign to analyst" button — the UI disabling the button isn't
        // itself enforcement, a direct Apex call could still bypass it.
        // Un-uploaded rows are a different, already-visible gap and aren't
        // blocked here — Approve/Reject/Defer can't act on them anyway.
        Integer undecided = [
            SELECT COUNT()
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :accountId
              AND  Compliance_Document__c != null
              AND  Procurement_Decision__c = null
              AND  (NOT Requirement_Key__c LIKE 'SCREEN_%')
        ];
        if (undecided > 0) {
            throw new AuraHandledException(
                undecided + ' document' + (undecided == 1 ? '' : 's') + ' still need'
                + (undecided == 1 ? 's' : '') + ' a decision (Approve/Reject/Defer) before handoff.');
        }

        // Set the owner to the analyst + status so it lands in the analyst queue.
        // Analyst_Assigned_DateTime__c is the authoritative "has this genuinely
        // been handed off" signal — Onboarding_Status__c = 'In Review' alone is
        // NOT enough, because upsertSupplier also uses 'In Review' pre-handoff
        // (see requestDocumentsFromSupplier), so the same status string can't
        // distinguish the two. This field only gets set here, exactly once.
        // Assigned_By__c/Assignment_Reason__c give the Analyst real handoff
        // context on the case itself instead of only an audit-log row —
        // reason reuses the same note Procurement already types here, just
        // persisted somewhere the Analyst console can actually render it.
        Account a = new Account(
            Id                           = accountId,
            OwnerId                      = analystUserId,
            Onboarding_Status__c         = 'In Review',
            Analyst_Assigned_DateTime__c = System.now(),
            Assigned_By__c               = UserInfo.getUserId(),
            Assignment_Reason__c         = note
        );
        update Security.stripInaccessible(AccessType.UPDATABLE, new List<Account>{ a }).getRecords();

        AuditLogService.write(new Audit_Log__c(
            Event_Type__c        = 'Status_Changed',
            Related_Object__c    = 'Supplier',
            Related_Record_Id__c = accountId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'User',
            Source_System__c     = 'Other',
            New_Value__c         = 'Assigned to analyst ' + analystUserId
                + (String.isNotBlank(note) ? (' · note: ' + note) : '')
        ));
        return accountId;
    }

    // Inverse of assignToAnalyst — the Analyst hands the case back to
    // Procurement instead of routing/closing it (e.g. a document needs
    // re-requesting from the supplier, or the case doesn't belong with this
    // analyst). Clears Analyst_Assigned_DateTime__c (the authoritative
    // "has this genuinely been handed off" flag assignToAnalyst sets) and
    // resets Onboarding_Status__c to 'Screening' — distinct from 'In Review',
    // which is used both pre- and post-handoff (see assignToAnalyst's own
    // comment) and would leave the case looking unchanged to Procurement.
    // Ownership reverts to whoever sent it TO the analyst (Assigned_By__c),
    // falling back to the running user if that's somehow blank.
    @AuraEnabled
    public static String sendCaseBackToProcurement(Id accountId, String note) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        if (!Schema.sObjectType.Account.isAccessible()
                || !Schema.sObjectType.Account.isUpdateable()) {
            throw new AuraHandledException(NO_ACCESS);
        }

        Account existing = [SELECT Assigned_By__c FROM Account WHERE Id = :accountId LIMIT 1];
        Id returnTo = (existing.Assigned_By__c != null) ? existing.Assigned_By__c : UserInfo.getUserId();

        update Security.stripInaccessible(AccessType.UPDATABLE, new List<Account>{
            new Account(
                Id                           = accountId,
                OwnerId                      = returnTo,
                Onboarding_Status__c         = 'Screening',
                Analyst_Assigned_DateTime__c = null,
                Assignment_Reason__c         = note
            )
        }).getRecords();

        AuditLogService.write(new Audit_Log__c(
            Event_Type__c        = 'Status_Changed',
            Related_Object__c    = 'Supplier',
            Related_Record_Id__c = accountId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'User',
            Source_System__c     = 'Other',
            New_Value__c         = 'Sent back to Procurement'
                + (String.isNotBlank(note) ? (' · note: ' + note) : '')
        ));
        return accountId;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ANALYST CONSOLE — queue, per-document validation, and generative co-pilot.
    // The Risk & Compliance Analyst reviews each document's AI summary, adds a
    // manual comment, and marks it validated; recommends a tier; routes to the
    // approver. (Reuses existing assessments/screening as the findings source.)
    // ═════════════════════════════════════════════════════════════════════════

    public class AnalystQueueRow {
        @AuraEnabled public Id     id;
        @AuraEnabled public String name;
        @AuraEnabled public String industry;
        @AuraEnabled public String aiTier;
        @AuraEnabled public Integer flags;          // non-compliant / at-risk findings
        @AuraEnabled public Integer docCount;
        @AuraEnabled public Integer validatedCount; // analyst-validated findings
        @AuraEnabled public String status;
        @AuraEnabled public String stageLabel;
        @AuraEnabled public String requestedBy;
        @AuraEnabled public String ageLabel;
        @AuraEnabled public Boolean isMine;          // OwnerId == running user
        @AuraEnabled public String stageAgeLabel;    // time in CURRENT stage
        @AuraEnabled public Boolean isStalled;        // stageAgeLabel >= STALLED_THRESHOLD_DAYS
    }

    // Suppliers that have reached the analyst (in review / handed over). Shows the
    // EXISTING requests. MUST be cacheable=true — it's consumed via @wire in the
    // analyst LWC, and @wire silently returns no data for a non-cacheable method
    // (which is why the queue rendered empty even when rows existed).
    //
    // Defaults to the RUNNING analyst's own assigned cases only — previously this
    // returned every 'In Review' account to every analyst regardless of who it was
    // assigned to. showTeamQueue=true opts into the full shared view for
    // supervisors who need it; nothing is hidden, just not the default anymore.
    @AuraEnabled(cacheable=true)
    public static List<AnalystQueueRow> getAnalystQueue(Boolean showTeamQueue) {
        // The analyst queue shows ONLY suppliers actually ROUTED to an analyst.
        // 'In Review' is the post-routing state (set by assignToAnalyst / the
        // analyst's own route). Pre-routing states (Draft, and the procurement
        // 'Screening' bucket) belong to the Procurement queue, not here.
        Id me = UserInfo.getUserId();
        if (!Schema.sObjectType.Account.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        List<Account> accs;
        if (showTeamQueue == true) {
            accs = [
                SELECT Id, Name, Industry, Risk_Tier__c, Onboarding_Status__c,
                       Requested_By__c, CreatedDate, OwnerId, Stage_Entered_DateTime__c
                FROM   Account
                WHERE  RecordType.DeveloperName = 'Supplier'
                  AND  Onboarding_Status__c = 'In Review'
                  AND  Compliance_Case_Status__c != 'Closed - Compliant'
                  AND  Compliance_Case_Status__c != 'Closed - Rejected'
                ORDER BY CreatedDate DESC
                LIMIT  200
            ];
        } else {
            accs = [
                SELECT Id, Name, Industry, Risk_Tier__c, Onboarding_Status__c,
                       Requested_By__c, CreatedDate, OwnerId, Stage_Entered_DateTime__c
                FROM   Account
                WHERE  RecordType.DeveloperName = 'Supplier'
                  AND  Onboarding_Status__c = 'In Review'
                  AND  Compliance_Case_Status__c != 'Closed - Compliant'
                  AND  Compliance_Case_Status__c != 'Closed - Rejected'
                  AND  OwnerId = :me
                ORDER BY CreatedDate DESC
                LIMIT  200
            ];
        }

        // Flag + validated + doc counts per supplier, from persisted assessments —
        // scoped to just the queue's own accounts (accs, capped at 200 above), not
        // every Compliance_Assessment__c row in the org (that grows unbounded with
        // every supplier ever onboarded and was flagged as a non-restrictive query).
        Set<Id> accIds = new Map<Id, Account>(accs).keySet();
        Map<Id, Integer> flagsByAcc = new Map<Id, Integer>();
        Map<Id, Integer> docByAcc   = new Map<Id, Integer>();
        Map<Id, Integer> valByAcc   = new Map<Id, Integer>();
        if (!accIds.isEmpty()) {
            for (AggregateResult ar : [
                SELECT Supplier__c sid, COUNT(Id) c
                FROM   Compliance_Assessment__c
                WHERE  Supplier__c IN :accIds
                AND    Status__c IN ('Non-Compliant','At Risk')
                GROUP BY Supplier__c
            ]) flagsByAcc.put((Id) ar.get('sid'), (Integer) ar.get('c'));
            for (AggregateResult ar : [
                SELECT Supplier__c sid, COUNT(Id) c FROM Compliance_Assessment__c
                WHERE Supplier__c IN :accIds GROUP BY Supplier__c
            ]) docByAcc.put((Id) ar.get('sid'), (Integer) ar.get('c'));
            for (AggregateResult ar : [
                SELECT Supplier__c sid, COUNT(Id) c FROM Compliance_Assessment__c
                WHERE Supplier__c IN :accIds AND Analyst_Validated__c = true GROUP BY Supplier__c
            ]) valByAcc.put((Id) ar.get('sid'), (Integer) ar.get('c'));
        }

        List<AnalystQueueRow> out = new List<AnalystQueueRow>();
        for (Account a : accs) {
            AnalystQueueRow r = new AnalystQueueRow();
            r.id             = a.Id;
            r.name           = a.Name;
            r.industry       = a.Industry;
            r.aiTier         = a.Risk_Tier__c;
            r.flags          = flagsByAcc.containsKey(a.Id) ? flagsByAcc.get(a.Id) : 0;
            r.docCount       = docByAcc.containsKey(a.Id) ? docByAcc.get(a.Id) : 0;
            r.validatedCount = valByAcc.containsKey(a.Id) ? valByAcc.get(a.Id) : 0;
            r.status         = a.Onboarding_Status__c;
            r.stageLabel     = mapStage(a.Onboarding_Status__c);
            r.requestedBy    = a.Requested_By__c;
            r.ageLabel       = ageLabel(a.CreatedDate);
            r.isMine         = (a.OwnerId == me);
            r.stageAgeLabel  = stageAgeLabel(a.Stage_Entered_DateTime__c);
            r.isStalled      = isStalled(a.Stage_Entered_DateTime__c);
            out.add(r);
        }
        return out;
    }

    // Per-document case for the analyst: each finding/document with its AI summary,
    // the analyst's comment, and validated state.
    public class AnalystDoc {
        @AuraEnabled public Id      assessmentId;
        @AuraEnabled public String  requirementLabel;
        @AuraEnabled public String  aiStatus;        // Compliant | Non-Compliant | Needs Analyst | Pending
        @AuraEnabled public String  severity;
        @AuraEnabled public String  aiSummary;       // AI's reason detail
        @AuraEnabled public String  analystComment;  // analyst's own comment
        @AuraEnabled public Boolean validated;
        @AuraEnabled public String  badgeClass;
        @AuraEnabled public String  versionId;       // ContentVersion Id — used for renditionDownload
        @AuraEnabled public String  contentDocumentId; // ContentDocument Id — used for generatePublicDocumentUrl
        @AuraEnabled public String  fileType;        // e.g. PDF, PNG, DOCX
        @AuraEnabled public String  docUrl;          // fallback download link
        @AuraEnabled public String  docTitle;        // uploaded file title
        // Provenance: who last reviewed THIS document and when — was captured
        // (Evaluator_User__c/Evaluation_DateTime__c) but never surfaced before,
        // so a freshly-handed-off case and an untouched one looked identical.
        @AuraEnabled public String  evaluatedByName;
        @AuraEnabled public String  evaluatedDateLabel;
        // Procurement's own decision on this document — surfaced to the
        // Analyst specifically so a Deferred document's note ("why
        // Procurement couldn't make this call") is visible exactly where
        // it's needed once the case is assigned. Not shown anywhere on the
        // Supplier Portal (see getSupplierSnapshot's isSupplierRunningUser
        // filter) — this is the Analyst-only counterpart to that gate.
        @AuraEnabled public String  procurementDecision;
        @AuraEnabled public String  procurementDecisionReason;
        // Full comment/upload history (newest first) — the same
        // Audit_Log__c-based thread Procurement's own console gets via
        // AssessmentSummary.procurementComments (see getSupplierSnapshot).
        // Previously the Analyst only ever saw the single latest
        // procurementDecisionReason string above, with no dated history —
        // this gives full context (every past decision + supplier reply +
        // upload) on a case that may have gone through several rounds before
        // ever reaching the Analyst queue.
        @AuraEnabled public List<ProcurementComment> commentHistory;
        @AuraEnabled public Boolean isDeferred;
        // True when this document was (re-)uploaded after the case was handed
        // off to the Analyst — see the WFL-06 build note at getCaseForAnalyst.
        @AuraEnabled public Boolean isNewSinceHandoff;
        // Multi-document-per-requirement — see AssessmentSummary.documentLinks
        // for the full rationale. Empty for a requirement that only ever had
        // its single default document.
        @AuraEnabled public List<LinkedDocument> documentLinks;
    }
    public class AnalystCase {
        @AuraEnabled public Id      accountId;
        @AuraEnabled public String  name;
        @AuraEnabled public String  industry;
        @AuraEnabled public String  country;
        @AuraEnabled public String  aiTier;
        // Account.Risk_Score__c — the REAL server-computed score (see
        // RiskScoreService), not re-derived here. scComplianceDashboard used
        // to compute its own separate score client-side from `docs`, which
        // silently diverged from this real number.
        @AuraEnabled public Decimal riskScore;
        @AuraEnabled public Integer docCount;
        @AuraEnabled public Integer validatedCount;
        @AuraEnabled public List<AnalystDoc> docs;
        // Handoff context — who assigned this case, when, and why — rendered as
        // a banner on the case header so the analyst isn't starting cold.
        @AuraEnabled public String  assignedByName;
        @AuraEnabled public String  assignedDateLabel;
        @AuraEnabled public String  assignmentReason;
        @AuraEnabled public Boolean hasAssignment;
        // Case_Closed_By__c/_DateTime__c are already written by
        // closeComplianceCase (see closeCaseInternal) — exposed here so the
        // Analyst Console's "Approved by" strip can show the REAL approver
        // once the case is closed, instead of a permanently-static "pending"
        // placeholder. Null/blank on any still-open case — that's correct,
        // not a bug: nobody has approved it yet.
        @AuraEnabled public String   approvedByName;
        @AuraEnabled public String   approvedDateLabel;
        @AuraEnabled public Boolean  hasApproval;
    }

    @AuraEnabled(cacheable=false)
    public static AnalystCase getCaseForAnalyst(Id accountId) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        if (!Schema.sObjectType.Account.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isAccessible()
                || !Schema.sObjectType.Compliance_Document_Link__c.isAccessible()
                || !Schema.sObjectType.ContentDocumentLink.isAccessible()
                || !Schema.sObjectType.ContentVersion.isAccessible()
                || !Schema.sObjectType.Audit_Log__c.isAccessible()
                || !Schema.sObjectType.Organization.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        Account a = [
            SELECT Id, Name, Industry, BillingCountry, Country_of_Origin__c, Risk_Tier__c, Risk_Score__c,
                   Assigned_By__r.Name, Analyst_Assigned_DateTime__c, Assignment_Reason__c,
                   Case_Closed_By__r.Name, Case_Closed_DateTime__c
            FROM   Account WHERE Id = :accountId LIMIT 1
        ];
        AnalystCase c = new AnalystCase();
        c.accountId = a.Id;
        c.name      = a.Name;
        c.industry  = a.Industry;
        c.riskScore = a.Risk_Score__c;
        c.country   = String.isNotBlank(a.Country_of_Origin__c) ? a.Country_of_Origin__c : a.BillingCountry;
        c.aiTier    = a.Risk_Tier__c;
        c.docs      = new List<AnalystDoc>();
        c.assignedByName    = a.Assigned_By__r != null ? a.Assigned_By__r.Name : null;
        c.assignedDateLabel = a.Analyst_Assigned_DateTime__c == null ? null
                               : a.Analyst_Assigned_DateTime__c.format('MMM d, h:mm a');
        c.assignmentReason  = a.Assignment_Reason__c;
        c.hasAssignment     = (a.Analyst_Assigned_DateTime__c != null);
        c.approvedByName    = a.Case_Closed_By__r != null ? a.Case_Closed_By__r.Name : null;
        c.approvedDateLabel = a.Case_Closed_DateTime__c == null ? null
                               : a.Case_Closed_DateTime__c.format('MMM d, h:mm a');
        c.hasApproval       = (a.Case_Closed_DateTime__c != null);
        Integer validated = 0;
        // Pre-resolve the latest ContentVersion download URL for each uploaded
        // Compliance Document, so the analyst can PREVIEW the real file (not just
        // the AI summary) before marking it validated.
        List<Compliance_Assessment__c> rows = [
            SELECT Id, Requirement_Label__c, Status__c, Severity__c, Reason_Detail__c,
                   Analyst_Comment__c, Analyst_Validated__c, Compliance_Document__c,
                   Evaluator_User__r.Name, Evaluation_DateTime__c, LastModifiedDate,
                   Procurement_Decision__c, Procurement_Decision_Reason__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :accountId
            ORDER BY Analyst_Validated__c ASC, Requirement_Label__c ASC
            LIMIT  200
        ];
        Set<Id> docIds = new Set<Id>();
        for (Compliance_Assessment__c x : rows) if (x.Compliance_Document__c != null) docIds.add(x.Compliance_Document__c);
        // Compliance Document → ContentDocumentId → latest ContentVersion.
        Map<Id, Id> cdByComp = new Map<Id, Id>();
        if (!docIds.isEmpty()) {
            for (ContentDocumentLink l : [SELECT LinkedEntityId, ContentDocumentId
                                          FROM ContentDocumentLink WHERE LinkedEntityId IN :docIds]) {
                cdByComp.put(l.LinkedEntityId, l.ContentDocumentId);
            }
        }
        Map<Id, ContentVersion> cvByCd = new Map<Id, ContentVersion>();
        if (!cdByComp.values().isEmpty()) {
            for (ContentVersion v : [SELECT Id, Title, FileType, ContentDocumentId
                                     FROM ContentVersion
                                     WHERE ContentDocumentId IN :cdByComp.values() AND IsLatest = true]) {
                cvByCd.put(v.ContentDocumentId, v);
            }
        }
        for (Compliance_Assessment__c x : rows) {
            AnalystDoc d = new AnalystDoc();
            d.assessmentId     = x.Id;
            d.requirementLabel = x.Requirement_Label__c;
            d.aiStatus         = String.isBlank(x.Status__c) ? 'Pending' : x.Status__c;
            d.severity         = x.Severity__c;
            d.aiSummary        = x.Reason_Detail__c;
            d.analystComment   = x.Analyst_Comment__c;
            d.validated        = x.Analyst_Validated__c;
            d.badgeClass       = statusBadge(d.aiStatus);
            d.evaluatedByName  = x.Evaluator_User__r != null ? x.Evaluator_User__r.Name : null;
            d.evaluatedDateLabel = x.Evaluation_DateTime__c == null ? null
                                    : x.Evaluation_DateTime__c.format('MMM d, h:mm a');
            d.procurementDecision       = x.Procurement_Decision__c;
            d.procurementDecisionReason = x.Procurement_Decision_Reason__c;
            d.commentHistory = new List<ProcurementComment>();
            d.isDeferred = (x.Procurement_Decision__c == 'Deferred');
            // Flags a document that was (re-)uploaded AFTER the handoff — the
            // supplier's upload path is never locked (see assertNotHandedOff),
            // so this is the only signal the analyst has that a document in
            // front of them isn't the one Procurement actually reviewed before
            // handing the case over. LastModifiedDate is bumped by
            // DocumentProcessingController's re-upload update (which also
            // resets Status__c/Procurement_Decision__c) — no new field needed.
            d.isNewSinceHandoff = a.Analyst_Assigned_DateTime__c != null
                && x.LastModifiedDate > a.Analyst_Assigned_DateTime__c;
            if (x.Compliance_Document__c != null && cdByComp.containsKey(x.Compliance_Document__c)) {
                Id cdId = cdByComp.get(x.Compliance_Document__c);
                ContentVersion v = cvByCd.get(cdId);
                if (v != null) {
                    d.versionId         = v.Id;
                    d.contentDocumentId = cdId;
                    d.fileType          = v.FileType;
                    d.docUrl            = '/sfc/servlet.shepherd/version/download/' + v.Id;
                    d.docTitle          = v.Title;
                }
            }
            c.docs.add(d);
            if (x.Analyst_Validated__c) validated++;
        }
        c.docCount       = c.docs.size();
        c.validatedCount = validated;

        // Bulk-attach the full comment/upload history (newest first) — same
        // Audit_Log__c trail and query shape as getSupplierSnapshot's own
        // block, just never hiding Deferred entries (the Analyst is exactly
        // who's supposed to see WHY Procurement deferred something).
        Set<String> analystAssessmentIdStrs = new Set<String>();
        for (AnalystDoc d : c.docs) if (d.assessmentId != null) analystAssessmentIdStrs.add(d.assessmentId);
        if (!analystAssessmentIdStrs.isEmpty()) {
            Map<Id, AnalystDoc> docById = new Map<Id, AnalystDoc>();
            for (AnalystDoc d : c.docs) docById.put(d.assessmentId, d);

            String orgTz2 = [SELECT TimeZoneSidKey FROM Organization LIMIT 1].TimeZoneSidKey;
            for (Audit_Log__c log : [
                SELECT Related_Record_Id__c, New_Value__c, Reason__c, Event_DateTime__c,
                       Event_Type__c, Actor_User__c
                FROM   Audit_Log__c
                WHERE  Related_Object__c = 'Compliance_Assessment'
                AND    Related_Record_Id__c IN :analystAssessmentIdStrs
                AND    Event_Type__c IN ('Procurement_Decision_Recorded', 'Supplier_Comment_Added',
                                          'Document_Uploaded', 'Analyst_Decision_Recorded')
                ORDER BY Event_DateTime__c DESC
            ]) {
                Boolean isUpload = (log.Event_Type__c == 'Document_Uploaded');
                Boolean isAnalystDecision = (log.Event_Type__c == 'Analyst_Decision_Recorded');
                Boolean isSupplierComment = (log.Event_Type__c == 'Supplier_Comment_Added')
                    || (isUpload && log.Actor_User__c == null);
                AnalystDoc d = docById.get((Id) log.Related_Record_Id__c);
                if (d == null) continue;
                ProcurementComment pc = new ProcurementComment();
                pc.decision  = isSupplierComment ? null : (isUpload ? 'Uploaded' : log.New_Value__c);
                pc.reason    = isUpload ? ('Uploaded ' + log.Reason__c) : log.Reason__c;
                pc.actorName = isSupplierComment ? 'Supplier' : (isAnalystDecision ? 'Analyst' : 'Procurement');
                pc.isSupplierComment = isSupplierComment;
                pc.dateLabel = log.Event_DateTime__c == null
                    ? null : log.Event_DateTime__c.format('MMM d, yyyy h:mm a', orgTz2);
                d.commentHistory.add(pc);
            }
        }

        // Multi-document-per-requirement — see AssessmentSummary.documentLinks.
        Set<Id> analystAssessmentIds = new Set<Id>();
        for (AnalystDoc d : c.docs) if (d.assessmentId != null) analystAssessmentIds.add(d.assessmentId);
        Map<Id, List<LinkedDocument>> byAssessment = getDocumentLinksByAssessment(analystAssessmentIds);
        for (AnalystDoc d : c.docs) {
            if (byAssessment.containsKey(d.assessmentId)) {
                d.documentLinks = byAssessment.get(d.assessmentId);
            }
        }
        return c;
    }

    // Persist the analyst's per-document comment + validated flag. finalStatus is
    // optional (existing callers that only toggle validation, e.g. handleMarkValidated,
    // omit it and leave Status__c untouched) — when supplied it's the analyst's own
    // compliance decision (Compliant/Non-Compliant — hyphenated, matching
    // DocAssessQueueable.mapVerdict's spelling; scAnalystConsole._normalizedAiStatus
    // sends this same form), confirming or overriding the AI's Status__c.
    // Human-in-the-loop: this write always wins over whatever the AI set,
    // since it's the analyst explicitly recording their own final call.
    @AuraEnabled
    public static void saveDocValidation(Id assessmentId, String comment, Boolean validated, String finalStatus) {
        if (assessmentId == null) throw new AuraHandledException('No document selected.');
        if (!Schema.sObjectType.Compliance_Assessment__c.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isUpdateable()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        Compliance_Assessment__c ca = new Compliance_Assessment__c(
            Id                     = assessmentId,
            Analyst_Comment__c    = comment,
            Analyst_Validated__c  = (validated == true),
            Evaluator_User__c     = UserInfo.getUserId(),
            Evaluation_DateTime__c = System.now()
        );
        if (String.isNotBlank(finalStatus)) {
            ca.Status__c = finalStatus;
        }
        update Security.stripInaccessible(AccessType.UPDATABLE, new List<Compliance_Assessment__c>{ ca }).getRecords();

        // Every other decision-recording action in this class (Procurement's
        // Approve/Reject/Defer, closeComplianceCase) writes an Audit_Log__c
        // row so it shows up in the dated history thread both consoles read
        // (getSupplierSnapshot.procurementComments / getCaseForAnalyst.
        // commentHistory) — this one never did, so an Analyst's Confirm/
        // Override call left literally no trace anywhere. Only logged when a
        // real compliance call was made (finalStatus set) — a bare
        // handleMarkValidated toggle with no status change stays unlogged,
        // same as before, since there's no decision to record yet.
        if (String.isNotBlank(finalStatus)) {
            AuditLogService.write(new Audit_Log__c(
                Event_Type__c        = 'Analyst_Decision_Recorded',
                Related_Object__c    = 'Compliance_Assessment',
                Related_Record_Id__c = assessmentId,
                Event_DateTime__c    = DateTime.now(),
                Actor_Type__c        = 'User',
                Actor_User__c        = UserInfo.getUserId(),
                Source_System__c     = 'Other',
                New_Value__c          = finalStatus,
                Reason__c             = comment
            ));
        }

        // The Analyst's Confirm/Override is a real change to Status__c — the
        // dashboard risk score must reflect it (confirming a Non-Compliant
        // verdict shouldn't leave the score looking like everything passed;
        // overriding one to Compliant should bring the score back down).
        if (String.isNotBlank(finalStatus)) {
            try {
                Compliance_Assessment__c withSupplier = [
                    SELECT Supplier__c FROM Compliance_Assessment__c WHERE Id = :assessmentId LIMIT 1
                ];
                RiskScoreService.recompute(withSupplier.Supplier__c);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[saveDocValidation] risk score recompute failed: ' + e.getMessage());
            }
        }
    }

    // WFL-06 — server-side twin of the Procurement Console's isPostHandoffLocked.
    // Client-side hiding of Approve/Reject/Defer/Add files/Remove item is UX,
    // not enforcement — any of these Apex entry points is still directly
    // callable, so each one that changes case content post-handoff needs its
    // own guard. Reuses the exact Analyst_Assigned_DateTime__c signal
    // approveDocumentAsProcurement already established below.
    private static void assertNotHandedOff(Id accountId) {
        if (accountId == null) return;
        if (!Schema.sObjectType.Account.isAccessible()) throw new AuraHandledException(NO_ACCESS);
        Account a = [SELECT Analyst_Assigned_DateTime__c FROM Account WHERE Id = :accountId LIMIT 1];
        if (a.Analyst_Assigned_DateTime__c != null) {
            throw new AuraHandledException(
                'This supplier has already been handed off to the Analyst — Procurement can no '
                + 'longer edit this case.');
        }
    }
    private static void assertAssessmentNotHandedOff(Id assessmentId) {
        if (assessmentId == null) return;
        if (!Schema.sObjectType.Compliance_Assessment__c.isAccessible()) throw new AuraHandledException(NO_ACCESS);
        Compliance_Assessment__c ca = [
            SELECT Supplier__r.Analyst_Assigned_DateTime__c
            FROM   Compliance_Assessment__c
            WHERE  Id = :assessmentId
            LIMIT  1
        ];
        if (ca.Supplier__r.Analyst_Assigned_DateTime__c != null) {
            throw new AuraHandledException(
                'This supplier has already been handed off to the Analyst — Procurement can no '
                + 'longer edit this case.');
        }
    }

    // Segregation of duties (Three Lines of Defense model): Procurement (First
    // Line, owns the vendor relationship) can release a document's AI summary
    // to the supplier ONLY until the case is genuinely handed off to the
    // Analyst (Second Line, owns the actual risk sign-off). The status string
    // alone can't gate this — Onboarding_Status__c = 'In Review' is used BOTH
    // pre-handoff (requestDocumentsFromSupplier) and as the value
    // assignToAnalyst sets — so this checks Analyst_Assigned_DateTime__c,
    // which is only ever written once, by assignToAnalyst itself.
    //
    // Procurement-side equivalent of saveDocValidation — writes the SAME
    // Analyst_Validated__c/Analyst_Comment__c fields (no separate approval
    // field: one supplier-visibility gate, settable by whichever persona
    // currently owns the case) but ONLY while the supplier hasn't yet been
    // handed to the Analyst. This is what unlocks the document's compliance
    // summary on the supplier portal (see scSupplierPortal) while Procurement
    // is still the owning persona.
    @AuraEnabled
    public static void approveDocumentAsProcurement(Id assessmentId, String comment, Boolean approved) {
        if (assessmentId == null) throw new AuraHandledException('No document selected.');
        if (!Schema.sObjectType.Compliance_Assessment__c.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isUpdateable()) {
            throw new AuraHandledException(NO_ACCESS);
        }

        Compliance_Assessment__c ca = [
            SELECT Id, Supplier__r.Analyst_Assigned_DateTime__c
            FROM   Compliance_Assessment__c
            WHERE  Id = :assessmentId
            LIMIT  1
        ];
        if (ca.Supplier__r.Analyst_Assigned_DateTime__c != null) {
            throw new AuraHandledException(
                'This supplier has already been handed to the Analyst — approval is now '
                + 'the Analyst\'s responsibility.');
        }

        update Security.stripInaccessible(AccessType.UPDATABLE, new List<Compliance_Assessment__c>{
            new Compliance_Assessment__c(
                Id                     = assessmentId,
                Analyst_Comment__c     = comment,
                Analyst_Validated__c   = (approved == true),
                Evaluator_User__c      = UserInfo.getUserId(),
                Evaluation_DateTime__c = System.now()
            )
        }).getRecords();
    }

    // Re-runs AI assessment for ONE already-uploaded document — the per-
    // document counterpart to the whole-supplier "Refresh" action that used
    // to live at the top of Documents & Screening (removed: it silently
    // re-summarized every document at once, with no way to target just the
    // one a user actually wanted re-checked). Reuses the exact same
    // DocAssessQueueable the original upload path enqueues — same /assess
    // call, same verdict-writing logic — just re-triggered on demand instead
    // of only at upload time.
    @AuraEnabled
    public static void reassessDocument(Id assessmentId) {
        if (assessmentId == null) throw new AuraHandledException('No document selected.');
        if (!Schema.sObjectType.Compliance_Assessment__c.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isUpdateable()
                || !Schema.sObjectType.ContentVersion.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }

        Compliance_Assessment__c ca = [
            SELECT Id, Supplier__c, Requirement_Label__c, Compliance_Document__c,
                   Compliance_Document__r.Source_File__c,
                   Compliance_Document__r.Document_Type__c
            FROM   Compliance_Assessment__c
            WHERE  Id = :assessmentId
            LIMIT  1
        ];
        if (ca.Compliance_Document__c == null || ca.Compliance_Document__r.Source_File__c == null) {
            throw new AuraHandledException('This requirement has no uploaded document to re-assess.');
        }

        List<ContentVersion> cv = [
            SELECT Id FROM ContentVersion
            WHERE  ContentDocumentId = :ca.Compliance_Document__r.Source_File__c
            AND    IsLatest = true
            LIMIT  1
        ];
        if (cv.isEmpty()) {
            throw new AuraHandledException('Could not locate the uploaded file to re-assess.');
        }

        String docType = String.isNotBlank(ca.Compliance_Document__r.Document_Type__c)
            ? ca.Compliance_Document__r.Document_Type__c : ca.Requirement_Label__c;

        // Same "in progress" placeholder the original upload path sets, so
        // the row shows it's re-checking instead of leaving the OLD (possibly
        // now-wrong) summary visible while the queueable runs.
        update Security.stripInaccessible(AccessType.UPDATABLE, new List<Compliance_Assessment__c>{
            new Compliance_Assessment__c(
                Id               = assessmentId,
                Reason_Detail__c = 'Re-assessment requested — pending AI extraction'
            )
        }).getRecords();

        System.enqueueJob(new DocAssessQueueable(
            ca.Compliance_Document__c, cv[0].Id, ca.Supplier__c, docType, assessmentId));
    }

    // True for anyone NOT an internal Salesforce user — logged-in Experience
    // Cloud supplier portal users (PowerCustomerSuccess/PowerPartner/
    // CustomerSuccess, same check as DocumentProcessingController.
    // getPortalContactId) and true Guest Users alike. Used to keep a
    // Deferred document's internal note (Analyst-only) out of anything the
    // supplier can see, regardless of which of the two portal auth paths
    // (logged-in vs. guest token) they're calling through.
    // Public so DocumentProcessingController.linkDocumentToCompliance can log
    // upload events with the same Supplier-vs-internal distinction this class
    // already uses for the comment/decision thread (see getSupplierSnapshot).
    public static Boolean isSupplierRunningUser() {
        String userType = UserInfo.getUserType();
        return userType == 'PowerCustomerSuccess' || userType == 'PowerPartner'
            || userType == 'CustomerSuccess' || userType == 'Guest';
    }

    // Procurement's OWN Approve/Reject/Deferred decision on an uploaded
    // document — a genuinely separate checkpoint from Analyst_Validated__c/
    // Analyst_Comment__c (the supplier-visibility gate above), which is why
    // this writes its own Procurement_Decision__c/_Reason__c/_By__c/
    // _DateTime__c fields rather than reusing the Analyst's.
    //
    // Approved/Rejected DO now also update Status__c to the equivalent
    // AI-verdict value (Compliant/Non-Compliant) — Procurement's decision IS
    // the effective compliance call whenever no Analyst reviews the case (the
    // common case: routeDecision() auto-routes anything at/below the HITL
    // threshold and no Analyst ever sees it). Previously Status__c stayed
    // frozen at the AI's original verdict even after Procurement explicitly
    // overrode it, so an all-Approved supplier's requirements still read
    // "Non-Compliant" everywhere that reads Status__c directly — including
    // closeComplianceCase's all-Compliant gate, which could never be
    // satisfied by Procurement approvals alone.
    // Deferred leaves Status__c untouched — Procurement isn't making a
    // compliance call, just routing the document to a human (the Analyst) for
    // one; the reason is an internal note for that Analyst, never shown to
    // the supplier (see getSupplierSnapshot's isSupplierRunningUser() filter).
    @AuraEnabled
    public static void recordProcurementDecision(Id assessmentId, String decision, String reason) {
        if (assessmentId == null) throw new AuraHandledException('No document selected.');
        if (decision != 'Approved' && decision != 'Rejected' && decision != 'Deferred') {
            throw new AuraHandledException('Decision must be Approved, Rejected, or Deferred.');
        }
        if (String.isBlank(reason)) {
            throw new AuraHandledException('A reason is required to record this decision.');
        }
        assertAssessmentNotHandedOff(assessmentId);
        if (!Schema.sObjectType.Compliance_Assessment__c.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isUpdateable()) {
            throw new AuraHandledException(NO_ACCESS);
        }

        Compliance_Assessment__c upd = new Compliance_Assessment__c(
            Id                               = assessmentId,
            Procurement_Decision__c          = decision,
            Procurement_Decision_Reason__c   = reason,
            Procurement_Decision_By__c       = UserInfo.getUserId(),
            Procurement_Decision_DateTime__c = System.now()
        );
        if (decision == 'Approved') {
            upd.Status__c = 'Compliant';
        } else if (decision == 'Rejected') {
            upd.Status__c = 'Non-Compliant';
        }
        update Security.stripInaccessible(AccessType.UPDATABLE, new List<Compliance_Assessment__c>{ upd }).getRecords();

        // One row per decision (never updated/deleted — Audit_Log__c is
        // create-only) so getSupplierSnapshot can surface the FULL comment
        // history, not just the latest — see AssessmentSummary.procurementComments.
        AuditLogService.write(new Audit_Log__c(
            Event_Type__c        = 'Procurement_Decision_Recorded',
            Related_Object__c    = 'Compliance_Assessment',
            Related_Record_Id__c = assessmentId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'User',
            Actor_User__c        = UserInfo.getUserId(),
            Source_System__c     = 'Other',
            New_Value__c          = decision,
            Reason__c             = reason
        ));

        // Procurement's Approve/Reject is real human judgment, and for any
        // supplier whose risk tier auto-routes below the HITL threshold (see
        // routeDecision()), it's the ONLY human judgment that document will
        // ever get — no Analyst will review it. Without this, the dashboard
        // score stayed frozen at whatever the AI alone said, even after
        // Procurement explicitly overruled a finding. RiskScoreService now
        // weighs Procurement_Decision__c over Status__c when they disagree.
        // Deferred is excluded — Procurement couldn't decide, so it's not a
        // compliance signal either way; recompute() already ignores it.
        try {
            Compliance_Assessment__c withSupplier = [
                SELECT Supplier__c FROM Compliance_Assessment__c WHERE Id = :assessmentId LIMIT 1
            ];
            RiskScoreService.recompute(withSupplier.Supplier__c);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[recordProcurementDecision] risk score recompute failed: ' + e.getMessage());
        }
    }

    // WFL-04: the supplier's own reply on a rejected requirement, when what's
    // needed is an explanation rather than a fresh file (e.g. "the expiry
    // date on the certificate is a typo, the real one is 2027"). Reuses the
    // exact same Audit_Log__c thread recordProcurementDecision writes to, so
    // the two consoles render one combined, dated conversation instead of
    // two separate comment lists.
    @AuraEnabled
    public static void addSupplierComment(Id assessmentId, String note) {
        // The comment is an audit row (system-context sink), but the caller must
        // at least be allowed to see the assessment they are commenting on.
        if (!Schema.sObjectType.Compliance_Assessment__c.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        addSupplierCommentImpl(assessmentId, note);
    }

    // Shared with addSupplierCommentByToken (guest: token-verified and the
    // assessment matched to the token's account first) — see class header.
    private static void addSupplierCommentImpl(Id assessmentId, String note) {
        if (assessmentId == null) throw new AuraHandledException('No document selected.');
        if (String.isBlank(note)) {
            throw new AuraHandledException('Enter a comment before sending.');
        }
        AuditLogService.write(new Audit_Log__c(
            Event_Type__c        = 'Supplier_Comment_Added',
            Related_Object__c    = 'Compliance_Assessment',
            Related_Record_Id__c = assessmentId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'User',
            Actor_User__c        = isSupplierRunningUser() ? null : UserInfo.getUserId(),
            Source_System__c     = 'Other',
            New_Value__c         = 'Comment',
            Reason__c             = note
        ));
    }

    // Guest/token counterpart — same verify-then-act pattern as every other
    // *ByToken method (assessmentId is looked up as belonging to the token's
    // account first, so a guest can't comment on a document that isn't theirs).
    @SuppressWarnings('PMD.ApexCRUDViolation') // guest token path — see class header
    @AuraEnabled
    public static void addSupplierCommentByToken(String token, Id assessmentId, String note) {
        Id accountId = verifyPortalTokenId(token);
        if (accountId == null) throw new AuraHandledException('Invalid or expired link.');
        if (assessmentId == null) throw new AuraHandledException('No document selected.');
        Compliance_Assessment__c ca = [
            SELECT Id FROM Compliance_Assessment__c
            WHERE  Id = :assessmentId AND Supplier__c = :accountId LIMIT 1
        ];
        addSupplierCommentImpl(ca.Id, note);
    }

    // Generative co-pilot: the analyst types a rough observation; the co-pilot
    // returns a polished, professional validation comment grounded on the
    // document's AI summary. Reuses the /copilot callout.
    @AuraEnabled
    public static String copilotDraftComment(Id accountId, String requirementLabel,
                                             String aiSummary, String observation) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        if (!Schema.sObjectType.Account.isAccessible()) throw new AuraHandledException(NO_ACCESS);
        Account a = [SELECT Name, Industry, Industry__c FROM Account WHERE Id = :accountId LIMIT 1];
        String industry = String.isNotBlank(a.Industry) ? a.Industry : a.Industry__c;
        String context =
            'You are helping a compliance analyst write a concise, professional '
            + 'validation comment for a supplier document. Document: '
            + (String.isBlank(requirementLabel) ? 'document' : requirementLabel)
            + '. AI assessment: ' + (String.isBlank(aiSummary) ? '(none)' : aiSummary.left(800)) + '.';
        String question =
            'The analyst observed: "' + (String.isBlank(observation) ? 'looks acceptable' : observation)
            + '". Write a 1-2 sentence formal validation comment capturing this judgement.';
        try {
            CopilotService.CopilotResponse r = CopilotService.ask(question, a.Name, context, null, null, industry);
            return (r != null && String.isNotBlank(r.answer)) ? r.answer : observation;
        } catch (Exception e) {
            throw new AuraHandledException('Co-pilot draft failed: ' + e.getMessage());
        }
    }

    // ── Save as Draft ────────────────────────────────────────────────────────
    @AuraEnabled
    public static String saveDraft(
        String accountId,
        String supplierName,
        String country,
        String requestedBy,
        String industry,
        String engagementType,
        String annualSpend,
        String riskDomains,
        String supplierEmail,
        String hitlThreshold
    ) {
        return upsertSupplier(
            accountId, supplierName, country, requestedBy,
            industry, engagementType, annualSpend, riskDomains,
            supplierEmail, hitlThreshold, 'Draft',
            null, null
        );
    }

    // ── Submit for AI review ─────────────────────────────────────────────────
    @AuraEnabled
    public static String submitForReview(
        String accountId,
        String supplierName,
        String country,
        String requestedBy,
        String industry,
        String engagementType,
        String annualSpend,
        String riskDomains,
        String supplierEmail,
        String hitlThreshold
    ) {
        return upsertSupplier(
            accountId, supplierName, country, requestedBy,
            industry, engagementType, annualSpend, riskDomains,
            supplierEmail, hitlThreshold, 'In Review',
            null, null
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Submit → documents & screening. Persists the supplier (status 'Screening'),
    // kicks off PRE-DOCUMENT screening asynchronously (the AI engine runs
    // registry / sanctions / conflict / media checks), AND sends the supplier
    // their checklist + portal-access email in the same action — previously
    // this was a separate manual "Email supplier" step the user had to
    // remember to click; now Submit alone is enough to grant portal access.
    // ═════════════════════════════════════════════════════════════════════════
    @AuraEnabled
    public static String submitAndScreen(
        String supplierName,
        String country,
        String requestedBy,
        String industry,
        String engagementType,
        String annualSpend,
        String riskDomains,
        String supplierEmail,
        String hitlThreshold,
        List<String> documents,
        String materialType,
        String serviceCategory
    ) {
        if (String.isBlank(supplierName)) {
            throw new AuraHandledException('Supplier legal entity name is required.');
        }
        if (!Schema.sObjectType.Account.isAccessible()) throw new AuraHandledException(NO_ACCESS);
        // DEDUP: re-submitting the same supplier (or a double-click) must UPDATE
        // the existing record, not create a duplicate. Match on legal name (+ email
        // when present) among supplier accounts.
        String existingId = null;
        String nm = supplierName.trim();
        List<Account> dupes = (String.isNotBlank(supplierEmail))
            ? [SELECT Id FROM Account
               WHERE RecordType.DeveloperName = 'Supplier' AND Name = :nm
                 AND Supplier_Contact_Email__c = :supplierEmail
               ORDER BY CreatedDate DESC LIMIT 1]
            : [SELECT Id FROM Account
               WHERE RecordType.DeveloperName = 'Supplier' AND Name = :nm
               ORDER BY CreatedDate DESC LIMIT 1];
        if (!dupes.isEmpty()) existingId = dupes[0].Id;

        // 1. Persist the supplier (DML) with status 'Screening' — update if found.
        // checklistCurated=true: `documents` below is the Procurement user's
        // post-edit checklist (already emailed as-is) — the trigger-fired
        // ScopeCalloutQueueable must not re-derive and overwrite it from /scope.
        String accId = upsertSupplier(
            existingId, supplierName, country, requestedBy,
            industry, engagementType, annualSpend, riskDomains,
            supplierEmail, hitlThreshold, 'Screening',
            materialType, serviceCategory, true
        );
        persistCuratedChecklist(accId, documents);
        // 2. Run pre-document screening asynchronously (callout-after-DML rule).
        System.enqueueJob(new ScreeningQueueable((Id) accId));
        // Submit does NOT send the checklist/portal-access email — that's the
        // dedicated "Email supplier" action's job (requestDocumentsFromSupplier).
        // Previously both this method AND the Email button sent an email, and
        // nothing stopped a user clicking both, resulting in the supplier
        // getting the same email twice. Submit now only persists + screens;
        // the user must explicitly click "Email supplier" to actually notify
        // the supplier and grant portal access.
        return accId;
    }

    // ── Create or update based on whether an ID is supplied ──────────────────
    private static String upsertSupplier(
        String accountId,
        String supplierName,
        String country,
        String requestedBy,
        String industry,
        String engagementType,
        String annualSpend,
        String riskDomains,
        String supplierEmail,
        String hitlThreshold,
        String status,
        String materialType,
        String serviceCategory
    ) {
        return upsertSupplier(
            accountId, supplierName, country, requestedBy,
            industry, engagementType, annualSpend, riskDomains,
            supplierEmail, hitlThreshold, status, materialType, serviceCategory,
            false
        );
    }

    // checklistCurated = true when the caller (submitAndScreen /
    // requestDocumentsFromSupplier) already sent/will send a specific,
    // human-edited document list — sets Checklist_Seeded_By_Caller__c so
    // ScopeCalloutQueueable doesn't re-derive and overwrite it from /scope.
    // See Checklist_Seeded_By_Caller__c.field-meta.xml for the full rationale.
    private static String upsertSupplier(
        String accountId,
        String supplierName,
        String country,
        String requestedBy,
        String industry,
        String engagementType,
        String annualSpend,
        String riskDomains,
        String supplierEmail,
        String hitlThreshold,
        String status,
        String materialType,
        String serviceCategory,
        Boolean checklistCurated
    ) {
        if (String.isBlank(supplierName)) {
            throw new AuraHandledException('Supplier name is required.');
        }
        if (!Schema.sObjectType.Account.isCreateable()
                || !Schema.sObjectType.Account.isUpdateable()
                || !Schema.sObjectType.Supplier_Profile__c.isCreateable()) {
            throw new AuraHandledException(NO_ACCESS);
        }

        Boolean isUpdate = String.isNotBlank(accountId);

        Account acc = isUpdate ? new Account(Id = accountId) : new Account();
        if (!isUpdate) {
            // Explicit Supplier record type. Every queue/dedup query in this app
            // filters on RecordType.DeveloperName = 'Supplier'; relying on the
            // running user's DEFAULT record type made a supplier created by a
            // user whose default is Master vanish from all of them (found by
            // the release rehearsal running as a non-admin persona).
            Map<String, Schema.RecordTypeInfo> rtMap =
                Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
            if (rtMap.containsKey('Supplier')) acc.RecordTypeId = rtMap.get('Supplier').getRecordTypeId();
        }
        acc.Name                     = supplierName.trim();
        acc.BillingCountry           = country;
        acc.Requested_By__c          = requestedBy;
        acc.Industry                 = industry;
        acc.Engagement_Type__c       = engagementType;
        acc.Risk_Domains__c          = riskDomains;
        acc.Onboarding_Status__c     = status;
        acc.Checklist_Seeded_By_Caller__c = checklistCurated;
        // Persisted so ScopeCalloutQueueable (the trigger-fired /scope call that
        // seeds the ACTUAL Compliance_Assessment__c rows) can resolve the same
        // materialDomains this screen's live preview used — otherwise the emailed
        // preview checklist and the persisted/portal checklist silently diverge.
        if (String.isNotBlank(materialType))    acc.Material_Type__c    = materialType;
        if (String.isNotBlank(serviceCategory)) acc.Service_Category__c = serviceCategory;
        if (String.isNotBlank(supplierEmail)) {
            acc.Supplier_Contact_Email__c = supplierEmail;
        }
        if (String.isNotBlank(hitlThreshold)) {
            acc.HITL_Threshold__c = hitlThreshold;
        }

        if (String.isNotBlank(annualSpend)) {
            // Free-text input: keep only a well-formed number (digits with at
            // most one decimal point); anything else leaves the field null.
            String cleaned = annualSpend.replaceAll('[^0-9.]', '');
            if (Pattern.matches('^\\d+(\\.\\d+)?$', cleaned)) {
                acc.Annual_Spend_Est__c = Decimal.valueOf(cleaned);
            }
        }

        if (isUpdate) {
            update Security.stripInaccessible(AccessType.UPDATABLE, new List<Account>{ acc }).getRecords();
            return accountId;
        } else {
            insert acc;
            // Create linked Supplier Profile only on first save
            Supplier_Profile__c sp = new Supplier_Profile__c();
            sp.Account__c = acc.Id;
            insert Security.stripInaccessible(AccessType.CREATABLE, new List<Supplier_Profile__c>{ sp }).getRecords();
            return acc.Id;
        }
    }

    // ── Supplier Queue: Edit supplier details ──────────────────────────────────
    // A lightweight, dedicated editor — deliberately NOT the "New Supplier"
    // intake wizard, since that flow is bundled with AI checklist generation/
    // risk scoring and would risk re-deriving the checklist just to fix a typo.
    // Only Name/Annual Spend/Email are user-editable (per the UI); the rest are
    // read back here and re-sent unchanged in updateSupplierDetails so saving
    // can't silently blank them out.
    public class SupplierEditDetails {
        @AuraEnabled public String accountId;
        @AuraEnabled public String supplierName;
        @AuraEnabled public String country;
        @AuraEnabled public String industry;
        @AuraEnabled public String engagementType;
        @AuraEnabled public String annualSpend;
        @AuraEnabled public String supplierEmail;
        @AuraEnabled public String materialType;
        @AuraEnabled public String serviceCategory;
    }

    @AuraEnabled(cacheable=false)
    public static SupplierEditDetails getSupplierEditDetails(Id accountId) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        if (!Schema.sObjectType.Account.isAccessible()) throw new AuraHandledException(NO_ACCESS);
        Account a = [
            SELECT Id, Name, BillingCountry, Industry, Engagement_Type__c,
                   Annual_Spend_Est__c, Supplier_Contact_Email__c,
                   Material_Type__c, Service_Category__c
            FROM   Account WHERE Id = :accountId LIMIT 1
        ];
        SupplierEditDetails d = new SupplierEditDetails();
        d.accountId       = a.Id;
        d.supplierName    = a.Name;
        d.country         = a.BillingCountry;
        d.industry        = a.Industry;
        d.engagementType  = a.Engagement_Type__c;
        d.annualSpend     = a.Annual_Spend_Est__c == null ? '' : String.valueOf(a.Annual_Spend_Est__c);
        d.supplierEmail   = a.Supplier_Contact_Email__c;
        d.materialType    = a.Material_Type__c;
        d.serviceCategory = a.Service_Category__c;
        return d;
    }

    // Reuses upsertSupplier (no duplicate save logic) — first reads back the
    // fields this editor doesn't expose (Requested_By__c, Risk_Domains__c,
    // Onboarding_Status__c, HITL_Threshold__c, Checklist_Seeded_By_Caller__c)
    // so the update can't silently blank/reset them.
    @AuraEnabled
    public static void updateSupplierDetails(
        Id accountId, String supplierName, String country, String industry,
        String engagementType, String annualSpend, String supplierEmail,
        String materialType, String serviceCategory
    ) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        if (!Schema.sObjectType.Account.isAccessible()) throw new AuraHandledException(NO_ACCESS);
        Account existing = [
            SELECT Requested_By__c, Risk_Domains__c, Onboarding_Status__c,
                   HITL_Threshold__c, Checklist_Seeded_By_Caller__c
            FROM   Account WHERE Id = :accountId LIMIT 1
        ];
        upsertSupplier(
            accountId, supplierName, country, existing.Requested_By__c,
            industry, engagementType, annualSpend, existing.Risk_Domains__c,
            supplierEmail, existing.HITL_Threshold__c, existing.Onboarding_Status__c,
            materialType, serviceCategory, existing.Checklist_Seeded_By_Caller__c
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Screening queue (Screen 2) — all Supplier-record-type Accounts as a worklist
    // ═════════════════════════════════════════════════════════════════════════
    public class ScreeningQueue {
        @AuraEnabled public Integer total;
        @AuraEnabled public Integer prospective;   // In Review
        @AuraEnabled public Integer needsReview;   // has flags or High/Critical tier
        @AuraEnabled public Integer approved;
        @AuraEnabled public Integer autoCleared;          // AI auto-approve route, no flags
        @AuraEnabled public Decimal avgTimeToOnboardDays; // KPI: created → onboarded
        @AuraEnabled public List<SupplierRow> rows;
    }
    public class SupplierRow {
        @AuraEnabled public Id       id;
        @AuraEnabled public String   name;
        @AuraEnabled public String   industry;
        @AuraEnabled public String   riskTier;
        @AuraEnabled public Decimal  riskScore;
        @AuraEnabled public String   status;       // Onboarding_Status__c API value
        @AuraEnabled public String   stageLabel;   // friendly stage text
        @AuraEnabled public String   riskDomains;
        @AuraEnabled public String   requestedBy;
        @AuraEnabled public Integer  flags;
        @AuraEnabled public String   ageLabel;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public String   hitlThreshold;  // Low/Medium/High
        @AuraEnabled public String   routing;        // Auto-approve | Needs analyst
        @AuraEnabled public String   aiStatus;       // Onboarded | AI cleared | Needs analyst | Screening
        @AuraEnabled public String   durationLabel;  // time in pipeline since created (E1)
        @AuraEnabled public Boolean  isAssignedToAnalyst; // TRUE only once assignToAnalyst() has actually run —
                                                            // distinct from aiStatus=='Needs analyst', which is
                                                            // just the AI's recommendation before any human acts.
        @AuraEnabled public String   stageAgeLabel;  // time in CURRENT stage (distinct from durationLabel)
        @AuraEnabled public Boolean  isStalled;      // stageAgeLabel >= STALLED_THRESHOLD_DAYS
        @AuraEnabled public Integer  docsUploaded;   // same definition as P3's checklistProgressLabel
        @AuraEnabled public Integer  docsTotal;      // total non-screening checklist items
    }

    @AuraEnabled(cacheable=true)
    public static ScreeningQueue getScreeningQueue() {
        if (!Schema.sObjectType.Account.isAccessible()
                || !Schema.sObjectType.Compliance_Assessment__c.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        // Flag counts per supplier (non-compliant / at-risk assessments)
        Map<Id, Integer> flagsByAcc = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Supplier__c sid, COUNT(Id) c
            FROM   Compliance_Assessment__c
            WHERE  Status__c IN ('Non-Compliant', 'At Risk')
            GROUP BY Supplier__c
        ]) {
            flagsByAcc.put((Id) ar.get('sid'), (Integer) ar.get('c'));
        }

        // Documents progress per supplier — SAME definition as checklistProgressLabel
        // on Documents & Screening (P3): uploaded / total checklist items. "Uploaded"
        // means a document is linked (Compliance_Document__c != null), same test the
        // snapshot uses to set AssessmentSummary.uploaded — regardless of AI verdict.
        // Screening rows excluded.
        // NOTE: AI_Confidence__c is intentionally NOT aggregated to supplier level
        // anywhere in this class — it's a document-level extraction-quality signal
        // (see AssessmentRow.aiConfidence in getSupplierSnapshot) and stays there.
        // Risk_Score__c (RiskScoreService) is the one supplier-level risk number.
        Map<Id, Integer> docsTotalByAcc    = new Map<Id, Integer>();
        Map<Id, Integer> docsUploadedByAcc = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Supplier__c sid, COUNT(Id) c
            FROM   Compliance_Assessment__c
            WHERE  (NOT Requirement_Key__c LIKE 'SCREEN_%')
            GROUP BY Supplier__c
        ]) {
            docsTotalByAcc.put((Id) ar.get('sid'), (Integer) ar.get('c'));
        }
        for (AggregateResult ar : [
            SELECT Supplier__c sid, COUNT(Id) c
            FROM   Compliance_Assessment__c
            WHERE  Compliance_Document__c != null
               AND (NOT Requirement_Key__c LIKE 'SCREEN_%')
            GROUP BY Supplier__c
        ]) {
            docsUploadedByAcc.put((Id) ar.get('sid'), (Integer) ar.get('c'));
        }

        ScreeningQueue q = new ScreeningQueue();
        q.rows = new List<SupplierRow>();
        Integer prospective = 0, approved = 0, needsReview = 0, autoCleared = 0;
        Decimal onboardDaysSum = 0; Integer onboardCount = 0;

        for (Account a : [
            SELECT Id, Name, Industry, Risk_Tier__c, Risk_Score__c,
                   Onboarding_Status__c, Risk_Domains__c, Requested_By__c,
                   HITL_Threshold__c, CreatedDate, LastModifiedDate,
                   Stage_Entered_DateTime__c, Analyst_Assigned_DateTime__c
            FROM   Account
            WHERE  RecordType.DeveloperName = 'Supplier'
              AND  Compliance_Case_Status__c != 'Closed - Compliant'
              AND  Compliance_Case_Status__c != 'Closed - Rejected'
            ORDER BY CreatedDate DESC
            LIMIT  200
        ]) {
            SupplierRow r = new SupplierRow();
            r.id            = a.Id;
            r.name          = a.Name;
            r.industry      = a.Industry;
            r.riskTier      = a.Risk_Tier__c;
            r.riskScore     = a.Risk_Score__c;
            r.status        = a.Onboarding_Status__c;
            r.riskDomains   = a.Risk_Domains__c;
            r.requestedBy   = a.Requested_By__c;
            r.flags         = flagsByAcc.containsKey(a.Id) ? flagsByAcc.get(a.Id) : 0;
            r.createdDate   = a.CreatedDate;
            r.ageLabel      = ageLabel(a.CreatedDate);
            r.hitlThreshold = a.HITL_Threshold__c;
            r.routing       = routeDecision(a.Risk_Tier__c, a.HITL_Threshold__c);
            r.aiStatus      = aiStatus(a.Onboarding_Status__c, a.Risk_Tier__c, r.flags, r.routing);
            r.durationLabel = durationLabel(a.CreatedDate);
            r.isAssignedToAnalyst = (a.Analyst_Assigned_DateTime__c != null);
            r.stageAgeLabel = stageAgeLabel(a.Stage_Entered_DateTime__c);
            r.isStalled     = isStalled(a.Stage_Entered_DateTime__c);
            r.docsTotal    = docsTotalByAcc.containsKey(a.Id) ? docsTotalByAcc.get(a.Id) : 0;
            r.docsUploaded = docsUploadedByAcc.containsKey(a.Id) ? docsUploadedByAcc.get(a.Id) : 0;
            r.stageLabel    = queueStage(a.Onboarding_Status__c, r.isAssignedToAnalyst, r.aiStatus, r.docsUploaded, r.docsTotal);
            q.rows.add(r);

            if (a.Onboarding_Status__c == 'In Review') prospective++;
            if (a.Onboarding_Status__c == 'Approved') {
                approved++;
                // Time-to-Onboard proxy: created → last update (when it reached Approved).
                onboardDaysSum += (a.LastModifiedDate.getTime() - a.CreatedDate.getTime())
                                  / (1000.0 * 60 * 60 * 24);
                onboardCount++;
            }
            if (r.flags > 0 || a.Risk_Tier__c == 'High' || a.Risk_Tier__c == 'Critical') needsReview++;
            if (r.routing == 'Auto-approve' && r.flags == 0 && a.Risk_Tier__c != null) autoCleared++;
        }

        q.total       = q.rows.size();
        q.prospective = prospective;
        q.approved    = approved;
        q.needsReview = needsReview;
        q.autoCleared = autoCleared;
        q.avgTimeToOnboardDays = onboardCount > 0
            ? (onboardDaysSum / onboardCount).setScale(1) : null;
        return q;
    }

    // AI pipeline status for the queue (deterministic from tier/flags/routing).
    private static String aiStatus(String onboardingStatus, String tier, Integer flags, String routing) {
        if (onboardingStatus == 'Approved')           return 'Onboarded';
        if (flags != null && flags > 0)               return 'Needs analyst';
        if (routing == 'Needs analyst')               return 'Needs analyst';
        if (String.isNotBlank(tier))                  return 'AI cleared';
        return 'Screening';
    }

    // Tier ordering used by the HITL gate. Threshold shares the value set
    // (minus Critical). Higher number = higher risk.
    private static Integer tierRank(String tier) {
        if (tier == 'Critical') return 4;
        if (tier == 'High')     return 3;
        if (tier == 'Medium')   return 2;
        if (tier == 'Low')      return 1;
        return 0;
    }

    /**
     * The human-in-the-loop routing rule: if the AI risk tier is ABOVE the
     * configured threshold, the case must go to a human analyst; otherwise it
     * can auto-proceed. Threshold defaults to Medium when unset.
     */
    @AuraEnabled(cacheable=true)
    public static String routeDecision(String riskTier, String threshold) {
        if (String.isBlank(riskTier)) return 'Pending';
        Integer t = String.isBlank(threshold) ? 2 : tierRank(threshold);
        return tierRank(riskTier) > t ? 'Needs analyst' : 'Auto-approve';
    }

    private static String mapStage(String status) {
        if (status == 'In Review') return 'Prospective · in review';
        if (status == 'Approved')  return 'Approved';
        if (status == 'Rejected')  return 'Rejected';
        return 'Draft';
    }

    // Single-list queue stage — replaces the old 4-tab bucketing (In review /
    // Drafts / Awaiting documents / Handed to analyst), which lived client-side
    // in scProcurementConsole.js's _inBucket() and had a real bug: it treated
    // aiStatus=='Needs analyst' (the AI's ROUTING RECOMMENDATION, computed the
    // instant risk tier crosses the HITL threshold) as equivalent to an actual
    // handoff — so a supplier the AI merely flagged showed up in "Handed to
    // analyst" before any human had assigned it, making the handoff look
    // automatic when it was never anything but a human clicking Assign
    // (VendorPortalController.assignToAnalyst). isAssignedToAnalyst (from
    // Analyst_Assigned_DateTime__c, set ONLY by assignToAnalyst) is the one
    // signal that actually distinguishes "recommended" from "handed off."
    private static String queueStage(String status, Boolean assigned, String aiStat, Integer docsUploaded, Integer docsTotal) {
        if (status == 'Draft') return 'Draft';
        if (assigned == true)  return 'Handed to Analyst';
        if (aiStat == 'Needs analyst') return 'Flagged - Needs Review';
        if (docsTotal != null && docsTotal > 0 && (docsUploaded == null || docsUploaded < docsTotal)) {
            return 'Awaiting Documents';
        }
        return 'In review';
    }

    private static String ageLabel(Datetime created) {
        if (created == null) return '';
        Long mins = (System.now().getTime() - created.getTime()) / 60000;
        if (mins < 60)        return 'received ' + mins + 'm ago';
        if (mins < 60 * 24)   return 'received ' + (mins / 60) + 'h ago';
        return 'received ' + (mins / (60 * 24)) + 'd ago';
    }

    // Duration the supplier has been in the pipeline (since intake/created). The
    // honest proxy for "time since initial screening" — no separate timestamp.
    private static String durationLabel(Datetime created) {
        if (created == null) return '—';
        Long mins = (System.now().getTime() - created.getTime()) / 60000;
        if (mins < 60)        return mins + 'm';
        if (mins < 60 * 24)   return (mins / 60) + 'h';
        return (mins / (60 * 24)) + 'd';
    }

    // ── "Days in this stage" (SLA/aging indicator) ────────────────────────────
    // Distinct from durationLabel above (total time since the record was
    // created): this is how long the record has sat in whatever
    // Onboarding_Status__c it's CURRENTLY in — set/refreshed by
    // AccountTriggerHandler whenever the status actually changes. A case that
    // just moved to a new stage reads "0h in stage" even if it's been in the
    // pipeline for weeks; a case stuck in one stage for a long time is what
    // this is meant to surface.
    private static final Integer STALLED_THRESHOLD_DAYS = 5;

    private static String stageAgeLabel(Datetime stageEntered) {
        if (stageEntered == null) return '—';
        Long mins = (System.now().getTime() - stageEntered.getTime()) / 60000;
        if (mins < 60)        return mins + 'm in stage';
        if (mins < 60 * 24)   return (mins / 60) + 'h in stage';
        return (mins / (60 * 24)) + 'd in stage';
    }

    private static Boolean isStalled(Datetime stageEntered) {
        if (stageEntered == null) return false;
        Long days = (System.now().getTime() - stageEntered.getTime()) / (60000L * 60 * 24);
        return days >= STALLED_THRESHOLD_DAYS;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Case activity (Screen 5) — the agent/audit run-log for a supplier
    // ═════════════════════════════════════════════════════════════════════════
    public class ActivityRow {
        @AuraEnabled public String   title;
        @AuraEnabled public String   detail;
        @AuraEnabled public String   actor;
        @AuraEnabled public String   whenLabel;
    }

    @AuraEnabled(cacheable=true)
    public static List<ActivityRow> getCaseActivity(Id accountId) {
        List<ActivityRow> rows = new List<ActivityRow>();
        if (accountId == null) return rows;
        if (!Schema.sObjectType.Audit_Log__c.isAccessible()) throw new AuraHandledException(NO_ACCESS);
        for (Audit_Log__c a : [
            SELECT Event_Type__c, New_Value__c, Actor_Type__c, Event_DateTime__c
            FROM   Audit_Log__c
            WHERE  Related_Record_Id__c = :accountId
            ORDER BY Event_DateTime__c DESC
            LIMIT  50
        ]) {
            ActivityRow r = new ActivityRow();
            r.title     = prettyEvent(a.Event_Type__c);
            r.detail    = a.New_Value__c;
            r.actor     = a.Actor_Type__c;
            r.whenLabel = a.Event_DateTime__c == null
                ? '' : a.Event_DateTime__c.format('MMM d, h:mm a');
            rows.add(r);
        }
        return rows;
    }

    private static String prettyEvent(String e) {
        if (e == 'Checklist_Generated')  return 'Generated compliance checklist';
        if (e == 'Compliance_Evaluated') return 'Evaluated document against policy';
        if (e == 'Document_Uploaded')    return 'Document uploaded';
        if (e == 'AI_Extraction')        return 'Extracted document data';
        if (e == 'Manual_Override')      return 'Analyst decision recorded';
        if (e == 'Status_Changed')       return 'Status changed';
        if (e == 'Case_Closed')          return 'Compliance case closed';
        return 'Activity';
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Decision (Screen 6) — persist the human tier + routing decision
    // ═════════════════════════════════════════════════════════════════════════
    @AuraEnabled
    public static String saveDecision(Id accountId, String tier, String route, String rationale) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        if (!Schema.sObjectType.Account.isUpdateable()) throw new AuraHandledException(NO_ACCESS);
        String riskTier = mapUiTier(tier);
        String status   = (tier == 'LOW') ? 'Approved' : 'In Review';

        Account upd = new Account(
            Id                   = accountId,
            Risk_Tier__c         = riskTier,
            Onboarding_Status__c = status
        );
        // A LOW-confirmed tier auto-approves and leaves the analyst's hands
        // for good — clear Analyst_Assigned_DateTime__c (the ONLY signal
        // Procurement's queueStage/isAssignedToAnalyst reads, see
        // getScreeningQueue) so the case stops showing "Handed to Analyst"
        // there. Previously this only changed Onboarding_Status__c, which
        // dropped the case out of getAnalystQueue's 'In Review' filter but
        // left Procurement's queue label stale/wrong — the two screens read
        // two different fields for "is this with the analyst," and only one
        // of them was ever updated here.
        if (status == 'Approved') {
            upd.Analyst_Assigned_DateTime__c = null;
        }
        update Security.stripInaccessible(AccessType.UPDATABLE, new List<Account>{ upd }).getRecords();

        AuditLogService.write(new Audit_Log__c(
            Event_Type__c        = 'Manual_Override',
            Related_Object__c    = 'Supplier',
            Related_Record_Id__c = accountId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'User',
            Source_System__c     = 'Other',
            New_Value__c         = 'Tier=' + riskTier + ' · route=' + route
                + (String.isNotBlank(rationale) ? (' · ' + rationale) : '')
        ));

        return accountId;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Close compliance case — the Analyst's final action once every checklist
    // document is Compliant. Ends the case: pulls the supplier out of BOTH the
    // Analyst queue (getAnalystQueue) and the Procurement queue
    // (getScreeningQueue), and leaves the final score/tier/remarks as the
    // permanent record shown on the Account page (scSupplierRiskDashboard).
    // ═════════════════════════════════════════════════════════════════════════
    @AuraEnabled
    public static void closeComplianceCase(Id accountId, String closingRemarks) {
        closeCaseInternal(accountId, closingRemarks, 'Compliance case closed');
    }

    // Procurement's direct-onboard action (WFL, Issue 5/6): when EVERY
    // checklist document is Procurement-Approved (no Deferred, nothing left
    // undecided), Procurement can onboard the supplier immediately without
    // ever routing the case to an Analyst — the case never enters the Analyst
    // queue at all. Uses the exact same close mechanics as closeComplianceCase
    // (queue removal via Compliance_Case_Status__c, Onboarding_Status__c=
    // Approved, Account-page final record) since both represent the same
    // real-world outcome — "this supplier's compliance case is done" — just
    // reached via a different path (Procurement alone vs. Procurement+Analyst).
    @AuraEnabled
    public static void onboardSupplierDirectly(Id accountId, String closingRemarks) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        if (!Schema.sObjectType.Compliance_Assessment__c.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }

        List<Compliance_Assessment__c> checklist = [
            SELECT Id, Procurement_Decision__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :accountId
            AND    (NOT Requirement_Key__c LIKE 'SCREEN_%')
        ];
        if (checklist.isEmpty()) {
            throw new AuraHandledException('This supplier has no checklist items to onboard.');
        }
        for (Compliance_Assessment__c ca : checklist) {
            if (ca.Procurement_Decision__c != 'Approved') {
                throw new AuraHandledException(
                    'Every checklist document must be Approved (none Deferred or undecided) to onboard directly. '
                    + 'Defer at least one document if this case needs Analyst review instead.');
            }
        }

        closeCaseInternal(accountId, closingRemarks, 'Supplier onboarded directly by Procurement');
    }

    // Shared close mechanics for closeComplianceCase (Analyst) and
    // onboardSupplierDirectly (Procurement) — both remove the case from
    // whichever queue(s) it's currently in and leave the same final record on
    // the Account page. The two callers differ only in WHO can call it and
    // WHAT they gate on (Status__c=Compliant vs. Procurement_Decision__c=
    // Approved) — the actual state change is identical.
    private static void closeCaseInternal(Id accountId, String closingRemarks, String auditPrefix) {
        if (!Schema.sObjectType.Account.isUpdateable()) throw new AuraHandledException(NO_ACCESS);
        update Security.stripInaccessible(AccessType.UPDATABLE, new List<Account>{
            new Account(
                Id                        = accountId,
                Compliance_Case_Status__c = 'Closed - Compliant',
                Onboarding_Status__c      = 'Approved',
                Closing_Remarks__c        = closingRemarks,
                Case_Closed_DateTime__c   = DateTime.now(),
                Case_Closed_By__c         = UserInfo.getUserId()
            )
        }).getRecords();

        AuditLogService.write(new Audit_Log__c(
            Event_Type__c        = 'Case_Closed',
            Related_Object__c    = 'Supplier',
            Related_Record_Id__c = accountId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'User',
            Source_System__c     = 'Other',
            New_Value__c         = auditPrefix
                + (String.isNotBlank(closingRemarks) ? (' · ' + closingRemarks) : '')
        ));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Approver outcome (final review) — ends Phase 1.
    //   'ready'  → Reviewed (Ready for Purchase → Phase 2)
    //   'failed' → Rejected
    // ═════════════════════════════════════════════════════════════════════════
    @AuraEnabled
    public static String setReviewOutcome(Id accountId, String outcome, String comments) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        String status = (outcome == 'ready') ? 'Reviewed' : 'Rejected';
        if (!Schema.sObjectType.Account.isUpdateable()) throw new AuraHandledException(NO_ACCESS);
        update Security.stripInaccessible(AccessType.UPDATABLE, new List<Account>{
            new Account(Id = accountId, Onboarding_Status__c = status)
        }).getRecords();
        AuditLogService.write(new Audit_Log__c(
            Event_Type__c        = 'Status_Changed',
            Related_Object__c    = 'Supplier',
            Related_Record_Id__c = accountId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'User',
            Source_System__c     = 'Other',
            New_Value__c         = 'Approver outcome: '
                + (outcome == 'ready' ? 'Reviewed · Ready for Purchase' : 'Failed · Rejected')
                + (String.isNotBlank(comments) ? (' · ' + comments) : '')
        ));
        return accountId;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Co-pilot feedback (Phase 5 capture) — the analyst accepts/overrides the
    // grounded AI summary; recorded for the learning loop + audit.
    // ═════════════════════════════════════════════════════════════════════════
    @AuraEnabled
    public static void saveCopilotFeedback(Id accountId, String decision, String note) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        AuditLogService.write(new Audit_Log__c(
            Event_Type__c        = 'Manual_Override',
            Related_Object__c    = 'Supplier',
            Related_Record_Id__c = accountId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'User',
            Source_System__c     = 'Other',
            New_Value__c         = 'Co-pilot feedback [' + decision + ']'
                + (String.isNotBlank(note) ? (' — ' + note) : '')
        ));
    }

    private static String mapUiTier(String uiTier) {
        if (uiTier == 'LOW')  return 'Low';
        if (uiTier == 'HIGH') return 'High';
        return 'Medium';
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Supplier Portal token — generates a UUID stored on the Account and returns
    @TestVisible
    static String SUPPLIER_PORTAL_SITE_BASE = 'https://aivendoronboarding-dev-ed.develop.my.site.com/supplierPortal';

    // SYSTEM CONTEXT BY DESIGN (documented CRUD/FLS scanner exception): mints or
    // reads the supplier's durable portal token. Called from the internal
    // document-request emails AND from SubSupplierController's invite flow,
    // which itself runs on behalf of a token-verified guest (Tier-1 supplier
    // inviting a sub-supplier) who holds no Account permissions — so this
    // cannot carry a user-permission guard without breaking that path. Not
    // imported by any LWC; only reachable through those Apex callers.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    @AuraEnabled
    public static String generateSupplierPortalUrl(Id accountId) {
        if (accountId == null) throw new AuraHandledException('Account ID required.');
        Account a = [SELECT Id, Supplier_Portal_Token__c FROM Account WHERE Id = :accountId LIMIT 1];
        if (String.isBlank(a.Supplier_Portal_Token__c)) {
            a.Supplier_Portal_Token__c = generateUUID();
            update a;
        }
        return SUPPLIER_PORTAL_SITE_BASE + '/?token=' + a.Supplier_Portal_Token__c;
    }

    // Resolves a supplier portal token → Account ID.
    // Called by the LWC on the public/guest page before loading the snapshot.
    // Declared without sharing so guest community users can call it.
    @AuraEnabled(cacheable=false)
    public static String resolveSupplierToken(String token) {
        return verifyPortalToken(token);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Guest-portal access verification (security fix)
    //
    // WHY THIS EXISTS: the portal token used to be resolved to an accountId
    // ONCE, at page load — every other guest-callable method just trusted
    // whatever accountId the client sent back on later calls, with nothing
    // re-checking it server-side. Since these methods are `without sharing`
    // (required for guest access) and took a plain client-supplied Id, any
    // guest visitor holding ANY valid portal token could call
    // getSupplierSnapshot/removeSupplierDocument/etc. directly (bypassing the
    // LWC UI) with a DIFFERENT supplier's Account Id and read or modify their
    // data — a real IDOR, not theoretical.
    //
    // FIX: every guest-facing method now takes the TOKEN, not a trusted
    // accountId, and re-resolves it server-side on EVERY call via this
    // helper — mirroring resolveSupplierToken exactly so there is only one
    // definition of "does this token grant access to this account." The
    // token itself stays long-lived (weeks, matching how long a real
    // onboarding can take) — this isn't a short session, it's re-verifying
    // the same durable credential on every request instead of trusting a
    // value the client already had.
    //
    // SYSTEM CONTEXT BY DESIGN (documented CRUD/FLS scanner exception): this
    // Account lookup IS the guest's authorization step — the guest user holds
    // no Account permission, so a CRUD guard here would make every token
    // unusable. Selects only Id, filtered by the exact token.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    public static Id verifyPortalTokenId(String token) {
        if (String.isBlank(token)) throw new AuraHandledException('Token is required.');
        List<Account> matches = [
            SELECT Id FROM Account
            WHERE Supplier_Portal_Token__c = :token.trim()
            LIMIT 1
        ];
        if (matches.isEmpty()) throw new AuraHandledException('Invalid or expired portal link.');
        return matches[0].Id;
    }
    private static String verifyPortalToken(String token) {
        return String.valueOf(verifyPortalTokenId(token));
    }

    // ── Guest-scoped wrappers ───────────────────────────────────────────────
    // Each re-derives accountId from the token, then delegates to the same
    // internal logic the authenticated Procurement/Analyst consoles use — no
    // duplicated business logic, just a verified accountId instead of a
    // trusted one.

    @AuraEnabled(cacheable=false)
    public static SupplierSnapshot getSupplierSnapshotByToken(String token) {
        return getSupplierSnapshotImpl(verifyPortalTokenId(token));
    }

    @AuraEnabled
    public static void removeSupplierDocumentByToken(String token, Id contentDocumentId) {
        Id accountId = verifyPortalTokenId(token);
        // Ownership check: the document must actually belong to THIS supplier
        // (linked to their Account or one of their Compliance_Document__c
        // records) — otherwise a guest could pass any ContentDocumentId in
        // the org and delete a file that isn't theirs.
        if (!documentBelongsToSupplier(contentDocumentId, accountId)) {
            throw new AuraHandledException('Document not found for this supplier.');
        }
        removeSupplierDocumentImpl(accountId, contentDocumentId);
    }

    @AuraEnabled
    public static String addRequirementFromDocumentByToken(String token, String documentTitle, String requirementKey) {
        Id accountId = verifyPortalTokenId(token);
        return addRequirementFromDocumentImpl(accountId, documentTitle, requirementKey);
    }

    // True if contentDocumentId is linked to the supplier's Account directly,
    // or to one of the supplier's own Compliance_Document__c records.
    // SYSTEM CONTEXT BY DESIGN (documented scanner exception): this is the
    // guest path's ownership check — it must run for a user with no object
    // permissions, and it only ever narrows what a guest may touch.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private static Boolean documentBelongsToSupplier(Id contentDocumentId, Id accountId) {
        if (contentDocumentId == null || accountId == null) return false;
        Set<Id> ownedEntityIds = new Set<Id>{ accountId };
        for (Compliance_Document__c cd : [
            SELECT Id FROM Compliance_Document__c WHERE Account__c = :accountId
        ]) {
            ownedEntityIds.add(cd.Id);
        }
        for (ContentDocumentLink l : [
            SELECT LinkedEntityId FROM ContentDocumentLink
            WHERE ContentDocumentId = :contentDocumentId AND LinkedEntityId IN :ownedEntityIds
        ]) {
            return true;
        }
        return false;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Generate public document URLs for iframe preview — creates a
    // ContentDistribution (public sharing link) via the latest ContentVersion.
    //
    // SECURITY: this used to take a bare contentDocumentId with NO ownership
    // check and mint a PERMANENT (PreferencesExpires=false), unauthenticated
    // public URL to it — any caller (including a guest) could pass ANY
    // ContentDocumentId in the org, not just their own supplier's files, and
    // get a link nothing ever expired. Fixed two ways:
    //   1. Every new distribution now expires (30 days — generous for the
    //      preview use case, but bounded, not permanent).
    //   2. Guest callers must go through generatePublicDocumentUrlByToken,
    //      which verifies the document actually belongs to the token's
    //      supplier before minting anything. This internal method stays
    //      callable by the authenticated Procurement/Analyst consoles, which
    //      operate under normal Salesforce auth and can legitimately preview
    //      any supplier's documents.
    // ═════════════════════════════════════════════════════════════════════════
    @AuraEnabled
    public static String generatePublicDocumentUrl(Id contentDocumentId) {
        // ContentDistribution is deliberately not describe-checked: its access
        // is governed by the "Distribute uploaded files" user permission, not
        // object CRUD, and the platform enforces that on the insert itself
        // (PMD AvoidInvalidCrudContentDistribution).
        if (!Schema.sObjectType.ContentVersion.isAccessible()) {
            throw new AuraHandledException(NO_ACCESS);
        }
        return generatePublicDocumentUrlImpl(contentDocumentId);
    }

    // Shared with generatePublicDocumentUrlByToken (guest: token-verified and
    // ownership-checked first) — system context by design, see class header.
    @SuppressWarnings('PMD.ApexCRUDViolation') // guest token path — see class header
    private static String generatePublicDocumentUrlImpl(Id contentDocumentId) {
        if (contentDocumentId == null) throw new AuraHandledException('Content Document ID required.');

        // Get the latest ContentVersion for this ContentDocument
        List<ContentVersion> versions = [
            SELECT Id FROM ContentVersion
            WHERE ContentDocumentId = :contentDocumentId AND IsLatest = true
            LIMIT 1
        ];

        if (versions.isEmpty()) {
            throw new AuraHandledException('No valid document version found.');
        }

        Id contentVersionId = versions[0].Id;

        // Check if a distribution already exists for this version
        List<ContentDistribution> existing = [
            SELECT Id, DistributionPublicUrl
            FROM ContentDistribution
            WHERE ContentVersionId = :contentVersionId
            LIMIT 1
        ];

        if (!existing.isEmpty()) {
            // Public URL already exists, return it
            return existing[0].DistributionPublicUrl;
        }

        // Create a new public distribution linking to the ContentVersion
        ContentDistribution dist = new ContentDistribution();
        dist.ContentVersionId = contentVersionId;
        dist.Name = 'Public Share - ' + System.now().getTime();
        dist.PreferencesAllowViewInBrowser = true;
        dist.PreferencesExpires = true;
        dist.ExpiryDate = Date.today().addDays(30);

        try {
            insert dist;
            // Retrieve the newly created distribution to get the public URL
            ContentDistribution created = [
                SELECT DistributionPublicUrl
                FROM ContentDistribution
                WHERE Id = :dist.Id
                LIMIT 1
            ];
            return created.DistributionPublicUrl;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to generate public document URL: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static String generatePublicDocumentUrlByToken(String token, Id contentDocumentId) {
        Id accountId = verifyPortalTokenId(token);
        if (!documentBelongsToSupplier(contentDocumentId, accountId)) {
            throw new AuraHandledException('Document not found for this supplier.');
        }
        return generatePublicDocumentUrlImpl(contentDocumentId);
    }

    private static String generateUUID() {
        return UUID.randomUUID().toString();
    }
}