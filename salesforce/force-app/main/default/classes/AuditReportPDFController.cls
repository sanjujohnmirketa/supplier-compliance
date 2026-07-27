/**
 * AuditReportPDFController
 * ════════════════════════════════════════════════════════════════════════════
 * Visualforce page controller for AuditReportPDF (renderAs="pdf").
 *
 * Visualforce cannot resolve properties on an inner class that belongs to
 * a different Apex class, so this controller defines its own Row inner class
 * with {get;set;} declarations and maps from AuditReportController.AuditRow.
 *
 * URL format produced by scAuditConsole LWC:
 *   /apex/AuditReportPDF?dateFrom=2024-01-01&dateTo=2024-12-31
 *                       &supplierName=Acme&eventTypes=Manual_Override,Compliance_Evaluated
 *                       &actorType=Human&requirementKey=ISO_9001
 */
public without sharing class AuditReportPDFController {

    // ── VF-compatible row class ───────────────────────────────────────────
    public class Row {
        public String  auditId         { get; set; }
        public String  eventType       { get; set; }
        public String  eventDateTime   { get; set; }
        public String  actorType       { get; set; }
        public String  actorName       { get; set; }
        public String  relatedObject   { get; set; }
        public String  relatedRecordId { get; set; }
        public String  newValue        { get; set; }
        public String  originalValue   { get; set; }
        public String  reason          { get; set; }
        public Decimal aiConfidence    { get; set; }
        public String  aiModelName     { get; set; }
        public String  sourceSystem    { get; set; }
    }

    // ── Page-level properties ─────────────────────────────────────────────
    public List<Row> rows          { get; private set; }
    public String    generatedAt   { get; private set; }
    public String    filterSummary { get; private set; }
    public Integer   totalRecords  { get; private set; }
    public String    dateFrom      { get; private set; }
    public String    dateTo        { get; private set; }
    public String    supplierName  { get; private set; }
    public String    actorType     { get; private set; }
    public String    requirementKey{ get; private set; }
    public String    eventTypesLabel{ get; private set; }

    public AuditReportPDFController() {
        Map<String, String> params = ApexPages.currentPage().getParameters();

        // Build filter from URL params
        AuditReportController.AuditFilter f = new AuditReportController.AuditFilter();
        f.dateFrom       = params.get('dateFrom');
        f.dateTo         = params.get('dateTo');
        f.supplierName   = params.get('supplierName');
        f.actorType      = params.get('actorType');
        f.requirementKey = params.get('requirementKey');

        String rawTypes = params.get('eventTypes');
        if (String.isNotBlank(rawTypes)) {
            f.eventTypes = rawTypes.split(',');
        }

        // Query via shared service and map to VF-compatible rows
        List<AuditReportController.AuditRow> sourceRows =
            AuditReportController.getAuditReport(JSON.serialize(f));

        rows = new List<Row>();
        for (AuditReportController.AuditRow s : sourceRows) {
            Row r          = new Row();
            r.auditId         = s.auditId;
            r.eventType       = s.eventType;
            r.eventDateTime   = s.eventDateTime;
            r.actorType       = s.actorType;
            r.actorName       = s.actorName;
            r.relatedObject   = s.relatedObject;
            r.relatedRecordId = s.relatedRecordId;
            r.newValue        = s.newValue != null && s.newValue.length() > 400
                                ? s.newValue.left(400) + '…' : s.newValue;
            r.originalValue   = s.originalValue != null && s.originalValue.length() > 200
                                ? s.originalValue.left(200) + '…' : s.originalValue;
            r.reason          = s.reason != null && s.reason.length() > 150
                                ? s.reason.left(150) + '…' : s.reason;
            r.aiConfidence    = s.aiConfidence;
            r.aiModelName     = s.aiModelName;
            r.sourceSystem    = s.sourceSystem;
            rows.add(r);
        }

        totalRecords = rows.size();
        generatedAt  = DateTime.now().format('yyyy-MM-dd HH:mm:ss') + ' UTC';

        // Human-readable filter summary for the report header
        List<String> parts = new List<String>();
        if (String.isNotBlank(f.dateFrom) || String.isNotBlank(f.dateTo)) {
            parts.add('Date: ' + (String.isNotBlank(f.dateFrom) ? f.dateFrom : '*')
                      + ' → ' + (String.isNotBlank(f.dateTo)   ? f.dateTo   : '*'));
        }
        if (String.isNotBlank(f.supplierName)) parts.add('Supplier: '   + f.supplierName);
        if (String.isNotBlank(f.actorType))    parts.add('Actor: '      + f.actorType);
        if (String.isNotBlank(f.requirementKey)) parts.add('Rule: '     + f.requirementKey);
        if (f.eventTypes != null && !f.eventTypes.isEmpty()) {
            parts.add('Events: ' + String.join(f.eventTypes, ', '));
        }
        filterSummary   = parts.isEmpty() ? 'All records (no filters applied)' : String.join(parts, ' · ');

        // Expose individual params for the report meta table
        dateFrom        = f.dateFrom;
        dateTo          = f.dateTo;
        supplierName    = f.supplierName;
        actorType       = f.actorType;
        requirementKey  = f.requirementKey;
        eventTypesLabel = (f.eventTypes != null && !f.eventTypes.isEmpty())
                          ? String.join(f.eventTypes, ', ') : 'All';
    }
}