import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin }  from 'lightning/navigation';
import { ShowToastEvent }   from 'lightning/platformShowToastEvent';
import { CurrentPageReference } from 'lightning/navigation';

import getChecklistWithDocStatus    from '@salesforce/apex/DocumentProcessingController.getChecklistWithDocStatus';
import linkDocumentToCompliance     from '@salesforce/apex/DocumentProcessingController.linkDocumentToCompliance';
import removeDocumentFromCompliance from '@salesforce/apex/DocumentProcessingController.removeDocumentFromCompliance';

export default class ScProcurementDocumentUploader
    extends NavigationMixin(LightningElement) {

    // Kept for internal Lightning record pages where it is auto-injected.
    // On Experience Cloud it is often not injected through Tabs components,
    // so CurrentPageReference is used as the authoritative source instead.
    @api recordId;

    @track rows       = [];
    @track isLoading  = true;
    @track errorMessage;

    // ── Other Document (ad-hoc, no AI extraction) ─────────────────────────
    @track _otherDocStatus = 'pending';
    @track _otherDocFiles  = [];

    get otherIsPending()     { return this._otherDocStatus === 'pending'; }
    get otherIsDone()        { return this._otherDocStatus === 'done';    }
    get otherUploadedFiles() { return this._otherDocFiles; }
    get otherAcceptedFormats() { return ['.pdf', '.jpg', '.jpeg', '.png', '.docx']; }
    get otherRowClass()        { return this._otherDocStatus === 'done' ? 'row row-uploaded' : 'row row-pending'; }

    handleOtherUploadFinished(event) {
        const files = event.detail.files;
        if (!files?.length) return;
        this._otherDocStatus = 'done';
        this._otherDocFiles  = [{ name: files[0].name }];
        this._toast('success', 'Document uploaded',
            `${files[0].name} has been attached to this record.`);
    }

    handleOtherRemove() {
        this._otherDocStatus = 'pending';
        this._otherDocFiles  = [];
    }

    _resolvedId;  // the account ID we actually use — resolved from multiple sources

    // ── Primary: read recordId from the page URL via CurrentPageReference ────
    // Works on both internal Lightning and LWR Experience Cloud record pages.
    // On LWR detail pages (routeType detail-001) the record ID is in
    // pageRef.attributes.recordId. Inside a Tabs component, @api recordId
    // is not propagated automatically — this wire is the reliable fallback.
    @wire(CurrentPageReference)
    handlePageRef(pageRef) {
        console.log('[ProcurementUploader] pageRef=', JSON.stringify(pageRef));

        let id;
        if (pageRef) {
            // LWR record detail page
            id = (pageRef.attributes && pageRef.attributes.recordId)
              // Some LWR themes use state
              || (pageRef.state && pageRef.state.recordId)
              // Last resort: try to parse from the URL path
              || this._parseIdFromUrl();
        }
        // Final fallback: @api recordId (works on internal pages)
        id = id || this.recordId;

        console.log('[ProcurementUploader] resolved recordId=', id);

        if (id && id !== this._resolvedId) {
            this._resolvedId = id;
            this._loadChecklist();
        }
    }

    // Backup: parse the Salesforce record ID from the current page URL.
    // LWR routes for detail pages follow /account/{recordId}
    _parseIdFromUrl() {
        try {
            const path = window.location.pathname;
            // Match a 15 or 18 char Salesforce ID (starts with 001 for Account)
            const match = path.match(/\/([a-zA-Z0-9]{15,18})(?:\/|$)/);
            if (match && match[1]) {
                console.log('[ProcurementUploader] ID from URL path:', match[1]);
                return match[1];
            }
        } catch { /* ignore — storage unavailable */ }
        return null;
    }

    // ── Imperative Apex call ─────────────────────────────────────────────────
    // Using imperative rather than @wire because _resolvedId is a private
    // field — @wire reactive params only track @api/@track properties.
    _loadChecklist() {
        if (!this._resolvedId) return;
        this.isLoading = true;
        console.log('[ProcurementUploader] calling getChecklistWithDocStatus for', this._resolvedId);

        getChecklistWithDocStatus({ accountId: this._resolvedId })
            .then(data => {
                console.log('[ProcurementUploader] loaded', data.length, 'rows');
                this.rows = this._enrichRows(data);
                this.errorMessage = null;
                this.isLoading = false;
            })
            .catch(err => {
                console.error('[ProcurementUploader] error', err);
                this.errorMessage = this._extractError(err);
                this.rows = [];
                this.isLoading = false;
            });
    }

    // ── Computed helpers ─────────────────────────────────────────────────────
    get hasRows()       { return this.rows.length > 0; }
    get hasError()      { return !!this.errorMessage; }
    get totalCount()    { return this.rows.length; }
    get uploadedCount() { return this.rows.filter(r => r.hasDocument && r.documentStatus !== 'Rejected').length; }
    get pendingCount()  { return this.rows.filter(r => !r.hasDocument || r.documentStatus === 'Rejected').length; }

    // ── Enrich rows with display-layer computed properties ───────────────────
    _enrichRows(data) {
        return data.map(r => {
            const isUploaded = r.hasDocument && r.documentStatus !== 'Rejected';
            const isRejected = r.hasDocument && r.documentStatus === 'Rejected';
            const isPending  = !r.hasDocument;
            return {
                ...r,
                isUploaded, isRejected, isPending,
                rowClass: isRejected ? 'row row-rejected'
                        : isUploaded ? 'row row-uploaded'
                        : 'row row-pending',
                badgeLabel:   isUploaded ? r.documentStatus
                            : isRejected ? 'Rejected'
                            : 'Not uploaded',
                badgeVariant: isUploaded && r.documentStatus === 'Validated' ? 'success'
                            : isUploaded ? 'warning'
                            : isRejected ? 'error'
                            : 'inverse',
                confidenceLabel: r.confidenceScore != null
                    ? `${Math.round(r.confidenceScore * 100)}%` : null,
                uploadedLabel: r.uploadedDate
                    ? new Date(r.uploadedDate).toLocaleDateString() : null,
                expiryLabel: r.expiryDate
                    ? new Date(r.expiryDate).toLocaleDateString() : null,
                uploadLabel:       isRejected ? 'Re-upload' : 'Upload',
                showReplace:       isUploaded && r.documentStatus !== 'Validated',
                isUploading:       false,
                acceptedFormats:   ['.pdf', '.jpg', '.jpeg', '.png', '.docx']
            };
        });
    }

    // ── Upload ───────────────────────────────────────────────────────────────
    handleUploadFinished(event) {
        // Use currentTarget (the element with the handler) not target
        // (the element that fired) — on Experience Cloud inside Shadow DOM
        // event.target doesn't reliably carry dataset attributes
        const assessmentId = event.currentTarget.dataset.assessmentId;
        const documentType = event.currentTarget.dataset.documentType;
        const files        = event.detail.files;
        if (!files || files.length === 0) return;

        const file = files[0];
        console.log('[ProcurementUploader] uploadFinished assessmentId=', assessmentId,
            'documentType=', documentType, 'file=', file.name, 'documentId=', file.documentId);

        this._setRowState(assessmentId, { isUploading: true });

        linkDocumentToCompliance({
            accountId:         this._resolvedId,
            contentDocumentId: file.documentId,
            documentType:      documentType,
            assessmentId:      assessmentId,
            fileName:          file.name
        })
        .then(() => {
            this._setRowState(assessmentId, { isUploading: false });
            this._toast('success', 'Document uploaded',
                `${file.name} has been uploaded successfully.`);
            // Force rows to empty first so LWC detects the change on reload
            this.rows = [];
            this.isLoading = true;
            // Small delay to let the server commit before re-querying
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => this._loadChecklist(), 1000);
        })
        .catch(err => {
            this._setRowState(assessmentId, { isUploading: false });
            console.error('[ProcurementUploader] upload error', err);
            this._toast('error', 'Upload failed', this._extractError(err));
        });
    }

    // ── Replace ──────────────────────────────────────────────────────────────
    handleReplace(event) {
        const assessmentId = event.currentTarget.dataset.assessmentId;
        const documentId   = event.currentTarget.dataset.documentId;
        this._setRowState(assessmentId, { isUploading: true });

        removeDocumentFromCompliance({ complianceDocId: documentId, assessmentId })
        .then(() => {
            this._setRowState(assessmentId, { isUploading: false });
            this._toast('info', 'Document removed', 'Upload a new document to replace it.');
            this.rows = [];
            this.isLoading = true;
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => this._loadChecklist(), 500);
        })
        .catch(err => {
            this._setRowState(assessmentId, { isUploading: false });
            this._toast('error', 'Remove failed', this._extractError(err));
        });
    }

    // ── Navigate to document ─────────────────────────────────────────────────
    handleDocumentClick(event) {
        const docId = event.currentTarget.dataset.documentId;
        if (!docId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: docId, objectApiName: 'Compliance_Document__c', actionName: 'view' }
        });
    }

    // ── Utilities ────────────────────────────────────────────────────────────
    _setRowState(assessmentId, patch) {
        this.rows = this.rows.map(r =>
            r.assessmentId === assessmentId ? { ...r, ...patch } : r
        );
    }

    _toast(variant, title, message) {
        this.dispatchEvent(new ShowToastEvent({ variant, title, message }));
    }

    _extractError(err) {
        if (err?.body?.message) return err.body.message;
        if (err?.message)        return err.message;
        return 'An unexpected error occurred.';
    }
}