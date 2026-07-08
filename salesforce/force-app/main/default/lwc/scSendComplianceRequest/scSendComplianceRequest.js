import { LightningElement, api, track, wire } from 'lwc';
import { CloseActionScreenEvent }              from 'lightning/actions';
import { ShowToastEvent }                      from 'lightning/platformShowToastEvent';
import getEmailPreview  from '@salesforce/apex/ComplianceEmailController.getEmailPreview';
import sendComplianceEmail from '@salesforce/apex/ComplianceEmailController.sendComplianceEmail';

export default class ScSendComplianceRequest extends LightningElement {

    @api recordId;

    @track toEmail       = '';
    @track customNote    = '';
    @track isSending     = false;
    @track isLoading     = true;
    @track error         = null;
    @track preview       = null;

    @wire(getEmailPreview, { accountId: '$recordId' })
    wiredPreview({ data, error }) {
        if (data) {
            this.preview = {
                ...data,
                requiredDocs:   this._enrichDocs(data.requiredDocs),
                additionalDocs: this._enrichDocs(data.additionalDocs)
            };
            this.toEmail = data.toEmail || '';
            this.error   = null;
            // Auto-send without showing the popup form
            this._autoSend();
        } else if (error) {
            this.isLoading = false;
            this.error     = error?.body?.message || 'Failed to load compliance data.';
        }
    }

    _autoSend() {
        if (!this.toEmail?.trim()) {
            this.isLoading = false;
            this.error = 'No recipient email found for this account. Please add a contact email before sending.';
            return;
        }
        sendComplianceEmail({
            accountId:  this.recordId,
            toEmail:    this.toEmail.trim(),
            customNote: ''
        })
            .then(() => {
                this.isLoading = false;
                this.dispatchEvent(new ShowToastEvent({
                    title:   'Email sent',
                    message: `Compliance document request sent to ${this.toEmail}.`,
                    variant: 'success'
                }));
                this.dispatchEvent(new CloseActionScreenEvent());
            })
            .catch(err => {
                this.isLoading = false;
                this.error     = err?.body?.message || 'Failed to send email. Please try again.';
            });
    }

    _enrichDocs(docs) {
        if (!docs) return [];
        const BADGE = {
            Critical: 'sev-badge sev-badge_critical',
            High:     'sev-badge sev-badge_high',
            Medium:   'sev-badge sev-badge_medium',
            Low:      'sev-badge sev-badge_low'
        };
        return docs.map(d => ({
            ...d,
            severityDisplay:    d.severity || 'Required',
            severityBadgeClass: BADGE[d.severity] || 'sev-badge sev-badge_critical'
        }));
    }

    handleEmailChange(event) {
        this.toEmail = event.target.value;
    }

    handleNoteChange(event) {
        this.customNote = event.target.value;
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    handleSend() {
        if (!this.toEmail?.trim()) {
            this.error = 'Please enter a recipient email address.';
            return;
        }
        this.isSending = true;
        this.error     = null;

        sendComplianceEmail({
            accountId:  this.recordId,
            toEmail:    this.toEmail.trim(),
            customNote: this.customNote || ''
        })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title:   'Email sent',
                    message: `Compliance document request sent to ${this.toEmail}.`,
                    variant: 'success'
                }));
                this.dispatchEvent(new CloseActionScreenEvent());
            })
            .catch(err => {
                this.error    = err?.body?.message || 'Failed to send email. Please try again.';
                this.isSending = false;
            });
    }

    get sendLabel() {
        return this.isSending ? 'Sending…' : 'Send Email';
    }

    get totalCount() {
        if (!this.preview) return 0;
        return (this.preview.requiredDocs?.length || 0)
             + (this.preview.additionalDocs?.length || 0);
    }

    get hasDocuments() {
        return this.totalCount > 0;
    }

    get requiredCount() {
        return this.preview?.requiredDocs?.length || 0;
    }

    get hasError() {
        return !!this.error;
    }

    get isSendDisabled() {
        return this.isSending || !this.toEmail?.trim();
    }
}