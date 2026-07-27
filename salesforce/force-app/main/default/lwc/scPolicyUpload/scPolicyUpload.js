import { LightningElement, track } from 'lwc';
import createPolicyDocument from '@salesforce/apex/PolicyDocumentController.createPolicyDocument';
import startIngestion from '@salesforce/apex/PolicyDocumentController.startIngestion';
import getPolicyDocuments from '@salesforce/apex/PolicyDocumentController.getPolicyDocuments';

// Must match Policy_Document__c.Domain__c picklist values exactly.
const DOMAIN_OPTIONS = [
    { value: 'Auto-Detect', label: 'Auto-detect (recommended)' },
    { value: 'conflict', label: 'Conflict Minerals' },
    { value: 'trade', label: 'Trade / Sanctions' },
    { value: 'finance', label: 'Finance / KYC' },
    { value: 'quality', label: 'Quality' },
    { value: 'material', label: 'Material Safety' },
    { value: 'cyber', label: 'Cyber / Data Protection' }
];

const STATUS_BADGE = {
    Uploaded:   'vc-badge neutral',
    Processing: 'vc-badge warn',
    Ingested:   'vc-badge ok',
    Failed:     'vc-badge bad'
};

// Poll while any row is still Processing so the list reflects ingestion
// finishing without the user needing to manually refresh.
const POLL_MS = 4000;

export default class ScPolicyUpload extends LightningElement {

    @track domainOverride = 'Auto-Detect';
    @track uploading = false;
    @track rows = [];
    @track loadingList = true;

    _pendingPolicyDocId = null;
    _pollHandle = null;

    get domainOptions() {
        return DOMAIN_OPTIONS.map((opt) => ({ ...opt, selected: opt.value === this.domainOverride }));
    }

    get acceptedFormats() { return ['.pdf', '.txt', '.md', '.docx']; }
    get uploadLabel() { return this.uploading ? 'Starting…' : 'Attach policy document'; }
    get hasRows() { return this.rows.length > 0; }
    get isUploadDisabled() { return this.uploading; }

    connectedCallback() {
        this._loadRows();
    }

    disconnectedCallback() {
        this._stopPoll();
    }

    handleDomainChange(event) {
        this.domainOverride = event.target.value;
    }

    // Step 1: create the Policy_Document__c record so lightning-file-upload has
    // a record-id to attach the ContentVersion to (same two-step pattern as
    // Compliance_Document__c + scProcurementDocumentUploader).
    async handleStartUpload() {
        this.uploading = true;
        try {
            this._pendingPolicyDocId = await createPolicyDocument({ domainOverride: this.domainOverride });
        } catch (err) {
            this.uploading = false;
            this._toast('error', 'Could not start upload',
                (err && err.body && err.body.message) || 'Unknown error.');
            return;
        }
        // Now that we have a record Id, programmatically click the (hidden until
        // now) lightning-file-upload — simplest is to just render it once the Id
        // exists and let the user pick the file via its own button.
        this.uploading = false;
    }

    get hasPendingRecord() { return !!this._pendingPolicyDocId; }
    get pendingRecordId() { return this._pendingPolicyDocId; }

    async handleUploadFinished(event) {
        const files = event.detail.files;
        if (!files || !files.length) return;
        const contentDocumentId = files[0].documentId;
        const policyDocId = this._pendingPolicyDocId;
        this._pendingPolicyDocId = null;   // reset so the upload slot can be reused

        try {
            await startIngestion({ policyDocumentId: policyDocId, contentDocumentId });
            this._toast('success', 'Upload received', 'Ingesting into the policy corpus…');
        } catch (err) {
            this._toast('error', 'Ingestion failed to start',
                (err && err.body && err.body.message) || 'Unknown error.');
        }
        this._loadRows();
        this._startPollIfNeeded();
    }

    async _loadRows() {
        this.loadingList = true;
        try {
            const data = await getPolicyDocuments();
            this.rows = (data || []).map((r) => ({
                ...r,
                badgeClass: STATUS_BADGE[r.status] || 'vc-badge neutral',
                chunkCountLabel: r.chunkCount != null ? String(r.chunkCount) : '—',
                domainLabel: r.domain || '—'
            }));
        } catch (err) {
            this._toast('error', 'Could not load policy documents',
                (err && err.body && err.body.message) || 'Unknown error.');
        } finally {
            this.loadingList = false;
        }
        this._startPollIfNeeded();
    }

    _startPollIfNeeded() {
        const stillProcessing = this.rows.some((r) => r.status === 'Processing' || r.status === 'Uploaded');
        if (stillProcessing && !this._pollHandle) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this._pollHandle = setInterval(() => this._loadRows(), POLL_MS);
        } else if (!stillProcessing) {
            this._stopPoll();
        }
    }

    _stopPoll() {
        if (this._pollHandle) {
            clearInterval(this._pollHandle);
            this._pollHandle = null;
        }
    }

    _toast(variant, title, message) {
        this.dispatchEvent(new CustomEvent('toast', { detail: { variant, title, message } }));
        // Fallback console output — this component may be embedded without a
        // parent listening for 'toast' (e.g. directly on an App Page).
        // eslint-disable-next-line no-console
        if (variant === 'error') console.error(`[scPolicyUpload] ${title}: ${message}`);
    }
}
