import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import complianceLogo from '@salesforce/resourceUrl/complianceLogo';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import userId from '@salesforce/user/Id';
import FIRSTNAME_FIELD  from '@salesforce/schema/User.FirstName';
import LASTNAME_FIELD   from '@salesforce/schema/User.LastName';
import ACCOUNT_FIELD    from '@salesforce/schema/User.AccountId';
import getSupplierSnapshot     from '@salesforce/apex/VendorPortalController.getSupplierSnapshot';
import getSupplierSnapshotByToken from '@salesforce/apex/VendorPortalController.getSupplierSnapshotByToken';
import resolveSupplierToken    from '@salesforce/apex/VendorPortalController.resolveSupplierToken';
import removeSupplierDocument  from '@salesforce/apex/VendorPortalController.removeSupplierDocument';
import removeSupplierDocumentByToken from '@salesforce/apex/VendorPortalController.removeSupplierDocumentByToken';
import saveFile                from '@salesforce/apex/DocumentProcessingController.saveFile';
import saveFileByToken         from '@salesforce/apex/DocumentProcessingController.saveFileByToken';
import linkDocumentToCompliance from '@salesforce/apex/DocumentProcessingController.linkDocumentToCompliance';
import linkDocumentToComplianceByToken from '@salesforce/apex/DocumentProcessingController.linkDocumentToComplianceByToken';
import generatePublicDocumentUrl from '@salesforce/apex/VendorPortalController.generatePublicDocumentUrl';
import generatePublicDocumentUrlByToken from '@salesforce/apex/VendorPortalController.generatePublicDocumentUrlByToken';
import getSubSuppliers            from '@salesforce/apex/SubSupplierController.getSubSuppliers';
import getSubSuppliersByToken     from '@salesforce/apex/SubSupplierController.getSubSuppliersByToken';
import inviteSubSupplier          from '@salesforce/apex/SubSupplierController.inviteSubSupplier';
import inviteSubSupplierByToken   from '@salesforce/apex/SubSupplierController.inviteSubSupplierByToken';
import getRequirementsForParent   from '@salesforce/apex/SubSupplierController.getRequirementsForParent';
import getRequirementsForParentByToken from '@salesforce/apex/SubSupplierController.getRequirementsForParentByToken';
import addSupplierComment         from '@salesforce/apex/VendorPortalController.addSupplierComment';
import addSupplierCommentByToken  from '@salesforce/apex/VendorPortalController.addSupplierCommentByToken';

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
    // Guest visitors have no authenticated Salesforce session — a portal
    // token IS their credential. _portalToken is kept (not just the resolved
    // accountId) so every later Apex call can re-verify it server-side on
    // every request instead of trusting a client-held accountId — see
    // VendorPortalController.verifyPortalTokenId for why that re-check
    // matters. Logged-in Experience Cloud users (the ACCOUNT_FIELD path
    // below) have a real Salesforce session as their authorization instead,
    // so they keep using the plain (non-token) Apex methods.
    _portalToken = null;
    @track _showUserMenu = false;

    // Read ?token= from the URL — works for both authenticated and guest pages.
    @wire(CurrentPageReference)
    wiredPageRef(ref) {
        if (!ref || !ref.state) return;
        const token = ref.state.token;
        if (!token || this._tokenResolved) return;
        this._tokenResolved = true;
        this._portalToken = token;
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
        // Escape closes the invite modal — the standard keyboard affordance for
        // any dialog; the modal already has visible Cancel/× buttons, but a
        // keyboard-only user shouldn't need to tab to find them.
        this._boundKeydown = (evt) => {
            if (evt.key === 'Escape' && this.showInviteModal) {
                this.handleCloseInvite();
            }
        };
        document.addEventListener('keydown', this._boundKeydown);
    }

    disconnectedCallback() {
        document.removeEventListener('click', this._boundDocClick);
        document.removeEventListener('keydown', this._boundKeydown);
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

    // ── SP3 sub-tabs: Checklist & Upload vs Document Summary ──────────────────
    // Single screen (SP3), two tabs — not a separate nav destination, per the
    // decision to keep this a single-screen portal.
    @track activeSubTab = 'checklist';   // 'checklist' | 'summary'
    get isChecklistTab() { return this.activeSubTab === 'checklist'; }
    get isSummaryTab()   { return this.activeSubTab === 'summary'; }
    get checklistTabClass() { return this.activeSubTab === 'checklist' ? 'vc-tab active' : 'vc-tab'; }
    get summaryTabClass()   { return this.activeSubTab === 'summary'   ? 'vc-tab active' : 'vc-tab'; }
    handleSubTab(event) {
        const tab = event.currentTarget.dataset.tab;
        if (tab === 'checklist' || tab === 'summary') this.activeSubTab = tab;
    }

    handleNav(event) {
        const screen = event.currentTarget.dataset.screen;
        if (!BREADCRUMBS[screen]) return;
        // Sub-suppliers get a restricted, single-tab view — "My sub-suppliers"
        // is not reachable for them even if this somehow fires (e.g. stale UI).
        if (screen === 'sp4' && this.isSubSupplier) return;
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
        // Guest visitors: the token is re-verified server-side and the parent
        // account is derived from it — never sent from the client (same pattern
        // as every other *ByToken call in this component).
        const call = this._portalToken
            ? getRequirementsForParentByToken({ token: this._portalToken })
            : getRequirementsForParent({ parentAccountId: this._accountId });
        call
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
        const inviteArgs = {
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
        };
        const call = this._portalToken
            ? inviteSubSupplierByToken({ token: this._portalToken, ...inviteArgs })
            : inviteSubSupplier({ parentAccountId: this._accountId, ...inviteArgs });
        call
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
        const call = this._portalToken
            ? getSubSuppliersByToken({ token: this._portalToken })
            : getSubSuppliers({ parentAccountId: this._accountId });
        call
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
    @track snapRiskScore = 0;
    @track snapDomains = [];
    @track storedDocs  = [];
    @track complianceRows = [];
    @track rejectedDocs   = [];
    _expandedRows = new Set();
    // Which rows have their "Audit history" (decision/comment thread) open —
    // collapsed by default, same toggle pattern as _expandedRows/handleToggleDetail.
    _auditHistoryOpenRows = new Set();
    // WFL-04: which rejected rows currently have their reply box open, and
    // the in-progress draft text per row (survives a _loadSnapshot refresh
    // the same way _expandedRows does, since both are keyed off requirementLabel).
    _openCommentRows = new Set();
    _commentDrafts = {};

    // ── Multi-tier: am I someone's sub-supplier? / do I have my own sub-suppliers? ──
    @track isSubSupplier = false;
    @track subTierCount  = 0;
    @track cascadingRiskTier = '';
    @track cascadingRiskSource = '';
    @track cascadingRiskFlagged = false;

    get hasSubTierSuppliers() { return this.subTierCount > 0; }
    get subTierCountLabel() {
        return `${this.subTierCount} sub-tier supplier${this.subTierCount === 1 ? '' : 's'}`;
    }
    get cascadingRiskBadgeClass() {
        const map = { Critical: 'vc-badge bad', High: 'vc-badge bad', Medium: 'vc-badge warn', Low: 'vc-badge ok' };
        return map[this.cascadingRiskTier] || 'vc-badge neutral';
    }
    get isCascadingWorseThanOwn() {
        const rank = { Low: 0, Medium: 1, High: 2, Critical: 3 };
        const own = rank[this.snapTier] ?? -1;
        const cascading = rank[this.cascadingRiskTier] ?? -1;
        return cascading > own;
    }
    get cascadingRiskNote() {
        if (!this.isCascadingWorseThanOwn) return '';
        return this.cascadingRiskSource
            ? `Driven by ${this.cascadingRiskSource}`
            : 'Driven by a sub-supplier';
    }

    get hasStoredDocs() { return this.storedDocs.length > 0; }
    get hasComplianceRows() { return this.complianceRows.length > 0; }
    get hasRejectedDocs() { return this.rejectedDocs.length > 0; }
    get checklistProgressLabel() {
        const done = this.complianceRows.filter(r => r.ticked).length;
        return `${done}/${this.complianceRows.length} uploaded`;
    }

    // Reframed from internal review-process jargon ("Full analyst review" /
    // "Auto-clear eligible") to what it actually means for the supplier —
    // whether a person will look at their documents or the system can clear
    // them on its own, which is the thing they actually want to know.
    get oversightLabel() {
        const t = (this.snapTier || '').toLowerCase();
        if (t === 'high' || t === 'critical') return 'Reviewed by an analyst';
        if (t === 'medium') return 'May need analyst review';
        return 'Cleared automatically';
    }

    _loadSnapshot() {
        if (!this._accountId) return;
        this.snapshotLoading = true;
        const call = this._portalToken
            ? getSupplierSnapshotByToken({ token: this._portalToken })
            : getSupplierSnapshot({ accountId: this._accountId });
        call
            .then(s => {
                this.snapshotLoading = false;
                this.snapName   = s.name || '';
                this.snapTier   = s.riskTier || '';
                this.snapStatus = s.onboardingStatus || '';
                this.snapRiskScore = (s.riskScore == null) ? 0 : Math.round(s.riskScore);
                this.snapDomains = (s.domains || []).map((d, i) => ({ id: 'sd' + i, label: d }));
                this.isSubSupplier      = s.isSubSupplier === true;
                this.subTierCount       = s.subTierSupplierCount || 0;
                this.cascadingRiskTier  = s.cascadingRiskTier || '';
                this.cascadingRiskSource = s.cascadingRiskSource || '';
                this.cascadingRiskFlagged = s.cascadingRiskFlagged === true;

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
                        createdLabel: d.createdLabel || '',
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
                // Requirements this supplier could connect a rejected file to
                // instead of leaving it unmatched — every checklist item is
                // offered, not just open ones: connecting to one that already
                // has a document replaces it with this file. Already-uploaded
                // items are labeled so the supplier knows connecting will
                // replace the file.
                const openRequirementOptions = this.complianceRows
                    .filter(r => r.assessmentId)
                    .map(r => ({ value: r.assessmentId, label: r.label, alreadyUploaded: r.ticked }));

                this.rejectedDocs = this.storedDocs
                    .filter(d => {
                        const k = this._fileKey(d.title);
                        return k && !matchedKeys.has(k);
                    })
                    .map((d, i) => ({
                        id: 'rj' + i,
                        requirementKey: null,
                        title: d.title,
                        contentDocumentId: d.contentDocumentId,
                        reason: this._rejectedReason(d.title, openRequirementOptions),
                        connecting: false,
                        removing: false,
                        selectedRequirementId: '',
                        requirementOptions: openRequirementOptions,
                        hasRequirementOptions: openRequirementOptions.length > 0
                    }));
            })
            .catch(err => {
                this.snapshotLoading = false;
                this._toast('error', 'Could not load your submission',
                    (err && err.body && err.body.message) || 'Snapshot failed.');
            });
    }

    // ── Compliance row builder (mirrors procurement P3) ───────────────────────
    // Strips a trailing "- Approved"/"- Rejected" from a reason string, so the
    // decision note doesn't repeat the decision word already shown in the badge.
    _stripDecisionSuffix(reason) {
        return (reason || '').replace(/\s*-\s*(Approved|Rejected)\s*$/i, '');
    }

    _buildComplianceRow(x, i) {
        const ticked = x.uploaded === true;
        const parsed = this._parseSummary(x.reason);
        // Match this requirement's linked document by its real ContentDocumentId
        // (x.contentDocumentId, sourced server-side from Compliance_Document__c.
        // Source_File__c) — NOT by fuzzy-matching x.documentTitle, which is
        // actually the requirement's own label (Document_Type__c), not the
        // uploaded file's name. A real upload's filename routinely shares no
        // substring with its requirement's label, so the old fuzzy match
        // misclassified correctly-linked documents as "unmatched." Fuzzy
        // title matching is kept only as a fallback for older data that
        // predates contentDocumentId being tracked.
        let file = x.contentDocumentId
            ? this.storedDocs.find(d => d.contentDocumentId === x.contentDocumentId)
            : null;
        if (!file) {
            const titleKey = (x.documentTitle || '').toLowerCase()
                .replace(/\.[^.]+$/, '').replace(/[\s_-]+/g, '');
            file = titleKey ? this.storedDocs.find(d => {
                const k = (d.title || '').toLowerCase().replace(/\.[^.]+$/, '').replace(/[\s_-]+/g, '');
                return k && (k.includes(titleKey) || titleKey.includes(k));
            }) : null;
        }
        const expanded = this._expandedRows.has(x.requirementLabel);
        const auditHistoryOpen = this._auditHistoryOpenRows.has(x.requirementLabel);
        // Summary content becomes visible to the supplier the moment EITHER
        // human checkpoint has acted on this document — Procurement records
        // ANY decision (Approve/Reject/Defer — x.procurementDecision non-blank,
        // since Procurement's own note already routinely references/pastes
        // the AI summary when taking that action), OR the Analyst validates it
        // (x.approved, mirroring Analyst_Validated__c — covers a deferred
        // document the Analyst later resolves as Compliant/Non-Compliant,
        // which re-fires this same flag). Previously this was gated ONLY on
        // Analyst_Validated__c, so a Procurement decision alone never revealed
        // anything — the supplier saw just a bare status badge until a case
        // happened to also reach an Analyst, which most auto-routed suppliers
        // never do. Un-acted-on rows still show upload/verdict status only.
        const approved = x.approved === true || !!x.procurementDecision;
        const hasDocumentLinks = approved && (x.documentLinks || []).length > 0;
        const hasDetail = approved
            && !!(parsed.headline || parsed.checksPassed.length || parsed.concerns.length || hasDocumentLinks);
        // A document ComplianceExpiryBatch has flagged as stale (Reason_Code__c
        // ='Expired') is NOT a fresh AI rejection — it's a previously-Compliant
        // document whose Valid_Until__c lapsed with nothing re-checking it.
        // ticked stays true (a document IS still linked), but the row needs its
        // OWN "Renew" action rather than looking like a generic open requirement
        // or a real rejection — that's the whole reason this state exists: a
        // renewal upload must re-target THIS exact assessmentId (see
        // handleRenewDoc), not rely on the fuzzy-matcher, which only ever
        // offers un-ticked rows as match candidates and would never surface
        // this one.
        const isExpired = x.reasonCode === 'Expired';
        // Deferred documents show "Pending review" to the supplier, never
        // the internal word "Deferred" — Apex only sets this override for
        // supplier-facing callers (see getSupplierSnapshot's
        // isSupplierRunningUser filter), so its mere presence here is enough
        // to trust without re-deriving the decision client-side.
        const hasSupplierOverride = !!x.supplierStatusOverride;
        return {
            id: 'cr' + i,
            key: x.requirementLabel,
            assessmentId: x.assessmentId || null,
            label: x.requirementLabel,
            ticked,
            isExpired,
            boxClass: isExpired ? 'vc-chk expired' : (ticked ? 'vc-chk ticked' : 'vc-chk'),
            rowClass: isExpired ? 'vc-cdoc-row expired' : (ticked ? 'vc-cdoc-row done' : 'vc-cdoc-row'),
            statusText: isExpired ? 'Renewal needed' : (ticked ? 'Uploaded' : 'Awaiting upload'),
            verdict: hasSupplierOverride ? x.supplierStatusOverride
                : isExpired ? 'Renewal needed' : (x.uploaded ? (x.status || 'Pending') : ''),
            verdictBadgeClass: hasSupplierOverride ? 'vc-badge warn'
                : isExpired ? 'vc-badge warn' : 'vc-badge ' + (x.badgeClass || 'neutral'),
            hasVerdict: x.uploaded === true,
            approved,
            // Procurement's own Approve/Reject decision — a separate checkpoint
            // from the AI/Analyst verdict above; shown to the supplier regardless
            // of the approved/hasDetail gate so a rejection reason is always
            // visible. Full comment history (newest first) — every past
            // decision stays visible with its own timestamp, not just the latest.
            // Deferred entries never reach this list at all (Apex filters them
            // out server-side for supplier callers), so no client-side check
            // is needed here — anything that arrives is safe to show.
            // Every upload is its own dated entry in this SAME thread (see
            // DocumentProcessingController.linkDocumentToCompliance), reading
            // "Uploaded <document name>" — the requirement's label, not the
            // raw uploaded filename. Server-sorted (Event_DateTime__c DESC)
            // together with decisions/comments, so ordering is always correct
            // across every past upload, not just the currently-linked file.
            comments: (x.procurementComments || []).map((c, j) => ({
                id: 'pc' + i + '_' + j,
                decision: c.decision,
                reason: this._stripDecisionSuffix(c.reason),
                actorName: c.actorName || 'Procurement',
                dateLabel: c.dateLabel || '',
                badgeClass: 'vc-badge ' + (c.decision === 'Rejected' ? 'bad' : 'ok'),
                isSupplierComment: c.isSupplierComment === true
            })),
            hasComments: (x.procurementComments || []).length > 0,
            // The Analyst's own comment (Analyst_Comment__c) — shown to the
            // supplier only when the document reads Non-Compliant, mirroring
            // how a Procurement rejection reason is always visible. An
            // Analyst comment on an otherwise-Compliant document (e.g. an
            // internal validation note) stays internal — the supplier only
            // needs to see it when it explains a problem they must act on.
            analystComment: x.analystComment || '',
            hasAnalystComment: !!x.analystComment && (x.status === 'Non-Compliant'),
            auditHistoryOpen,
            auditHistoryLabel: auditHistoryOpen ? 'Hide Audit History ▴' : 'Audit History ▾',
            commentOpen: this._openCommentRows.has(x.requirementLabel),
            commentInput: this._commentDrafts[x.requirementLabel] || '',
            commentSending: false,
            // Wording is explicit that this is a HUMAN sign-off step, not the AI
            // still working — the AI verdict (x.status) may already be in, but
            // the detailed summary only surfaces to the supplier once Procurement
            // or the Analyst has reviewed and approved it.
            pendingApprovalLabel: (x.uploaded === true && !approved)
                ? 'Awaiting procurement/analyst review' : '',
            confidence: (x.aiConfidence == null) ? null : x.aiConfidence,
            confidenceLabel: '',   // confidence % is an internal signal — not shown to suppliers
            hasConfidence: false,
            headline: parsed.headline,
            hasHeadline: !!parsed.headline,
            checksPassed: parsed.checksPassed.map((t, j) => ({ id: 'cf' + i + '_' + j, text: t })),
            hasChecksPassed: parsed.checksPassed.length > 0,
            concerns: parsed.concerns.map((t, j) => ({ id: 'co' + i + '_' + j, text: t })),
            hasConcerns: parsed.concerns.length > 0,
            evaluatedLabel: x.evaluatedLabel || '',
            hasEvaluatedLabel: !!x.evaluatedLabel,
            // Multi-document-per-requirement: same approved-only visibility
            // gate as the rest of this row's detail — no confidence % shown
            // (same internal-signal policy as the rest of this portal).
            documentLinks: (x.documentLinks || []).map((dl, j) => this._buildLinkedDocRow(dl, j)),
            hasDocumentLinks,
            hasDetail,
            expanded,
            toggleLabel: expanded ? 'Hide summary ▴' : 'Show summary ▾',
            fileId: file ? file.id : '',
            contentDocumentId: file ? file.contentDocumentId : '',
            hasFile: !!file,
            fileName: file ? file.title : (x.documentTitle || ''),
            hasFileName: !!(file ? file.title : x.documentTitle),
            // Per-row upload button (same "targets this exact requirement"
            // mechanism as handleRenewClick, same as Documents & Screening's
            // own row-upload button): visible while nothing is uploaded yet,
            // hidden once a file lands, and visible again once EITHER
            // checkpoint rejects it — Procurement's own decision
            // (procurementDecision === 'Rejected') OR the AI/Analyst verdict
            // itself (status === 'Non-Compliant'). Previously only the
            // Procurement field was checked, so an Analyst marking a document
            // Non-Compliant via saveDocValidation (which never touches
            // Procurement_Decision__c) left the supplier with no way to
            // re-upload — the button just silently never reappeared.
            showUploadButton: !file || x.procurementDecision === 'Rejected' || x.status === 'Non-Compliant'
        };
    }

    _buildLinkedDocRow(dl, j) {
        const parsed = this._parseSummary(dl.reason);
        return {
            id: 'dl' + j,
            docLinkId: dl.docLinkId,
            documentTitle: dl.documentTitle || 'Untitled document',
            status: dl.status || 'Pending',
            badgeClass: 'vc-badge ' + (dl.badgeClass || 'neutral'),
            headline: parsed.headline,
            hasHeadline: !!parsed.headline,
            checksPassed: parsed.checksPassed.map((t, k) => ({ id: 'dlcp' + j + '_' + k, text: t })),
            hasChecksPassed: parsed.checksPassed.length > 0,
            concerns: parsed.concerns.map((t, k) => ({ id: 'dlco' + j + '_' + k, text: t })),
            hasConcerns: parsed.concerns.length > 0
        };
    }

    _fileKey(name) {
        return (name || '').toLowerCase().replace(/\.[^.]+$/, '').replace(/[\s_-]+/g, '');
    }

    // Explains WHY a file landed in Unmatched, instead of a flat generic
    // sentence — names the closest requirement considered (if any) so the
    // supplier understands what almost matched, or that nothing did at all.
    _rejectedReason(fileName, openRequirementOptions) {
        const tokenize = (s) => (s || '')
            .replace(/\.[^.]+$/, '')
            .replace(/([a-z])([A-Z])/g, '$1_$2')
            .toLowerCase()
            .split(/[^a-z0-9]+/)
            .filter((t) => t.length >= 3);
        const fileTokens = new Set(tokenize(fileName));
        let best = null;
        let bestScore = 0;
        (openRequirementOptions || []).forEach((opt) => {
            const shared = tokenize(opt.label).filter((t) => fileTokens.has(t)).length;
            if (shared > bestScore) { bestScore = shared; best = opt; }
        });
        if (best && bestScore === 1) {
            return `Closest match was "${best.label}", but the filename didn't share enough in common to link automatically — connect it below if that's correct.`;
        }
        if (!openRequirementOptions || !openRequirementOptions.length) {
            return 'No checklist items to match against — this file is stored but not linked to any requirement.';
        }
        return "Didn't match any required document by name — pick the correct checklist item below if this file satisfies one.";
    }

    // Parse the AI summary blob (DocAssessQueueable.buildDetail) into a
    // headline plus two flat lists — checksPassed (✓) and concerns (⚠).
    // Deterministic gates and registry results are already folded into
    // these same two lists server-side, by their own pass/fail.
    _parseSummary(reason) {
        const out = { headline: '', checksPassed: [], concerns: [] };
        if (!reason) return out;
        const lines = String(reason).split(/\r?\n/).map(l => l.trim()).filter(Boolean);
        for (const line of lines) {
            if (/^checks passed:$/i.test(line)) continue;
            if (/^concerns:$/i.test(line)) continue;
            if (/^policy citations:/i.test(line)) break;
            if (line.startsWith('✓')) { out.checksPassed.push(line.replace(/^✓\s*/, '')); continue; }
            if (line.startsWith('⚠')) { out.concerns.push(line.replace(/^⚠\s*/, '')); continue; }
            if (!out.headline) out.headline = line;
        }
        return out;
    }

    // ── Toggle summary detail row ─────────────────────────────────────────────
    handleToggleDetail(event) {
        const key = event.currentTarget.dataset.key;
        if (!key) return;
        if (this._expandedRows.has(key)) this._expandedRows.delete(key);
        else this._expandedRows.add(key);
        this.complianceRows = this.complianceRows.map(r =>
            r.key === key
                ? { ...r, expanded: !r.expanded,
                    toggleLabel: !r.expanded ? 'Hide summary ▴' : 'Show summary ▾' }
                : r);
    }

    // ── Toggle audit history (decision/comment thread) — collapsed by default,
    // same pattern as handleToggleDetail above, but a separate toggle since it
    // covers a different section (Procurement's decisions + supplier replies,
    // not the AI summary).
    handleToggleAuditHistory(event) {
        const key = event.currentTarget.dataset.key;
        if (!key) return;
        if (this._auditHistoryOpenRows.has(key)) this._auditHistoryOpenRows.delete(key);
        else this._auditHistoryOpenRows.add(key);
        this.complianceRows = this.complianceRows.map(r =>
            r.key === key
                ? { ...r, auditHistoryOpen: !r.auditHistoryOpen,
                    auditHistoryLabel: !r.auditHistoryOpen ? 'Hide Audit History ▴' : 'Audit History ▾' }
                : r);
    }

    handleOpenComment(event) {
        const key = event.currentTarget.dataset.key;
        if (!key) return;
        this._openCommentRows.add(key);
        this.complianceRows = this.complianceRows.map(r =>
            r.key === key ? { ...r, commentOpen: true, commentInput: this._commentDrafts[key] || '' } : r);
    }
    handleCancelComment(event) {
        const key = event.currentTarget.dataset.key;
        if (!key) return;
        this._openCommentRows.delete(key);
        delete this._commentDrafts[key];
        this.complianceRows = this.complianceRows.map(r =>
            r.key === key ? { ...r, commentOpen: false, commentInput: '' } : r);
    }
    handleCommentDraftInput(event) {
        const key = event.currentTarget.dataset.key;
        if (!key) return;
        const value = event.target.value;
        this._commentDrafts[key] = value;
        this.complianceRows = this.complianceRows.map(r =>
            r.key === key ? { ...r, commentInput: value } : r);
    }
    handleSendComment(event) {
        const key = event.currentTarget.dataset.key;
        const row = this.complianceRows.find(r => r.key === key);
        if (!row || !row.assessmentId) return;
        const note = (row.commentInput || '').trim();
        if (!note) return;
        this.complianceRows = this.complianceRows.map(r =>
            r.key === key ? { ...r, commentSending: true } : r);
        const call = this._portalToken
            ? addSupplierCommentByToken({ token: this._portalToken, assessmentId: row.assessmentId, note })
            : addSupplierComment({ assessmentId: row.assessmentId, note });
        call
            .then(() => {
                this._openCommentRows.delete(key);
                delete this._commentDrafts[key];
                this._toast('success', 'Comment sent', 'Procurement will see your reply.');
                this._loadSnapshot();
            })
            .catch(err => {
                this.complianceRows = this.complianceRows.map(r =>
                    r.key === key ? { ...r, commentSending: false } : r);
                this._toast('error', 'Could not send',
                    (err && err.body && err.body.message) || 'Failed to send your comment.');
            });
    }

    // Track which existing requirement the supplier picked in a rejected row's dropdown.
    handleRejectedRequirementChange(event) {
        const id = event.currentTarget.dataset.id;
        const value = event.target.value;
        this.rejectedDocs = this.rejectedDocs.map(r =>
            r.id === id ? { ...r, selectedRequirementId: value } : r);
    }

    // Connects a rejected/unmatched file to an EXISTING open requirement —
    // same self-service action Procurement has in their own console, so a
    // supplier who uploaded the right file under an unexpected filename can
    // fix the link themselves instead of waiting on Procurement.
    handleConnectRejected(event) {
        const id = event.currentTarget.dataset.id;
        const rej = this.rejectedDocs.find(r => r.id === id);
        if (!rej || !rej.selectedRequirementId || !rej.contentDocumentId) return;
        this.rejectedDocs = this.rejectedDocs.map(r =>
            r.id === id ? { ...r, connecting: true } : r);
        const call = this._portalToken
            ? linkDocumentToComplianceByToken({
                token: this._portalToken,
                contentDocumentId: rej.contentDocumentId,
                documentType: rej.title,
                assessmentId: rej.selectedRequirementId,
                fileName: rej.title
            })
            : linkDocumentToCompliance({
                accountId: this._accountId,
                contentDocumentId: rej.contentDocumentId,
                documentType: rej.title,
                assessmentId: rej.selectedRequirementId,
                fileName: rej.title
            });
        call
            .then(() => {
                this._toast('success', 'Connected', `"${rej.title}" is now linked and queued for review.`);
                this._loadSnapshot();
                this._pollForAssessment();
            })
            .catch(err => {
                this.rejectedDocs = this.rejectedDocs.map(r =>
                    r.id === id ? { ...r, connecting: false } : r);
                this._toast('error', 'Could not connect',
                    (err && err.body && err.body.message) || 'Failed to connect the document.');
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
            const call = this._portalToken
                ? generatePublicDocumentUrlByToken({ token: this._portalToken, contentDocumentId: doc.contentDocumentId })
                : generatePublicDocumentUrl({ contentDocumentId: doc.contentDocumentId });
            call
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
        const removeCall = this._portalToken
            ? removeSupplierDocumentByToken({ token: this._portalToken, contentDocumentId: doc.contentDocumentId })
            : removeSupplierDocument({ accountId: this._accountId, contentDocumentId: doc.contentDocumentId });
        removeCall
            .then(() => {
                if (this._previewDocId === id) this.closePreview();
                this._toast('success', 'Document removed', `${doc.title} was removed.`);
                this._loadSnapshot();
            })
            .catch(err => this._toast('error', 'Remove failed',
                (err && err.body && err.body.message) || 'Could not remove the document.'));
    }

    // Same removal call as handleRemoveDoc, but for a file in the Unmatched
    // documents list — rejectedDocs rows use their own synthetic id space
    // ('rj' + i), not storedDocs', so this looks the file up there instead
    // and keys the delete off contentDocumentId directly, which every
    // rejectedDocs row already carries.
    handleRemoveRejectedDoc(event) {
        const id = event.currentTarget.dataset.id;
        const rej = this.rejectedDocs.find(r => r.id === id);
        if (!rej || !rej.contentDocumentId) {
            this._toast('warning', 'Cannot remove', 'This document has no removable file reference.');
            return;
        }
        this.rejectedDocs = this.rejectedDocs.map(r =>
            r.id === id ? { ...r, removing: true } : r);
        const removeCall = this._portalToken
            ? removeSupplierDocumentByToken({ token: this._portalToken, contentDocumentId: rej.contentDocumentId })
            : removeSupplierDocument({ accountId: this._accountId, contentDocumentId: rej.contentDocumentId });
        removeCall
            .then(() => {
                this._toast('success', 'Document removed', `${rej.title} was removed.`);
                this._loadSnapshot();
            })
            .catch(err => {
                this.rejectedDocs = this.rejectedDocs.map(r =>
                    r.id === id ? { ...r, removing: false } : r);
                this._toast('error', 'Remove failed',
                    (err && err.body && err.body.message) || 'Could not remove the document.');
            });
    }

    // ── Document renewal (expired document → forced re-upload) ─────────────────
    // Distinct from the generic uploader: a renewal MUST re-target the exact
    // assessmentId ComplianceExpiryBatch flagged — the fuzzy-matcher used by
    // _uploadOne only ever offers un-ticked (still-open) rows as candidates,
    // and an expired row is still ticked=true (a document IS still linked,
    // it's just stale), so it would never be offered as a match target there.
    @track _renewAssessmentId = null;
    @track _renewLabel = '';

    handleRenewClick(event) {
        this._renewAssessmentId = event.currentTarget.dataset.assessmentId;
        this._renewLabel = event.currentTarget.dataset.label;
        const picker = this.template.querySelector('.vc-renew-file-input');
        if (picker) picker.click();
    }

    handleRenewFilePicked(event) {
        const file = (event.target.files || [])[0];
        event.target.value = '';
        if (!file || !this._renewAssessmentId) return;
        const assessmentId = this._renewAssessmentId;
        const label = this._renewLabel;
        this._renewAssessmentId = null;
        this._renewLabel = '';

        const reader = new FileReader();
        reader.onload = () => {
            const base64 = (reader.result || '').toString().split(',')[1];
            const saveCall = this._portalToken
                ? saveFileByToken({ token: this._portalToken, fileName: file.name, base64Data: base64 })
                : saveFile({ recordId: this._accountId, fileName: file.name, base64Data: base64 });
            saveCall
                .then(contentDocumentId =>
                    this._portalToken
                        ? linkDocumentToComplianceByToken({
                            token: this._portalToken,
                            contentDocumentId,
                            documentType: label,
                            assessmentId,
                            fileName: file.name
                        })
                        : linkDocumentToCompliance({
                            accountId: this._accountId,
                            contentDocumentId,
                            documentType: label,
                            assessmentId,
                            fileName: file.name
                        })
                )
                .then(() => {
                    this._toast('success', 'Renewal uploaded', `${label} — new document queued for review.`);
                    this._loadSnapshot();
                    this._pollForAssessment();
                })
                .catch(err => {
                    this._toast('error', 'Renewal failed',
                        (err && err.body && err.body.message) || `Could not upload the renewal for ${label}.`);
                });
        };
        reader.onerror = () => {
            this._toast('error', 'Read failed', `Could not read ${file.name}.`);
        };
        reader.readAsDataURL(file);
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
        // Fuzzy-match the filename against this supplier's OPEN checklist
        // requirement labels BEFORE uploading — same rule as
        // scProcurementConsole's bulk uploader (see _fuzzyMatchRequirement),
        // so a supplier uploading a well-named file (e.g.
        // "CMRT_ConflictMinerals_Nordwind.txt") links straight to "Conflict
        // Minerals Due Diligence (OECD/CMRT)" instead of always landing in
        // Unmatched. Passing assessmentId directly is what makes
        // linkDocumentToCompliance attach to THAT row — documentType alone
        // requires an exact string match.
        const matchedAssessmentId = this._fuzzyMatchRequirement(file.name);

        const reader = new FileReader();
        reader.onload = () => {
            const base64 = (reader.result || '').toString().split(',')[1];
            const saveCall = this._portalToken
                ? saveFileByToken({ token: this._portalToken, fileName: file.name, base64Data: base64 })
                : saveFile({ recordId: this._accountId, fileName: file.name, base64Data: base64 });
            saveCall
                .then(contentDocumentId =>
                    this._portalToken
                        ? linkDocumentToComplianceByToken({
                            token: this._portalToken,
                            contentDocumentId,
                            documentType: file.name,
                            assessmentId: matchedAssessmentId,
                            fileName: file.name
                        })
                        : linkDocumentToCompliance({
                            accountId: this._accountId,
                            contentDocumentId,
                            documentType: file.name,
                            assessmentId: matchedAssessmentId,
                            fileName: file.name
                        })
                )
                .then(() => {
                    this._setUploadStatus(tempId, 'Uploaded · Reviewing');
                    this._toast('success', 'Uploaded', `${file.name} stored and queued for review.`);
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

    // Returns the assessmentId of the best-matching OPEN (not yet uploaded)
    // requirement for a filename, or null if nothing plausible matches.
    // Token-overlap scoring (not plain substring) — see scProcurementConsole's
    // identical helper for the full rationale/example.
    _fuzzyMatchRequirement(fileName) {
        const tokenize = (s) => (s || '')
            .replace(/\.[^.]+$/, '')
            .replace(/([a-z])([A-Z])/g, '$1_$2')
            .toLowerCase()
            .split(/[^a-z0-9]+/)
            .filter((t) => t.length >= 3);
        const fileTokens = new Set(tokenize(fileName));
        if (fileTokens.size === 0) return null;

        const candidates = (this.complianceRows || []).filter((r) => !r.ticked && r.assessmentId);
        let best = null;
        let bestScore = 0;
        candidates.forEach((r) => {
            const labelTokens = tokenize(r.label);
            const shared = labelTokens.filter((t) => fileTokens.has(t)).length;
            if (shared > bestScore) {
                bestScore = shared;
                best = r;
            }
        });
        return (best && bestScore >= 2) ? best.assessmentId : null;
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
    // Every checklist row counts toward the denominator, not just the ones
    // already uploaded/assessed — an un-uploaded row naturally maps to
    // verdict:'' -> decision:'pending' (0 credit, same as a document still
    // awaiting AI assessment), so "3 of 8 compliant" reads against the WHOLE
    // checklist the supplier sees below it, not just what they've gotten to
    // so far — a denominator of "only what's been touched" made "0 of 5" on
    // an 8-item checklist read as if 3 requirements didn't exist.
    get dashboardDocs() {
        return (this.complianceRows || []).map(a => ({
            decision: this._statusToDecision(a.verdict),
            confidence: a.confidence,
            uploaded: a.ticked
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