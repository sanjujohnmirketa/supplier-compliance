import { LightningElement, track } from 'lwc';
import uploadPolicyDocument from '@salesforce/apex/PolicyDocumentController.uploadPolicyDocument';
import reuploadPolicyDocument from '@salesforce/apex/PolicyDocumentController.reuploadPolicyDocument';
import deletePolicyDocument from '@salesforce/apex/PolicyDocumentController.deletePolicyDocument';
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

    _pollHandle = null;
    _reuploadTargetId = null;   // set while a "Reupload" file-pick is in flight

    get domainOptions() {
        return DOMAIN_OPTIONS.map((opt) => ({ ...opt, selected: opt.value === this.domainOverride }));
    }

    get acceptedFormats() { return '.pdf,.txt,.md,.docx,.xlsx'; }
    get uploadLabel() { return this.uploading ? 'Uploading…' : 'Attach policy document'; }
    get hasRows() { return this.rows.length > 0; }
    get isUploadDisabled() { return this.uploading; }

    connectedCallback() {
        this._loadRows(true);
    }

    disconnectedCallback() {
        this._stopPoll();
    }

    handleDomainChange(event) {
        this.domainOverride = event.target.value;
    }

    // Opens the OS file picker directly — no Policy_Document__c record is
    // created until a file is actually chosen and read (see _uploadFile).
    // This is the fix for the earlier bug where clicking "Attach" alone
    // created a phantom record with Status__c defaulting to 'Uploaded' even
    // if the user closed the file picker without selecting anything.
    handleStartUpload() {
        this._reuploadTargetId = null;
        const picker = this.template.querySelector('.vc-file-input');
        if (picker) picker.click();
    }

    handleReupload(event) {
        this._reuploadTargetId = event.currentTarget.dataset.id;
        const picker = this.template.querySelector('.vc-file-input');
        if (picker) picker.click();
    }

    handleFilePicked(event) {
        const file = event.target.files && event.target.files[0];
        event.target.value = '';   // allow re-picking the same filename later
        if (!file) return;   // user cancelled the picker — nothing created, nothing to clean up

        const reader = new FileReader();
        reader.onload = () => {
            const base64 = (reader.result || '').toString().split(',')[1];
            this._uploadFile(file.name, base64);
        };
        reader.onerror = () => {
            this._toast('error', 'Read failed', `Could not read ${file.name}.`);
        };
        reader.readAsDataURL(file);
    }

    _uploadFile(fileName, base64Data) {
        this.uploading = true;
        const reuploadId = this._reuploadTargetId;
        this._reuploadTargetId = null;

        const call = reuploadId
            ? reuploadPolicyDocument({ policyDocumentId: reuploadId, fileName, base64Data })
            : uploadPolicyDocument({ fileName, base64Data, domainOverride: this.domainOverride });

        call
            .then(() => {
                this.uploading = false;
                this._toast('success', reuploadId ? 'New version uploaded' : 'Upload received',
                    'Ingesting into the policy corpus…');
                this._loadRows(true);
            })
            .catch((err) => {
                this.uploading = false;
                this._toast('error', 'Upload failed',
                    (err && err.body && err.body.message) || 'Unknown error.');
            });
    }

    // In-component confirm instead of the native confirm() dialog — this LWC
    // can be embedded in contexts (Experience Cloud, Lightning Out) where a
    // browser-native confirm() is unreliable or silently suppressed, and it
    // matches this app's own established pattern of custom confirm UI
    // (e.g. scProcurementConsole's assign-to-analyst modal) rather than a
    // native dialog.
    @track pendingDeleteId = null;
    @track pendingDeleteName = '';

    get showDeleteConfirm() { return !!this.pendingDeleteId; }

    handleDelete(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        const row = this.rows.find((r) => r.id === id);
        this.pendingDeleteId = id;
        this.pendingDeleteName = (row && row.name) || 'this policy document';
    }

    handleCancelDelete() {
        this.pendingDeleteId = null;
        this.pendingDeleteName = '';
    }

    handleConfirmDelete() {
        const id = this.pendingDeleteId;
        this.pendingDeleteId = null;
        this.pendingDeleteName = '';
        if (!id) return;
        deletePolicyDocument({ policyDocumentId: id })
            .then(() => {
                this._toast('success', 'Deleted', 'Policy document removed.');
            })
            .catch((err) => {
                this._toast('error', 'Could not delete',
                    (err && err.body && err.body.message) || 'Unknown error.');
            })
            .finally(() => {
                // Refresh either way — if the delete failed because the row
                // was already gone (stale list), a stuck row would otherwise
                // keep showing a now-nonexistent record forever, and every
                // future click on it would hit the same error.
                this._loadRows(true);
            });
    }

    // showSpinner is only true for the INITIAL load (or a manual reload after an
    // upload) — background poll ticks (every POLL_MS while a row is still
    // Processing) must NOT flip loadingList, or the spinner flickers above the
    // already-rendered table every few seconds even though nothing meaningful
    // changed yet (the "buffering" symptom).
    async _loadRows(showSpinner) {
        if (showSpinner) this.loadingList = true;
        try {
            const data = await getPolicyDocuments();
            this.rows = (data || []).map((r) => ({
                ...r,
                badgeClass: STATUS_BADGE[r.status] || 'vc-badge neutral',
                domainLabel: r.domain || 'Not classified yet',
                errorRowKey: r.id + '-error'
            }));
        } catch (err) {
            this._toast('error', 'Could not load policy documents',
                (err && err.body && err.body.message) || 'Unknown error.');
        } finally {
            if (showSpinner) this.loadingList = false;
        }
        this._startPollIfNeeded();
    }

    _startPollIfNeeded() {
        const stillProcessing = this.rows.some((r) => r.status === 'Processing');
        if (stillProcessing && !this._pollHandle) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this._pollHandle = setInterval(() => this._loadRows(false), POLL_MS);
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