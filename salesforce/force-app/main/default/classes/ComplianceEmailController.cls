public with sharing class ComplianceEmailController {


    public class EmailPreview {
        @AuraEnabled public String           accountName;
        @AuraEnabled public String           toEmail;
        @AuraEnabled public List<DocRow>     requiredDocs;
        @AuraEnabled public List<DocRow>     additionalDocs;
        @AuraEnabled public Boolean          hasRequiredDocs;
        @AuraEnabled public Boolean          hasAdditionalDocs;
    }

    public class DocRow {
        @AuraEnabled public String  requirementLabel;
        @AuraEnabled public String  severity;
        @AuraEnabled public String  status;
        @AuraEnabled public String  statusLabel;
        @AuraEnabled public Boolean hasDocument;
    }

    // Severity sort order: Critical=1, High=2, Medium=3, Low=4, other=5
    private static final Map<String, Integer> SEVERITY_ORDER =
        new Map<String, Integer>{ 'Critical'=>1, 'High'=>2, 'Medium'=>3, 'Low'=>4 };

    // ── getEmailPreview ───────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static EmailPreview getEmailPreview(Id accountId) {
        if (accountId == null) throw new AuraHandledException('accountId is required.');

        Account acc = [SELECT Id, Name FROM Account WHERE Id = :accountId LIMIT 1];

        List<Compliance_Assessment__c> rawAssessments = [
            SELECT Requirement_Label__c, Requirement_Key__c, Status__c, Severity__c,
                   Compliance_Document__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :accountId
            AND    (NOT Requirement_Key__c LIKE 'SCREEN_%')
        ];

        // Sort by severity priority in Apex (SOQL ORDER BY CASE not supported)
        rawAssessments.sort(new SeverityComparator());

        EmailPreview preview    = new EmailPreview();
        preview.accountName     = acc.Name;
        preview.toEmail         = findContactEmail(accountId);
        preview.requiredDocs    = new List<DocRow>();
        preview.additionalDocs  = new List<DocRow>();

        for (Compliance_Assessment__c a : rawAssessments) {
            Boolean hasDoc       = a.Compliance_Document__c != null;
            DocRow row           = new DocRow();
            row.requirementLabel = a.Requirement_Label__c;
            row.severity         = a.Severity__c;
            row.status           = a.Status__c;
            row.statusLabel      = toStatusLabel(a.Status__c, hasDoc);
            row.hasDocument      = hasDoc;

            if (a.Severity__c == 'Critical' || a.Severity__c == 'High'
                    || String.isBlank(a.Severity__c)) {
                preview.requiredDocs.add(row);
            } else {
                preview.additionalDocs.add(row);
            }
        }

        preview.hasRequiredDocs    = !preview.requiredDocs.isEmpty();
        preview.hasAdditionalDocs  = !preview.additionalDocs.isEmpty();
        return preview;
    }

    // ── sendComplianceEmail ───────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static void sendComplianceEmail(
        Id     accountId,
        String toEmail,
        String customNote
    ) {
        if (accountId == null)     throw new AuraHandledException('accountId is required.');
        if (String.isBlank(toEmail)) throw new AuraHandledException('A recipient email address is required.');

        Account acc = [SELECT Id, Name FROM Account WHERE Id = :accountId LIMIT 1];

        List<Compliance_Assessment__c> assessments = [
            SELECT Requirement_Label__c, Requirement_Key__c, Status__c, Severity__c,
                   Compliance_Document__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :accountId
            AND    (NOT Requirement_Key__c LIKE 'SCREEN_%')
        ];
        assessments.sort(new SeverityComparator());

        String portalUrl = null;
        try { portalUrl = VendorPortalController.generateSupplierPortalUrl(accountId); }
        catch (Exception e) { System.debug(LoggingLevel.WARN, 'Portal URL generation failed for ' + accountId + ': ' + e.getMessage()); }

        String htmlBody = buildEmailHtml(acc.Name, assessments, customNote, portalUrl);

        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setToAddresses(new List<String>{ toEmail.trim() });
        email.setSubject('Action Required: Compliance Document Submission – ' + acc.Name);
        email.setHtmlBody(htmlBody);
        email.setSaveAsActivity(true);
        email.setTargetObjectId(findContactId(accountId));

        List<OrgWideEmailAddress> orgEmails = [
            SELECT Id FROM OrgWideEmailAddress LIMIT 1
        ];
        if (!orgEmails.isEmpty()) {
            email.setOrgWideEmailAddressId(orgEmails[0].Id);
        }

        List<Messaging.SendEmailResult> results =
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email }, false);

        if (!results[0].isSuccess()) {
            List<String> msgs = new List<String>();
            for (Messaging.SendEmailError err : results[0].getErrors()) {
                msgs.add(err.getMessage());
            }
            throw new AuraHandledException('Email could not be sent: ' + String.join(msgs, '; '));
        }
    }

    // ── sendRenewalAlert ──────────────────────────────────────────────────────
    // Distinct from sendComplianceEmail (the generic "these documents are
    // required" onboarding-style list): this names the ONE specific item that
    // broke or expired — the "trigger the alert" action from the Intelligence
    // Dashboard's supplier-alerts widget and the Account page's compliance
    // component. Reuses the SAME durable portal link every other supplier
    // email in this org uses (VendorPortalController.generateSupplierPortalUrl)
    // — no new identity mechanism, existing suppliers and new suppliers are
    // not actually distinguished anywhere in this system; the link always
    // resolves to live, current data on every open (never a stale snapshot).
    @AuraEnabled(cacheable=false)
    public static void sendRenewalAlert(Id accountId, Id assessmentId) {
        if (accountId == null)    throw new AuraHandledException('accountId is required.');
        if (assessmentId == null) throw new AuraHandledException('assessmentId is required.');

        Account acc = [SELECT Id, Name, Onboarding_Status__c FROM Account WHERE Id = :accountId LIMIT 1];
        // This is a RENEWAL alert — it only makes sense for a supplier that's
        // already onboarded. The dashboard widget that surfaces this button
        // already filters to Approved/Reviewed suppliers only (a still-
        // onboarding supplier's flags belong to the normal onboarding review
        // flow, not a renewal), but that's a UI-layer filter — guard it here
        // too so a direct call can't fire this on a supplier who was never
        // approved in the first place.
        if (acc.Onboarding_Status__c != 'Approved' && acc.Onboarding_Status__c != 'Reviewed') {
            throw new AuraHandledException('Renewal alerts are only for already-onboarded suppliers.');
        }
        Compliance_Assessment__c a = [
            SELECT Requirement_Label__c, Status__c, Reason_Code__c, Reason_Detail__c, Valid_Until__c
            FROM   Compliance_Assessment__c
            WHERE  Id = :assessmentId
            LIMIT  1
        ];

        String toEmail = findContactEmail(accountId);
        if (String.isBlank(toEmail)) {
            throw new AuraHandledException('No contact email found for this supplier.');
        }

        String portalUrl = null;
        try { portalUrl = VendorPortalController.generateSupplierPortalUrl(accountId); }
        catch (Exception e) { System.debug(LoggingLevel.WARN, 'Portal URL generation failed for ' + accountId + ': ' + e.getMessage()); }

        Boolean isExpiry = (a.Reason_Code__c == 'Expired');
        String reasonLine = isExpiry
            ? (a.Valid_Until__c != null && a.Valid_Until__c < Date.today()
                ? 'expired on ' + a.Valid_Until__c.format()
                : 'is expiring soon' + (a.Valid_Until__c != null ? ' (' + a.Valid_Until__c.format() + ')' : ''))
            : 'was flagged ' + (a.Status__c == 'Non-Compliant' ? 'Non-Compliant' : 'At Risk')
                + (String.isNotBlank(a.Reason_Detail__c) ? ': ' + a.Reason_Detail__c.abbreviate(200) : '.');

        String htmlBody = buildRenewalEmailHtml(acc.Name, a.Requirement_Label__c, reasonLine, isExpiry, portalUrl);

        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setToAddresses(new List<String>{ toEmail });
        email.setSubject((isExpiry ? 'Renewal Required' : 'Action Required') + ': ' + a.Requirement_Label__c + ' — ' + acc.Name);
        email.setHtmlBody(htmlBody);
        email.setSaveAsActivity(true);
        email.setTargetObjectId(findContactId(accountId));

        List<OrgWideEmailAddress> orgEmails = [SELECT Id FROM OrgWideEmailAddress LIMIT 1];
        if (!orgEmails.isEmpty()) {
            email.setOrgWideEmailAddressId(orgEmails[0].Id);
        }

        List<Messaging.SendEmailResult> results =
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email }, false);

        if (!results[0].isSuccess()) {
            List<String> msgs = new List<String>();
            for (Messaging.SendEmailError err : results[0].getErrors()) {
                msgs.add(err.getMessage());
            }
            throw new AuraHandledException('Email could not be sent: ' + String.join(msgs, '; '));
        }
    }

    private static String buildRenewalEmailHtml(
        String accountName,
        String requirementLabel,
        String reasonLine,
        Boolean isExpiry,
        String portalUrl
    ) {
        String senderName = UserInfo.getName();
        String senderOrg  = UserInfo.getOrganizationName();

        List<String> parts = new List<String>{
            '<!DOCTYPE html><html><head>',
            '<meta charset="UTF-8">',
            '<style>',
            'body{font-family:Arial,Helvetica,sans-serif;color:#1d1d1d;margin:0;padding:0;background:#f4f6fb;}',
            '.wrapper{max-width:640px;margin:32px auto;background:#fff;border-radius:6px;overflow:hidden;border:1px solid #ddd;}',
            '.header{background:#9a3412;padding:28px 36px;}',
            '.header h1{color:#fff;margin:0;font-size:20px;font-weight:700;letter-spacing:.02em;}',
            '.header p{color:#fed7aa;margin:6px 0 0;font-size:13px;}',
            '.body{padding:28px 36px;}',
            'p{font-size:14px;line-height:1.7;margin:0 0 14px;}',
            '.item-box{background:#fff7ed;border:1px solid #fdba8c;border-radius:6px;padding:16px 18px;margin:16px 0;}',
            '.item-box .label{font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.04em;color:#9a3412;margin-bottom:6px;}',
            '.item-box .name{font-size:15px;font-weight:700;margin-bottom:6px;}',
            '.item-box .reason{font-size:13px;color:#514f4d;}',
            '.portal-cta{background:#f0f7ff;border:1px solid #b3d4f5;border-radius:6px;padding:20px 24px;margin:20px 0;text-align:center;}',
            '.portal-cta p{font-size:14px;color:#005fb2;margin:0 0 14px;}',
            '.portal-btn{display:inline-block;padding:11px 28px;background:#0176d3;color:#ffffff !important;text-decoration:none;border-radius:4px;font-size:14px;font-weight:700;letter-spacing:.01em;}',
            '.footer{background:#f4f6fb;padding:16px 36px;font-size:12px;color:#706e6b;text-align:center;}',
            '</style></head><body>',
            '<div class="wrapper">',
            '<div class="header">',
            '<h1>' + (isExpiry ? 'Document Renewal Required' : 'Compliance Attention Required') + '</h1>',
            '<p>Sent by ' + escHtml(senderName) + ' &middot; ' + escHtml(senderOrg) + '</p>',
            '</div>',
            '<div class="body">',
            '<p>Dear <strong>' + escHtml(accountName) + '</strong> Team,</p>',
            '<p>' + (isExpiry
                ? 'One of your on-file compliance documents needs to be renewed:'
                : 'A compliance review has flagged an item on your account that needs your attention:') + '</p>',
            '<div class="item-box">',
            '<div class="label">' + (isExpiry ? 'Expiring Document' : 'Flagged Item') + '</div>',
            '<div class="name">' + escHtml(requirementLabel) + '</div>',
            '<div class="reason">' + escHtml(reasonLine) + '</div>',
            '</div>'
        };

        if (String.isNotBlank(portalUrl)) {
            parts.add('<div class="portal-cta">');
            parts.add('<p><strong>Upload a renewed document via your Supplier Portal</strong><br/>');
            parts.add('The item above is marked for renewal in your checklist — open the portal and use the Renew action next to it.</p>');
            parts.add('<a class="portal-btn" href="' + escHtml(portalUrl) + '">Open Supplier Portal &rarr;</a>');
            parts.add('</div>');
        }

        parts.add('<p style="margin-top:20px;">If you have questions, please reply to this email or contact your assigned account manager.</p>');
        parts.add('<p>Thank you for your cooperation.</p>');
        parts.add('<p><strong>' + escHtml(senderName) + '</strong><br/>');
        parts.add(escHtml(senderOrg) + '</p>');
        parts.add('</div>');
        parts.add('<div class="footer">This email was generated from the Supplier Compliance Management system. Please do not reply directly to an automated sender.</div>');
        parts.add('</div></body></html>');

        return String.join(parts, '\n');
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    private static String findContactEmail(Id accountId) {
        // Portal contact preferred — they are the supplier's primary user
        List<User> portalUsers = [
            SELECT Contact.Email
            FROM   User
            WHERE  AccountId = :accountId
            AND    UserType  IN ('PowerCustomerSuccess', 'PowerPartner', 'CustomerSuccess')
            AND    Contact.Email != null
            AND    IsActive   = true
            LIMIT  1
        ];
        if (!portalUsers.isEmpty()) return portalUsers[0].Contact.Email;

        List<Contact> contacts = [
            SELECT Email
            FROM   Contact
            WHERE  AccountId = :accountId
            AND    Email     != null
            ORDER BY CreatedDate ASC
            LIMIT  1
        ];
        return contacts.isEmpty() ? null : contacts[0].Email;
    }

    private static Id findContactId(Id accountId) {
        List<User> portalUsers = [
            SELECT ContactId
            FROM   User
            WHERE  AccountId  = :accountId
            AND    UserType   IN ('PowerCustomerSuccess', 'PowerPartner', 'CustomerSuccess')
            AND    ContactId  != null
            AND    IsActive   = true
            LIMIT  1
        ];
        if (!portalUsers.isEmpty()) return portalUsers[0].ContactId;

        List<Contact> contacts = [
            SELECT Id
            FROM   Contact
            WHERE  AccountId = :accountId
            ORDER BY CreatedDate ASC
            LIMIT  1
        ];
        return contacts.isEmpty() ? null : contacts[0].Id;
    }

    private static String toStatusLabel(String status, Boolean hasDocument) {
        if (hasDocument == null || !hasDocument) return 'Pending Upload';
        if (status == 'Compliant')               return 'Approved';
        if (status == 'Non-Compliant')           return 'Rejected – Resubmission Required';
        if (status == 'Needs Human Review')      return 'Under Review';
        if (status == 'Pending')                 return 'Processing';
        return 'Pending Upload';
    }

    // ── Email HTML builder ────────────────────────────────────────────────────

    private static String buildEmailHtml(
        String accountName,
        List<Compliance_Assessment__c> assessments,
        String customNote,
        String portalUrl
    ) {
        List<Compliance_Assessment__c> required    = new List<Compliance_Assessment__c>();
        List<Compliance_Assessment__c> additional  = new List<Compliance_Assessment__c>();
        for (Compliance_Assessment__c a : assessments) {
            if (a.Severity__c == 'Critical' || a.Severity__c == 'High'
                    || String.isBlank(a.Severity__c)) {
                required.add(a);
            } else {
                additional.add(a);
            }
        }

        String senderName = UserInfo.getName();
        String senderOrg  = UserInfo.getOrganizationName();

        List<String> parts = new List<String>{
            '<!DOCTYPE html><html><head>',
            '<meta charset="UTF-8">',
            '<style>',
            'body{font-family:Arial,Helvetica,sans-serif;color:#1d1d1d;margin:0;padding:0;background:#f4f6fb;}',
            '.wrapper{max-width:680px;margin:32px auto;background:#fff;border-radius:6px;overflow:hidden;border:1px solid #ddd;}',
            '.header{background:#0176d3;padding:28px 36px;}',
            '.header h1{color:#fff;margin:0;font-size:20px;font-weight:700;letter-spacing:.02em;}',
            '.header p{color:#cce5ff;margin:6px 0 0;font-size:13px;}',
            '.body{padding:28px 36px;}',
            'p{font-size:14px;line-height:1.7;margin:0 0 14px;}',
            'h2{font-size:15px;font-weight:700;margin:24px 0 10px;padding-bottom:6px;border-bottom:2px solid #e5e5e5;}',
            'h2.required{color:#c23934;}',
            'h2.additional{color:#514f4d;}',
            'table{width:100%;border-collapse:collapse;font-size:13px;margin-bottom:8px;}',
            'th{text-align:left;padding:8px 10px;background:#f3f3f3;color:#514f4d;font-weight:700;border-bottom:2px solid #dddbda;}',
            'td{padding:9px 10px;border-bottom:1px solid #f0f0f0;vertical-align:top;}',
            'tr:last-child td{border-bottom:none;}',
            '.badge{display:inline-block;padding:2px 8px;border-radius:3px;font-size:11px;font-weight:700;}',
            '.badge-critical{background:#fde8e8;color:#c23934;}',
            '.badge-high{background:#fff3e0;color:#e07312;}',
            '.badge-medium{background:#fff8e1;color:#ca8700;}',
            '.badge-low{background:#e8f5e9;color:#2e844a;}',
            '.status-ok{color:#2e844a;font-weight:600;}',
            '.status-reject{color:#c23934;font-weight:600;}',
            '.status-review{color:#ca8700;font-weight:600;}',
            '.status-pending{color:#514f4d;}',
            '.callout{background:#f0f7ff;border:1px solid #b3d4f5;border-radius:4px;padding:14px 18px;margin:20px 0;font-size:13px;color:#005fb2;}',
            '.note{background:#fffbee;border-left:4px solid #ca8700;padding:12px 16px;margin:16px 0;font-size:13px;color:#514f4d;}',
            '.portal-cta{background:#f0f7ff;border:1px solid #b3d4f5;border-radius:6px;padding:20px 24px;margin:20px 0;text-align:center;}',
            '.portal-cta p{font-size:14px;color:#005fb2;margin:0 0 14px;}',
            '.portal-btn{display:inline-block;padding:11px 28px;background:#0176d3;color:#ffffff !important;text-decoration:none;border-radius:4px;font-size:14px;font-weight:700;letter-spacing:.01em;}',
            '.footer{background:#f4f6fb;padding:16px 36px;font-size:12px;color:#706e6b;text-align:center;}',
            '</style></head><body>',
            '<div class="wrapper">',
            '<div class="header">',
            '<h1>Compliance Document Submission Request</h1>',
            '<p>Sent by ' + escHtml(senderName) + ' &middot; ' + escHtml(senderOrg) + '</p>',
            '</div>',
            '<div class="body">',
            '<p>Dear <strong>' + escHtml(accountName) + '</strong> Team,</p>',
            '<p>As part of our supplier qualification and compliance process, we kindly request that you submit the compliance documents listed below through our Supplier Portal. Documents marked <strong style="color:#c23934;">Required</strong> must be provided before your account can be fully approved.</p>'
        };

        if (String.isNotBlank(customNote)) {
            parts.add('<div class="note"><strong>Note from ' + escHtml(senderName) + ':</strong> '
                + escHtml(customNote) + '</div>');
        }

        if (!required.isEmpty()) {
            parts.add('<h2 class="required">Required Documents (' + required.size() + ')</h2>');
            parts.add(buildDocTable(required, true));
        }

        if (!additional.isEmpty()) {
            parts.add('<h2 class="additional">Additional Documents (' + additional.size() + ')</h2>');
            parts.add(buildDocTable(additional, false));
        }

        if (required.isEmpty() && additional.isEmpty()) {
            parts.add('<div class="callout">No compliance documents are currently required for this account.</div>');
        }

        if (String.isNotBlank(portalUrl)) {
            parts.add('<div class="portal-cta">');
            parts.add('<p><strong>Upload documents via your personal Supplier Portal</strong><br/>');
            parts.add('Track your checklist, view AI compliance results, and see your status in real time.</p>');
            parts.add('<a class="portal-btn" href="' + escHtml(portalUrl) + '">Open Supplier Portal &rarr;</a>');
            parts.add('</div>');
        } else {
            parts.add('<div class="callout">');
            parts.add('<strong>How to submit:</strong> Reply to this email with the required documents attached. ');
            parts.add('Your compliance status updates automatically once each document is reviewed by our team.');
            parts.add('</div>');
        }

        parts.add('<p style="margin-top:20px;">If you have questions about any of these requirements, please reply to this email or contact your assigned account manager.</p>');
        parts.add('<p>Thank you for your cooperation.</p>');
        parts.add('<p><strong>' + escHtml(senderName) + '</strong><br/>');
        parts.add(escHtml(senderOrg) + '</p>');
        parts.add('</div>');
        parts.add('<div class="footer">This email was generated from the Supplier Compliance Management system. Please do not reply directly to an automated sender.</div>');
        parts.add('</div></body></html>');

        return String.join(parts, '\n');
    }

    private static String buildDocTable(
        List<Compliance_Assessment__c> docs,
        Boolean isRequired
    ) {
        List<String> rows = new List<String>{
            '<table>',
            '<tr><th>Document Required</th><th>Severity</th><th>Status</th></tr>'
        };

        for (Compliance_Assessment__c a : docs) {
            Boolean hasDoc     = a.Compliance_Document__c != null;
            String statusLabel = toStatusLabel(a.Status__c, hasDoc);
            String statusClass = !hasDoc                              ? 'status-pending'
                               : a.Status__c == 'Compliant'          ? 'status-ok'
                               : a.Status__c == 'Non-Compliant'      ? 'status-reject'
                               : a.Status__c == 'Needs Human Review' ? 'status-review'
                               :                                       'status-pending';

            String sevBadge = buildSeverityBadge(a.Severity__c);

            rows.add('<tr>');
            rows.add('<td><strong>' + escHtml(a.Requirement_Label__c) + '</strong></td>');
            rows.add('<td>' + sevBadge + '</td>');
            rows.add('<td class="' + statusClass + '">' + statusLabel + '</td>');
            rows.add('</tr>');
        }

        rows.add('</table>');
        return String.join(rows, '\n');
    }

    private static String buildSeverityBadge(String severity) {
        String cssClass = severity == 'Critical' ? 'badge badge-critical'
                        : severity == 'High'     ? 'badge badge-high'
                        : severity == 'Medium'   ? 'badge badge-medium'
                        :                         'badge badge-low';
        return '<span class="' + cssClass + '">' + escHtml(severity) + '</span>';
    }

    private static String escHtml(String val) {
        if (val == null) return '';
        return val.replace('&', '&amp;')
                  .replace('<', '&lt;')
                  .replace('>', '&gt;')
                  .replace('"', '&quot;');
    }

    // ── Sort by severity priority ─────────────────────────────────────────────

    private class SeverityComparator implements Comparator<Compliance_Assessment__c> {
        public Integer compare(Compliance_Assessment__c a, Compliance_Assessment__c b) {
            Integer orderA = SEVERITY_ORDER.containsKey(a.Severity__c) ? SEVERITY_ORDER.get(a.Severity__c) : 5;
            Integer orderB = SEVERITY_ORDER.containsKey(b.Severity__c) ? SEVERITY_ORDER.get(b.Severity__c) : 5;
            return orderA - orderB;
        }
    }
}