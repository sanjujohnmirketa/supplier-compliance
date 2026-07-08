import { LightningElement, api, track } from 'lwc';
import saveFile from '@salesforce/apex/DocumentProcessingController.saveFile';

export default class ScDocumentUploaderRow extends LightningElement {
    @api requirementKey;
    @api uploadLabel = 'Upload';
    @api acceptedFormats;
    @api recordId;
    @api uploadedName;          // persisted/last filename (so it survives refresh)

    @track uploading = false;
    @track errorMsg = '';
    @track _lastFile = null;

    // The filename to display below the button (this session's upload wins).
    get displayName() { return this._lastFile || this.uploadedName; }
    get hasFile()     { return !!this.displayName; }
    get buttonLabel() { return this.hasFile ? 'Replace' : (this.uploadLabel || 'Upload'); }

    triggerPicker() {
        this.template.querySelector('.vcu-input').click();
    }
    handleFileChange(event) {
        const file = event.target.files && event.target.files[0];
        if (file) this._upload(file);
    }
    handleDragOver(event) { event.preventDefault(); }
    handleDrop(event) {
        event.preventDefault();
        const file = event.dataTransfer && event.dataTransfer.files && event.dataTransfer.files[0];
        if (file) this._upload(file);
    }

    _upload(file) {
        this.errorMsg = '';
        this.uploading = true;
        const reader = new FileReader();
        reader.onload = () => {
            const base64 = (reader.result || '').split(',')[1];
            saveFile({ recordId: this.recordId, fileName: file.name, base64Data: base64 })
                .then(documentId => {
                    this.uploading = false;
                    this._lastFile = file.name;            // show the latest file immediately
                    // Fire-and-forget: parent links the doc + runs AI in the background.
                    this.dispatchEvent(new CustomEvent('uploadfinished', {
                        detail: { requirementKey: this.requirementKey,
                                  files: [{ documentId, name: file.name }] }
                    }));
                })
                .catch(err => {
                    this.uploading = false;
                    this.errorMsg = (err && err.body && err.body.message) || 'Upload failed — try again.';
                });
        };
        reader.onerror = () => { this.uploading = false; this.errorMsg = 'Could not read the file.'; };
        reader.readAsDataURL(file);
    }
}