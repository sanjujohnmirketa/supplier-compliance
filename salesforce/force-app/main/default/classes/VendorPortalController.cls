public without sharing class VendorPortalController {

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
        List<String> documents
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
        // Persist the supplier so the request is tied to a record
        String accId = upsertSupplier(
            accountId, supplierName, country, requestedBy,
            industry, engagementType, annualSpend, riskDomains,
            supplierEmail, hitlThreshold, 'In Review'
        );

        // Generate a personal portal URL for this supplier (stable: same token on re-send).
        String portalUrl = null;
        try { portalUrl = generateSupplierPortalUrl(accId); } catch (Exception e) { /* non-fatal */ }

        // Build + send the request email
        Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
        msg.setToAddresses(new List<String>{ supplierEmail });
        msg.setSubject('Required compliance documents — ' + supplierName + ' onboarding');
        msg.setPlainTextBody(buildRequestBody(supplierName, documents, portalUrl));
        msg.setSaveAsActivity(false);

        Messaging.SendEmailResult[] results =
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ msg }, false);

        if (results != null && !results.isEmpty() && !results[0].isSuccess()) {
            String err = results[0].getErrors().isEmpty()
                ? 'Unknown error' : results[0].getErrors()[0].getMessage();
            throw new AuraHandledException('Email send failed: ' + err);
        }

        // Audit the request
        Database.insert(new Audit_Log__c(
            Event_Type__c        = 'Status_Changed',
            Related_Object__c    = 'Supplier',
            Related_Record_Id__c = accId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'User',
            Source_System__c     = 'Other',
            New_Value__c         = 'Requested ' + documents.size()
                + ' document(s) from ' + supplierEmail
        ), false);

        return accId;
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
                 + '\nThe portal shows your required checklist, upload status, and AI compliance results in real time.\n';
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
            insert toUpsert;
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
        Account a = [SELECT Name FROM Account WHERE Id = :accountId LIMIT 1];
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
        try {
            return CopilotService.ask(question, a.Name, context);
        } catch (Exception e) {
            throw new AuraHandledException('Co-pilot failed: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=false)
    public static List<CaseDocument> getCaseDocuments(Id accountId) {
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
        } catch (Exception ignored) { /* audit is best-effort */ }

        return ca.Id;
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
        // Risk propagation fields
        // @AuraEnabled public Decimal  riskScore;          // propagated risk score (0-100)
        // @AuraEnabled public Decimal  ownComplianceScore; // own score before sub-supplier influence
        // @AuraEnabled public Boolean  cascadingRiskFlag;  // true = elevated by sub-supplier non-compliance
        // @AuraEnabled public String   cascadingRiskSource; // which sub-suppliers are driving the cascade
    }

    public class AssessmentSummary {
        @AuraEnabled public String requirementKey;
        @AuraEnabled public String requirementLabel;
        @AuraEnabled public String status;        // Compliant | Non-Compliant | Needs Analyst | Pending
        @AuraEnabled public String severity;
        @AuraEnabled public String reason;        // AI summary / reason detail
        @AuraEnabled public String validUntil;    // key date if extracted
        @AuraEnabled public String evaluatedLabel;
        @AuraEnabled public String badgeClass;    // ok | warn | bad | neutral (UI hint)
        @AuraEnabled public Boolean uploaded;     // a document IS linked to this requirement
        @AuraEnabled public String documentTitle; // the linked document's title (for the rejected list)
        @AuraEnabled public Boolean rejected;     // uploaded but failed/unmatched → "Rejected" section
        @AuraEnabled public Integer aiConfidence; // AI engine's 0-100 confidence in this assessment
    }

    @AuraEnabled(cacheable=false)
    public static SupplierSnapshot getSupplierSnapshot(Id accountId) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');

        Account a = [
            SELECT Id, Name, Industry, BillingCountry, Country_of_Origin__c,
                   Risk_Tier__c, Risk_Score__c, Risk_Domains__c, Onboarding_Status__c,
                   Own_Compliance_Score__c, Cascading_Risk_Flag__c, Cascading_Risk_Source__c
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
        // s.riskScore            = a.Risk_Score__c;
        // s.ownComplianceScore   = a.Own_Compliance_Score__c;
        // s.cascadingRiskFlag    = a.Cascading_Risk_Flag__c == true;
        // s.cascadingRiskSource  = a.Cascading_Risk_Source__c;

        s.domains = new List<String>();
        if (String.isNotBlank(a.Risk_Domains__c)) {
            for (String d : a.Risk_Domains__c.split(',')) {
                String t = d.trim();
                if (String.isNotBlank(t)) s.domains.add(t);
            }
        }

        // Documents stored in Salesforce (ContentDocumentLink → ContentVersion).
        s.documents = getCaseDocuments(accountId);
        s.docCount  = s.documents.size();

        // Past AI summaries — one row per assessed requirement.
        s.assessments = new List<AssessmentSummary>();
        for (Compliance_Assessment__c x : [
            SELECT Requirement_Key__c, Requirement_Label__c, Status__c, Severity__c,
                   Reason_Detail__c, Valid_Until__c, Evaluation_DateTime__c,
                   AI_Confidence__c,
                   Compliance_Document__c,
                   Compliance_Document__r.Document_Type__c,
                   Compliance_Document__r.Source_File__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :accountId
            ORDER BY Requirement_Label__c
            LIMIT  100
        ]) {
            AssessmentSummary as1 = new AssessmentSummary();
            as1.requirementKey   = x.Requirement_Key__c;
            as1.requirementLabel = x.Requirement_Label__c;
            as1.status           = String.isBlank(x.Status__c) ? 'Pending' : x.Status__c;
            as1.severity         = x.Severity__c;
            as1.reason           = x.Reason_Detail__c;
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
            as1.rejected = as1.uploaded && (as1.status == 'Non-Compliant');
            as1.aiConfidence = (x.AI_Confidence__c == null) ? null : Integer.valueOf(x.AI_Confidence__c);
            s.assessments.add(as1);
        }
        s.assessedCount = s.assessments.size();
        return s;
    }

    private static String statusBadge(String status) {
        String t = (status == null) ? '' : status.toLowerCase();
        if (t.contains('non-compliant') || t.contains('fail')) return 'bad';
        if (t.contains('needs') || t.contains('review'))       return 'warn';
        if (t.contains('compliant') || t.contains('clear'))    return 'ok';
        return 'neutral';
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

        // Set the owner to the analyst + status so it lands in the analyst queue.
        Account a = new Account(
            Id                   = accountId,
            OwnerId              = analystUserId,
            Onboarding_Status__c = 'In Review'
        );
        update a;

        Database.insert(new Audit_Log__c(
            Event_Type__c        = 'Status_Changed',
            Related_Object__c    = 'Supplier',
            Related_Record_Id__c = accountId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'User',
            Source_System__c     = 'Other',
            New_Value__c         = 'Assigned to analyst ' + analystUserId
                + (String.isNotBlank(note) ? (' · note: ' + note) : '')
        ), false);
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
    }

    // Suppliers that have reached the analyst (in review / handed over). Shows the
    // EXISTING requests. MUST be cacheable=true — it's consumed via @wire in the
    // analyst LWC, and @wire silently returns no data for a non-cacheable method
    // (which is why the queue rendered empty even when rows existed).
    @AuraEnabled(cacheable=true)
    public static List<AnalystQueueRow> getAnalystQueue() {
        // Flag + validated + doc counts per supplier, from persisted assessments.
        Map<Id, Integer> flagsByAcc = new Map<Id, Integer>();
        Map<Id, Integer> docByAcc   = new Map<Id, Integer>();
        Map<Id, Integer> valByAcc   = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Supplier__c sid, COUNT(Id) c
            FROM   Compliance_Assessment__c
            WHERE  Status__c IN ('Non-Compliant','At Risk')
            GROUP BY Supplier__c
        ]) flagsByAcc.put((Id) ar.get('sid'), (Integer) ar.get('c'));
        for (AggregateResult ar : [
            SELECT Supplier__c sid, COUNT(Id) c FROM Compliance_Assessment__c GROUP BY Supplier__c
        ]) docByAcc.put((Id) ar.get('sid'), (Integer) ar.get('c'));
        for (AggregateResult ar : [
            SELECT Supplier__c sid, COUNT(Id) c FROM Compliance_Assessment__c
            WHERE Analyst_Validated__c = true GROUP BY Supplier__c
        ]) valByAcc.put((Id) ar.get('sid'), (Integer) ar.get('c'));

        // The analyst queue shows ONLY suppliers actually ROUTED to an analyst.
        // 'In Review' is the post-routing state (set by assignToAnalyst / the
        // analyst's own route). Pre-routing states (Draft, and the procurement
        // 'Screening' bucket) belong to the Procurement queue, not here.
        List<AnalystQueueRow> out = new List<AnalystQueueRow>();
        for (Account a : [
            SELECT Id, Name, Industry, Risk_Tier__c, Onboarding_Status__c,
                   Requested_By__c, CreatedDate
            FROM   Account
            WHERE  RecordType.DeveloperName = 'Supplier'
              AND  Onboarding_Status__c = 'In Review'
            ORDER BY CreatedDate DESC
            LIMIT  200
        ]) {
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
    }
    public class AnalystCase {
        @AuraEnabled public Id      accountId;
        @AuraEnabled public String  name;
        @AuraEnabled public String  industry;
        @AuraEnabled public String  country;
        @AuraEnabled public String  aiTier;
        @AuraEnabled public Integer docCount;
        @AuraEnabled public Integer validatedCount;
        @AuraEnabled public List<AnalystDoc> docs;
    }

    @AuraEnabled(cacheable=false)
    public static AnalystCase getCaseForAnalyst(Id accountId) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        Account a = [
            SELECT Id, Name, Industry, BillingCountry, Country_of_Origin__c, Risk_Tier__c
            FROM   Account WHERE Id = :accountId LIMIT 1
        ];
        AnalystCase c = new AnalystCase();
        c.accountId = a.Id;
        c.name      = a.Name;
        c.industry  = a.Industry;
        c.country   = String.isNotBlank(a.Country_of_Origin__c) ? a.Country_of_Origin__c : a.BillingCountry;
        c.aiTier    = a.Risk_Tier__c;
        c.docs      = new List<AnalystDoc>();
        Integer validated = 0;
        // Pre-resolve the latest ContentVersion download URL for each uploaded
        // Compliance Document, so the analyst can PREVIEW the real file (not just
        // the AI summary) before marking it validated.
        List<Compliance_Assessment__c> rows = [
            SELECT Id, Requirement_Label__c, Status__c, Severity__c, Reason_Detail__c,
                   Analyst_Comment__c, Analyst_Validated__c, Compliance_Document__c
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
        return c;
    }

    // Persist the analyst's per-document comment + validated flag.
    @AuraEnabled
    public static void saveDocValidation(Id assessmentId, String comment, Boolean validated) {
        if (assessmentId == null) throw new AuraHandledException('No document selected.');
        update new Compliance_Assessment__c(
            Id                  = assessmentId,
            Analyst_Comment__c  = comment,
            Analyst_Validated__c = (validated == true),
            Evaluator_User__c   = UserInfo.getUserId(),
            Evaluation_DateTime__c = System.now()
        );
    }

    // Generative co-pilot: the analyst types a rough observation; the co-pilot
    // returns a polished, professional validation comment grounded on the
    // document's AI summary. Reuses the /copilot callout.
    @AuraEnabled
    public static String copilotDraftComment(Id accountId, String requirementLabel,
                                             String aiSummary, String observation) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        Account a = [SELECT Name FROM Account WHERE Id = :accountId LIMIT 1];
        String context =
            'You are helping a compliance analyst write a concise, professional '
            + 'validation comment for a supplier document. Document: '
            + (String.isBlank(requirementLabel) ? 'document' : requirementLabel)
            + '. AI assessment: ' + (String.isBlank(aiSummary) ? '(none)' : aiSummary.left(800)) + '.';
        String question =
            'The analyst observed: "' + (String.isBlank(observation) ? 'looks acceptable' : observation)
            + '". Write a 1-2 sentence formal validation comment capturing this judgement.';
        try {
            CopilotService.CopilotResponse r = CopilotService.ask(question, a.Name, context);
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
            supplierEmail, hitlThreshold, 'Draft'
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
            supplierEmail, hitlThreshold, 'In Review'
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Submit → documents & screening. Persists the supplier (status 'Screening')
    // and kicks off PRE-DOCUMENT screening asynchronously (the AI engine runs
    // registry / sanctions / conflict / media checks). The user is returned to a
    // refreshed screen; the supplier appears in the screening queue with the
    // screening results already attached when opened.
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
        String hitlThreshold
    ) {
        if (String.isBlank(supplierName)) {
            throw new AuraHandledException('Supplier legal entity name is required.');
        }
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
        String accId = upsertSupplier(
            existingId, supplierName, country, requestedBy,
            industry, engagementType, annualSpend, riskDomains,
            supplierEmail, hitlThreshold, 'Screening'
        );
        // 2. Run pre-document screening asynchronously (callout-after-DML rule).
        System.enqueueJob(new ScreeningQueueable((Id) accId));
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
        String status
    ) {
        if (String.isBlank(supplierName)) {
            throw new AuraHandledException('Supplier name is required.');
        }

        Boolean isUpdate = String.isNotBlank(accountId);

        Account acc = isUpdate ? new Account(Id = accountId) : new Account();
        acc.Name                     = supplierName.trim();
        acc.BillingCountry           = country;
        acc.Requested_By__c          = requestedBy;
        acc.Industry                 = industry;
        acc.Engagement_Type__c       = engagementType;
        acc.Risk_Domains__c          = riskDomains;
        acc.Onboarding_Status__c     = status;
        if (String.isNotBlank(supplierEmail)) {
            acc.Supplier_Contact_Email__c = supplierEmail;
        }
        if (String.isNotBlank(hitlThreshold)) {
            acc.HITL_Threshold__c = hitlThreshold;
        }

        if (String.isNotBlank(annualSpend)) {
            String cleaned = annualSpend.replaceAll('[^0-9.]', '');
            if (String.isNotBlank(cleaned)) {
                try {
                    acc.Annual_Spend_Est__c = Decimal.valueOf(cleaned);
                } catch (Exception e) { /* leave null if unparseable */ }
            }
        }

        if (isUpdate) {
            update acc;
            return accountId;
        } else {
            insert acc;
            // Create linked Supplier Profile only on first save
            Supplier_Profile__c sp = new Supplier_Profile__c();
            sp.Account__c = acc.Id;
            insert sp;
            return acc.Id;
        }
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
        @AuraEnabled public Integer  confidence;     // supplier-level AI confidence, avg of doc assessments (E3)
    }

    @AuraEnabled(cacheable=true)
    public static ScreeningQueue getScreeningQueue() {
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

        // Supplier-level AI confidence = average of its document assessments (E3).
        Map<Id, Decimal> confByAcc = new Map<Id, Decimal>();
        for (AggregateResult ar : [
            SELECT Supplier__c sid, AVG(AI_Confidence__c) avgc
            FROM   Compliance_Assessment__c
            WHERE  AI_Confidence__c != null
               AND (NOT Requirement_Key__c LIKE 'SCREEN_%')
            GROUP BY Supplier__c
        ]) {
            confByAcc.put((Id) ar.get('sid'), (Decimal) ar.get('avgc'));
        }

        ScreeningQueue q = new ScreeningQueue();
        q.rows = new List<SupplierRow>();
        Integer prospective = 0, approved = 0, needsReview = 0, autoCleared = 0;
        Decimal onboardDaysSum = 0; Integer onboardCount = 0;

        for (Account a : [
            SELECT Id, Name, Industry, Risk_Tier__c, Risk_Score__c,
                   Onboarding_Status__c, Risk_Domains__c, Requested_By__c,
                   HITL_Threshold__c, CreatedDate, LastModifiedDate
            FROM   Account
            WHERE  RecordType.DeveloperName = 'Supplier'
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
            r.stageLabel    = mapStage(a.Onboarding_Status__c);
            r.riskDomains   = a.Risk_Domains__c;
            r.requestedBy   = a.Requested_By__c;
            r.flags         = flagsByAcc.containsKey(a.Id) ? flagsByAcc.get(a.Id) : 0;
            r.createdDate   = a.CreatedDate;
            r.ageLabel      = ageLabel(a.CreatedDate);
            r.hitlThreshold = a.HITL_Threshold__c;
            r.routing       = routeDecision(a.Risk_Tier__c, a.HITL_Threshold__c);
            r.aiStatus      = aiStatus(a.Onboarding_Status__c, a.Risk_Tier__c, r.flags, r.routing);
            r.durationLabel = durationLabel(a.CreatedDate);
            r.confidence    = confByAcc.containsKey(a.Id) ? Integer.valueOf(confByAcc.get(a.Id).round()) : null;
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
        return 'Activity';
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Decision (Screen 6) — persist the human tier + routing decision
    // ═════════════════════════════════════════════════════════════════════════
    @AuraEnabled
    public static String saveDecision(Id accountId, String tier, String route, String rationale) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        String riskTier = mapUiTier(tier);
        String status   = (tier == 'LOW') ? 'Approved' : 'In Review';

        update new Account(
            Id                   = accountId,
            Risk_Tier__c         = riskTier,
            Onboarding_Status__c = status
        );

        Database.insert(new Audit_Log__c(
            Event_Type__c        = 'Manual_Override',
            Related_Object__c    = 'Supplier',
            Related_Record_Id__c = accountId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'User',
            Source_System__c     = 'Other',
            New_Value__c         = 'Tier=' + riskTier + ' · route=' + route
                + (String.isNotBlank(rationale) ? (' · ' + rationale) : '')
        ), false);

        return accountId;
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
        update new Account(Id = accountId, Onboarding_Status__c = status);
        Database.insert(new Audit_Log__c(
            Event_Type__c        = 'Status_Changed',
            Related_Object__c    = 'Supplier',
            Related_Record_Id__c = accountId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'User',
            Source_System__c     = 'Other',
            New_Value__c         = 'Approver outcome: '
                + (outcome == 'ready' ? 'Reviewed · Ready for Purchase' : 'Failed · Rejected')
                + (String.isNotBlank(comments) ? (' · ' + comments) : '')
        ), false);
        return accountId;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Co-pilot feedback (Phase 5 capture) — the analyst accepts/overrides the
    // grounded AI summary; recorded for the learning loop + audit.
    // ═════════════════════════════════════════════════════════════════════════
    @AuraEnabled
    public static void saveCopilotFeedback(Id accountId, String decision, String note) {
        if (accountId == null) throw new AuraHandledException('No supplier selected.');
        Database.insert(new Audit_Log__c(
            Event_Type__c        = 'Manual_Override',
            Related_Object__c    = 'Supplier',
            Related_Record_Id__c = accountId,
            Event_DateTime__c    = DateTime.now(),
            Actor_Type__c        = 'User',
            Source_System__c     = 'Other',
            New_Value__c         = 'Co-pilot feedback [' + decision + ']'
                + (String.isNotBlank(note) ? (' — ' + note) : '')
        ), false);
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
        if (String.isBlank(token)) throw new AuraHandledException('Token is required.');
        List<Account> matches = [
            SELECT Id FROM Account
            WHERE Supplier_Portal_Token__c = :token.trim()
            LIMIT 1
        ];
        if (matches.isEmpty()) throw new AuraHandledException('Invalid or expired portal link.');
        return matches[0].Id;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Generate public document URLs for iframe preview — creates a
    // ContentDistribution (public sharing link) via the latest ContentVersion.
    // ═════════════════════════════════════════════════════════════════════════
    @AuraEnabled
    public static String generatePublicDocumentUrl(Id contentDocumentId) {
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
        dist.PreferencesExpires = false;  // No expiration
        
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

    private static String generateUUID() {
        Blob b = Crypto.generateAesKey(128);
        String h = EncodingUtil.convertToHex(b);
        return h.substring(0,8)  + '-' + h.substring(8,12)  + '-' +
               h.substring(12,16) + '-' + h.substring(16,20) + '-' +
               h.substring(20,32);
    }
}