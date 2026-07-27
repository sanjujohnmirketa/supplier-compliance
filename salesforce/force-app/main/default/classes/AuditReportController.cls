/**
 * AuditReportController
 * ════════════════════════════════════════════════════════════════════════════
 * Backs the scAuditConsole LWC.  Provides filtered reads of Audit_Log__c
 * and CSV export.  PDF export is handled by AuditReportPDF (Visualforce).
 *
 * Uses without sharing so Compliance Managers and Internal Auditors can see
 * every audit record regardless of ownership — the object CRUD on their
 * permission set must be Read-only (never Edit / Delete).
 */
public without sharing class AuditReportController {

    // ── Filter DTO ────────────────────────────────────────────────────────
    public class AuditFilter {
        @AuraEnabled public String       dateFrom;       // 'yyyy-MM-dd' or blank
        @AuraEnabled public String       dateTo;         // 'yyyy-MM-dd' or blank, inclusive
        @AuraEnabled public String       supplierName;   // partial name match → Account IDs
        @AuraEnabled public List<String> eventTypes;     // null / empty = all
        @AuraEnabled public String       actorType;      // 'AI' | 'Human' | 'System' | blank
        @AuraEnabled public String       requirementKey; // Requirement_Key__c on Assessment, or blank
    }

    // ── Result row ────────────────────────────────────────────────────────
    public class AuditRow {
        @AuraEnabled public String  id;
        @AuraEnabled public String  auditId;
        @AuraEnabled public String  eventType;
        @AuraEnabled public String  eventDateTime;
        @AuraEnabled public String  actorType;
        @AuraEnabled public String  actorName;
        @AuraEnabled public String  relatedObject;
        @AuraEnabled public String  relatedRecordId;
        @AuraEnabled public String  newValue;
        @AuraEnabled public String  originalValue;
        @AuraEnabled public String  reason;
        @AuraEnabled public Decimal aiConfidence;
        @AuraEnabled public String  aiModelName;
        @AuraEnabled public String  sourceSystem;
    }

    // ── Main query (cacheable — audit logs are append-only) ───────────────
    @AuraEnabled(cacheable=true)
    public static List<AuditRow> getAuditReport(String filterJson) {
        AuditFilter f = (AuditFilter) JSON.deserialize(filterJson, AuditFilter.class);

        // Resolve supplier name → set of related record IDs
        Set<String> relatedIds = resolveRelatedIds(f.supplierName, f.requirementKey);

        String soql = buildSoql(f, relatedIds);
        List<Audit_Log__c> logs = Database.query(soql);

        // Bulk-resolve user names
        Set<Id> userIds = new Set<Id>();
        for (Audit_Log__c l : logs) if (l.Actor_User__c != null) userIds.add(l.Actor_User__c);
        Map<Id, String> nameById = new Map<Id, String>();
        for (User u : [SELECT Id, Name FROM User WHERE Id IN :userIds]) {
            nameById.put(u.Id, u.Name);
        }

        List<AuditRow> rows = new List<AuditRow>();
        for (Audit_Log__c l : logs) {
            AuditRow r       = new AuditRow();
            r.id             = l.Id;
            r.auditId        = l.Name;
            r.eventType      = l.Event_Type__c;
            r.eventDateTime  = l.Event_DateTime__c != null
                               ? l.Event_DateTime__c.format('yyyy-MM-dd HH:mm:ss') : '';
            r.actorType      = l.Actor_Type__c;
            r.actorName      = l.Actor_User__c != null
                               ? nameById.get(l.Actor_User__c) : l.Actor_Type__c;
            r.relatedObject  = l.Related_Object__c;
            r.relatedRecordId= l.Related_Record_Id__c;
            r.newValue       = l.New_Value__c;
            r.originalValue  = l.Original_Value__c;
            r.reason         = l.Reason__c;
            r.aiConfidence   = l.AI_Confidence__c;
            r.aiModelName    = l.AI_Model_Name__c;
            r.sourceSystem   = l.Source_System__c;
            rows.add(r);
        }
        return rows;
    }

    // ── CSV export ────────────────────────────────────────────────────────
    // Runs the same filtered query, writes a CSV ContentVersion, and returns
    // the ContentDocumentId so the LWC can build a download URL.
    @AuraEnabled
    public static String exportToCSV(String filterJson) {
        List<AuditRow> rows = getAuditReport(filterJson);

        String csv = '"Audit ID","Date/Time","Event Type","Actor Type","Actor Name",'
                   + '"Related Object","Related Record ID","AI Confidence","AI Model",'
                   + '"Source System","Details","Original Value","Reason"\n';
        for (AuditRow r : rows) {
            csv += cell(r.auditId)         + ','
                 + cell(r.eventDateTime)   + ','
                 + cell(r.eventType)       + ','
                 + cell(r.actorType)       + ','
                 + cell(r.actorName)       + ','
                 + cell(r.relatedObject)   + ','
                 + cell(r.relatedRecordId) + ','
                 + (r.aiConfidence != null ? String.valueOf(r.aiConfidence) : '') + ','
                 + cell(r.aiModelName)     + ','
                 + cell(r.sourceSystem)    + ','
                 + cell(r.newValue)        + ','
                 + cell(r.originalValue)   + ','
                 + cell(r.reason)          + '\n';
        }

        String fileName = 'Audit_Report_' + DateTime.now().format('yyyyMMdd_HHmm') + '.csv';
        ContentVersion cv = new ContentVersion(
            Title          = fileName,
            PathOnClient   = fileName,
            VersionData    = Blob.valueOf(csv),
            IsMajorVersion = true
        );
        insert cv;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].ContentDocumentId;
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    private static Set<String> resolveRelatedIds(String supplierName, String requirementKey) {
        Set<String> ids = new Set<String>();
        Set<Id> accountIds = new Set<Id>();

        // Supplier name filter: partial match on Account.Name
        if (String.isNotBlank(supplierName)) {
            String nameLike = '%' + String.escapeSingleQuotes(supplierName) + '%';
            for (Account a : [SELECT Id FROM Account WHERE Name LIKE :nameLike LIMIT 100]) {
                ids.add(a.Id);
                accountIds.add(a.Id);
            }
        }

        // Expand to related Compliance Documents and Assessments for those suppliers
        if (!accountIds.isEmpty()) {
            for (Compliance_Document__c d : [
                SELECT Id FROM Compliance_Document__c WHERE Account__c IN :accountIds
            ]) { ids.add(d.Id); }
        }

        // Requirement key filter: match Assessment IDs; if supplier also selected, intersect
        if (String.isNotBlank(requirementKey)) {
            String keyLike = '%' + String.escapeSingleQuotes(requirementKey) + '%';
            List<Compliance_Assessment__c> matches = accountIds.isEmpty()
                ? [SELECT Id FROM Compliance_Assessment__c WHERE Requirement_Key__c LIKE :keyLike LIMIT 200]
                : [SELECT Id FROM Compliance_Assessment__c WHERE Requirement_Key__c LIKE :keyLike
                   AND Supplier__c IN :accountIds LIMIT 200];
            for (Compliance_Assessment__c a : matches) ids.add(a.Id);
        } else if (!accountIds.isEmpty()) {
            // No requirement filter — include all assessments for the supplier
            for (Compliance_Assessment__c a : [
                SELECT Id FROM Compliance_Assessment__c WHERE Supplier__c IN :accountIds
            ]) { ids.add(a.Id); }
        }

        return ids;
    }

    private static String buildSoql(AuditFilter f, Set<String> relatedIds) {
        List<String> clauses = new List<String>();

        if (String.isNotBlank(f.dateFrom)) {
            clauses.add('Event_DateTime__c >= ' + toSoqlDt(f.dateFrom, false));
        }
        if (String.isNotBlank(f.dateTo)) {
            clauses.add('Event_DateTime__c <= ' + toSoqlDt(f.dateTo, true));
        }
        if (!relatedIds.isEmpty()) {
            List<String> quoted = new List<String>();
            for (String rid : relatedIds) quoted.add('\'' + rid + '\'');
            clauses.add('Related_Record_Id__c IN (' + String.join(quoted, ',') + ')');
        }
        if (f.eventTypes != null && !f.eventTypes.isEmpty()) {
            List<String> quoted = new List<String>();
            for (String et : f.eventTypes) quoted.add('\'' + String.escapeSingleQuotes(et) + '\'');
            clauses.add('Event_Type__c IN (' + String.join(quoted, ',') + ')');
        }
        if (String.isNotBlank(f.actorType)) {
            clauses.add('Actor_Type__c = \'' + String.escapeSingleQuotes(f.actorType) + '\'');
        }

        String soql = 'SELECT Id, Name, Event_Type__c, Event_DateTime__c, Actor_Type__c, '
                    + 'Actor_User__c, Related_Object__c, Related_Record_Id__c, '
                    + 'New_Value__c, Original_Value__c, Reason__c, '
                    + 'AI_Confidence__c, AI_Model_Name__c, Source_System__c '
                    + 'FROM Audit_Log__c';
        if (!clauses.isEmpty()) soql += ' WHERE ' + String.join(clauses, ' AND ');
        soql += ' ORDER BY Event_DateTime__c DESC LIMIT 2000';
        return soql;
    }

    // Returns ISO-8601 UTC datetime string suitable for embedding in dynamic SOQL
    private static String toSoqlDt(String dateStr, Boolean endOfDay) {
        Date d = Date.valueOf(dateStr);
        DateTime dt = endOfDay
            ? DateTime.newInstance(d, Time.newInstance(23, 59, 59, 0))
            : DateTime.newInstance(d, Time.newInstance(0, 0, 0, 0));
        return dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
    }

    private static String cell(String v) {
        if (String.isBlank(v)) return '""';
        return '"' + v.replace('"', '""').replace('\r\n', ' ').replace('\n', ' ').replace('\r', '') + '"';
    }
}