import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import complianceLogo from '@salesforce/resourceUrl/complianceLogo';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import userId from '@salesforce/user/Id';
import FIRSTNAME_FIELD  from '@salesforce/schema/User.FirstName';
import LASTNAME_FIELD   from '@salesforce/schema/User.LastName';
import ACCOUNT_FIELD    from '@salesforce/schema/User.AccountId';
import getSupplierSnapshot     from '@salesforce/apex/VendorPortalController.getSupplierSnapshot';
import resolveSupplierToken    from '@salesforce/apex/VendorPortalController.resolveSupplierToken';
import removeSupplierDocument  from '@salesforce/apex/VendorPortalController.removeSupplierDocument';
import addRequirementFromDocument from '@salesforce/apex/VendorPortalController.addRequirementFromDocument';
import saveFile                from '@salesforce/apex/DocumentProcessingController.saveFile';
import linkDocumentToCompliance from '@salesforce/apex/DocumentProcessingController.linkDocumentToCompliance';
import generatePublicDocumentUrl from '@salesforce/apex/VendorPortalController.generatePublicDocumentUrl';
import getSubSuppliers            from '@salesforce/apex/SubSupplierController.getSubSuppliers';
import inviteSubSupplier          from '@salesforce/apex/SubSupplierController.inviteSubSupplier';
import getRequirementsForParent   from '@salesforce/apex/SubSupplierController.getRequirementsForParent';

const BREADCRUMBS = {
    sp3: '/Compliance summary',
    sp4: '/My sub-suppliers'
};

export default class ScSupplierPortal extends NavigationMixin(LightningElement) {

    logoUrl = complianceLogo;

    // ── Logged-in user + their Account ───────────────────────────────────────
    _userInitials = '??';
    _userName = '';
    _accountId = null;
    _tokenResolved = false;   // true once token path has run (prevents double-load)
    @track _showUserMenu = false;

    // Read ?token= from the URL — works for both authenticated and guest pages.
    @wire(CurrentPageReference)
    wiredPageRef(ref) {
        if (!ref || !ref.state) return;
        const token = ref.state.token;
        if (!token || this._tokenResolved) return;
        this._tokenResolved = true;
        resolveSupplierToken({ token })
            .then(accountId => {
                if (accountId && accountId !== this._accountId) {
                    this._accountId = accountId;
                    this._loadSnapshot();
                }
            })
            .catch(err => {
                this._toast('error', 'Invalid link',
                    (err && err.body && err.body.message) || 'This portal link is invalid or has expired.');
            });
    }

    @wire(getRecord, { recordId: userId, fields: [FIRSTNAME_FIELD, LASTNAME_FIELD, ACCOUNT_FIELD] })
    wiredUser({ data, error }) {
        if (data) {
            const first = getFieldValue(data, FIRSTNAME_FIELD) || '';
            const last  = getFieldValue(data, LASTNAME_FIELD)  || '';
            this._userInitials = (first.charAt(0) + last.charAt(0)).toUpperCase() || '??';
            this._userName = `${first} ${last}`.trim();
            // Only use AccountId from the logged-in user if the URL token
            // hasn't already resolved an account (token takes precedence).
            if (!this._tokenResolved) {
                const acctId = getFieldValue(data, ACCOUNT_FIELD);
                if (acctId && acctId !== this._accountId) {
                    this._accountId = acctId;
                    this._loadSnapshot();
                }
            }
        } else if (error) {
            // eslint-disable-next-line no-console
            console.error('[SupplierPortal] Could not load user:', error);
        }
    }

    get userInitials() { return this._userInitials; }
    get userName()     { return this._userName; }
    get showUserMenu() { return this._showUserMenu; }

    connectedCallback() {
        this._boundDocClick = (evt) => {
            if (!this._showUserMenu) return;
            if (!evt.composedPath().includes(this.template.host)) {
                this._showUserMenu = false;
            }
        };
        document.addEventListener('click', this._boundDocClick);
    }

    disconnectedCallback() {
        document.removeEventListener('click', this._boundDocClick);
        this._stopAssessPoll();
    }

    handleAvatarClick() { this._showUserMenu = !this._showUserMenu; }

    handleLogout() {
        this._showUserMenu = false;
        this[NavigationMixin.Navigate]({
            type: 'comm__loginPage',
            attributes: { actionName: 'logout' }
        });
    }

    // ── Active screen ─────────────────────────────────────────────────────────
    @track activeScreen = 'sp3';
    @track breadcrumb   = BREADCRUMBS.sp3;

    get isSp2() { return false; }
    get isSp3() { return this.activeScreen === 'sp3'; }
    get isSp4() { return this.activeScreen === 'sp4'; }

    get sbSp3Active() { return this.activeScreen === 'sp3' ? 'vc-sb-item active' : 'vc-sb-item'; }
    get sbSp4Active() { return this.activeScreen === 'sp4' ? 'vc-sb-item active' : 'vc-sb-item'; }
    get dotSp3() { return this.activeScreen === 'sp3' ? 'vc-sb-dot curr' : 'vc-sb-dot'; }
    get dotSp4() { return this.activeScreen === 'sp4' ? 'vc-sb-dot curr' : 'vc-sb-dot'; }

    handleNav(event) {
        const screen = event.currentTarget.dataset.screen;
        if (!BREADCRUMBS[screen]) return;
        this.activeScreen = screen;
        this.breadcrumb   = BREADCRUMBS[screen];
        if (screen === 'sp4') this._loadSubSuppliers();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const main = this.template.querySelector('.vc-main');
            if (main) main.scrollTop = 0;
        }, 0);
    }

    handleGoToSummary() {
        this.activeScreen = 'sp3';
        this.breadcrumb   = BREADCRUMBS.sp3;
    }

    // ── Sub-supplier invite modal ─────────────────────────────────────────────
    @track showInviteModal     = false;
    @track inviteSending       = false;
    @track inviteError         = null;
    @track requirements        = [];
    @track requirementsLoading = false;
    @track _inviteForm = {
        company: '', firstName: '', lastName: '',
        email: '', phone: '', category: '',
        country: '', tier: 'Tier 2', message: '', expiry: '14'
    };

    get inviteFormValid() {
        const f = this._inviteForm;
        return f.company && f.firstName && f.email && f.category && f.country && f.tier;
    }
    get hasRequirements()      { return this.requirements.length > 0; }
    get selectedRequirements() { return this.requirements.filter(r => r.checked); }
    get selectedCount()        { return this.selectedRequirements.length; }
    get hasSelectedRequirements() { return this.selectedCount > 0; }

    handleOpenInvite() {
        this.showInviteModal = true;
        this.inviteError     = null;
        this._loadRequirements();
    }

    handleCloseInvite() {
        this.showInviteModal = false;
        this.inviteSending   = false;
        this.inviteError     = null;
        this.requirements    = [];
        this._inviteForm = {
            company: '', firstName: '', lastName: '',
            email: '', phone: '', category: '',
            country: '', tier: 'Tier 2', message: '', expiry: '14'
        };
    }

    handleInviteField(event) {
        const field = event.target.dataset.field;
        this._inviteForm = { ...this._inviteForm, [field]: event.target.value };
    }

    handleInviteExpiry(event) {
        this._inviteForm = { ...this._inviteForm, expiry: event.currentTarget.dataset.expiry };
    }

    handleRequirementToggle(event) {
        const id = event.target.dataset.id;
        this.requirements = this.requirements.map(r =>
            r.id === id ? { ...r, checked: event.target.checked } : r
        );
    }

    _loadRequirements() {
        if (!this._accountId) return;
        this.requirementsLoading = true;
        getRequirementsForParent({ parentAccountId: this._accountId })
            .then(rows => {
                this.requirementsLoading = false;
                this.requirements = (rows || []).map(r => ({ ...r, checked: false }));
            })
            .catch(() => { this.requirementsLoading = false; });
    }

    handleInviteSend() {
        if (!this.inviteFormValid) {
            this.inviteError = 'Please fill in all required fields.';
            return;
        }
        this.inviteSending = true;
        this.inviteError   = null;
        const f = this._inviteForm;
        const selectedIds = this.selectedRequirements.map(r => r.id).join(',');
        inviteSubSupplier({
            parentAccountId:        this._accountId,
            company:                f.company,
            firstName:              f.firstName,
            lastName:               f.lastName,
            email:                  f.email,
            phone:                  f.phone,
            category:               f.category,
            country:                f.country,
            tier:                   f.tier,
            message:                f.message,
            expiryDays:             f.expiry || '14',
            selectedRequirementIds: selectedIds
        })
            .then(result => {
                this.inviteSending = false;
                this._toast('success', 'Invitation sent',
                    `${f.company} has been registered${result.userCreated ? ' with portal access' : ''}.`
                    + ` Invite email sent to ${f.email}.`);
                this.handleCloseInvite();
                this._loadSubSuppliers();
            })
            .catch(err => {
                this.inviteSending = false;
                this.inviteError = (err && err.body && err.body.message)
                    || 'Failed to send invitation. Please try again.';
            });
    }

    // Expose form + expiry options to template
    get inviteForm() { return this._inviteForm; }
    get inviteExpiryOptions() {
        return [
            { value: '7',  label: '7 days'  },
            { value: '14', label: '14 days' },
            { value: '30', label: '30 days' }
        ].map(o => ({
            ...o,
            selected: this._inviteForm.expiry === o.value,
            cls: this._inviteForm.expiry === o.value ? 'vc-expiry-chip selected' : 'vc-expiry-chip'
        }));
    }
    get inviteBtnStyle() {
        return this.inviteFormValid ? 'opacity:1' : 'opacity:0.5';
    }
    get inviteTierOptions() {
        return ['Tier 2', 'Tier 3'].map(t => ({ value: t, label: t, selected: this._inviteForm.tier === t }));
    }

    // ── SP4 — sub-supplier directory ─────────────────────────────────────────
    @track subSuppliers        = [];
    @track subSuppliersLoading = false;

    get hasSubSuppliers() { return this.subSuppliers.length > 0; }

    get sp4Stats() {
        const rows    = this.subSuppliers;
        const total   = rows.length;
        const active  = rows.filter(r => r.status === 'Approved').length;
        const pending = rows.filter(r =>
            ['Draft', 'Screening', 'In Review'].includes(r.status)).length;
        const docs    = rows.reduce((s, r) => s + (r.docCount || 0), 0);
        return { total, active, pending, docs };
    }

    _loadSubSuppliers() {
        if (!this._accountId) return;
        this.subSuppliersLoading = true;
        getSubSuppliers({ parentAccountId: this._accountId })
            .then(rows => {
                this.subSuppliersLoading = false;
                this.subSuppliers = (rows || []).map((r, i) => ({
                    ...r,
                    rowId: 'ss' + i
                }));
            })
            .catch(() => {
                this.subSuppliersLoading = false;
            });
    }

    // ── Supplier snapshot ─────────────────────────────────────────────────────
    @track snapshotLoading = false;
    @track snapName    = '';
    @track snapTier    = '';
    @track snapStatus  = '';
    @track snapDomains = [];
    @track storedDocs  = [];
    @track complianceRows = [];
    @track rejectedDocs   = [];
    _expandedRows = new Set();

    get storedDocsCount() { return this.storedDocs.length; }
    get hasStoredDocs() { return this.storedDocs.length > 0; }
    get hasComplianceRows() { return this.complianceRows.length > 0; }
    get hasRejectedDocs() { return this.rejectedDocs.length > 0; }
    get checklistProgressLabel() {
        const done = this.complianceRows.filter(r => r.ticked).length;
        return `${done}/${this.complianceRows.length} uploaded`;
    }

    get oversightLabel() {
        const t = (this.snapTier || '').toLowerCase();
        if (t === 'high' || t === 'critical') return 'Full analyst review';
        if (t === 'medium') return 'Partial review';
        return 'Auto-clear eligible';
    }

    _loadSnapshot() {
        if (!this._accountId) return;
        this.snapshotLoading = true;
        getSupplierSnapshot({ accountId: this._accountId })
            .then(s => {
                this.snapshotLoading = false;
                this.snapName   = s.name || '';
                this.snapTier   = s.riskTier || '';
                this.snapStatus = s.onboardingStatus || '';
                this.snapDomains = (s.domains || []).map((d, i) => ({ id: 'sd' + i, label: d }));

                const docAssessments = (s.assessments || []).filter(
                    x => !((x.requirementLabel || '').startsWith('Screening — '))
                );
                this.storedDocs = (s.documents || []).map((d, i) => {
                    let complianceStatus = d.status || 'Pending';
                    let complianceBadgeClass = 'vc-badge ' + (d.badgeClass || 'neutral');
                    if (!d.status) {
                        const titleKey = (d.title || '').toLowerCase()
                            .replace(/\.[^.]+$/, '').replace(/[\s_-]+/g, '');
                        const match = docAssessments.find(a => {
                            const labelKey = (a.requirementLabel || '').toLowerCase()
                                .replace(/[\s_-]+/g, '');
                            return titleKey && labelKey &&
                                (titleKey.includes(labelKey) || labelKey.includes(titleKey));
                        });
                        if (match) {
                            complianceStatus = match.status;
                            complianceBadgeClass = 'vc-badge ' + (match.badgeClass || 'neutral');
                        }
                    }
                    return {
                        id: 'doc' + i,
                        title: d.title,
                        fileType: (d.fileType || '').toLowerCase(),
                        meta: `${d.fileType || ''} · ${d.createdLabel || ''}`,
                        versionId: d.versionId,
                        contentDocumentId: d.contentDocumentId,
                        isPreviewing: false,
                        complianceStatus,
                        complianceBadgeClass
                    };
                });

                this._previewUrl = null;
                this._previewTitle = '';

                const all = (s.assessments || []);
                const reqRows = all.filter(x =>
                    !(x.requirementLabel || '').startsWith('Screening — ') &&
                    !(x.requirementLabel || '').includes('Manual verification'));
                this.complianceRows = reqRows.map((x, i) => this._buildComplianceRow(x, i));

                const matchedKeys = new Set(
                    this.complianceRows.filter(r => r.hasFile).map(r => this._fileKey(r.fileName)));
                this.rejectedDocs = this.storedDocs
                    .filter(d => {
                        const k = this._fileKey(d.title);
                        return k && !matchedKeys.has(k);
                    })
                    .map((d, i) => ({
                        id: 'rj' + i,
                        requirementKey: null,
                        title: d.title,
                        reason: 'Uploaded but not matched to any checklist requirement — add it if relevant.',
                        promoting: false
                    }));
            })
            .catch(err => {
                this.snapshotLoading = false;
                this._toast('error', 'Could not load your submission',
                    (err && err.body && err.body.message) || 'Snapshot failed.');
            });
    }

    // ── Compliance row builder (mirrors procurement P3) ───────────────────────
    _buildComplianceRow(x, i) {
        const ticked = x.uploaded === true;
        const parsed = this._parseSummary(x.reason);
        const titleKey = (x.documentTitle || '').toLowerCase()
            .replace(/\.[^.]+$/, '').replace(/[\s_-]+/g, '');
        const file = titleKey ? this.storedDocs.find(d => {
            const k = (d.title || '').toLowerCase().replace(/\.[^.]+$/, '').replace(/[\s_-]+/g, '');
            return k && (k.includes(titleKey) || titleKey.includes(k));
        }) : null;
        const expanded = this._expandedRows.has(x.requirementLabel);
        const hasDetail = !!(parsed.headline || parsed.facts.length || parsed.checks.length || parsed.concerns.length);
        return {
            id: 'cr' + i,
            key: x.requirementLabel,
            label: x.requirementLabel,
            ticked,
            boxClass: ticked ? 'vc-chk ticked' : 'vc-chk',
            rowClass: ticked ? 'vc-cdoc-row done' : 'vc-cdoc-row',
            statusText: ticked ? 'Uploaded' : 'Awaiting upload',
            verdict: x.uploaded ? (x.status || 'Pending') : '',
            verdictBadgeClass: 'vc-badge ' + (x.badgeClass || 'neutral'),
            hasVerdict: x.uploaded === true,
            confidence: (x.aiConfidence == null) ? null : x.aiConfidence,
            confidenceLabel: (x.aiConfidence == null) ? '' : x.aiConfidence + '% confidence',
            hasConfidence: x.aiConfidence != null,
            headline: parsed.headline,
            hasHeadline: !!parsed.headline,
            facts: parsed.facts.map((t, j) => ({ id: 'cf' + i + '_' + j, text: t })),
            hasFacts: parsed.facts.length > 0,
            checks: parsed.checks.map((k, j) => ({
                id: 'cc' + i + '_' + j, text: k.text, pass: k.pass,
                chkClass: k.pass ? 'vc-chkline pass' : 'vc-chkline fail'
            })),
            hasChecks: parsed.checks.length > 0,
            concerns: parsed.concerns.map((t, j) => ({ id: 'co' + i + '_' + j, text: t })),
            hasConcerns: parsed.concerns.length > 0,
            hasDetail,
            expanded,
            toggleLabel: expanded ? 'Hide AI detail ▴' : 'Show AI detail ▾',
            fileId: file ? file.id : '',
            contentDocumentId: file ? file.contentDocumentId : '',
            hasFile: !!file,
            fileName: file ? file.title : (x.documentTitle || ''),
            hasFileName: !!(file ? file.title : x.documentTitle)
        };
    }

    _fileKey(name) {
        return (name || '').toLowerCase().replace(/\.[^.]+$/, '').replace(/[\s_-]+/g, '');
    }

    _parseSummary(reason) {
        const out = { headline: '', facts: [], concerns: [], checks: [] };
        if (!reason) return out;
        const lines = String(reason).split(/\r?\n/).map(l => l.trim()).filter(Boolean);
        let inChecks = false;
        for (const line of lines) {
            if (/^clause checks:/i.test(line))    { inChecks = true;  continue; }
            if (/^concerns:/i.test(line))          { inChecks = false; continue; }
            if (/^policy citations:/i.test(line))  { inChecks = false; continue; }
            if (line.startsWith('•')) { out.facts.push(line.replace(/^•\s*/, '')); continue; }
            if (line.startsWith('⚠')) { out.concerns.push(line.replace(/^⚠\s*/, '')); continue; }
            const m = line.match(/^\[(PASS|FAIL)\]\s*(.*)$/i);
            if (m) { out.checks.push({ pass: /pass/i.test(m[1]), text: m[2] }); continue; }
            if (inChecks) { out.checks.push({ pass: !/fail/i.test(line), text: line }); continue; }
            if (!out.headline) {
                out.headline = line.replace(/^\[[^\]]*\]\s*/, '');
            } else if (/^(extracted|expiry|registry)\b/i.test(line)) {
                out.facts.push(line.replace(/^[A-Za-z]+\s·\s*/, ''));
            }
        }
        return out;
    }

    // ── Toggle AI detail row ──────────────────────────────────────────────────
    handleToggleDetail(event) {
        const key = event.currentTarget.dataset.key;
        if (!key) return;
        if (this._expandedRows.has(key)) this._expandedRows.delete(key);
        else this._expandedRows.add(key);
        this.complianceRows = this.complianceRows.map(r =>
            r.key === key
                ? { ...r, expanded: !r.expanded,
                    toggleLabel: !r.expanded ? 'Hide AI detail ▴' : 'Show AI detail ▾' }
                : r);
    }

    // ── Promote rejected doc to checklist ─────────────────────────────────────
    handlePromoteRejected(event) {
        const id = event.currentTarget.dataset.id;
        const rej = this.rejectedDocs.find(r => r.id === id);
        if (!rej || !this._accountId) return;
        this.rejectedDocs = this.rejectedDocs.map(r =>
            r.id === id ? { ...r, promoting: true } : r);
        addRequirementFromDocument({
            accountId: this._accountId,
            documentTitle: rej.title,
            requirementKey: rej.requirementKey
        })
            .then(() => {
                this._toast('success', 'Added to checklist',
                    `"${rej.title}" is now a tracked requirement.`);
                this._loadSnapshot();
            })
            .catch(err => {
                this.rejectedDocs = this.rejectedDocs.map(r =>
                    r.id === id ? { ...r, promoting: false } : r);
                this._toast('error', 'Could not add',
                    (err && err.body && err.body.message) || 'Failed to add the document.');
            });
    }

    // ── Document preview ──────────────────────────────────────────────────────
    @track _previewUrl    = null;
    @track _previewTitle  = '';
    @track _previewIsImage = false;
    @track _previewDocId  = '';
    @track _publicDocumentUrl = null;  // Public URL for iframe display
    @track _showIframe = false;
    @track _iframeLoading = false;

    get hasPreview()    { return !!this._previewUrl; }
    get previewUrl()    { return this._previewUrl; }
    get previewTitle()  { return this._previewTitle; }
    get previewIsImage(){ return this._previewIsImage; }
    get publicDocumentUrl() { return this._publicDocumentUrl; }
    get showIframe() { return this._showIframe; }
    get iframeLoading() { return this._iframeLoading; }

    handlePreviewDoc(event) {
        const id = event.currentTarget.dataset.id;
        const doc = this.storedDocs.find(d => d.id === id);
        if (!doc) return;
        if (this._previewDocId === id && this._previewUrl) { this.closePreview(); return; }
        if (!doc.versionId) {
            this._toast('warning', 'No preview available', 'This document has no previewable file reference.');
            return;
        }
        const imageTypes = ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'svg', 'webp'];
        const pdfRenderable = ['pdf', 'doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx','txt'];
        const ft = (doc.fileType || '').toLowerCase();
        this._previewIsImage = imageTypes.includes(ft);
        if (this._previewIsImage) {
            this._previewUrl = `/sfc/servlet.shepherd/version/renditionDownload?rendition=ORIGINAL_Jpg&versionId=${doc.versionId}`;
        } else if (pdfRenderable.includes(ft)) {
            this._previewUrl = `/sfc/servlet.shepherd/version/renditionDownload?rendition=PDF&versionId=${doc.versionId}`;
        } else {
            this._previewUrl = `/sfc/servlet.shepherd/version/renditionDownload?rendition=PDF&versionId=${doc.versionId}`;
            // this._previewUrl = `/sfc/servlet.shepherd/version/download/${doc.versionId}`;
        }
        this._previewTitle = doc.title;
        this._previewDocId = id;
        this.storedDocs = this.storedDocs.map(d => ({ ...d, isPreviewing: d.id === id }));
        
        // Generate public document URL for iframe display
        if (doc.contentDocumentId) {
            this._iframeLoading = true;
            generatePublicDocumentUrl({ contentDocumentId: doc.contentDocumentId })
                .then(publicUrl => {
                    this._publicDocumentUrl = publicUrl;
                    this._showIframe = true;
                    this._iframeLoading = false;
                    console.log('Public document URL generated:', publicUrl);
                    // Optionally inject iframe directly into DOM after component renders
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
    
    // Create and inject iframe with public document URL
    _setupIframe() {
        if (!this._publicDocumentUrl || !this._showIframe) return;
        
        // Find the preview container element
        const container = this.template.querySelector('[data-preview-container]');
        if (!container) return;
        
        // Clear existing iframe if any
        const existingIframe = container.querySelector('iframe');
        if (existingIframe) {
            existingIframe.remove();
        }
        
        // Create new iframe with public URL
        const iframe = document.createElement('iframe');
        iframe.src = this._publicDocumentUrl;
        iframe.style.width = '100%';
        iframe.style.height = '460px';
        iframe.style.border = '2px solid #ddd';
        iframe.style.borderRadius = '4px';
        iframe.allow = 'fullscreen';
        
        iframe.onload = () => {
            console.log('Iframe loaded successfully');
            this._iframeLoading = false;
        };
        iframe.onerror = (e) => {
            console.error('Iframe failed to load:', e);
            this._iframeLoading = false;
            this._toast('error', 'Preview failed', 'Could not load document preview in iframe.');
        };
        
        container.prepend(iframe);
    }

    closePreview() {
        this._previewUrl = null;
        this._previewTitle = '';
        this._previewIsImage = false;
        this._previewDocId = '';
        this._publicDocumentUrl = null;
        this._showIframe = false;
        this._iframeLoading = false;
        this.storedDocs = this.storedDocs.map(d => ({ ...d, isPreviewing: false }));
    }

    // ── Document remove ───────────────────────────────────────────────────────
    handleRemoveDoc(event) {
        const id = event.currentTarget.dataset.id;
        const doc = this.storedDocs.find(d => d.id === id);
        if (!doc || !doc.contentDocumentId) {
            this._toast('warning', 'Cannot remove', 'This document has no removable file reference.');
            return;
        }
        removeSupplierDocument({ accountId: this._accountId, contentDocumentId: doc.contentDocumentId })
            .then(() => {
                if (this._previewDocId === id) this.closePreview();
                this._toast('success', 'Document removed', `${doc.title} was removed.`);
                this._loadSnapshot();
            })
            .catch(err => this._toast('error', 'Remove failed',
                (err && err.body && err.body.message) || 'Could not remove the document.'));
    }

    // ── File upload ───────────────────────────────────────────────────────────
    @track uploadedDocs = [];
    get hasUploadedDocs() { return this.uploadedDocs.length > 0; }

    handleAddFiles() {
        const picker = this.template.querySelector('.vc-file-input');
        if (picker) picker.click();
    }

    handleFilesPicked(event) {
        const files = Array.from(event.target.files || []);
        if (!files.length) return;
        if (!this._accountId) {
            this._toast('warning', 'Not ready', 'Your supplier account could not be identified.');
            return;
        }
        files.forEach(f => this._uploadOne(f));
        event.target.value = '';
    }

    _uploadOne(file) {
        const tempId = 'u' + Date.now() + Math.floor(Math.random() * 1000);
        this.uploadedDocs = [...this.uploadedDocs, {
            id: tempId,
            name: file.name,
            sizeLabel: `${Math.max(1, Math.round(file.size / 1024))} KB`,
            status: 'Uploading…'
        }];
        const reader = new FileReader();
        reader.onload = () => {
            const base64 = (reader.result || '').toString().split(',')[1];
            saveFile({ recordId: this._accountId, fileName: file.name, base64Data: base64 })
                .then(contentDocumentId =>
                    linkDocumentToCompliance({
                        accountId: this._accountId,
                        contentDocumentId,
                        documentType: file.name,
                        assessmentId: null,
                        fileName: file.name
                    })
                )
                .then(() => {
                    this._setUploadStatus(tempId, 'Uploaded · AI assessing');
                    this._toast('success', 'Uploaded', `${file.name} stored and queued for AI assessment.`);
                    this._loadSnapshot();
                    this._pollForAssessment();
                })
                .catch(err => {
                    this._setUploadStatus(tempId, 'Failed');
                    this._toast('error', 'Upload failed',
                        (err && err.body && err.body.message) || `Could not upload ${file.name}.`);
                });
        };
        reader.onerror = () => {
            this._setUploadStatus(tempId, 'Failed');
            this._toast('error', 'Read failed', `Could not read ${file.name}.`);
        };
        reader.readAsDataURL(file);
    }

    _setUploadStatus(id, status) {
        const i = this.uploadedDocs.findIndex(d => d.id === id);
        if (i >= 0) {
            const copy = [...this.uploadedDocs];
            copy[i] = { ...copy[i], status };
            this.uploadedDocs = copy;
        }
    }

    _pendingUploaded() {
        return (this.complianceRows || []).filter(
            r => r.uploaded && (!r.verdict || r.verdict === 'Pending')).length;
    }

    _pollForAssessment() {
        if (this._assessPoll) return;
        let tries = 0;
        const MAX = 8;
        const baseline = this._pendingUploaded();
        this._assessPoll = setInterval(() => {
            tries++;
            this._loadSnapshot();
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                const stillPending = this._pendingUploaded();
                if (stillPending < baseline || stillPending === 0 || tries >= MAX
                    || this.activeScreen !== 'sp3') {
                    this._stopAssessPoll();
                }
            }, 400);
        }, 3000);
    }

    _stopAssessPoll() {
        if (this._assessPoll) { clearInterval(this._assessPoll); this._assessPoll = null; }
    }

    // ── SP3 dashboard data ────────────────────────────────────────────────────
    get docOnlyAssessments() {
        return (this.complianceRows || []).filter(r => r.hasVerdict);
    }

    get dashboardDocs() {
        return this.docOnlyAssessments.map(a => ({
            decision: this._statusToDecision(a.verdict),
            confidence: a.confidence
        }));
    }

    _statusToDecision(status) {
        const s = (status || '').toLowerCase();
        if (s === 'compliant')     return 'approved';
        if (s === 'non-compliant') return 'rejected';
        return 'pending';
    }

    // ── Toast (inline notice, matches procurement pattern) ────────────────────
    _toast(variant, title, message) {
        // eslint-disable-next-line no-console
        console.info(`[SupplierPortal] ${variant}: ${title} — ${message}`);
        this._notice = { title, message, variant };
        this._showNotice = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this._showNotice = false; }, 2600);
    }

    @track _showNotice = false;
    @track _notice = { title: '', message: '', variant: 'info' };
    get showNotice()    { return this._showNotice; }
    get noticeTitle()   { return this._notice.title; }
    get noticeMessage() { return this._notice.message; }
    get noticeClass()   {
        const v = this._notice.variant || 'info';
        return `vc-notice ${v}`;
    }
}