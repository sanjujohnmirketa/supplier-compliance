/**
 * SubSupplierController — manages Tier 2 / Tier 3 sub-supplier onboarding
 * initiated by a logged-in Tier 1 supplier from scSupplierPortal (SP4).
 *
 * Flow:
 *   1. Supplier fills invite form → inviteSubSupplier() is called
 *   2. A new Account (sub-supplier) is created under the caller's Account (ParentId)
 *   3. A Contact is created for the invite recipient
 *   4. A Salesforce community portal User is provisioned via direct User insert
 *      (best-effort — falls back to token-URL-only if no community profile is found)
 *   5. A Supplier_Portal_Token__c is generated so the token-URL always works
 *   6. An invitation email is sent with the portal access link
 *
 * IMPORTANT — prerequisite field:
 *   Account.Tier__c (Text, picklist or free-text) must exist.
 *   Expected values: 'Tier 1', 'Tier 2', 'Tier 3'.
 *   If the field does not exist, add it via Setup → Object Manager → Account → Fields.
 */
public without sharing class SubSupplierController {

    // ─── DTOs ─────────────────────────────────────────────────────────────────

    public class SubSupplierRow {
        @AuraEnabled public Id      accountId;
        @AuraEnabled public String  company;
        @AuraEnabled public String  country;
        @AuraEnabled public String  tier;
        @AuraEnabled public String  status;
        @AuraEnabled public String  email;
        @AuraEnabled public Integer docCount;
        @AuraEnabled public String  ageLabel;
        @AuraEnabled public String  badgeClass;
    }

    public class InviteResult {
        @AuraEnabled public String  accountId;
        @AuraEnabled public String  contactId;
        @AuraEnabled public String  portalUrl;
        @AuraEnabled public Boolean userCreated;
        @AuraEnabled public String  tempPassword;
        @AuraEnabled public String  username;
    }

    public class RequirementRow {
        @AuraEnabled public String id;
        @AuraEnabled public String label;
        @AuraEnabled public String severity;
        @AuraEnabled public String severityBadge;
    }

    // ─── getRequirementsForParent ─────────────────────────────────────────────
    // Returns the Tier 1 supplier's compliance checklist so the invite modal
    // can let them select which items the sub-supplier must also provide.

    @AuraEnabled(cacheable=false)
    public static List<RequirementRow> getRequirementsForParent(Id parentAccountId) {
        List<RequirementRow> out = new List<RequirementRow>();
        if (parentAccountId == null) return out;
        for (Compliance_Assessment__c a : [
            SELECT Id, Requirement_Label__c, Requirement_Key__c, Severity__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :parentAccountId
            ORDER BY Requirement_Label__c ASC
            LIMIT  100
        ]) {
            RequirementRow r = new RequirementRow();
            r.id           = a.Id;
            r.label        = String.isNotBlank(a.Requirement_Label__c)
                             ? a.Requirement_Label__c : a.Requirement_Key__c;
            r.severity     = String.isNotBlank(a.Severity__c) ? a.Severity__c : 'Medium';
            r.severityBadge = sevBadgeClass(a.Severity__c);
            out.add(r);
        }
        return out;
    }

    // ─── getSubSuppliers ──────────────────────────────────────────────────────
    // Returns sub-suppliers whose ParentId = parentAccountId.

    @AuraEnabled(cacheable=false)
    public static List<SubSupplierRow> getSubSuppliers(Id parentAccountId) {
        if (parentAccountId == null) return new List<SubSupplierRow>();

        // Assessment count per sub-supplier account (proxy for "docs submitted")
        Set<Id> childIds = new Set<Id>();
        for (Account a : [SELECT Id FROM Account WHERE ParentId = :parentAccountId
                           AND RecordType.DeveloperName = 'Supplier']) {
            childIds.add(a.Id);
        }

        Map<Id, Integer> docCountMap = new Map<Id, Integer>();
        if (!childIds.isEmpty()) {
            for (AggregateResult ar : [
                SELECT Supplier__c sid, COUNT(Id) c
                FROM   Compliance_Assessment__c
                WHERE  Supplier__c IN :childIds
                GROUP BY Supplier__c
            ]) {
                docCountMap.put((Id) ar.get('sid'), (Integer) ar.get('c'));
            }
        }

        List<SubSupplierRow> out = new List<SubSupplierRow>();
        for (Account a : [
            SELECT Id, Name, BillingCountry, Country_of_Origin__c,
                   Supplier_Tier__c, Onboarding_Status__c, Supplier_Contact_Email__c, CreatedDate
            FROM   Account
            WHERE  ParentId = :parentAccountId
              AND  RecordType.DeveloperName = 'Supplier'
            ORDER BY CreatedDate DESC
            LIMIT  100
        ]) {
            SubSupplierRow r = new SubSupplierRow();
            r.accountId  = a.Id;
            r.company    = a.Name;
            r.country    = String.isNotBlank(a.Country_of_Origin__c)
                           ? a.Country_of_Origin__c : a.BillingCountry;
            r.tier       = a.Supplier_Tier__c;
            r.status     = a.Onboarding_Status__c;
            r.email      = a.Supplier_Contact_Email__c;
            r.docCount   = docCountMap.containsKey(a.Id) ? docCountMap.get(a.Id) : 0;
            r.ageLabel   = ageLabel(a.CreatedDate);
            r.badgeClass = statusBadge(a.Onboarding_Status__c);
            out.add(r);
        }
        return out;
    }

    // ─── inviteSubSupplier ────────────────────────────────────────────────────

    @AuraEnabled
    public static InviteResult inviteSubSupplier(
        Id      parentAccountId,
        String  company,
        String  firstName,
        String  lastName,
        String  email,
        String  phone,
        String  category,
        String  country,
        String  tier,
        String  message,
        String  expiryDays,
        String  selectedRequirementIds
    ) {
        // ── Validation ──────────────────────────────────────────────────────
        List<String> errs = new List<String>();
        if (parentAccountId == null)   errs.add('Parent account is required.');
        if (String.isBlank(company))   errs.add('Company name is required.');
        if (String.isBlank(firstName)) errs.add('First name is required.');
        if (String.isBlank(email))     errs.add('Email is required.');
        if (String.isBlank(category))  errs.add('Supplier category is required.');
        if (String.isBlank(country))   errs.add('Country is required.');
        if (String.isBlank(tier))      errs.add('Supplier tier is required.');
        if (!errs.isEmpty()) throw new AuraHandledException(String.join(errs, ' '));

        if (!Pattern.matches('^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$', email)) {
            throw new AuraHandledException('Please enter a valid email address.');
        }

        Account parent = [SELECT Id, Name FROM Account WHERE Id = :parentAccountId LIMIT 1];
        String  safeLastName = String.isNotBlank(lastName) ? lastName : company;

        // ── 1. Upsert sub-supplier Account ──────────────────────────────────
        // Match on parentId + email to avoid duplicates on re-invite.
        List<Account> existing = [
            SELECT Id FROM Account
            WHERE  ParentId = :parentAccountId
              AND  Supplier_Contact_Email__c = :email
              AND  RecordType.DeveloperName  = 'Supplier'
            LIMIT  1
        ];

        Account subAcc;
        if (!existing.isEmpty()) {
            subAcc = new Account(Id = existing[0].Id);
        } else {
            subAcc = new Account();
            List<RecordType> rts = [
                SELECT Id FROM RecordType
                WHERE DeveloperName = 'Supplier' AND SObjectType = 'Account'
                LIMIT 1
            ];
            if (!rts.isEmpty()) subAcc.RecordTypeId = rts[0].Id;
        }

        subAcc.Name                     = company.trim();
        subAcc.ParentId                 = parentAccountId;
        subAcc.BillingCountry           = country;
        subAcc.Country_of_Origin__c     = country;
        subAcc.Industry                 = category;
        subAcc.Supplier_Tier__c                  = tier;
        subAcc.Supplier_Contact_Email__c = email;
        // Use 'Draft' as initial status (Onboarding_Status__c picklist values
        // are: Draft, Screening, In Review, Approved, Reviewed, Rejected).
        // The sub-supplier becomes 'Screening' once they log in and upload.
        subAcc.Onboarding_Status__c     = 'Draft';
        // When the Tier 1 supplier selected specific requirements below, that
        // curated subset (copied at 1b) IS this account's checklist — the
        // trigger-fired ScopeCalloutQueueable must not also seed a full
        // /scope-derived checklist on top of it (that's what let the
        // sub-supplier see every document instead of just the 3 selected).
        // If nothing was selected, leave it unset so a full default checklist
        // still gets seeded rather than leaving the sub-supplier with none.
        subAcc.Checklist_Seeded_By_Caller__c = String.isNotBlank(selectedRequirementIds);

        if (existing.isEmpty()) {
            insert subAcc;
            try { insert new Supplier_Profile__c(Account__c = subAcc.Id); }
            catch (Exception e) { IntegrationErrorLogger.log(subAcc.Id, 'SubSupplierController', 'Supplier_Profile__c creation failed: ' + e.getMessage()); }
        } else {
            update subAcc;
        }

        // ── 1b. Copy selected compliance requirements onto the sub-supplier ──
        List<Compliance_Assessment__c> selectedReqs = new List<Compliance_Assessment__c>();
        if (String.isNotBlank(selectedRequirementIds)) {
            Set<Id> reqIds = new Set<Id>();
            for (String s : selectedRequirementIds.split(',')) {
                if (String.isNotBlank(s)) reqIds.add((Id) s.trim());
            }
            if (!reqIds.isEmpty()) {
                List<Compliance_Assessment__c> toUpsert = new List<Compliance_Assessment__c>();
                for (Compliance_Assessment__c src : [
                    SELECT Requirement_Label__c, Requirement_Key__c, Severity__c
                    FROM   Compliance_Assessment__c WHERE Id IN :reqIds
                ]) {
                    selectedReqs.add(src);
                    // Requirement_Key__c is a unique External ID — copying the parent's key
                    // verbatim would fail (DUPLICATE_VALUE). Build a new key scoped to the
                    // sub-supplier's account so it's globally unique. Strip any existing
                    // account-prefix (format: "{accountId15}__{base}") first.
                    String baseKey = String.isNotBlank(src.Requirement_Key__c)
                        ? (src.Requirement_Key__c.contains('__')
                           ? src.Requirement_Key__c.substringAfter('__')
                           : src.Requirement_Key__c)
                        : (String.isNotBlank(src.Requirement_Label__c)
                           ? src.Requirement_Label__c.toUpperCase().replaceAll('[^A-Z0-9]', '_').left(40)
                           : 'REQ');
                    String newKey = String.valueOf(subAcc.Id).left(15) + '__' + baseKey;
                    toUpsert.add(new Compliance_Assessment__c(
                        Supplier__c          = subAcc.Id,
                        Requirement_Label__c = src.Requirement_Label__c,
                        Requirement_Key__c   = newKey,
                        Severity__c          = src.Severity__c,
                        Status__c            = 'Pending'
                    ));
                }
                if (!toUpsert.isEmpty()) {
                    try {
                        upsert toUpsert Requirement_Key__c;
                        // Checklist_Seeded_By_Caller__c=true (set above) stops
                        // the trigger-fired ScopeCalloutQueueable from also
                        // seeding a checklist — which means it never sets
                        // Checklist_Item_Count__c for THIS account either
                        // (that write is itself gated on being the one doing
                        // the seeding). Left null, RiskScoreService.computeScore
                        // falls back to counting only resolved outcomes instead
                        // of the true checklist size, so an early Approve can
                        // inflate the score the same way the P1 checklist-freeze
                        // bug did. Set it here, once, to the curated count.
                        update new Account(Id = subAcc.Id, Checklist_Item_Count__c = toUpsert.size());
                    } catch (Exception e) {
                        System.debug('[SubSupplier] Requirement copy failed: ' + e.getMessage());
                    }
                }
            }
        }

        // ── 2. Upsert Contact ────────────────────────────────────────────────
        List<Contact> existingCons = [
            SELECT Id FROM Contact WHERE AccountId = :subAcc.Id AND Email = :email LIMIT 1
        ];
        Contact con;
        if (!existingCons.isEmpty()) {
            con = new Contact(Id = existingCons[0].Id,
                              FirstName = firstName, LastName = safeLastName, Phone = phone);
            update con;
        } else {
            con = new Contact(AccountId = subAcc.Id, FirstName = firstName,
                              LastName = safeLastName, Email = email, Phone = phone);
            insert con;
        }

        // ── 3. Provision community portal User ──────────────────────────────
        // Site.createExternalUser() is the right API for community user creation
        // (bypasses the 'Manage Users' permission check for the running user).
        // It requires a community site to be active — wrapped in try/catch so
        // the invite still completes (token URL) even without a live community.
        InviteResult result = new InviteResult();
        result.accountId   = subAcc.Id;
        result.contactId   = con.Id;
        result.userCreated = false;

        List<User> existingUsers = [
            SELECT Id FROM User WHERE ContactId = :con.Id AND IsActive = true LIMIT 1
        ];
        if (existingUsers.isEmpty()) {
            try {
                // Query by license type rather than exact profile name so this works
                // across all org editions (Developer, Enterprise, Partner, etc.).
                // LicenseDefinitionKey values for community licences:
                //   CUSTOMER_COMMUNITY          → Customer Community
                //   CUSTOMER_COMMUNITY_LOGIN    → Customer Community Login
                //   PARTNER_COMMUNITY           → Partner Community
                //   PARTNER_COMMUNITY_LOGIN     → Partner Community Login
                List<Profile> profiles = [
                    SELECT Id, Name
                    FROM   Profile
                    WHERE  UserLicense.LicenseDefinitionKey
                               IN ('PID_Customer_Community_Login',
                                   'PID_Customer_Community',
                                   'PID_Customer_Community_Plus_Login',
                                   'PID_Customer_Community_Plus')
                    ORDER BY Name ASC
                    LIMIT  1
                ];

                if (profiles.isEmpty()) {
                    System.debug('[SubSupplier] No community profile found — skipping user creation. '
                        + 'Enable Experience Cloud and assign a Customer Community licence.');
                } else {
                    String orgSuffix = String.valueOf(UserInfo.getOrganizationId()).right(6);
                    String username  = (email.toLowerCase() + '.' + orgSuffix).left(80);
                    String nickname  = buildNickname(firstName, safeLastName, subAcc.Id);

                    User newUser = new User(
                        Username          = username,
                        Email             = email,
                        FirstName         = firstName,
                        LastName          = safeLastName,
                        Alias             = buildAlias(firstName, safeLastName),
                        CommunityNickname = nickname,
                        ProfileId         = profiles[0].Id,
                        ContactId         = con.Id,
                        TimeZoneSidKey    = 'America/New_York',
                        LocaleSidKey      = 'en_US',
                        EmailEncodingKey  = 'UTF-8',
                        LanguageLocaleKey = 'en_US',
                        IsActive          = true
                    );
                    // Direct insert works from any Apex context (without sharing).
                    // Site.createExternalUser() is intentionally NOT used here because
                    // it requires the HTTP request to originate from within an active
                    // Experience Cloud site — it fails when called from LWC/Aura stack.
                    insert newUser;
                    result.userCreated = true;
                    System.debug('[SubSupplier] Portal user created: ' + newUser.Id
                        + ' using profile: ' + profiles[0].Name);
                    // Set a temporary password and embed it in our branded email.
                    // This avoids relying on Salesforce's system reset email which
                    // is often blocked in sandbox or lands in spam.
                    String tempPwd = generateTempPassword();
                    try {
                        System.setPassword(newUser.Id, tempPwd);
                        result.tempPassword = tempPwd;
                        result.username     = username;
                    } catch (Exception pe) {
                        System.debug('[SubSupplier] setPassword failed: ' + pe.getMessage());
                    }
                }
            } catch (Exception e) {
                // Surface the real reason in the debug log so admins can diagnose.
                // The invite itself still succeeds — the supplier uses the token URL.
                System.debug('[SubSupplier] Portal user creation failed: ' + e.getMessage());
                result.userCreated = false;
            }
        } else {
            result.userCreated = true;
            // User already exists — set a fresh temp password so re-invites still
            // deliver working credentials even when the original was forgotten.
            try {
                User existingUser = [SELECT Id, Username FROM User
                                     WHERE ContactId = :con.Id AND IsActive = true LIMIT 1];
                String tempPwd = generateTempPassword();
                System.setPassword(existingUser.Id, tempPwd);
                result.tempPassword = tempPwd;
                result.username     = existingUser.Username;
            } catch (Exception pe) {
                System.debug('[SubSupplier] setPassword (existing user) failed: ' + pe.getMessage());
            }
        }

        // ── 4. Generate portal token URL (always available as fallback) ──────
        String portalUrl = null;
        try {
            portalUrl = VendorPortalController.generateSupplierPortalUrl(subAcc.Id);
        } catch (Exception e) {
            System.debug('[SubSupplier] Portal URL generation failed: ' + e.getMessage());
        }
        result.portalUrl = portalUrl;

        // ── 5. Send invitation email ─────────────────────────────────────────
        System.debug('[SubSupplier] Email creds — username: ' + result.username
            + ' | tempPassword set: ' + String.isNotBlank(result.tempPassword));
        try {
            sendInvitationEmail(email, firstName, company, parent.Name,
                                tier, message, portalUrl, expiryDays,
                                result.username, result.tempPassword, selectedReqs);
        } catch (Exception e) {
            throw new AuraHandledException(
                'Sub-supplier account created but email send failed: ' + e.getMessage());
        }

        // ── 6. Audit trail ───────────────────────────────────────────────────
        try {
            Database.insert(new Audit_Log__c(
                Event_Type__c        = 'Status_Changed',
                Related_Object__c    = 'Supplier',
                Related_Record_Id__c = subAcc.Id,
                Event_DateTime__c    = DateTime.now(),
                Actor_Type__c        = 'User',
                Source_System__c     = 'Other',
                New_Value__c         = 'Sub-supplier invited — email: ' + email
                    + ', tier: ' + tier + ', parent: ' + parentAccountId
                    + ', portal user: ' + result.userCreated
            ), false);
        } catch (Exception e) { IntegrationErrorLogger.log(subAcc.Id, 'SubSupplierController', 'Audit_Log__c write failed: ' + e.getMessage()); }

        return result;
    }

    // ─── Email builder ────────────────────────────────────────────────────────

    private static void sendInvitationEmail(
        String  toEmail,
        String  firstName,
        String  company,
        String  parentName,
        String  tier,
        String  personalMessage,
        String  portalUrl,
        String  expiryDays,
        String  username,
        String  tempPassword,
        List<Compliance_Assessment__c> requirements
    ) {
        String htmlBody = buildInvitationHtml(
            firstName, company, parentName, tier, personalMessage, portalUrl, expiryDays,
            username, tempPassword, requirements);

        Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
        msg.setToAddresses(new List<String>{ toEmail });
        msg.setSubject('You\'ve been invited to join ' + parentName + '\'s supplier network');
        msg.setHtmlBody(htmlBody);
        msg.setSaveAsActivity(false);

        List<OrgWideEmailAddress> orgEmails = [SELECT Id FROM OrgWideEmailAddress LIMIT 1];
        if (!orgEmails.isEmpty()) msg.setOrgWideEmailAddressId(orgEmails[0].Id);

        Messaging.SendEmailResult[] results =
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ msg }, false);

        if (results != null && !results.isEmpty() && !results[0].isSuccess()) {
            String errMsg = results[0].getErrors().isEmpty()
                ? 'Unknown send error' : results[0].getErrors()[0].getMessage();
            throw new AuraHandledException('Email send failed: ' + errMsg);
        }
    }

    private static String buildInvitationHtml(
        String  firstName,
        String  company,
        String  parentName,
        String  tier,
        String  personalMessage,
        String  portalUrl,
        String  expiryDays,
        String  username,
        String  tempPassword,
        List<Compliance_Assessment__c> requirements
    ) {
        String displayName = String.isNotBlank(firstName) ? firstName : company;
        List<String> p = new List<String>{
            '<!DOCTYPE html><html><head><meta charset="UTF-8">',
            '<style>',
            'body{font-family:Arial,Helvetica,sans-serif;color:#1d1d1d;margin:0;padding:0;background:#f4f6fb;}',
            '.w{max-width:600px;margin:32px auto;background:#fff;border-radius:8px;overflow:hidden;border:1px solid #ddd;}',
            '.hdr{background:#166534;padding:28px 36px;}',
            '.hdr h1{color:#fff;margin:0;font-size:20px;font-weight:700;}',
            '.hdr p{color:#bbf7d0;margin:6px 0 0;font-size:13px;}',
            '.body{padding:28px 36px;}',
            'p{font-size:14px;line-height:1.7;margin:0 0 14px;}',
            '.tier{display:inline-block;background:#dcfce7;color:#166534;font-size:12px;',
            '      font-weight:700;padding:2px 10px;border-radius:10px;margin-left:4px;}',
            '.note{background:#fffbee;border-left:4px solid #ca8700;padding:12px 16px;',
            '      margin:16px 0;font-size:13px;color:#514f4d;border-radius:0 4px 4px 0;font-style:italic;}',
            '.cta{text-align:center;margin:28px 0 16px;}',
            '.btn{display:inline-block;padding:12px 32px;background:#166534;color:#fff !important;',
            '     text-decoration:none;border-radius:6px;font-size:15px;font-weight:700;}',
            '.expire{font-size:11px;color:#888;text-align:center;margin-top:8px;}',
            '.ftr{background:#f4f6fb;padding:14px 36px;font-size:12px;color:#706e6b;text-align:center;}',
            '</style></head><body><div class="w">',
            '<div class="hdr">',
            '<h1>Supplier Network Invitation</h1>',
            '<p>From ' + esc(parentName) + '</p>',
            '</div>',
            '<div class="body">',
            '<p>Hi <strong>' + esc(displayName) + '</strong>,</p>',
            '<p><strong>' + esc(parentName) + '</strong> has invited ',
            '<strong>' + esc(company) + '</strong> to join their supplier compliance network ',
            'as a <span class="tier">' + esc(tier) + '</span> sub-supplier.</p>',
            '<p>Once you accept, your organisation will be registered on the compliance platform ',
            'where you can manage required documents, track your compliance status, and communicate ',
            'directly with your supply chain partner.</p>',
            '<p>Use the login credentials below to access the supplier portal. '
            + 'You will be prompted to change your password after your first login.</p>'
        };

        if (String.isNotBlank(username) && String.isNotBlank(tempPassword)) {
            p.add('<table style="width:100%;border-collapse:collapse;margin:16px 0;font-size:13px;">');
            p.add('<tr><td style="background:#f4f6fb;border:1px solid #ddd;padding:10px 14px;width:40%;font-weight:700;color:#374151;">Username</td>');
            p.add('<td style="background:#fff;border:1px solid #ddd;padding:10px 14px;font-family:monospace;color:#166534;">' + esc(username) + '</td></tr>');
            p.add('<tr><td style="background:#f4f6fb;border:1px solid #ddd;padding:10px 14px;font-weight:700;color:#374151;">Temporary Password</td>');
            p.add('<td style="background:#fff;border:1px solid #ddd;padding:10px 14px;font-family:monospace;color:#166534;">' + esc(tempPassword) + '</td></tr>');
            p.add('</table>');
            p.add('<p style="font-size:12px;color:#888;margin-top:-8px;">Please change your password after your first login.</p>');
        }

        if (String.isNotBlank(personalMessage)) {
            p.add('<div class="note">"' + esc(personalMessage) + '"</div>');
        }

        if (requirements != null && !requirements.isEmpty()) {
            p.add('<p style="font-weight:700;font-size:13px;margin:18px 0 6px;color:#1d1d1d;">Compliance documents required from you:</p>');
            p.add('<table style="width:100%;border-collapse:collapse;font-size:12.5px;margin-bottom:16px;">');
            p.add('<thead><tr>');
            p.add('<th style="text-align:left;padding:7px 10px;background:#f4f6fb;border:1px solid #ddd;color:#374151;">Document</th>');
            p.add('<th style="text-align:left;padding:7px 10px;background:#f4f6fb;border:1px solid #ddd;color:#374151;width:90px;">Severity</th>');
            p.add('<th style="text-align:left;padding:7px 10px;background:#f4f6fb;border:1px solid #ddd;color:#374151;width:80px;">Status</th>');
            p.add('</tr></thead><tbody>');
            for (Compliance_Assessment__c r : requirements) {
                String sev   = String.isNotBlank(r.Severity__c) ? r.Severity__c : 'Medium';
                String sevBg = sev == 'Critical' ? '#fef2f2' : sev == 'High' ? '#fff7ed'
                             : sev == 'Low' ? '#f0fdf4' : '#f0f9ff';
                String sevColor = sev == 'Critical' ? '#991b1b' : sev == 'High' ? '#9a3412'
                                : sev == 'Low' ? '#166534' : '#075985';
                p.add('<tr>');
                p.add('<td style="padding:7px 10px;border:1px solid #ddd;color:#1d1d1d;"><strong>'
                    + esc(r.Requirement_Label__c) + '</strong></td>');
                p.add('<td style="padding:7px 10px;border:1px solid #ddd;">');
                p.add('<span style="background:' + sevBg + ';color:' + sevColor
                    + ';padding:2px 8px;border-radius:10px;font-size:11px;font-weight:700;">'
                    + esc(sev) + '</span></td>');
                p.add('<td style="padding:7px 10px;border:1px solid #ddd;color:#888;">Pending</td>');
                p.add('</tr>');
            }
            p.add('</tbody></table>');
        }

        if (String.isNotBlank(portalUrl)) {
            p.add('<div class="cta">');
            p.add('<a class="btn" href="' + esc(portalUrl) + '">Accept &amp; Access Supplier Portal &rarr;</a>');
            Integer expiryInt = String.isNotBlank(expiryDays) ? Integer.valueOf(expiryDays) : 0;
            if (expiryInt > 0) {
                p.add('<div class="expire">This invitation link expires in ' + expiryInt + ' days.</div>');
            }
            p.add('</div>');
        }

        p.add('<p style="font-size:12px;color:#888;margin-top:24px;">');
        p.add('If you did not expect this invitation, you can safely ignore this email. ');
        p.add('For questions, contact your liaison at ' + esc(parentName) + ' directly.</p>');
        p.add('</div>');
        p.add('<div class="ftr">Sent via the Supplier Compliance Management platform.</div>');
        p.add('</div></body></html>');
        return String.join(p, '\n');
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private static String sevBadgeClass(String sev) {
        if (sev == null)       return 'vc-sev-med';
        if (sev == 'Critical') return 'vc-sev-crit';
        if (sev == 'High')     return 'vc-sev-high';
        if (sev == 'Low')      return 'vc-sev-low';
        return 'vc-sev-med';
    }

    private static String generateTempPassword() {
        // Meets Salesforce default complexity: 8+ chars, upper, lower, digit, symbol.
        // Uses substring(i,i+1) — charAt() returns an Integer in Apex, not a char.
        String upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
        String lower   = 'abcdefghjkmnpqrstuvwxyz';
        String digits  = '23456789';
        String symbols = '@#$!';
        String all     = upper + lower + digits + symbols;
        Long   seed    = System.now().getTime();
        Integer ui = (Integer) Math.mod(seed,       upper.length());
        Integer li = (Integer) Math.mod(seed / 23,  lower.length());
        Integer di = (Integer) Math.mod(seed / 491, digits.length());
        Integer si = (Integer) Math.mod(seed / 97,  symbols.length());
        String pwd = upper.substring(ui, ui + 1)
                   + lower.substring(li, li + 1)
                   + digits.substring(di, di + 1)
                   + symbols.substring(si, si + 1);
        for (Integer i = 4; i < 12; i++) {
            Integer idx = (Integer) Math.mod(seed / (i * 37 + 1), all.length());
            pwd += all.substring(idx, idx + 1);
        }
        return pwd;
    }

    private static String buildAlias(String first, String last) {
        String a = '';
        if (String.isNotBlank(first)) a += first.substring(0, 1);
        if (String.isNotBlank(last))  a += last.substring(0, Math.min(7, last.length()));
        return (String.isBlank(a) ? 'user' : a).toLowerCase().left(8);
    }

    private static String buildNickname(String first, String last, Id accountId) {
        String base = (String.isNotBlank(first) ? first : '')
                    + (String.isNotBlank(last) ? last.substring(0, 1) : '');
        base = base.replaceAll('[^a-zA-Z0-9]', '');
        if (String.isBlank(base)) base = 'user';
        return (base + String.valueOf(accountId).right(4)).left(40);
    }

    private static String statusBadge(String status) {
        if (status == null) return 'vc-badge neutral';
        String t = status.toLowerCase();
        if (t == 'approved')                            return 'vc-badge ok';
        if (t == 'in review' || t == 'screening')       return 'vc-badge warn';
        if (t == 'rejected')                            return 'vc-badge bad';
        return 'vc-badge neutral';
    }

    private static String ageLabel(Datetime created) {
        if (created == null) return '';
        Long mins = (System.now().getTime() - created.getTime()) / 60000;
        if (mins < 60)      return mins + 'm ago';
        if (mins < 60 * 24) return (mins / 60) + 'h ago';
        return (mins / (60 * 24)) + 'd ago';
    }

    private static String esc(String val) {
        if (val == null) return '';
        return val.replace('&', '&amp;').replace('<', '&lt;')
                  .replace('>', '&gt;').replace('"', '&quot;');
    }
}