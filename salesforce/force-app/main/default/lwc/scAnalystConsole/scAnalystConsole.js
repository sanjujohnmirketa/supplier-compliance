import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import complianceLogo from '@salesforce/resourceUrl/complianceLogo';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import userId from '@salesforce/user/Id';
import FIRSTNAME_FIELD from '@salesforce/schema/User.FirstName';
import LASTNAME_FIELD from '@salesforce/schema/User.LastName';
import getAnalystQueue from '@salesforce/apex/VendorPortalController.getAnalystQueue';
import getCaseForAnalyst from '@salesforce/apex/VendorPortalController.getCaseForAnalyst';
import saveDocValidation from '@salesforce/apex/VendorPortalController.saveDocValidation';
import copilotDraftComment from '@salesforce/apex/VendorPortalController.copilotDraftComment';
import askCopilot from '@salesforce/apex/VendorPortalController.askCopilot';
import saveDecision from '@salesforce/apex/VendorPortalController.saveDecision';
import generatePublicDocumentUrl from '@salesforce/apex/VendorPortalController.generatePublicDocumentUrl';

/**
 * scAnalystConsole — Risk & Compliance Analyst workspace (operational).
 *
 *   A1  Analyst queue   — existing supplier requests handed over (NO co-pilot)
 *   A2  Risk analysis   — per-DOCUMENT validation: AI summary + analyst comment +
 *                         mark-validated; co-pilot drafts comments from observations
 *   A3  Decision & route — confirm tier + mitigations + route to approver
 *
 * A2/A3 are per-supplier: they only appear in the left nav after a supplier is
 * opened from the queue. The co-pilot is available on A2/A3 only.
 */

const BREADCRUMBS = {
    a1: '/Analyst queue',
    a2: '/Analyst queue / Risk analysis',
    a3: '/Analyst queue / Decision & route'
};

export default class ScAnalystConsole extends NavigationMixin(LightningElement) {

    logoUrl = complianceLogo;

    // ── Logged-in user ────────────────────────────────────────────────────────
    _userInitials = '??';
    _userName = '';
    @track _showUserMenu = false;

    @wire(getRecord, { recordId: userId, fields: [FIRSTNAME_FIELD, LASTNAME_FIELD] })
    wiredUser({ data }) {
        if (data) {
            const first = getFieldValue(data, FIRSTNAME_FIELD) || '';
            const last = getFieldValue(data, LASTNAME_FIELD) || '';
            this._userInitials = (first.charAt(0) + last.charAt(0)).toUpperCase() || '??';
            this._userName = `${first} ${last}`.trim();
        }
    }
    get userInitials() { return this._userInitials; }
    get userName() { return this._userName; }
    get showUserMenu() { return this._showUserMenu; }

    connectedCallback() {
        this._boundDocClick = (evt) => {
            if (!this._showUserMenu) return;
            if (!evt.composedPath().includes(this.template.host)) this._showUserMenu = false;
        };
        document.addEventListener('click', this._boundDocClick);
    }
    disconnectedCallback() { document.removeEventListener('click', this._boundDocClick); }
    handleAvatarClick() { this._showUserMenu = !this._showUserMenu; }
    handleLogout() {
        this._showUserMenu = false;
        this[NavigationMixin.Navigate]({ type: 'comm__loginPage', attributes: { actionName: 'logout' } });
    }

    // ── Active screen ─────────────────────────────────────────────────────────
    @track activeScreen = 'a1';
    @track breadcrumb = BREADCRUMBS.a1;

    get isA1() { return this.activeScreen === 'a1'; }
    get isA2() { return this.activeScreen === 'a2'; }
    get isA3() { return this.activeScreen === 'a3'; }

    // The queue tab stays highlighted while a per-supplier sub-screen is open.
    get sbA1Active() { return this.activeScreen === 'a1' ? 'vc-sb-item active' : 'vc-sb-item'; }
    get sbA2Active() { return this.activeScreen === 'a2' ? 'vc-sb-item active' : 'vc-sb-item'; }
    get sbA3Active() { return this.activeScreen === 'a3' ? 'vc-sb-item active' : 'vc-sb-item'; }
    get sbA3SubActive() { return this.activeScreen === 'a3' ? 'vc-sb-subitem active' : 'vc-sb-subitem'; }
    get dotA1() { return this.activeScreen === 'a1' ? 'vc-sb-dot curr' : 'vc-sb-dot'; }
    get dotA2() { return this.activeScreen === 'a2' ? 'vc-sb-dot curr' : 'vc-sb-dot'; }
    get dotA3() { return this.activeScreen === 'a3' ? 'vc-sb-dot curr' : 'vc-sb-dot'; }

    // A2/A3 sub-nav only after a supplier is selected.
    get hasSelectedCase() { return !!this._caseId; }

    handleNav(event) {
        const sid = event.currentTarget.dataset.screen;
        if (!sid || !BREADCRUMBS[sid]) return;
        if ((sid === 'a2' || sid === 'a3') && !this._caseId) return;  // gated
        this.activeScreen = sid;
        this.breadcrumb = BREADCRUMBS[sid];
    }
    handleBackToQueue() {
        this.activeScreen = 'a1';
        this.breadcrumb = BREADCRUMBS.a1;
        this.copilotOpen = false;
        this._selectedDocId = null;
    }

    // ── A1 — analyst queue (existing supplier requests) ───────────────────────
    _wiredQueue;
    @track queueRows = [];
    @track queueLoading = true;
    @wire(getAnalystQueue)
    wiredQueue(result) {
        this._wiredQueue = result;
        this.queueLoading = false;
        if (result.data) {
            this.queueRows = result.data.map(r => ({
                id: r.id,
                name: r.name,
                industry: r.industry || '—',
                aiTier: r.aiTier || '—',
                tierClass: 'vc-badge ' + this._tierBadge(r.aiTier),
                flags: r.flags,
                flagLabel: r.flags > 0 ? `${r.flags} flagged` : 'none',
                docLabel: `${r.validatedCount}/${r.docCount} validated`,
                stageLabel: r.stageLabel || r.status || '—',
                requestedBy: r.requestedBy || '—',
                ageLabel: r.ageLabel || '—'
            }));
        }
    }
    get hasQueueRows() { return this.queueRows.length > 0; }
    refreshQueue() { if (this._wiredQueue) refreshApex(this._wiredQueue); }

    _tierBadge(tier) {
        const t = (tier || '').toLowerCase();
        if (t === 'high' || t === 'critical') return 'bad';
        if (t === 'medium') return 'warn';
        if (t === 'low') return 'ok';
        return 'neutral';
    }

    // Open a supplier → load the case and reveal A2/A3.
    _caseId;
    @track caseName = '';
    @track caseIndustry = '';
    @track caseCountry = '';
    @track caseTier = '';
    handleOpenCase(event) {
        this._caseId = event.currentTarget.dataset.id;
        this._loadCase();
        this.activeScreen = 'a2';
        this.breadcrumb = BREADCRUMBS.a2;
    }

    // ── A2 — per-document validation ──────────────────────────────────────────
    @track docs = [];
    @track caseLoading = false;
    @track caseDocCount = 0;
    @track caseValidatedCount = 0;
    _selectedDocId = null;
    _docDecisions = {};

    _loadCase() {
        if (!this._caseId) return;
        this.caseLoading = true;
        this._selectedDocId = null;
        this._docDecisions = {};
        this.copilotMessages = [];
        this._copilotGreeted = false;
        getCaseForAnalyst({ accountId: this._caseId })
            .then(c => {
                this.caseLoading = false;
                this.caseName = c.name || '';
                this.caseIndustry = c.industry || '—';
                this.caseCountry = c.country || '—';
                this.caseTier = c.aiTier || '';
                this.confirmedTier = this._uiTier(c.aiTier);
                this.caseDocCount = c.docCount;
                this.caseValidatedCount = c.validatedCount;
                this.docs = (c.docs || []).map(d => this._mapDoc(d));
            })
            .catch(err => {
                this.caseLoading = false;
                this._toast('Load failed', (err && err.body && err.body.message) || 'Could not load the case.');
            });
    }
    _parseSummary(reason) {
        const out = { headline: '', facts: [], concerns: [], checks: [] };
        if (!reason) return out;
        const lines = String(reason).split(/\r?\n/).map(l => l.trim()).filter(Boolean);
        let inChecks = false;
        for (const line of lines) {
            if (/^clause checks:/i.test(line)) { inChecks = true; continue; }
            if (/^concerns:/i.test(line))       { inChecks = false; continue; }
            if (/^policy citations:/i.test(line)) { inChecks = false; continue; }
            if (line.startsWith('•')) { out.facts.push(line.replace(/^•\s*/, '')); continue; }
            if (line.startsWith('⚠')) { out.concerns.push(line.replace(/^⚠\s*/, '')); continue; }
            if (inChecks) {
                const pass = /\[pass\]/i.test(line);
                const text = line.replace(/\[(pass|fail)\]\s*/gi, '').trim();
                out.checks.push({ pass, text });
                continue;
            }
            if (!out.headline) {
                out.headline = line.replace(/^\[[^\]]*\]\s*/, '');
            } else if (/^(extracted|expiry|registry)\b/i.test(line)) {
                out.facts.push(line.replace(/^[A-Za-z]+\s·\s*/, ''));
            }
        }
        return out;
    }

    _mapDoc(d) {
        const decision = this._docDecisions[d.assessmentId] || (d.validated ? 'approved' : '');
        const parsed = this._parseSummary(d.aiSummary);
        return {
            assessmentId: d.assessmentId,
            label: d.requirementLabel,
            aiStatus: d.aiStatus,
            severity: d.severity,
            aiSummary: d.aiSummary || 'No AI summary recorded.',
            headline: parsed.headline,
            hasHeadline: !!parsed.headline,
            facts: parsed.facts.map((t, j) => ({ id: 'af_' + d.assessmentId + '_' + j, text: t })),
            hasFacts: parsed.facts.length > 0,
            checks: parsed.checks.map((k, j) => ({
                id: 'ck_' + d.assessmentId + '_' + j,
                pass: k.pass, text: k.text,
                chkClass: 'vc-chkline ' + (k.pass ? 'pass' : 'fail')
            })),
            hasChecks: parsed.checks.length > 0,
            concerns: parsed.concerns.map((t, j) => ({ id: 'cn_' + d.assessmentId + '_' + j, text: t })),
            hasConcerns: parsed.concerns.length > 0,
            comment: d.analystComment || '',
            validated: d.validated,
            confidence: d.confidence || '—',
            decision: decision,
            badgeClass: 'vc-badge ' + (d.badgeClass || 'neutral'),
            rowClass: d.validated ? 'vc-doc-card validated' : 'vc-doc-card',
            listItemClass: this._selectedDocId === d.assessmentId ? 'vc-a2-list-item selected' : 'vc-a2-list-item',
            approveBtnClass: decision === 'approved' ? 'vc-btn-sec vc-btn-sm vc-doc-approved' : 'vc-btn-pri vc-btn-sm',
            approveLabel: decision === 'approved' ? '✓ Approved' : 'Approve',
            rejectBtnClass: decision === 'rejected' ? 'vc-btn-sec vc-btn-sm vc-doc-rejected' : 'vc-btn-sec vc-btn-sm',
            rejectLabel: decision === 'rejected' ? '✗ Rejected' : 'Reject',
            versionId: d.versionId,
            contentDocumentId: d.contentDocumentId,
            docUrl: d.docUrl,
            fileType: (d.fileType || '').toLowerCase(),
            docTitle: d.docTitle,
            hasDoc: !!(d.versionId || d.docUrl),
            isPreviewing: this._previewDocId === d.assessmentId
        };
    }
    get hasDocs() { return this.docs.length > 0; }
    get hasSelectedDoc() { return !!this._selectedDocId; }
    get selectedDoc() { return this.docs.find(d => d.assessmentId === this._selectedDocId) || null; }
    get validationProgress() {
        return this.caseDocCount ? `${this.caseValidatedCount}/${this.caseDocCount} documents validated` : '—';
    }

    handleSelectDoc(event) {
        const id = event.currentTarget.dataset.id;
        this._selectedDocId = id;
        this._previewDocId = null;
        this._previewUrl = null;
        this._previewTitle = '';
        this._previewIsImage = false;
        this.docs = this.docs.map(d => ({
            ...d,
            listItemClass: d.assessmentId === id ? 'vc-a2-list-item selected' : 'vc-a2-list-item',
            isPreviewing: false
        }));
    }

    handleApproveDoc() {
        const doc = this.selectedDoc;
        if (!doc) return;
        const id = doc.assessmentId;
        this._docDecisions[id] = 'approved';
        saveDocValidation({ assessmentId: id, comment: doc.comment, validated: true })
            .then(() => {
                this.docs = this.docs.map(d => d.assessmentId !== id ? d : {
                    ...d, validated: true, decision: 'approved',
                    rowClass: 'vc-doc-card validated',
                    approveBtnClass: 'vc-btn-sec vc-btn-sm vc-doc-approved',
                    approveLabel: '✓ Approved',
                    rejectBtnClass: 'vc-btn-sec vc-btn-sm',
                    rejectLabel: 'Reject'
                });
                this.caseValidatedCount = this.docs.filter(d => d.validated).length;
                this._toast('Approved', `${doc.label} approved.`);
            })
            .catch(err => this._toast('Save failed', (err && err.body && err.body.message) || 'Could not save.'));
    }

    handleRejectDoc() {
        const doc = this.selectedDoc;
        if (!doc) return;
        const id = doc.assessmentId;
        this._docDecisions[id] = 'rejected';
        saveDocValidation({ assessmentId: id, comment: doc.comment, validated: false })
            .then(() => {
                this.docs = this.docs.map(d => d.assessmentId !== id ? d : {
                    ...d, validated: false, decision: 'rejected',
                    rowClass: 'vc-doc-card',
                    approveBtnClass: 'vc-btn-pri vc-btn-sm',
                    approveLabel: 'Approve',
                    rejectBtnClass: 'vc-btn-sec vc-btn-sm vc-doc-rejected',
                    rejectLabel: '✗ Rejected'
                });
                this.caseValidatedCount = this.docs.filter(d => d.validated).length;
                this._toast('Rejected', `${doc.label} rejected.`);
            })
            .catch(err => this._toast('Save failed', (err && err.body && err.body.message) || 'Could not save.'));
    }

    // ── Inline document preview (analyst — view only, no remove) ──────────────
    @track _previewDocId = null;
    @track _previewUrl = null;
    @track _previewTitle = '';
    @track _previewIsImage = false;
    @track _publicDocumentUrl = null;  // Public URL for iframe display
    @track _showIframe = false;
    @track _iframeLoading = false;
    get hasPreview() { return !!this._previewUrl; }
    get previewUrl() { return this._previewUrl; }
    get previewTitle() { return this._previewTitle; }
    get previewIsImage() { return this._previewIsImage; }
    get publicDocumentUrl() { return this._publicDocumentUrl; }
    get showIframe() { return this._showIframe; }
    get iframeLoading() { return this._iframeLoading; }
    get selectedDocIsPreviewing() { return !!this._previewDocId && this._previewDocId === this._selectedDocId; }
    handlePreviewDoc(event) {
        const id = event.currentTarget.dataset.id;
        const doc = this.docs.find(d => d.assessmentId === id);
        if (!doc) return;
        // Toggle: clicking the same doc again closes the panel.
        if (this._previewDocId === id && this._previewUrl) {
            this.closePreview();
            return;
        }
        if (!doc.versionId && !doc.docUrl) {
            this._toast('No preview available', 'This document has no previewable file reference.');
            return;
        }
        const imageTypes = ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'svg', 'webp'];
        const ft = (doc.fileType || '').toLowerCase();
        const isImage = imageTypes.includes(ft);
        this._previewIsImage = isImage;
        // Fallback rendition URL (requires session auth — shown only if public URL fails)
        if (doc.versionId) {
            this._previewUrl = isImage
                ? `/sfc/servlet.shepherd/version/renditionDownload?rendition=ORIGINAL_Jpg&versionId=${doc.versionId}`
                : `/sfc/servlet.shepherd/version/renditionDownload?rendition=PDF&versionId=${doc.versionId}`;
        } else {
            this._previewUrl = doc.docUrl;
        }
        this._previewTitle = doc.docTitle || doc.label;
        this._previewDocId = id;
        this.docs = this.docs.map(d => ({ ...d, isPreviewing: d.assessmentId === id }));

        // Generate public document URL for iframe display — works for ALL users
        if (doc.contentDocumentId) {
            this._iframeLoading = true;
            generatePublicDocumentUrl({ contentDocumentId: doc.contentDocumentId })
                .then(publicUrl => {
                    this._publicDocumentUrl = publicUrl;
                    this._showIframe = true;
                    this._iframeLoading = false;
                    // eslint-disable-next-line @lwc/lwc/no-async-operation
                    setTimeout(() => this._setupIframe(), 0);
                })
                .catch(err => {
                    this._iframeLoading = false;
                    console.warn('Failed to generate public URL, using standard preview:', err);
                    this._showIframe = false;
                });
        }
    }

    _setupIframe() {
        if (!this._publicDocumentUrl || !this._showIframe) return;
        const container = this.template.querySelector('[data-preview-container]');
        if (!container) return;
        const existingIframe = container.querySelector('iframe');
        if (existingIframe) existingIframe.remove();
        const iframe = document.createElement('iframe');
        iframe.src = this._publicDocumentUrl;
        iframe.style.width = '100%';
        iframe.style.height = '700px';
        iframe.style.border = '2px solid #ddd';
        iframe.style.borderRadius = '4px';
        iframe.allow = 'fullscreen';
        iframe.onload = () => { this._iframeLoading = false; };
        iframe.onerror = (e) => {
            console.error('Iframe failed to load:', e);
            this._iframeLoading = false;
            this._toast('Preview failed', 'Could not load document preview.');
        };
        container.prepend(iframe);
    }

    closePreview() {
        this._previewDocId = null;
        this._previewUrl = null;
        this._previewTitle = '';
        this._previewIsImage = false;
        this._publicDocumentUrl = null;
        this._showIframe = false;
        this._iframeLoading = false;
        this.docs = this.docs.map(d => ({ ...d, isPreviewing: false }));
    }

    handleCommentInput(event) {
        const id = event.currentTarget.dataset.id;
        const doc = this.docs.find(d => d.assessmentId === id);
        if (doc) doc.comment = event.target.value;
    }

    handleMarkValidated(event) {
        const id = event.currentTarget.dataset.id;
        const doc = this.docs.find(d => d.assessmentId === id);
        if (!doc) return;
        const newValidated = !doc.validated;
        saveDocValidation({ assessmentId: id, comment: doc.comment, validated: newValidated })
            .then(() => {
                doc.validated = newValidated;
                // re-map for class/label changes + recount
                const idx = this.docs.findIndex(d => d.assessmentId === id);
                this.docs = [
                    ...this.docs.slice(0, idx),
                    this._mapDoc({ assessmentId: id, requirementLabel: doc.label, aiStatus: doc.aiStatus,
                        severity: doc.severity, analystComment: doc.comment, analyst_Validated__c: newValidated,
                        validated: newValidated, badgeClass: doc.badgeClass.replace('vc-badge ', '') }),
                    ...this.docs.slice(idx + 1)
                ];
                this.caseValidatedCount = this.docs.filter(d => d.validated).length;
                this._toast(newValidated ? 'Validated' : 'Validation cleared',
                    `${doc.label} ${newValidated ? 'marked validated' : 'set back to pending'}.`);
            })
            .catch(err => this._toast('Save failed', (err && err.body && err.body.message) || 'Could not save.'));
    }

    // Co-pilot generative comment: analyst types a rough observation → polished comment.
    @track _summarizing = false;
    get summarizing() { return this._summarizing; }
    get summarizeDisabled() { return this._summarizing; }

    handleDraftComment(event) {
        const id = event.currentTarget.dataset.id;
        const doc = this.docs.find(d => d.assessmentId === id);
        if (!doc) return;
        const observation = doc.comment || '';
        this._summarizing = true;
        copilotDraftComment({
            accountId: this._caseId,
            requirementLabel: doc.label,
            aiSummary: doc.aiSummary,
            observation
        })
            .then(text => {
                this._summarizing = false;
                this.docs = this.docs.map(d => d.assessmentId !== id ? d : { ...d, comment: text });
                this._toast('Comment drafted', 'Co-pilot polished your observation — edit or save.');
            })
            .catch(err => {
                this._summarizing = false;
                this._toast('Draft failed', (err && err.body && err.body.message) || 'Co-pilot unavailable.');
            });
    }

    // ── A2 tabs ───────────────────────────────────────────────────────────────
    @track activeTab = 'documents';
    get tabDocsClass() { return this.activeTab === 'documents' ? 'vc-tab active' : 'vc-tab'; }
    get tabOverviewClass() { return this.activeTab === 'overview' ? 'vc-tab active' : 'vc-tab'; }
    get isDocsTab() { return this.activeTab === 'documents'; }
    get isOverviewTab() { return this.activeTab === 'overview'; }
    handleTab(event) { this.activeTab = event.currentTarget.dataset.tab; }

    handleTakeToDecision() {
        if (!this._caseId) return;
        this.activeScreen = 'a3';
        this.breadcrumb = BREADCRUMBS.a3;
    }

    // ── A3 — Final Verdict computed state ─────────────────────────────────────
    // Shape the case documents for the shared dashboard (decision + confidence).
    get dashboardDocs() {
        return this.docs.map(d => ({ decision: d.decision || 'pending', confidence: d.confidence }));
    }

    get verdictApproved() { return this.docs.filter(d => d.decision === 'approved').length; }
    get verdictRejected() { return this.docs.filter(d => d.decision === 'rejected').length; }
    get verdictPending()  { return this.docs.filter(d => !d.decision).length; }
    get verdictTotal()    { return this.docs.length; }
    get verdictStatus() {
        if (this.verdictRejected > 0) return 'blocked';
        if (this.verdictPending  > 0) return 'partial';
        return 'ready';
    }
    get verdictCardClass()     { return 'vc-verdict-card vc-verdict-' + this.verdictStatus; }
    get verdictStatusIcon() {
        if (this.verdictStatus === 'blocked') return '✗';
        if (this.verdictStatus === 'partial') return '◑';
        return '✓';
    }
    get verdictReadinessLabel() {
        if (this.verdictStatus === 'blocked') return 'Not ready to route';
        if (this.verdictStatus === 'partial') return 'Partially validated';
        return 'Ready to route';
    }
    get verdictStatusLabel() {
        const r = this.verdictRejected, p = this.verdictPending, t = this.verdictTotal;
        if (r > 0 && p > 0) return `${r} rejected and ${p} pending — resolve before routing`;
        if (r > 0) return `${r} document${r > 1 ? 's' : ''} rejected — review before routing`;
        if (p > 0) return `${p} document${p > 1 ? 's' : ''} still pending validation`;
        return `All ${t} document${t !== 1 ? 's' : ''} validated — ready to route`;
    }
    get verdictReviewedPct() {
        if (!this.docs.length) return '0%';
        return Math.round(((this.verdictApproved + this.verdictRejected) / this.docs.length) * 100) + '%';
    }
    get verdictApprovedBarStyle() { return this.docs.length ? `flex:${this.verdictApproved}` : 'flex:0'; }
    get verdictRejectedBarStyle() { return this.docs.length ? `flex:${this.verdictRejected}` : 'flex:0'; }
    get verdictPendingBarStyle()  { return this.docs.length ? `flex:${this.verdictPending}`  : 'flex:0'; }
    get verdictRejectedDocs()  { return this.docs.filter(d => d.decision === 'rejected'); }
    get verdictPendingDocs()   { return this.docs.filter(d => !d.decision); }
    get hasVerdictRejected()   { return this.verdictRejected > 0; }
    get hasVerdictPending()    { return this.verdictPending  > 0; }
    get hasVerdictIssues()     { return this.verdictRejected > 0 || this.verdictPending > 0; }
    get caseTierBadgeClass()   { return 'vc-badge ' + this._tierBadge(this.caseTier); }
    get confirmedTierBadgeClass() {
        const t = (this.confirmedTier || '').toUpperCase();
        if (t === 'HIGH') return 'vc-badge bad';
        if (t === 'MED')  return 'vc-badge warn';
        if (t === 'LOW')  return 'vc-badge ok';
        return 'vc-badge neutral';
    }

    // ── A3 — decision & route ─────────────────────────────────────────────────
    @track confirmedTier = 'MED';
    @track rationale = '';
    get cardLowSel() { return this.confirmedTier === 'LOW' ? 'vc-tc selected' : 'vc-tc'; }
    get cardMedSel() { return this.confirmedTier === 'MED' ? 'vc-tc selected' : 'vc-tc'; }
    get cardHighSel() { return this.confirmedTier === 'HIGH' ? 'vc-tc selected' : 'vc-tc'; }
    get radioLow() { return this.confirmedTier === 'LOW' ? 'vc-tc-radio checked' : 'vc-tc-radio'; }
    get radioMed() { return this.confirmedTier === 'MED' ? 'vc-tc-radio checked' : 'vc-tc-radio'; }
    get radioHigh() { return this.confirmedTier === 'HIGH' ? 'vc-tc-radio checked' : 'vc-tc-radio'; }
    handleConfirmTier(event) { this.confirmedTier = event.currentTarget.dataset.tier; }
    handleRationaleInput(event) { this.rationale = event.target.value; }

    _uiTier(tier) {
        const t = (tier || '').toLowerCase();
        if (t === 'high' || t === 'critical') return 'HIGH';
        if (t === 'low') return 'LOW';
        return 'MED';
    }
    get routeLabel() {
        if (this.confirmedTier === 'LOW') return 'Auto-approve (analyst notify)';
        if (this.confirmedTier === 'HIGH') return 'Risk Committee (dual sign-off + legal)';
        return 'Sr. Compliance Approver';
    }

    handleRoute() {
        if (!this._caseId) { this._toast('No case', 'Open a supplier first.'); return; }
        saveDecision({ accountId: this._caseId, tier: this.confirmedTier, route: this.routeLabel, rationale: this.rationale })
            .then(() => {
                this._toast('Routed to approver', `${this.caseName} sent to ${this.routeLabel}.`);
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => { this.handleBackToQueue(); this.refreshQueue(); }, 800);
            })
            .catch(err => this._toast('Route failed', (err && err.body && err.body.message) || 'Could not route.'));
    }
    handleSendBack() { this._toast('Sent back', 'Returned to Procurement (recorded).'); }

    // ── Co-pilot (A2/A3 only) — grounded chat ─────────────────────────────────
    @track copilotOpen = false;
    @track copilotMessages = [];
    @track copilotInput = '';
    @track copilotBusy = false;
    get showCopilot() { return (this.activeScreen === 'a2' || this.activeScreen === 'a3') && !!this._caseId; }
    get copilotFabClass() { return this.copilotMessages.length === 0 ? 'vc-cp-fab nudge' : 'vc-cp-fab'; }
    get hasCopilotMessages() { return this.copilotMessages.length > 0; }
    get copilotSendDisabled() { return this.copilotBusy || !this.copilotInput.trim(); }
    toggleCopilot() {
        this.copilotOpen = !this.copilotOpen;
        if (this.copilotOpen && !this._copilotGreeted) {
            this._copilotGreeted = true;
            this._pushMsg('ai', this._copilotGreeting());
        }
    }
    _copilotGreeted = false;
    _copilotGreeting() {
        const who = this.caseName || 'this supplier';
        return `Hi — I'm your VERA co-pilot for **${who}**. I'm grounded in this case's `
            + `validated documents, screening, and the policy clauses behind them. I can `
            + `summarise the findings, flag what needs your judgement, or draft your `
            + `recommendation rationale. What do you need?`;
    }
    closeCopilot() { this.copilotOpen = false; }

    // Analyst-persona suggested actions. `local` ones answer INSTANTLY from
    // already-stored assessment data (no engine callout → no 504).
    get copilotSuggestions() {
        return [
            { id: 'a1', text: 'Which findings need my judgement?', local: true, action: 'judgement' },
            { id: 'a2', text: 'Show the key fields from the documents', local: true, action: 'fields' },
            { id: 'a3', text: 'Summarise the non-compliant documents', local: true, action: 'noncompliant' },
            { id: 'a4', text: 'Draft my recommendation rationale', local: false }
        ];
    }
    get showCopilotSuggestions() { return true; }
    handleSuggestion(event) {
        const text = event.currentTarget.dataset.text;
        const local = event.currentTarget.dataset.local === 'true';
        const action = event.currentTarget.dataset.action;
        if (!text) return;
        if (local) {
            this._pushMsg('you', text);
            this._pushMsg('ai', this._localAnswer(action));
            return;
        }
        this.copilotInput = text;
        this.handleCopilotSend();
    }
    _localAnswer(action) {
        if (action === 'fields')       return this._answerFields();
        if (action === 'judgement')    return this._answerJudgement();
        if (action === 'noncompliant') return this._answerNonCompliant();
        return 'I can answer that from this case — ask me anything specific.';
    }
    _answerFields() {
        const rows = (this.docs || []).filter(a => a.hasFacts || a.hasChecks);
        if (!rows.length) return 'No documents have been AI-assessed yet.';
        const out = ['Here are the **key fields** the AI extracted, by document:'];
        rows.forEach(a => {
            out.push(`\n**${a.label}** — ${a.aiStatus}`);
            (a.facts || []).forEach(f => out.push(`- ${f.text}`));
            (a.checks || []).forEach(k => out.push(`- ${k.pass ? '✓' : '✕'} ${k.text}`));
        });
        return out.join('\n');
    }
    _answerJudgement() {
        const need = (this.docs || []).filter(a =>
            ['non-compliant', 'needs analyst'].includes((a.aiStatus || '').toLowerCase()) && !a.validated);
        if (!need.length) return 'Nothing is waiting on your judgement — all documents are AI-cleared or already validated.';
        return ['These documents **need your judgement**:',
            ...need.map(a => `- ${a.label} — ${a.aiStatus}`)].join('\n');
    }
    _answerNonCompliant() {
        const bad = (this.docs || []).filter(a => (a.aiStatus || '').toLowerCase() === 'non-compliant');
        if (!bad.length) return 'No documents are Non-Compliant.';
        const out = ['**Non-compliant documents:**'];
        bad.forEach(a => {
            out.push(`\n**${a.label}**`);
            (a.concerns || []).forEach(c => out.push(`- ⚠ ${c.text}`));
            (a.checks || []).filter(k => !k.pass).forEach(k => out.push(`- ✕ ${k.text}`));
        });
        return out.join('\n');
    }
    handleCopilotInput(event) { this.copilotInput = event.target.value; }
    handleCopilotKey(event) { if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); this.handleCopilotSend(); } }
    _pushMsg(who, text) {
        this.copilotMessages = [...this.copilotMessages, {
            id: 'm' + this.copilotMessages.length, who, text,
            blocks: this._formatMessage(text),
            rowClass: who === 'you' ? 'vc-cp-msg you' : 'vc-cp-msg ai'
        }];
    }
    _formatMessage(text) {
        const lines = String(text || '').split(/\r?\n/);
        const blocks = []; let k = 0;
        for (const raw of lines) {
            const line = raw.trim();
            if (!line) continue;
            const bullet = /^[-*•]\s+/.test(line) || /^\d+[.)]\s+/.test(line);
            const content = line.replace(/^[-*•]\s+/, '').replace(/^\d+[.)]\s+/, '');
            blocks.push({ id: 'b' + (k++), isBullet: bullet,
                blockClass: bullet ? 'vc-cp-line bullet' : 'vc-cp-line', runs: this._boldRuns(content) });
        }
        return blocks.length ? blocks
            : [{ id: 'b0', isBullet: false, blockClass: 'vc-cp-line', runs: this._boldRuns(text) }];
    }
    _boldRuns(s) {
        const parts = String(s || '').split(/(\*\*[^*]+\*\*)/g);
        return parts.filter(p => p !== '').map((p, i) => {
            const bold = /^\*\*[^*]+\*\*$/.test(p);
            return { id: 'r' + i, bold, text: bold ? p.slice(2, -2) : p };
        });
    }
    handleCopilotSend() {
        const q = this.copilotInput.trim();
        if (!q || !this._caseId) return;
        this._pushMsg('you', q);
        this.copilotInput = '';
        this.copilotBusy = true;
        askCopilot({ accountId: this._caseId, question: q })
            .then(res => {
                this.copilotBusy = false;
                this._pushMsg('ai', (res && (res.answer || res.response)) || 'No answer returned.');
            })
            .catch(err => {
                this.copilotBusy = false;
                this._pushMsg('ai', 'Co-pilot error: ' + ((err && err.body && err.body.message) || 'request failed.'));
            });
    }

    // ── Inline notice ─────────────────────────────────────────────────────────
    _toast(title, message) {
        this._notice = { title, message };
        this._showNotice = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this._showNotice = false; }, 2600);
    }
    @track _showNotice = false;
    @track _notice = { title: '', message: '' };
    get showNotice() { return this._showNotice; }
    get noticeTitle() { return this._notice.title; }
    get noticeMessage() { return this._notice.message; }
}