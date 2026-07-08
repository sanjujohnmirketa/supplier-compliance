import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import linkDocumentToCompliance     from '@salesforce/apex/DocumentProcessingController.linkDocumentToCompliance';
import removeDocumentFromCompliance from '@salesforce/apex/DocumentProcessingController.removeDocumentFromCompliance';
import getProcessingStatus          from '@salesforce/apex/DocumentProcessingController.getProcessingStatus';

// Polling configuration
const POLL_INITIAL_DELAY_MS = 15000;  // 15 s — give the platform event time to fire
const POLL_INTERVAL_MS      = 15000;   // 15 s between each subsequent check
const POLL_MAX_ATTEMPTS     = 12;    // 12 × 15 s = 3 min (gpt-5 + tunnel can be slow)
    
// User-facing labels for assessment statuses returned by ComplianceEvaluationQueueable
const ASSESSMENT_LABELS = {
    'Compliant':          'Approved',
    'Non-Compliant':      'Rejected',
    'Needs Human Review': 'Under Review',
    'Pending':            'Processing'
};

export default class ScDocumentUploader extends LightningElement {

    // ── Public API ────────────────────────────────────────────────────────────

    @api accountId;
    @api isOnboarding = false;

    _checklistJSON;
    @api
    get checklistJSON() { return this._checklistJSON; }
    set checklistJSON(value) {
        this._checklistJSON = value;
        if (!this.isLoading) this.parseChecklist();
    }

    // ── Internal state ────────────────────────────────────────────────────────

    @track checklistItems = [];
    @track isLoading = true;
    @track globalError = null;

    acceptedFormats = ['.pdf', '.png', '.jpg', '.jpeg', '.tiff', '.doc', '.docx'];

    // ── Other Document (ad-hoc, no AI extraction) ─────────────────────────
    @track _otherDocStatus = 'pending';
    @track _otherDocFiles  = [];

    get otherIsPending()     { return this._otherDocStatus === 'pending'; }
    get otherIsDone()        { return this._otherDocStatus === 'done';    }
    get otherUploadedFiles() { return this._otherDocFiles; }

    handleOtherUploadFinished(event) {
        const files = event.detail.files;
        if (!files?.length) return;
        this._otherDocStatus = 'done';
        this._otherDocFiles  = files.map(f => ({ name: f.name }));
        this.dispatchEvent(new ShowToastEvent({
            title:   'Document uploaded',
            message: `${files[0].name} has been attached to your record.`,
            variant: 'success'
        }));
    }

    handleOtherRemove() {
        this._otherDocStatus = 'pending';
        this._otherDocFiles  = [];
    }

    // Keyed by requirementKey → { timeoutId, attempts }
    _pollMap = new Map();

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    connectedCallback() {
        this.parseChecklist();
    }

    disconnectedCallback() {
        // Cancel every pending poll to avoid memory leaks after unmount
        this._pollMap.forEach(entry => {
            if (entry.timeoutId != null) clearTimeout(entry.timeoutId);
        });
        this._pollMap.clear();
    }

    // ── Parsing ───────────────────────────────────────────────────────────────

    parseChecklist() {
        this.isLoading = false;
        if (!this._checklistJSON) { this.checklistItems = []; return; }
        try {
            const raw = JSON.parse(this._checklistJSON);
            this.checklistItems = raw.map((item, i) => this._buildItem(item, i));
            // Resume polling for any doc uploaded but not yet assessed, so the
            // verdict appears automatically (no more stuck "reviewing" state).
            this.checklistItems.forEach(it => {
                if (it.uploadStatus === 'done' && it.aiStatus === 'processing'
                    && it.complianceDocId && it.assessmentId && !this._pollMap.has(it.requirementKey)) {
                    this._startPolling(it.requirementKey, it.complianceDocId, it.assessmentId);
                }
            });
        } catch (e) {
            this.globalError = 'Unable to load your compliance checklist. Please refresh the page.';
            console.error('[scDocumentUploader] parse error:', e);
        }
    }

    /**
     * Single source of truth for every item shape.
     * Called on initial parse AND on every row update.
     * All computed booleans and display values derive from raw fields here.
     */
    // File-type icon from the filename extension (was hardcoded to PDF).
    _fileIcon(name) {
        const n = (name || '').toLowerCase();
        if (n.endsWith('.pdf')) return 'doctype:pdf';
        if (n.endsWith('.doc') || n.endsWith('.docx')) return 'doctype:word';
        if (n.endsWith('.xls') || n.endsWith('.xlsx') || n.endsWith('.csv')) return 'doctype:excel';
        if (/\.(png|jpe?g|gif|webp|tiff?)$/.test(n)) return 'doctype:image';
        return 'doctype:attachment';
    }

    _buildItem(raw, index) {
        const status    = raw.uploadStatus    || 'pending';
        const aiStatus  = raw.aiStatus        || null;   // null | 'processing' | 'complete'
        const files     = Array.isArray(raw.uploadedFiles) ? raw.uploadedFiles : [];

        const assessmentStatus = raw.assessmentStatus || null;
        const docStatus        = raw.docStatus        || null;
        const reasonDetail     = raw.reasonDetail     || null;

        // Derive display-level booleans from assessmentStatus
        const isCompliant   = assessmentStatus === 'Compliant';
        const isRejected    = assessmentStatus === 'Non-Compliant' || docStatus === 'Rejected';
        const isHumanReview = assessmentStatus === 'Needs Human Review';

        const aiResultPanelClass = isCompliant   ? 'ai-result-panel ai-result-panel_compliant'
                                 : isRejected    ? 'ai-result-panel ai-result-panel_rejected'
                                 : isHumanReview ? 'ai-result-panel ai-result-panel_review'
                                 :                 'ai-result-panel ai-result-panel_neutral';

        const assessmentBadgeVariant = isCompliant   ? 'success'
                                     : isRejected    ? 'error'
                                     : isHumanReview ? 'warning'
                                     :                 'inverse';

        return {
            // ── identity ──────────────────────────────────────────────────
            key:               raw.assessmentId || `row-${index}`,
            requirementKey:    raw.requirementKey || raw.assessmentId || `row-${index}`,
            requirementLabel:  raw.requirementLabel,
            documentType:      raw.documentType,
            assessmentId:      raw.assessmentId,
            severity:          raw.severity,
            isMandatory:       raw.isMandatory,
            regulation:        raw.regulation || '',

            // ── upload state ──────────────────────────────────────────────
            uploadStatus:      status,
            complianceDocId:   raw.complianceDocId || null,
            uploadedFiles:     files.map(f => ({ ...f, iconName: this._fileIcon(f.name) })),
            uploadedFileName:  files.length ? files[0].name : null,
            errorMessage:      raw.errorMessage || null,

            // ── AI pipeline state ─────────────────────────────────────────
            aiStatus:                aiStatus,
            docStatus:               docStatus,
            assessmentStatus:        assessmentStatus,
            assessmentLabel:         ASSESSMENT_LABELS[assessmentStatus] || assessmentStatus || '',
            reasonDetail:            reasonDetail,
            aiResultPanelClass:      aiResultPanelClass,
            assessmentBadgeVariant:  assessmentBadgeVariant,

            // ── LWC inputs ────────────────────────────────────────────────
            uploadLabel:       raw.isMandatory
                                   ? 'Choose file to upload'
                                   : 'Choose file to upload (optional)',
            uploadRecordId:    this.accountId,

            // ── computed booleans ─────────────────────────────────────────
            isDone:            status === 'done',
            isUploading:       status === 'uploading',
            isRemoving:        status === 'removing',
            isError:           status === 'error',
            isPending:         status === 'pending',
            hasFiles:          files.length > 0,

            isAiProcessing:    aiStatus === 'processing',
            isAiComplete:      aiStatus === 'complete',
            // Hide remove button while AI is running — don't let the supplier
            // delete the file before we know whether it passed
            showRemoveBtn:     status === 'done' && aiStatus !== 'processing',

            // ── display ───────────────────────────────────────────────────
            severityClass:     this._severityClass(raw.severity),
            rowClass:          raw.isMandatory
                                   ? 'checklist-row checklist-row_mandatory'
                                   : 'checklist-row checklist-row_recommended'
        };
    }

    // ── Upload ────────────────────────────────────────────────────────────────

    handleUploadFinished(event) {
        const requirementKey = event.detail.requirementKey;
        const files          = event.detail.files;

        if (!requirementKey || !files?.length) return;

        const item = this.checklistItems.find(i => i.requirementKey === requirementKey);
        if (!item) return;

        this._updateRow(requirementKey, { uploadStatus: 'uploading' });

        const promises = files.map(file =>
            linkDocumentToCompliance({
                accountId:         this.accountId,
                contentDocumentId: file.documentId,
                documentType:      item.documentType,
                assessmentId:      item.assessmentId,
                fileName:          file.name
            })
        );

        Promise.all(promises)
            .then(complianceDocIds => {
                const complianceDocId = complianceDocIds[0];
                this._updateRow(requirementKey, {
                    uploadStatus:    'done',
                    aiStatus:        'processing',   // immediately show AI spinner
                    complianceDocId: complianceDocId,
                    uploadedFiles:   files.map(f => ({
                        name:              f.name,
                        contentDocumentId: f.documentId
                    })),
                    errorMessage: null
                });
                this.dispatchEvent(new ShowToastEvent({
                    title:   'Document uploaded',
                    message: `${files[0].name} linked to your compliance record.`,
                    variant: 'success'
                }));
                // Tell the parent the case changed (doc count etc.) — auto-refresh.
                this.dispatchEvent(new CustomEvent('casechanged', { bubbles: true, composed: true }));
                // Begin polling for AI pipeline completion
                this._startPolling(requirementKey, complianceDocId, item.assessmentId);
            })
            .catch(err => {
                const msg = err?.body?.message || err?.message || 'Upload failed. Please try again.';
                this._updateRow(requirementKey, { uploadStatus: 'error', errorMessage: msg });
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Upload failed', message: msg,
                    variant: 'error', mode: 'sticky'
                }));
            });
    }

    // ── AI result polling ─────────────────────────────────────────────────────

    _startPolling(requirementKey, complianceDocId, assessmentId) {
        // Cancel any pre-existing poll for this row (e.g. re-upload after reject)
        const existing = this._pollMap.get(requirementKey);
        if (existing?.timeoutId != null) clearTimeout(existing.timeoutId);
        this._pollMap.set(requirementKey, { timeoutId: null, attempts: 0 });

        console.log('[scDocumentUploader] Starting AI result poll for', requirementKey);

        // eslint-disable-next-line @lwc/lwc/no-async-operation
        const id = setTimeout(
            () => this._poll(requirementKey, complianceDocId, assessmentId),
            POLL_INITIAL_DELAY_MS
        );
        this._pollMap.set(requirementKey, { timeoutId: id, attempts: 0 });
    }

    _poll(requirementKey, complianceDocId, assessmentId) {
        const state = this._pollMap.get(requirementKey);
        if (!state) return; // component unmounted or row removed

        const attempts = (state.attempts || 0) + 1;
        this._pollMap.set(requirementKey, { ...state, attempts });

        if (attempts > POLL_MAX_ATTEMPTS) {
            // Stop polling but stay positive — the AI is still working; the result
            // will be there on the next visit/refresh (it's persisted server-side).
            this._updateRow(requirementKey, {
                aiStatus:         'processing',
                assessmentStatus: 'Pending',
                reasonDetail:     '✦ AI is still reviewing this document — your upload is saved and the result will appear automatically once it’s done.'
            });
            this._pollMap.delete(requirementKey);
            return;
        }

        getProcessingStatus({ complianceDocId, assessmentId })
            .then(result => {
                const aStatus = result.assessmentStatus;
                if (aStatus && aStatus !== 'Pending') {
                    // Chain complete — show final result
                    console.log('[scDocumentUploader] AI chain complete for', requirementKey,
                        '| Assessment:', aStatus, '| Doc:', result.docStatus);
                    this._updateRow(requirementKey, {
                        aiStatus:         'complete',
                        docStatus:        result.docStatus,
                        assessmentStatus: result.assessmentStatus,
                        reasonDetail:     result.reasonDetail
                    });
                    this._pollMap.delete(requirementKey);
                    // AI verdict is in — auto-refresh the parent's risk summary.
                    this.dispatchEvent(new CustomEvent('casechanged', { bubbles: true, composed: true }));
                } else {
                    this._scheduleNextPoll(requirementKey, complianceDocId, assessmentId);
                }
            })
            .catch(() => {
                // Transient error — keep retrying silently
                this._scheduleNextPoll(requirementKey, complianceDocId, assessmentId);
            });
    }

    _scheduleNextPoll(requirementKey, complianceDocId, assessmentId) {
        const state = this._pollMap.get(requirementKey);
        if (!state) return;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        const id = setTimeout(
            () => this._poll(requirementKey, complianceDocId, assessmentId),
            POLL_INTERVAL_MS
        );
        this._pollMap.set(requirementKey, { ...state, timeoutId: id });
    }

    // ── Remove ────────────────────────────────────────────────────────────────

    handleRemoveFile(event) {
        const requirementKey = event.currentTarget.dataset.requirementKey;
        if (!requirementKey) return;

        const item = this.checklistItems.find(i => i.requirementKey === requirementKey);
        if (!item) return;

        // Cancel any running poll — the document is being removed
        const poll = this._pollMap.get(requirementKey);
        if (poll?.timeoutId != null) clearTimeout(poll.timeoutId);
        this._pollMap.delete(requirementKey);

        this._updateRow(requirementKey, { uploadStatus: 'removing' });

        removeDocumentFromCompliance({
            complianceDocId: item.complianceDocId,
            assessmentId:    item.assessmentId
        })
            .then(() => {
                this._updateRow(requirementKey, {
                    uploadStatus:     'pending',
                    aiStatus:         null,
                    docStatus:        null,
                    assessmentStatus: null,
                    reasonDetail:     null,
                    complianceDocId:  null,
                    uploadedFiles:    [],
                    errorMessage:     null
                });
                this.dispatchEvent(new ShowToastEvent({
                    title:   'Document removed',
                    message: 'You can now upload a replacement document.',
                    variant: 'info'
                }));
            })
            .catch(err => {
                const msg = err?.body?.message || err?.message || 'Remove failed. Please try again.';
                this._updateRow(requirementKey, { uploadStatus: 'done', errorMessage: msg });
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Remove failed', message: msg,
                    variant: 'error', mode: 'sticky'
                }));
            });
    }

    // ── Retry after error ─────────────────────────────────────────────────────

    handleRetry(event) {
        const requirementKey = event.currentTarget.dataset.requirementKey;
        if (!requirementKey) return;
        this._updateRow(requirementKey, {
            uploadStatus:     'pending',
            aiStatus:         null,
            docStatus:        null,
            assessmentStatus: null,
            reasonDetail:     null,
            errorMessage:     null,
            uploadedFiles:    []
        });
    }

    // ── Row state management ──────────────────────────────────────────────────

    _updateRow(requirementKey, patch) {
        this.checklistItems = this.checklistItems.map((item, index) => {
            if (item.requirementKey !== requirementKey) return item;
            return this._buildItem({ ...item, ...patch }, index);
        });
    }

    // ── Getters ───────────────────────────────────────────────────────────────

    get hasChecklist()  { return this.checklistItems.length > 0; }
    get hasError()      { return !!this.globalError; }

    get mandatoryItems()   { return this.checklistItems.filter(i =>  i.isMandatory); }
    get recommendedItems() { return this.checklistItems.filter(i => !i.isMandatory); }

    get uploadedCount() { return this.checklistItems.filter(i => i.isDone).length; }
    get totalCount()    { return this.checklistItems.length; }
    get progressLabel() { return `${this.uploadedCount} of ${this.totalCount} documents uploaded`; }
    get progressValue() {
        return this.totalCount === 0 ? 0
            : Math.round((this.uploadedCount / this.totalCount) * 100);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    _severityClass(severity) {
        return { Critical: 'slds-badge slds-badge_error',
                 High:     'slds-badge slds-badge_error',
                 Medium:   'slds-badge slds-badge_warning',
                 Low:      'slds-badge slds-badge_success' }[severity] || 'slds-badge';
    }
}