import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getAuditReport from '@salesforce/apex/AuditReportController.getAuditReport';
import exportToCSV    from '@salesforce/apex/AuditReportController.exportToCSV';

// Must match Audit_Log__c Event_Type__c picklist
const EVENT_TYPE_OPTIONS = [
    { label: 'Document Uploaded',    value: 'Document_Uploaded'    },
    { label: 'AI Extraction',        value: 'AI_Extraction'        },
    { label: 'Compliance Evaluated', value: 'Compliance_Evaluated' },
    { label: 'Manual Override',      value: 'Manual_Override'      },
    { label: 'Checklist Generated',  value: 'Checklist_Generated'  },
    { label: 'Status Changed',       value: 'Status_Changed'       },
    { label: 'Other',                value: 'Other'                },
];

const ACTOR_TYPE_OPTIONS = [
    { label: 'All',    value: '' },
    { label: 'AI',     value: 'AI' },
    { label: 'Human',  value: 'Human' },
    { label: 'System', value: 'System' },
];

const COLUMNS = [
    { label: 'Audit ID',       fieldName: 'auditId',        type: 'text', initialWidth: 110, wrapText: false },
    { label: 'Date / Time',    fieldName: 'eventDateTime',  type: 'text', initialWidth: 160, wrapText: false },
    { label: 'Event Type',     fieldName: 'eventType',      type: 'text', initialWidth: 160, wrapText: false },
    { label: 'Actor',          fieldName: 'actorName',      type: 'text', initialWidth: 130, wrapText: false },
    { label: 'Related Object', fieldName: 'relatedObject',  type: 'text', initialWidth: 140, wrapText: false },
    {
        label: 'AI Conf',
        fieldName: 'aiConfidence',
        type: 'number',
        initialWidth: 85,
        cellAttributes: { alignment: 'right' },
        typeAttributes: { maximumFractionDigits: '0' },
    },
    {
        label: 'Details',
        fieldName: 'newValue',
        type: 'text',
        wrapText: true,
    },
    {
        label: '',
        type: 'button',
        initialWidth: 80,
        typeAttributes: { label: 'View', variant: 'base', name: 'view_detail' },
    },
];

const EMPTY_FILTER = {
    dateFrom:       '',
    dateTo:         '',
    supplierName:   '',
    eventTypes:     [],
    actorType:      '',
    requirementKey: '',
};

export default class ScAuditConsole extends NavigationMixin(LightningElement) {

    // ── State ──────────────────────────────────────────────────────────────
    @track filter          = { ...EMPTY_FILTER };
    @track rows            = [];
    @track isLoading       = false;
    @track reportGenerated = false;
    @track generatedAt     = '';
    @track selectedRow     = null;
    @track showDetailModal = false;
    @track error           = '';

    eventTypeOptions = EVENT_TYPE_OPTIONS;
    actorTypeOptions = ACTOR_TYPE_OPTIONS;
    columns          = COLUMNS;

    // ── Computed ───────────────────────────────────────────────────────────
    get totalCount()    { return this.rows.length; }
    get hasRows()       { return this.rows.length > 0; }
    get pluralRecords() { return this.rows.length !== 1; }

    // ── Filter handlers ────────────────────────────────────────────────────
    handleDateFromChange(e)    { this.filter = { ...this.filter, dateFrom:       e.detail.value }; }
    handleDateToChange(e)      { this.filter = { ...this.filter, dateTo:         e.detail.value }; }
    handleSupplierChange(e)    { this.filter = { ...this.filter, supplierName:   e.detail.value }; }
    handleActorTypeChange(e)   { this.filter = { ...this.filter, actorType:      e.detail.value }; }
    handleRequirementChange(e) { this.filter = { ...this.filter, requirementKey: e.detail.value }; }
    handleEventTypeChange(e)   { this.filter = { ...this.filter, eventTypes:     e.detail.value }; }

    // ── Generate ───────────────────────────────────────────────────────────
    async handleGenerate() {
        this.isLoading = true;
        this.error     = '';
        try {
            this.rows            = await getAuditReport({ filterJson: JSON.stringify(this.filter) });
            this.reportGenerated = true;
            this.generatedAt     = new Date().toLocaleString();
        } catch (err) {
            this.error = this._msg(err);
        } finally {
            this.isLoading = false;
        }
    }

    handleClear() {
        this.filter          = { ...EMPTY_FILTER, eventTypes: [] };
        this.rows            = [];
        this.reportGenerated = false;
        this.error           = '';
        this.generatedAt     = '';
    }

    // ── CSV export ─────────────────────────────────────────────────────────
    async handleExportCSV() {
        this.isLoading = true;
        this.error     = '';
        try {
            const contentDocId = await exportToCSV({ filterJson: JSON.stringify(this.filter) });
            // Navigate to the file so the browser downloads it
            this[NavigationMixin.Navigate]({
                type: 'standard__namedPage',
                attributes: { pageName: 'filePreview' },
                state: { selectedRecordId: contentDocId },
            });
        } catch (err) {
            this.error = this._msg(err);
        } finally {
            this.isLoading = false;
        }
    }

    // ── PDF export — opens VF page in a new browser tab ───────────────────
    handleExportPDF() {
        const f      = this.filter;
        const params = new URLSearchParams();
        if (f.dateFrom)       params.set('dateFrom',       f.dateFrom);
        if (f.dateTo)         params.set('dateTo',         f.dateTo);
        if (f.supplierName)   params.set('supplierName',   f.supplierName);
        if (f.eventTypes && f.eventTypes.length) params.set('eventTypes', f.eventTypes.join(','));
        if (f.actorType)      params.set('actorType',      f.actorType);
        if (f.requirementKey) params.set('requirementKey', f.requirementKey);

        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: { url: '/apex/AuditReportPDF?' + params.toString() },
        });
    }

    // ── Row action (View detail) ───────────────────────────────────────────
    handleRowAction(e) {
        if (e.detail.action.name === 'view_detail') {
            this.selectedRow     = e.detail.row;
            this.showDetailModal = true;
        }
    }

    closeDetailModal() {
        this.showDetailModal = false;
        this.selectedRow     = null;
    }

    // ── Utility ────────────────────────────────────────────────────────────
    _msg(err) {
        return (err && err.body && err.body.message) ? err.body.message : String(err);
    }
}