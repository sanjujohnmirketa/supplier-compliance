import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin }   from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import Toast from 'lightning/toast';
import getScreeningQueue from '@salesforce/apex/VendorPortalController.getScreeningQueue';
import getSupplierSnapshot from '@salesforce/apex/SupplierRiskDashboardController.getSupplierSnapshot';
import getCaseActivity from '@salesforce/apex/VendorPortalController.getCaseActivity';
import saveDecision from '@salesforce/apex/VendorPortalController.saveDecision';
import getCaseDocuments from '@salesforce/apex/VendorPortalController.getCaseDocuments';
import runScreening from '@salesforce/apex/VendorPortalController.runScreening';
import saveCopilotFeedback from '@salesforce/apex/VendorPortalController.saveCopilotFeedback';
import askCopilot from '@salesforce/apex/VendorPortalController.askCopilot';
import setReviewOutcome from '@salesforce/apex/VendorPortalController.setReviewOutcome';
import saveDraft         from '@salesforce/apex/VendorPortalController.saveDraft';
import submitForReview   from '@salesforce/apex/VendorPortalController.submitForReview';
import getDomainCatalog  from '@salesforce/apex/ComplianceDomainController.getDomainCatalog';
import generateChecklist from '@salesforce/apex/VendorPortalController.generateChecklist';
import requestDocuments  from '@salesforce/apex/VendorPortalController.requestDocumentsFromSupplier';
import userId          from '@salesforce/user/Id';
import FIRSTNAME_FIELD from '@salesforce/schema/User.FirstName';
import LASTNAME_FIELD  from '@salesforce/schema/User.LastName';

// ─── Country list ────────────────────────────────────────────────────────────
const COUNTRIES = [
    'Afghanistan','Albania','Algeria','Angola','Argentina','Armenia','Australia',
    'Austria','Azerbaijan','Bangladesh','Belgium','Bolivia','Bosnia and Herzegovina',
    'Brazil','Bulgaria','Cambodia','Canada','Chile','China','Colombia',
    'Costa Rica','Croatia','Czech Republic','Denmark','Dominican Republic','Ecuador',
    'Egypt','El Salvador','Estonia','Ethiopia','Finland','France','Georgia',
    'Germany','Ghana','Greece','Guatemala','Honduras','Hungary','India','Indonesia',
    'Iran','Iraq','Ireland','Israel','Italy','Ivory Coast','Japan','Jordan',
    'Kazakhstan','Kenya','Kuwait','Latvia','Lebanon','Libya','Lithuania',
    'Luxembourg','Malaysia','Mexico','Moldova','Morocco','Mozambique','Myanmar',
    'Nepal','Netherlands','New Zealand','Nicaragua','Nigeria','Norway','Oman',
    'Pakistan','Panama','Paraguay','Peru','Philippines','Poland','Portugal',
    'Qatar','Romania','Russia','Saudi Arabia','Senegal','Serbia','Singapore',
    'Slovakia','Slovenia','South Africa','South Korea','Spain','Sri Lanka',
    'Sweden','Switzerland','Taiwan','Tanzania','Thailand','Tunisia','Turkey',
    'Ukraine','United Arab Emirates','United Kingdom','United States','Uruguay',
    'Uzbekistan','Venezuela','Vietnam','Yemen','Zimbabwe'
];

// ─── Engagement type taxonomy (mirrors the Account.Engagement_Type__c picklist) ─
const ENGAGEMENT_TYPES = [
    'Direct Material - Production (Tier 1)',
    'Direct Material - Production (Tier 2)',
    'Indirect / Non-production (MRO)',
    'Raw Materials / Commodities',
    'Services / Consulting',
    'Logistics / Distribution',
    'Capital Equipment / Tooling'
];

// ─── Screen breadcrumb map ───────────────────────────────────────────────────
const BREADCRUMBS = {
    s1: '/Intake · New request',
    s2: '/Compliance review queue',
    s3: '/Due Diligence · AI review',
    s4: '/Due Diligence · Risk domains',
    s5: '/Due Diligence · Agent review',
    s6: '/Due Diligence · Decision',
};

export default class ScVendorConsole extends NavigationMixin(LightningElement) {

    // ── Logged-in user ───────────────────────────────────────────────────────
    _userInitials = '??';
    _userName     = '';
    @track _showUserMenu = false;

    @wire(getRecord, { recordId: userId, fields: [FIRSTNAME_FIELD, LASTNAME_FIELD] })
    wiredUser({ data, error }) {
        if (data) {
            const first = getFieldValue(data, FIRSTNAME_FIELD) || '';
            const last  = getFieldValue(data, LASTNAME_FIELD)  || '';
            this._userInitials = (first.charAt(0) + last.charAt(0)).toUpperCase() || '??';
            this._userName     = `${first} ${last}`.trim();
        } else if (error) {
            console.error('[VendorPortal] Could not load user:', error);
        }
    }

    get userInitials() { return this._userInitials; }
    get userName()     { return this._userName; }
    get showUserMenu() { return this._showUserMenu; }

    // Close menu when clicking anywhere outside the component
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
    }

    handleAvatarClick() {
        this._showUserMenu = !this._showUserMenu;
    }

    handleLogout() {
        this._showUserMenu = false;
        this[NavigationMixin.Navigate]({
            type: 'comm__loginPage',
            attributes: { actionName: 'logout' }
        });
    }

    // ── Active screen ────────────────────────────────────────────────────────
    @track activeScreen = 's1';
    @track breadcrumb   = BREADCRUMBS.s1;

    // ── Screen visibility getters ────────────────────────────────────────────
    get isS1() { return this.activeScreen === 's1'; }
    get isS2() { return this.activeScreen === 's2'; }
    get isS3() { return this.activeScreen === 's3'; }
    get isS4() { return this.activeScreen === 's4'; }
    get isS5() { return this.activeScreen === 's5'; }
    get isS6() { return this.activeScreen === 's6'; }

    // ── Sidebar active state getters ─────────────────────────────────────────
    get sbS1Active() { return this.activeScreen === 's1' ? 'vc-sb-item active' : 'vc-sb-item'; }
    get sbS2Active() { return this.activeScreen === 's2' ? 'vc-sb-item active' : 'vc-sb-item'; }
    get sbS3Active() { return this.activeScreen === 's3' ? 'vc-sb-item active' : 'vc-sb-item'; }
    get sbS4Active() { return this.activeScreen === 's4' ? 'vc-sb-item active' : 'vc-sb-item'; }
    get sbS5Active() { return this.activeScreen === 's5' ? 'vc-sb-item active' : 'vc-sb-item'; }
    get sbS6Active() { return this.activeScreen === 's6' ? 'vc-sb-item active' : 'vc-sb-item'; }

    // ── Sidebar dot getters ──────────────────────────────────────────────────
    get dotS1() { return this.activeScreen === 's1' ? 'vc-sb-dot curr' : 'vc-sb-dot'; }
    get dotS2() { return this.activeScreen === 's2' ? 'vc-sb-dot curr' : 'vc-sb-dot'; }
    get dotS3() { return this.activeScreen === 's3' ? 'vc-sb-dot curr' : 'vc-sb-dot'; }
    get dotS4() { return this.activeScreen === 's4' ? 'vc-sb-dot curr' : 'vc-sb-dot'; }
    get dotS5() { return this.activeScreen === 's5' ? 'vc-sb-dot curr' : 'vc-sb-dot'; }
    get dotS6() { return this.activeScreen === 's6' ? 'vc-sb-dot curr' : 'vc-sb-dot'; }

    // ── Navigation ───────────────────────────────────────────────────────────
    handleNav(event) {
        const sid = event.currentTarget.dataset.screen;
        if (!sid || !BREADCRUMBS[sid]) return;
        // Case stages (s3–s6) are contextual — only reachable with a supplier open
        if (sid !== 's1' && sid !== 's2' && !this.selectedSupplier) {
            this._toast('info', 'Select a supplier',
                'Open a supplier from the Screening queue to view its case.');
            return;
        }
        // Leaving the case context (back to a top-level destination) closes the case
        if (sid === 's1' || sid === 's2') this._clearCase();
        this.activeScreen = sid;
        this.breadcrumb   = BREADCRUMBS[sid];
        // Scroll main canvas back to top
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const main = this.template.querySelector('.vc-main');
            if (main) main.scrollTop = 0;
        }, 0);
    }

    _clearCase() {
        this.selectedSupplier = undefined;
        this.caseSnapshot = undefined;
        this.caseActivity = [];
    }

    // ── Guided case flow (S3 → S4 → S5 → S6) ─────────────────────────────────
    get isCaseScreen() { return ['s3', 's4', 's5', 's6'].includes(this.activeScreen); }

    get caseNextLabel() {
        return ({
            s3: 'Next: Risk Domains →',
            s4: 'Next: Agent Review →',
            s5: 'Next: Decision →'
        })[this.activeScreen] || 'Next →';
    }

    handleCaseNext() {
        const next = ({ s3: 's4', s4: 's5', s5: 's6' })[this.activeScreen];
        if (next) { this.activeScreen = next; this.breadcrumb = BREADCRUMBS[next]; }
    }

    handleStepperClick(event) {
        const step = event.target.closest('.vc-step');
        if (!step) return;
        const steps = Array.from(step.parentNode.querySelectorAll('.vc-step'));
        const idx = steps.indexOf(step);
        if (idx < 0) return;
        const sid = 's' + (idx + 1);
        if (!BREADCRUMBS[sid]) return;
        // Case stages need an open supplier
        if (idx + 1 >= 3 && !this.selectedSupplier) return;
        if (sid === 's1' || sid === 's2') this._clearCase();
        this.activeScreen = sid;
        this.breadcrumb = BREADCRUMBS[sid];
    }

    // ── Decision rationale (S6) ──────────────────────────────────────────────
    @track decisionRationale = '';
    handleRationale(event) { this.decisionRationale = event.target.value; }

    // ── Queue search filter (top bar) ────────────────────────────────────────
    @track searchTerm = '';
    handleSearch(event) { this.searchTerm = event.target.value; }

    // ── SCREEN 2 — Screening queue (real Supplier-record-type Accounts) ───────
    @track queue;
    _wiredQueue;

    @wire(getScreeningQueue)
    wiredQueue(result) {
        this._wiredQueue = result;
        if (result.data) {
            this.queue = result.data;
        } else if (result.error) {
            console.error('[VendorPortal] Screening queue load error:', JSON.stringify(result.error));
            this._toast('error', 'Queue', this._extractError(result.error));
        }
    }

    get queueRows() {
        const term = (this.searchTerm || '').trim().toLowerCase();
        let rows = (this.queue && this.queue.rows) ? this.queue.rows : [];
        if (term) {
            rows = rows.filter(r =>
                (r.name || '').toLowerCase().includes(term) ||
                (r.industry || '').toLowerCase().includes(term));
        }
        return rows.map(r => ({
            ...r,
            tierBadgeClass: this._tierBadge(r.riskTier),
            tierLabel:      (r.riskTier || '—').toUpperCase(),
            scoreLabel:     (r.riskScore == null) ? '—' : Math.round(r.riskScore),
            flagsLabel:     r.flags > 0 ? String(r.flags) : '',
            hasFlags:       r.flags > 0,
            routingClass:   r.routing === 'Needs analyst' ? 'vc-route-pill analyst'
                          : r.routing === 'Auto-approve'  ? 'vc-route-pill auto'
                          : 'vc-route-pill pending',
            aiStatusClass:  this._aiStatusClass(r.aiStatus)
        }));
    }
    _aiStatusClass(s) {
        if (s === 'Onboarded')     return 'vc-ai-pill onboarded';
        if (s === 'AI cleared')    return 'vc-ai-pill cleared';
        if (s === 'Needs analyst') return 'vc-ai-pill analyst';
        return 'vc-ai-pill screening';
    }
    get queueTotal()       { return this.queue ? this.queue.total : 0; }
    get queueProspective() { return this.queue ? this.queue.prospective : 0; }
    get queueNeedsReview() { return this.queue ? this.queue.needsReview : 0; }
    get queueApproved()    { return this.queue ? this.queue.approved : 0; }
    get queueAutoCleared() { return this.queue ? this.queue.autoCleared : 0; }
    get queueTimeToOnboard() {
        const d = this.queue ? this.queue.avgTimeToOnboardDays : null;
        return (d == null) ? '—' : (d + 'd');
    }
    get hasQueueRows()     { return (this.queue && this.queue.rows && this.queue.rows.length > 0); }

    _tierBadge(tier) {
        if (tier === 'Critical' || tier === 'High') return 'vc-badge-high';
        if (tier === 'Medium') return 'vc-badge-med';
        if (tier === 'Low')    return 'vc-badge-low';
        return 'vc-badge-med';
    }

    handleRefreshQueue() {
        if (this._wiredQueue) {
            refreshApex(this._wiredQueue);
            this._toast('success', 'Refreshed', 'Screening queue updated.');
        }
    }

    // ── Case workspace — the opened supplier (drives screens 3–6) ─────────────
    @track selectedSupplier;

    get hasSelectedSupplier() { return !!this.selectedSupplier; }
    get caseName()      { return this.selectedSupplier ? this.selectedSupplier.name : 'Supplier'; }
    get caseTier()      { return (this.selectedSupplier && this.selectedSupplier.riskTier
                                    ? this.selectedSupplier.riskTier : 'MED').toUpperCase(); }
    get caseTierBadge() { return this._tierBadge(this.selectedSupplier && this.selectedSupplier.riskTier); }
    get caseMeta() {
        const s = this.selectedSupplier;
        if (!s) return '';
        return [s.industry, s.riskDomains, s.ageLabel].filter(Boolean).join(' · ');
    }

    @track caseSnapshot;
    @track caseLoading = false;

    handleOpenSupplier(event) {
        const id = event.currentTarget.dataset.id;
        const row = (this.queue && this.queue.rows ? this.queue.rows : []).find(r => r.id === id);
        if (!row) return;
        this.selectedSupplier = row;
        this.caseSnapshot = undefined;
        this.caseActivity = [];
        this.caseLoading = true;
        this.activeScreen = 's3';
        this.breadcrumb   = BREADCRUMBS.s3;
        // Seed Screen-6 tier + routing from the AI risk tier (no longer hardcoded MED).
        const seed = this._tierToCode(row.riskTier);
        this.confirmedTier = seed;
        this.selectedRoute = seed;
        getSupplierSnapshot({ accountId: id })
            .then(snap => {
                this.caseSnapshot = snap; this.caseLoading = false;
                this.confirmedTier = this._tierToCode(this.liveTier);
                this.selectedRoute = this._tierToCode(this.liveTier);
                this.mitigations   = this._suggestMitigations();
            })
            .catch(err => {
                this.caseLoading = false;
                this._toast('error', 'Case load failed', this._extractError(err));
            });
        getCaseActivity({ accountId: id })
            .then(acts => {
                this.caseActivity = (acts || []).map((a, i) => ({ ...a, id: `act-${i}` }));
            })
            .catch(err => {
                console.error('[VendorPortal] activity load error:', JSON.stringify(err));
            });
        this._loadCaseDocuments(id);
        this._loadScreening(id);
    }

    // Auto-refresh the AI summary when the embedded uploader finishes assessing a
    // document — the analyst should never have to manually refresh.
    handleCaseChanged() {
        if (!this.selectedSupplier) return;
        const id = this.selectedSupplier.id;
        getSupplierSnapshot({ accountId: id })
            .then(snap => { this.caseSnapshot = snap; })
            .catch(() => {});
        getCaseActivity({ accountId: id })
            .then(acts => { this.caseActivity = (acts || []).map((a, i) => ({ ...a, id: `act-${i}` })); })
            .catch(() => {});
    }

    // ── S3 — Live registry screening (/verify) ───────────────────────────────
    @track screening;
    @track screeningLoading = false;
    @track screeningError = '';

    _loadScreening(id) {
        this.screening = undefined;
        this.screeningError = '';
        this.screeningLoading = true;
        runScreening({ accountId: id })
            .then(res => { this.screening = res; this.screeningLoading = false; })
            .catch(err => {
                this.screeningLoading = false;
                // Surface the failure (no silent error) — usually a callout/token issue.
                this.screeningError = this._extractError(err) || 'Screening service unavailable.';
                console.error('[VendorPortal] screening error:', JSON.stringify(err));
            });
    }
    handleRunScreening() {
        if (this.selectedSupplier) this._loadScreening(this.selectedSupplier.id);
    }
    get hasScreeningError() { return !!this.screeningError; }

    // ── Compliance co-pilot chat (grounded Q&A) ───────────────────────────────
    @track agentInput = '';
    @track agentMessages = [];
    @track agentLoading = false;
    get hasAgentMessages() { return this.agentMessages.length > 0; }
    handleAgentInput(event) { this.agentInput = event.target.value; }
    handleAgentKey(event) { if (event.key === 'Enter') this.handleAgentSend(); }
    handleAgentSend() {
        const q = (this.agentInput || '').trim();
        if (!q || this.agentLoading || !this.selectedSupplier) return;
        this.agentMessages = [...this.agentMessages, { id: 'm' + Date.now(), role: 'you', cls: 'vc-msg you', text: q }];
        this.agentInput = '';
        this.agentLoading = true;
        askCopilot({ accountId: this.selectedSupplier.id, question: q })
            .then(res => {
                this.agentLoading = false;
                this.agentMessages = [...this.agentMessages,
                    { id: 'a' + Date.now(), role: 'agent', cls: 'vc-msg agent', text: res.answer || '(no answer)' }];
            })
            .catch(err => {
                this.agentLoading = false;
                this.agentMessages = [...this.agentMessages,
                    { id: 'e' + Date.now(), role: 'agent', cls: 'vc-msg agent err', text: this._extractError(err) || 'Co-pilot unavailable.' }];
            });
    }

    get screeningResults() { return (this.screening && this.screening.results) || []; }
    _screenPill(status) {
        if (status === 'Verified' || status === 'Clear') return 'vc-screen-pill ok';
        if (status === 'Flag') return 'vc-screen-pill flag';
        return 'vc-screen-pill review';
    }
    _screeningByCat(cat) {
        return this.screeningResults
            .filter(r => r.category === cat)
            .map((r, i) => ({ ...r, id: `${cat}-${i}`, pillClass: this._screenPill(r.status) }));
    }
    get sanctionsResults() { return this._screeningByCat('Sanctions'); }
    get financialResults() { return this._screeningByCat('Financials'); }
    get conflictResults()  { return this._screeningByCat('Conflict Minerals'); }
    get mediaResults()     { return this._screeningByCat('Media'); }
    get hasSanctions()     { return this.sanctionsResults.length > 0; }
    get hasFinancials()    { return this.financialResults.length > 0; }
    get hasConflict()      { return this.conflictResults.length > 0; }
    get hasMedia()         { return this.mediaResults.length > 0; }

    // Evidence tab visibility
    get isDocTab()       { return this.activeEvidenceTab === 'Documents'; }
    get isSanctionsTab() { return this.activeEvidenceTab === 'Sanctions'; }
    get isFinTab()       { return this.activeEvidenceTab === 'Financials'; }
    get isConflictTab()  { return this.activeEvidenceTab === 'Conflict'; }
    get isMediaTab()     { return this.activeEvidenceTab === 'Media'; }

    // ── Co-pilot grounded summary (document + screening) + feedback ───────────
    // Screening signals folded into the AI summary so it captures BOTH the
    // document-level verdicts AND the screening-level results.
    get copilotScreening() {
        return this.screeningResults.map((r, i) => ({
            ...r, id: 'cs-' + i, pillClass: this._screenPill(r.status)
        }));
    }
    get hasScreeningSignals() { return this.screeningResults.length > 0; }
    get screeningSignalLabel() { return (this.screening && this.screening.signal) ? `signal: ${this.screening.signal}` : ''; }

    @track copilotNote = '';
    @track copilotSaving = false;
    handleCopilotNote(event) { this.copilotNote = event.target.value; }

    handleCopilotFeedback(event) {
        const decision = event.currentTarget.dataset.decision;  // 'accept' | 'override'
        if (!this.selectedSupplier || this.copilotSaving) return;
        this.copilotSaving = true;
        saveCopilotFeedback({
            accountId: this.selectedSupplier.id,
            decision,
            note: this.copilotNote
        })
            .then(() => {
                this.copilotSaving = false;
                this.copilotNote = '';
                this._toast('success', 'Feedback recorded',
                    decision === 'accept' ? 'AI summary accepted.' : 'Override captured for the learning loop.');
                if (this._wiredQueue) refreshApex(this._wiredQueue);
            })
            .catch(err => {
                this.copilotSaving = false;
                this._toast('error', 'Feedback failed', this._extractError(err));
            });
    }

    // ── S3 — Source document viewer ──────────────────────────────────────────
    @track caseDocuments = [];
    @track selectedDoc;           // { versionId, title, previewUrl, fileType }

    _loadCaseDocuments(id) {
        this.caseDocuments = [];
        this.selectedDoc = undefined;
        getCaseDocuments({ accountId: id })
            .then(docs => {
                this.caseDocuments = docs || [];
                if (this.caseDocuments.length) this.selectedDoc = this.caseDocuments[0];
            })
            .catch(err => console.error('[VendorPortal] doc load error:', JSON.stringify(err)));
    }

    get hasCaseDocuments() { return this.caseDocuments.length > 0; }
    get showSourceDocs() { return false; }   // preview panel removed per request
    get docRows() {
        return this.caseDocuments.map(d => ({
            ...d,
            rowClass: (this.selectedDoc && this.selectedDoc.versionId === d.versionId)
                ? 'vc-docfile selected' : 'vc-docfile'
        }));
    }
    handleSelectDoc(event) {
        const vid = event.currentTarget.dataset.vid;
        this.selectedDoc = this.caseDocuments.find(d => d.versionId === vid);
    }
    // Only PDFs/images render inline; other types (docx, txt, xlsx) can't be
    // embedded in a browser and the community download servlet errors in an iframe.
    get selectedDocPreviewable() {
        const t = (this.selectedDoc && this.selectedDoc.fileType || '').toUpperCase();
        return ['PDF', 'PNG', 'JPG', 'JPEG', 'GIF', 'TIFF', 'BMP', 'WEBP'].includes(t);
    }
    handleRefreshDocs() {
        if (this.selectedSupplier) this._loadCaseDocuments(this.selectedSupplier.id);
    }

    // ── Case data helpers ─────────────────────────────────────────────────────
    get _assessments() { return (this.caseSnapshot && this.caseSnapshot.assessments) || []; }
    get _domainLabelMap() {
        return this.riskDomains.reduce((m, d) => { m[d.key] = d.label; return m; }, {});
    }
    _domainOf(key) {
        if (!key) return '';
        const i = key.indexOf('__SCOPE_');
        return i >= 0 ? key.substring(i + 8) : '';
    }
    _titleCase(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : s; }
    _sevBadge(s) {
        if (s === 'Critical' || s === 'High') return 'vc-badge-high';
        if (s === 'Medium') return 'vc-badge-med';
        return 'vc-badge-low';
    }

    // ── S3 — Evidence + AI findings ──────────────────────────────────────────
    get evidenceItems() {
        return this._assessments.map(r => {
            const s = r.status;
            let label = 'requested', cls = 'vc-st-req';
            if (s === 'Compliant') { label = 'validated'; cls = 'vc-st-ok'; }
            else if (s === 'Non-Compliant' || s === 'At Risk') { label = 'issue'; cls = 'vc-st-mis'; }
            else if (s === 'Waived') { label = 'waived'; cls = 'vc-st-ok'; }
            return { id: r.assessmentId, name: r.requirementLabel, statusLabel: label, statusClass: cls };
        });
    }
    get hasEvidence()        { return this._assessments.length > 0; }
    get evidenceCountLabel() { return `${this._assessments.length} required`; }

    // Feed the embedded scDocumentUploader the case's required-document checklist.
    get hasCaseChecklist() { return this._assessments.length > 0; }
    get caseChecklistJson() {
        return JSON.stringify(this._assessments.map(a => {
            const uploaded = !!a.linkedDocumentId;
            const assessed = a.status && a.status !== 'Pending';
            return {
                assessmentId:     a.assessmentId,
                requirementKey:   a.requirementKey,
                requirementLabel: a.requirementLabel,
                documentType:     a.requirementLabel,   // doc-type hint passed to /assess
                severity:         a.severity,
                isMandatory:      a.severity !== 'Low',
                regulation:       a.sourceRegulation || '',
                // ── persisted upload + AI state (so a refresh restores it) ──
                complianceDocId:  a.linkedDocumentId,
                uploadStatus:     uploaded ? 'done' : 'pending',
                uploadedFiles:    a.linkedFileName ? [{ name: a.linkedFileName }] : [],
                aiStatus:         assessed ? 'complete' : (uploaded ? 'processing' : null),
                assessmentStatus: assessed ? (a.status === 'At Risk' ? 'Needs Human Review' : a.status) : null,
                reasonDetail:     a.reasonDetail
            };
        }));
    }

    get caseSummary() {
        if (this.caseLoading) return 'Loading case…';
        return (this.caseSnapshot && this.caseSnapshot.evaluationSummary)
            || 'Evaluation pending — no documents assessed yet.';
    }
    get caseScoreLabel() {
        return `${this.liveRiskScore} / 100`;
    }
    // Live risk score that ADJUSTS as documents are assessed + screening runs.
    get liveRiskScore() {
        const w = { Critical: 40, High: 25, Medium: 12, Low: 5 };
        let score = 0;
        this._assessments.forEach(r => {
            if (r.status === 'Non-Compliant') score += (w[r.severity] || 12);
            else if (r.status === 'Needs Human Review' || r.status === 'At Risk') score += Math.round((w[r.severity] || 12) / 2);
        });
        const sig = this.screening && this.screening.signal;
        if (sig === 'flag') score += 35; else if (sig === 'review') score += 15;
        const baseTier = (this.selectedSupplier && this.selectedSupplier.riskTier) || 'Medium';
        const base = { Critical: 85, High: 60, Medium: 35, Low: 10 }[baseTier] || 35;
        return Math.min(100, Math.max(score, base));
    }
    get liveTier() {
        const s = this.liveRiskScore;
        if (s >= 80) return 'CRITICAL';
        if (s >= 55) return 'HIGH';
        if (s >= 30) return 'MEDIUM';
        return 'LOW';
    }
    get liveTierBadge() { return this._tierBadge(this.liveTier.charAt(0) + this.liveTier.slice(1).toLowerCase()); }
    get riskBarStyle() {
        const s = this.liveRiskScore;
        const c = s >= 80 ? '#991B1B' : s >= 55 ? '#dc2626' : s >= 30 ? '#d97706' : '#16a34a';
        return `width:${s}%;background:${c};`;
    }
    get requirementsMetLabel() {
        const s = this.caseSnapshot;
        if (!s || s.totalRequirements == null) return 'no requirements yet';
        return `${s.requirementsMet || 0} / ${s.totalRequirements} satisfied`;
    }
    get caseFindings() {
        return this._assessments
            .filter(r => r.status === 'Non-Compliant' || r.status === 'At Risk')
            .map(r => ({
                id: r.assessmentId,
                label: r.requirementLabel,
                severity: (r.severity || 'MED').toUpperCase(),
                sevClass: this._sevBadge(r.severity) + ' vc-badge-xs',
                detail: r.reasonDetail || 'Flagged for analyst review.',
                domain: this._domainLabelMap[this._domainOf(r.requirementKey)] || this._domainOf(r.requirementKey),
                ...this._parseFinding(r.reasonDetail || '')
            }));
    }

    // Parse the grounded finding detail into highlightable parts (A3):
    // reason · extracted fields · expiry · clause PASS/FAIL chips · registry · citations.
    _parseFinding(detail) {
        const out = { reason: '', extracted: '', expiry: '', expired: false,
                      registry: '', registryClass: '', clauseChecks: [], citations: [],
                      hasClauseChecks: false, hasCitations: false };
        if (!detail) return out;
        out.reason = detail.split('\n\n')[0].replace(/^\[.*?\]\s*/, '');
        const cc = detail.match(/Clause checks:\n([\s\S]*?)(\n\n|$)/);
        if (cc) {
            out.clauseChecks = cc[1].split('\n').filter(Boolean).map((line, i) => {
                const pass = line.startsWith('[PASS]');
                return { id: 'cc' + i, text: line.replace(/^\[(PASS|FAIL)\]\s*/, ''),
                         chipClass: pass ? 'vc-cc-chip pass' : 'vc-cc-chip fail' };
            });
            out.hasClauseChecks = out.clauseChecks.length > 0;
        }
        const ci = detail.match(/Policy citations:\s*(.+)$/m);
        if (ci && ci[1].trim() !== 'none') {
            out.citations = ci[1].split(';').map(s => s.trim()).filter(Boolean)
                              .map((c, i) => ({ id: 'ci' + i, label: c }));
            out.hasCitations = out.citations.length > 0;
        }
        const ex = detail.match(/Expiry · (.+)/);
        if (ex) {
            out.expiry = ex[1].trim();
            out.expired = /EXPIRED/.test(ex[1]);
            out.expiryClass = out.expired ? 'vc-expiry-chip expired' : 'vc-expiry-chip ok';
        }
        const exf = detail.match(/Extracted · (.+)/);
        if (exf) out.extracted = exf[1].trim();
        const rg = detail.match(/Registry · (.+)/);
        if (rg) {
            out.registry = rg[1].trim();
            out.registryClass = /VERIFIED/.test(out.registry) ? 'vc-reg-pill ok'
                              : /(MANUAL|NOT_)/.test(out.registry) ? 'vc-reg-pill manual'
                              : 'vc-reg-pill';
        }
        return out;
    }
    get hasFindings()        { return this.caseFindings.length > 0; }
    get findingsCountLabel() { return `${this.caseFindings.length} flagged`; }

    // Document-level AI assessments (ALL assessed docs) — verdict + confidence.
    _verdictPill(s) {
        if (s === 'Compliant') return 'vc-screen-pill ok';
        if (s === 'Non-Compliant') return 'vc-screen-pill flag';
        return 'vc-screen-pill review';
    }
    get caseDocAssessments() {
        return this._assessments
            .filter(r => r.status && r.status !== 'Pending')
            .map(r => {
                const d = r.reasonDetail || '';
                const cm = d.match(/conf\s*(\d+)\s*%/);
                return {
                    id: r.assessmentId,
                    label: r.requirementLabel,
                    verdict: r.status,
                    verdictClass: this._verdictPill(r.status),
                    confidence: cm ? cm[1] + '%' : '—',
                    reason: (d.split('\n\n')[0] || '').replace(/^\[.*?\]\s*/, '') || 'Assessed.'
                };
            });
    }
    get hasDocAssessments()  { return this.caseDocAssessments.length > 0; }
    get docAssessCountLabel(){ return `${this.caseDocAssessments.length} assessed`; }

    // ── S4 — Risk domain cards (grouped from assessments) ─────────────────────
    get domainCards() {
        const by = {};
        this._assessments.forEach(r => {
            const d = this._domainOf(r.requirementKey) || 'general';
            if (!by[d]) by[d] = { key: d, total: 0, compliant: 0, failed: 0, pending: 0 };
            by[d].total++;
            if (r.status === 'Compliant') by[d].compliant++;
            else if (r.status === 'Non-Compliant' || r.status === 'At Risk') by[d].failed++;
            else by[d].pending++;
        });
        const labels = this._domainLabelMap;
        return Object.keys(by).map(k => {
            const c = by[k];
            const score = c.total ? Math.round((c.compliant / c.total) * 100) : 0;
            let tier, tierClass, statusLabel, statusClass, color;
            if (c.failed > 0)      { tier = 'HIGH'; tierClass = 'vc-badge-high'; statusLabel = 'Needs analyst'; statusClass = 'vc-st-ana'; color = '#ef4444'; }
            else if (c.pending > 0){ tier = 'MED';  tierClass = 'vc-badge-med';  statusLabel = 'Awaiting docs'; statusClass = 'vc-st-aw';  color = '#fbbf24'; }
            else                   { tier = 'LOW';  tierClass = 'vc-badge-low';  statusLabel = 'AI complete';   statusClass = 'vc-st-ai';  color = '#16a34a'; }
            return {
                key: c.key,
                label: labels[c.key] || this._titleCase(c.key),
                tier, tierClass, statusLabel, statusClass, score,
                tierSmClass: tierClass + ' vc-badge-sm',
                barStyle: `height:4px;border-radius:2px;background:${color};width:${score}%`,
                desc: `${c.compliant}/${c.total} requirements satisfied`
            };
        });
    }
    get hasDomainCards() { return this.domainCards.length > 0; }

    // ── S5 — Agent activity (Audit_Log run-log) ──────────────────────────────
    @track caseActivity = [];
    get hasActivity() { return this.caseActivity.length > 0; }

    // ── S6 — Decision: approve the AI summary, or route to the tier's approver ─
    get selectedApprover() {
        return ({ LOW: 'Auto-approve', MED: 'Sr. Compliance Approver', HIGH: 'Risk Committee + Legal' })[this.selectedRoute]
            || 'approver';
    }
    get isAutoApprove() { return this.selectedRoute === 'LOW'; }
    get decisionBtnLabel() {
        if (this.isSaving) return 'Saving…';
        return this.isAutoApprove ? '✓ Approve & onboard' : `Route to ${this.selectedApprover} →`;
    }
    get decisionHint() {
        return this.isAutoApprove
            ? 'Low risk — approving the AI summary onboards this supplier now.'
            : `${this.liveTier} risk — this routes to the ${this.selectedApprover} for sign-off.`;
    }

    // ── Approver mode: a case already routed (In Review) is being signed off ───
    get isApproverMode() { return !!(this.selectedSupplier && this.selectedSupplier.status === 'In Review'); }
    @track reviewComments = '';
    handleReviewComments(event) { this.reviewComments = event.target.value; }
    handleReviewOutcome(event) {
        const outcome = event.currentTarget.dataset.outcome;   // 'ready' | 'failed'
        if (!this.selectedSupplier || this.isSaving) return;
        this.isSaving = true;
        setReviewOutcome({ accountId: this.selectedSupplier.id, outcome, comments: this.reviewComments })
            .then(() => {
                this.isSaving = false;
                this._toast('success',
                    outcome === 'ready' ? 'Ready for Purchase' : 'Marked Failed',
                    outcome === 'ready'
                        ? `${this.caseName} reviewed — ready for purchase (Phase 2).`
                        : `${this.caseName} failed review.`);
                if (this._wiredQueue) refreshApex(this._wiredQueue);
                this.reviewComments = '';
                this._clearCase();
                this.goToS2();
            })
            .catch(err => { this.isSaving = false; this._toast('error', 'Update failed', this._extractError(err)); });
    }

    // ── Queue split: cases awaiting an approver vs the open intake queue ───────
    get reviewQueueRows() { return this.queueRows.filter(r => r.status === 'In Review'); }
    get openQueueRows()   { return this.queueRows.filter(r => r.status !== 'In Review'); }
    get hasReviewQueue()  { return this.reviewQueueRows.length > 0; }
    get reviewQueueCountLabel() { return `${this.reviewQueueRows.length} case(s)`; }

    handleSaveDecision() {
        if (this.isSaving) return;
        if (!this.selectedSupplier) {
            this._toast('warning', 'No supplier', 'Open a supplier case first.');
            return;
        }
        this.isSaving = true;
        saveDecision({
            accountId: this.selectedSupplier.id,
            tier:      this.confirmedTier,
            route:     this.selectedRoute,
            rationale: this.decisionRationale
        })
            .then(() => {
                this.isSaving = false;
                this._toast('success',
                    this.isAutoApprove ? 'Supplier onboarded' : 'Routed for review',
                    this.isAutoApprove
                        ? `${this.caseName} approved and onboarded.`
                        : `${this.caseName} routed to the ${this.selectedApprover}.`);
                if (this._wiredQueue) refreshApex(this._wiredQueue);
                // Procurement returns to the queue after deciding.
                this._clearCase();
                this.goToS2();
            })
            .catch(err => {
                this.isSaving = false;
                this._toast('error', 'Decision failed', this._extractError(err));
            });
    }

    // ── Pill / tab toggle (event delegation via bubbling) ────────────────────
    handlePillClick(event) {
        const pill = event.target.closest('.vc-pill');
        if (!pill) return;
        const container = pill.closest('.vc-tier-toggle')
            || pill.closest('.vc-hitl-row')
            || pill.closest('.vc-filter-row');
        if (container) {
            container.querySelectorAll('.vc-pill').forEach(p => p.classList.remove('active'));
            pill.classList.add('active');
        }
    }

    handleTabClick(event) {
        const tab = event.target.closest('.vc-tab');
        if (!tab) return;
        const row = tab.closest('.vc-tab-row');
        if (row) {
            row.querySelectorAll('.vc-tab').forEach(t => t.classList.remove('active'));
            tab.classList.add('active');
        }
    }

    // ── SCREEN 1 — Policy upload state ───────────────────────────────────────
    @track policyState      = 'idle';   // idle | generating | uploaded
    @track policyFileName   = '';
    @track checklistVisible = false;

    get policyZoneClass() {
        if (this.policyState === 'uploaded')   return 'vc-policy-zone uploaded';
        if (this.policyState === 'generating') return 'vc-policy-zone generating';
        return 'vc-policy-zone';
    }
    get policyIsIdle()      { return this.policyState === 'idle'; }
    get policyIsGenerating(){ return this.policyState === 'generating'; }
    get policyIsUploaded()  { return this.policyState === 'uploaded'; }

    handlePolicyZoneClick() {
        if (this.policyState !== 'idle') return;
        this.template.querySelector('.vc-policy-file-input').click();
    }
    handlePolicyBrowse() {
        this.template.querySelector('.vc-policy-file-input').click();
    }
    handlePolicyFileChange(event) {
        const file = event.target.files[0];
        if (!file) return;
        this.policyFileName = file.name;
        this.policyState    = 'generating';
        // Simulate AI generation delay
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.policyState    = 'uploaded';
            this.checklistVisible = true;
        }, 1200);
    }

    // ── SCREEN 1 — Checklist (generated by the AI /scope service) ─────────────
    @track checklistItems    = [];   // populated by Generate Checklist
    @track isGenerating      = false;
    @track checklistRiskTier = '';   // Low / Medium / High / Critical
    @track checklistSource   = '';   // 'existing' | 'ai'

    get enrichedChecklist() {
        return this.checklistItems.map(item => ({
            ...item,
            rowClass: item.done ? 'vc-ci done' : 'vc-ci',
        }));
    }

    get checklistSummary() {
        const n = this.checklistItems.length;
        const tier = this.checklistRiskTier ? `${this.checklistRiskTier} risk` : '';
        const src = this.checklistSource === 'existing' ? ' · reused from record' : '';
        return `${n} document${n === 1 ? '' : 's'} required${tier ? ' · ' + tier : ''}${src}`;
    }

    get hasChecklist() { return this.checklistItems.length > 0; }
    get generateBtnLabel() { return this.isGenerating ? 'Generating…' : 'Generate checklist'; }
    get showChecklistEmpty() { return !this.isGenerating && !this.checklistVisible; }

    handleChecklistUpload(event) {
        const id = parseInt(event.currentTarget.dataset.id, 10);
        this._markDone(id);
    }

    handleUploadAll() {
        const pending = this.checklistItems.filter(i => !i.done).map(i => i.id);
        pending.forEach((id, delay) => {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => this._markDone(id), delay * 120);
        });
    }

    _markDone(id) {
        this.checklistItems = this.checklistItems.map(item =>
            item.id === id ? { ...item, done: true } : item
        );
    }

    // Map a domain key to a small glyph for the checklist row
    _domainIcon(domainKey) {
        const map = {
            quality: '🏭', conflict: '⛏', material: '🧪', cyber: '🔐',
            trade: '🌐', finance: '📊', general: '📋'
        };
        return map[domainKey] || '📄';
    }

    // ── Generate Checklist — AI detects domains + required documents ──────────
    _missingIntakeFields() {
        const checks = [
            ['Legal entity name',       this.intakeName],
            ['Country / HQ',            this.intakeCountry],
            ['Requested by',            this.intakeRequestedBy],
            ['Industry',                this.intakeIndustry],
            ['Engagement type',         this.intakeEngagement],
            ['Annual spend',            this.intakeSpend],
            ['Supplier contact email',  this.intakeEmail]
        ];
        return checks.filter(([, v]) => !v || !String(v).trim()).map(([l]) => l);
    }

    handleGenerateChecklist() {
        if (this.isGenerating) return;
        const missing = this._missingIntakeFields();
        if (missing.length) {
            this._toast('warning', 'Complete all fields',
                'Generate checklist needs: ' + missing.join(', ') + '.');
            return;
        }
        this.isGenerating     = true;
        this.checklistVisible = false;
        generateChecklist({
            supplierName:   this.intakeName,
            country:        this.intakeCountry,
            industry:       this.intakeIndustry,
            engagementType: this.intakeEngagement,
            annualSpend:    this.intakeSpend,
            requestedBy:    this.intakeRequestedBy,
            supplierEmail:  this.intakeEmail
        })
            .then(result => {
                const items = (result && result.items) || [];
                if (!items.length) {
                    // Harden: never leave a silent no-op — surface and reset cleanly
                    this.isGenerating = false;
                    this.checklistVisible = false;
                    this._toast('warning', 'No documents identified',
                        'The compliance service returned no checklist. Check the supplier details or that the service is running, then try again.');
                    return;
                }
                // Scope domains = exactly the domains of the generated documents
                const hit = new Set(result.domains && result.domains.length
                    ? result.domains : items.map(i => i.domain));
                this.riskDomains = this.riskDomains.map(d => ({ ...d, selected: hit.has(d.key) }));

                this.checklistRiskTier = result.riskTier || '';
                // HITL threshold is AI-set by the backend (read-only) — not user-picked.
                this.hitlTier = ({ Low: 'LOW', Medium: 'MED', High: 'HIGH' })[result.recommendedHitl] || 'MED';
                this.checklistSource   = result.source || 'ai';
                this.checklistItems = items.map((it, idx) => ({
                    id:     idx,
                    icon:   this._domainIcon(it.domain),
                    name:   it.document,
                    src:    it.clauseId ? `clause ${it.clauseId}` : (it.domain || ''),
                    domain: it.domain,
                    done:   false
                }));
                this.checklistVisible = true;
                this.isGenerating = false;

                if (this.checklistSource === 'existing') {
                    this._toast('success', 'Existing checklist reused',
                        `Matched an existing supplier record — ${items.length} stored document(s).`);
                } else {
                    this._toast('success', 'Checklist generated',
                        `${items.length} required document(s) identified.`);
                }
            })
            .catch(err => {
                this.isGenerating = false;
                this.checklistVisible = false;
                this._toast('error', 'Generation failed', this._extractError(err));
            });
    }

    // ── Request to supplier — persist + email the document list ───────────────
    handleRequestToSupplier() {
        if (this.isSaving) return;
        if (!this.intakeName) {
            this._toast('warning', 'Required', 'Enter the supplier legal entity name first.');
            return;
        }
        if (!this.intakeEmail) {
            this._toast('warning', 'Required', 'Enter the supplier contact email to send the request.');
            return;
        }
        if (!this._validateEmail(this.intakeEmail)) {
            this.emailError = 'Enter a valid email address (e.g. name@company.com).';
            this._toast('warning', 'Invalid email', this.emailError);
            return;
        }
        if (!this.checklistItems.length) {
            this._toast('warning', 'No checklist', 'Generate the checklist before requesting documents.');
            return;
        }
        this.isSaving = true;
        requestDocuments({
            accountId:      this._savedAccountId,
            supplierName:   this.intakeName,
            country:        this.intakeCountry,
            requestedBy:    this.intakeRequestedBy,
            industry:       this.intakeIndustry,
            engagementType: this.intakeEngagement,
            annualSpend:    this.intakeSpend,
            riskDomains:    this.riskDomains.filter(d => d.selected).map(d => d.key).join(', '),
            supplierEmail:  this.intakeEmail,
            hitlThreshold:  this.hitlThresholdValue,
            documents:      this.checklistItems.map(i => i.name)
        })
            .then(id => {
                this._savedAccountId = id;
                this.isSaving = false;
                this._toast('success', 'Request sent',
                    `Document request emailed to ${this.intakeEmail}.`);
            })
            .catch(err => {
                this.isSaving = false;
                this._toast('error', 'Request failed', this._extractError(err));
            });
    }

    // ── SCREEN 1 — HITL threshold (AI-set by the backend, read-only) ──────────
    @track hitlTier = 'MED';

    // Read-only display value + badge style for the AI-set threshold.
    get hitlBadgeClass() {
        return ({ LOW: 'vc-hitl-badge low', MED: 'vc-hitl-badge med', HIGH: 'vc-hitl-badge high' })[this.hitlTier]
            || 'vc-hitl-badge med';
    }
    // Plain-language basis — ties the threshold to the detected risk tier (same
    // tier shown on the Risk Domains screen), so it reads consistently.
    get hitlExplain() {
        const t = this.checklistRiskTier || 'detected';
        return `Set by the AI from the ${t} risk tier. Cases above ${this.hitlThresholdValue} route to a compliance analyst; at or below auto-proceed.`;
    }
    get routingShort() { return this._routesToAnalyst ? 'routes to analyst' : 'auto-proceeds'; }

    // ── HITL routing gate ─────────────────────────────────────────────────────
    _tierRank(t) { return ({ Critical: 4, High: 3, Medium: 2, Low: 1 })[t] || 0; }

    // Map the UI button value (LOW/MED/HIGH) to the stored picklist value
    get hitlThresholdValue() {
        return ({ LOW: 'Low', MED: 'Medium', HIGH: 'High' })[this.hitlTier] || 'Medium';
    }

    get hasRoutingHint() { return !!this.checklistRiskTier; }

    get _routesToAnalyst() {
        return this._tierRank(this.checklistRiskTier) > this._tierRank(this.hitlThresholdValue);
    }

    get routingHint() {
        if (!this.checklistRiskTier) return '';
        const risk = this.checklistRiskTier;
        if (this._routesToAnalyst) {
            return `Detected tier ${risk} is above your ${this.hitlTier} threshold → routes to an analyst before approval.`;
        }
        return `Detected tier ${risk} is at or below your ${this.hitlTier} threshold → can auto-proceed.`;
    }

    get routingHintClass() {
        return this._routesToAnalyst ? 'vc-route-hint analyst' : 'vc-route-hint auto';
    }

    // ── SCREEN 1 — Intake form fields ─────────────────────────────────────────
    @track intakeName        = '';
    @track intakeCountry     = '';
    @track intakeRequestedBy = '';
    @track intakeIndustry    = '';
    @track intakeEngagement  = '';
    @track intakeSpend       = '';
    @track intakeEmail       = '';
    @track emailError        = '';
    @track isSaving          = false;
    _savedAccountId          = null;  // persists after first save; passed on updates

    // Populated from the Compliance_Domain__mdt catalog (config, not code).
    // Each item: { key, label, description, authority, selected }.
    @track riskDomains = [];

    @wire(getDomainCatalog)
    wiredDomainCatalog({ data, error }) {
        if (data) {
            this.riskDomains = data.map(d => ({
                key:         d.key,
                label:       d.label,
                description: d.description,
                authority:   d.authority,
                // Pre-select from the catalog default until /scope auto-detects
                // and writes Account.Risk_Domains__c for a saved supplier.
                selected:    !!d.defaultSelected
            }));
        } else if (error) {
            console.error('[VendorPortal] Could not load domain catalog:', JSON.stringify(error));
            this._toast('error', 'Domain catalog', this._extractError(error));
        }
    }

    get saveDraftLabel() { return this.isSaving ? 'Saving…' : 'Save draft'; }

    // Scope & risk domains are AI-determined and READ-ONLY — after generation
    // they show exactly the domains of the generated checklist (they must match
    // the documents we ask for).
    get scopeDomains() {
        // Domains are derived from the generated checklist — show nothing (the
        // hint) until Generate Checklist has run, then exactly the matched domains.
        if (!this.checklistVisible) return [];
        return this.riskDomains
            .filter(d => d.selected)
            .map(d => ({ ...d, tagClass: 'vc-tag-dark' }));
    }
    get hasScopeDomains() { return this.scopeDomains.length > 0; }

    // "What happens next" — the real verification pipeline this supplier will go
    // through, derived from its scoped domains (creative but grounded in what the
    // backend actually does per domain).
    get nextSteps() {
        const MAP = {
            trade:    { icon: '🌐', text: 'Screen the entity and its owners against OFAC SDN, EU & UK sanctions and adverse-media sources' },
            finance:  { icon: '📊', text: 'Verify the Legal Entity Identifier (LEI) via GLEIF and assess financial health (audited statements)' },
            conflict: { icon: '⛏',  text: 'Cross-check declared smelters/refiners against the RMI conformant-smelter list (DRC/CAHRA exposure)' },
            material: { icon: '🧪', text: 'Scan the SDS for banned CAS substances and validate REACH / RoHS declarations' },
            quality:  { icon: '🏭', text: 'Validate the IATF 16949 / ISO 9001 certificate against the issuing registrar' },
            cyber:    { icon: '🔐', text: 'Route the SOC 2 / TISAX report to a security analyst for scope review' },
            general:  { icon: '📋', text: 'Issue the Supplier Self-Assessment Questionnaire and collect baseline insurance (COI)' }
        };
        const steps = this.riskDomains
            .filter(d => d.selected && MAP[d.key])
            .map((d, i) => ({ id: 'ns-' + i, icon: MAP[d.key].icon, text: MAP[d.key].text }));
        // Always-on tail: synthesis + the HITL routing decision
        steps.push({
            id: 'ns-route', icon: '🧭',
            text: `Draft a risk summary, then ${this._routesToAnalyst ? 'route to a compliance analyst' : 'auto-approve'} per your ${this.hitlTier} threshold`
        });
        return steps;
    }
    get hasNextSteps() { return this.checklistVisible; }

    handleIntakeField(event) {
        const field = event.currentTarget.dataset.field;
        const val   = event.target.value;
        this[field] = val;
        if (field === 'intakeEmail') {
            this.emailError = val && !this._validateEmail(val)
                ? 'Enter a valid email address (e.g. name@company.com).'
                : '';
        }
    }

    // Country dropdown
    get countryOptions() {
        return COUNTRIES.map(v => ({ value: v, selected: v === this.intakeCountry }));
    }
    get isCountryEmpty() { return !this.intakeCountry; }

    // Engagement type dropdown (Account.Engagement_Type__c picklist)
    get engagementOptions() {
        return ENGAGEMENT_TYPES.map(v => ({ value: v, selected: v === this.intakeEngagement }));
    }
    get isEngagementEmpty() { return !this.intakeEngagement; }

    get hasEmailError() { return !!this.emailError; }

    _validateEmail(email) {
        return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email);
    }

    _intakePayload() {
        return {
            accountId:      this._savedAccountId,
            supplierName:   this.intakeName,
            country:        this.intakeCountry,
            requestedBy:    this.intakeRequestedBy,
            industry:       this.intakeIndustry,
            engagementType: this.intakeEngagement,
            annualSpend:    this.intakeSpend,
            supplierEmail:  this.intakeEmail,
            hitlThreshold:  this.hitlThresholdValue,
            // Persist domain KEYS (not labels) so Risk_Domains__c stays aligned
            // with /scope output and the Python RAG corpus slugs.
            riskDomains:    this.riskDomains.filter(d => d.selected).map(d => d.key).join(', ')
        };
    }

    handleSaveDraft() {
        if (this.isSaving) return;
        if (!this.intakeName) {
            this._toast('warning', 'Required', 'Please enter the supplier legal entity name.');
            return;
        }
        const payload = this._intakePayload();
        console.log('[VendorPortal] saveDraft payload:', JSON.stringify(payload));
        this.isSaving = true;
        saveDraft(payload)
            .then(id => {
                console.log('[VendorPortal] Draft saved with ID:', id);
                this._savedAccountId = id;
                this.isSaving = false;
                this._toast('success', 'Saved as draft', `Supplier record ${this._savedAccountId ? 'updated' : 'created'} (${id})`);
            })
            .catch(err => {
                console.error('[VendorPortal] saveDraft error:', JSON.stringify(err));
                this.isSaving = false;
                this._toast('error', 'Save failed', this._extractError(err));
            });
    }

    handleSubmitForReview() {
        if (this.isSaving) return;
        if (!this.intakeName) {
            this._toast('warning', 'Required', 'Please enter the supplier legal entity name.');
            return;
        }
        if (!this.intakeEmail) {
            this._toast('warning', 'Required', 'Please enter the supplier contact email.');
            return;
        }
        if (!this._validateEmail(this.intakeEmail)) {
            this.emailError = 'Enter a valid email address (e.g. name@company.com).';
            this._toast('warning', 'Invalid email', this.emailError);
            return;
        }
        const payload = this._intakePayload();
        console.log('[VendorPortal] submitForReview payload:', JSON.stringify(payload));
        this.isSaving = true;
        submitForReview(payload)
            .then(id => {
                console.log('[VendorPortal] Submitted, Account ID:', id);
                this._savedAccountId = id;
                this.isSaving = false;
                this._toast('success', 'Submitted', 'Supplier queued for AI review.');
                if (this._wiredQueue) refreshApex(this._wiredQueue);
                this.goToS2();
            })
            .catch(err => {
                console.error('[VendorPortal] submitForReview error:', JSON.stringify(err));
                this.isSaving = false;
                this._toast('error', 'Submit failed', this._extractError(err));
            });
    }

    _toast(variant, title, message) {
        Toast.show({ label: title, message, variant, mode: 'dismissible' }, this);
    }

    _extractError(err) {
        return err?.body?.message || err?.message || 'An unexpected error occurred.';
    }

    // ── SCREEN 3 — Override tier ──────────────────────────────────────────────
    @track overrideTier = 'MED';

    get ovLowClass()  { return this.overrideTier === 'LOW'  ? 'vc-pill active' : 'vc-pill'; }
    get ovMedClass()  { return this.overrideTier === 'MED'  ? 'vc-pill active' : 'vc-pill'; }
    get ovHighClass() { return this.overrideTier === 'HIGH' ? 'vc-pill active' : 'vc-pill'; }

    handleOverrideTier(event) {
        this.overrideTier = event.currentTarget.dataset.tier;
    }

    // ── SCREEN 4 — Set tier ───────────────────────────────────────────────────
    @track s4Tier = 'MED';

    get s4LowClass()  { return this.s4Tier === 'LOW'  ? 'vc-pill active' : 'vc-pill'; }
    get s4MedClass()  { return this.s4Tier === 'MED'  ? 'vc-pill active' : 'vc-pill'; }
    get s4HighClass() { return this.s4Tier === 'HIGH' ? 'vc-pill active' : 'vc-pill'; }

    handleS4Tier(event) {
        this.s4Tier = event.currentTarget.dataset.tier;
    }

    // ── SCREEN 6 — Confirm risk tier ─────────────────────────────────────────
    @track confirmedTier = 'MED';

    get tcLowClass()  { return this.confirmedTier === 'LOW'  ? 'vc-tc selected' : 'vc-tc'; }
    get tcMedClass()  { return this.confirmedTier === 'MED'  ? 'vc-tc selected' : 'vc-tc'; }
    get tcHighClass() { return this.confirmedTier === 'HIGH' ? 'vc-tc selected' : 'vc-tc'; }

    get isRecLow()  { return this._tierToCode(this.liveTier) === 'LOW'; }
    get isRecMed()  { return this._tierToCode(this.liveTier) === 'MED'; }
    get isRecHigh() { return this._tierToCode(this.liveTier) === 'HIGH'; }

    get tcLowRadio()  { return this.confirmedTier === 'LOW'  ? 'vc-tc-radio checked' : 'vc-tc-radio'; }
    get tcMedRadio()  { return this.confirmedTier === 'MED'  ? 'vc-tc-radio checked' : 'vc-tc-radio'; }
    get tcHighRadio() { return this.confirmedTier === 'HIGH' ? 'vc-tc-radio checked' : 'vc-tc-radio'; }

    handleConfirmTier(event) {
        this.confirmedTier = event.currentTarget.dataset.tier;
    }

    // ── SCREEN 6 — Routing selection ─────────────────────────────────────────
    @track selectedRoute = 'MED';

    get routeLowClass()  { return this.selectedRoute === 'LOW'  ? 'vc-route-opt selected' : 'vc-route-opt'; }
    get routeMedClass()  { return this.selectedRoute === 'MED'  ? 'vc-route-opt selected' : 'vc-route-opt'; }
    get routeHighClass() { return this.selectedRoute === 'HIGH' ? 'vc-route-opt selected' : 'vc-route-opt'; }

    get showLowSel()  { return this.selectedRoute === 'LOW'; }
    get showMedSel()  { return this.selectedRoute === 'MED'; }
    get showHighSel() { return this.selectedRoute === 'HIGH'; }

    handleSelectRoute(event) {
        this.selectedRoute = event.currentTarget.dataset.route;
    }

    // ── SCREEN 6 — Mitigations (AI-derived from findings + screening) ─────────
    @track mitigations = [];
    @track newMitigation = '';

    _tierToCode(t) {
        const u = (t || '').toUpperCase();
        if (u === 'CRITICAL' || u === 'HIGH') return 'HIGH';
        if (u === 'LOW') return 'LOW';
        return 'MED';
    }
    // Mitigations that track the actual risk: one per failing requirement + a
    // screening item when flagged + a baseline re-screen.
    _suggestMitigations() {
        const out = [];
        let i = 0;
        this._assessments
            .filter(r => r.status === 'Non-Compliant' || r.status === 'At Risk' || r.status === 'Needs Human Review')
            .forEach(r => out.push({ id: 'f' + (i++), label: 'Remediate: ' + r.requirementLabel }));
        const sig = this.screening && this.screening.signal;
        if (sig === 'flag') out.push({ id: 'scr', label: 'Sanctions / adverse-media analyst review' });
        out.push({ id: 'base', label: 'Annual re-screen' });
        return out;
    }
    handleNewMitigation(event) { this.newMitigation = event.target.value; }
    handleMitKey(event) { if (event.key === 'Enter') this.handleAddMitigation(); }
    handleAddMitigation() {
        const t = (this.newMitigation || '').trim();
        if (!t) return;
        this.mitigations = [...this.mitigations, { id: 'u' + Date.now(), label: t }];
        this.newMitigation = '';
    }
    handleRemoveMitigation(event) {
        const id = event.currentTarget.dataset.id;
        this.mitigations = this.mitigations.filter(m => String(m.id) !== String(id));
    }

    // ── SCREEN 3 — Evidence tab ───────────────────────────────────────────────
    @track activeEvidenceTab = 'Documents';
    get evDocActive()  { return this.activeEvidenceTab === 'Documents'  ? 'vc-tab active' : 'vc-tab'; }
    get evSanActive()  { return this.activeEvidenceTab === 'Sanctions'  ? 'vc-tab active' : 'vc-tab'; }
    get evFinActive()  { return this.activeEvidenceTab === 'Financials' ? 'vc-tab active' : 'vc-tab'; }
    get evConflictActive() { return this.activeEvidenceTab === 'Conflict' ? 'vc-tab active' : 'vc-tab'; }
    get evMedActive()  { return this.activeEvidenceTab === 'Media'      ? 'vc-tab active' : 'vc-tab'; }

    handleEvidenceTab(event) {
        this.activeEvidenceTab = event.currentTarget.dataset.tab;
    }

    // ── Stepper — one set of getters drives all 4 stepper instances ─────────
    _sn()  { return parseInt(this.activeScreen.replace('s', ''), 10); }
    _sc(n) { const s = this._sn(); return n < s ? 'vc-step-circle done' : n === s ? 'vc-step-circle current' : 'vc-step-circle'; }
    _sl(n) { return n === this._sn() ? 'vc-step-label current' : 'vc-step-label'; }
    _sv(n) { return n < this._sn() ? '✓' : String(n); }

    get step1c() { return this._sc(1); } get step1l() { return this._sl(1); } get step1v() { return this._sv(1); }
    get step2c() { return this._sc(2); } get step2l() { return this._sl(2); } get step2v() { return this._sv(2); }
    get step3c() { return this._sc(3); } get step3l() { return this._sl(3); } get step3v() { return this._sv(3); }
    get step4c() { return this._sc(4); } get step4l() { return this._sl(4); } get step4v() { return this._sv(4); }
    get step5c() { return this._sc(5); } get step5l() { return this._sl(5); } get step5v() { return this._sv(5); }
    get step6c() { return this._sc(6); } get step6l() { return this._sl(6); } get step6v() { return this._sv(6); }

    // ── Footer visibility per screen ──────────────────────────────────────────
    get footerIsS1() { return this.activeScreen === 's1'; }
    get footerIsS2() { return this.activeScreen === 's2'; }
    get footerIsS3() { return this.activeScreen === 's3'; }
    get footerIsS4() { return this.activeScreen === 's4'; }
    get footerIsS5() { return this.activeScreen === 's5'; }
    get footerIsS6() { return this.activeScreen === 's6'; }

    // ── Convenience nav handlers (footer buttons need named methods) ──────────
    goToS1() { this._clearCase(); this.activeScreen = 's1'; this.breadcrumb = BREADCRUMBS.s1; }
    goToS2() { this._clearCase(); this.activeScreen = 's2'; this.breadcrumb = BREADCRUMBS.s2; }
    goToS6() { this.activeScreen = 's6'; this.breadcrumb = BREADCRUMBS.s6; }
}