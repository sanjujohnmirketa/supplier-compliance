import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import complianceLogo from '@salesforce/resourceUrl/complianceLogo';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import userId from '@salesforce/user/Id';
import FIRSTNAME_FIELD from '@salesforce/schema/User.FirstName';
import LASTNAME_FIELD from '@salesforce/schema/User.LastName';
import getScreeningQueue from '@salesforce/apex/VendorPortalController.getScreeningQueue';
import generateChecklist from '@salesforce/apex/VendorPortalController.generateChecklist';
import getSupplierSnapshot from '@salesforce/apex/VendorPortalController.getSupplierSnapshot';
import askCopilot from '@salesforce/apex/VendorPortalController.askCopilot';
import runScreeningAndPersist from '@salesforce/apex/VendorPortalController.runScreeningAndPersist';
import requestDocumentsFromSupplier from '@salesforce/apex/VendorPortalController.requestDocumentsFromSupplier';
import submitAndScreen from '@salesforce/apex/VendorPortalController.submitAndScreen';
import getAnalystUsers from '@salesforce/apex/VendorPortalController.getAnalystUsers';
import assignToAnalyst from '@salesforce/apex/VendorPortalController.assignToAnalyst';
import saveFile from '@salesforce/apex/DocumentProcessingController.saveFile';
import linkDocumentToCompliance from '@salesforce/apex/DocumentProcessingController.linkDocumentToCompliance';
import removeSupplierDocument from '@salesforce/apex/VendorPortalController.removeSupplierDocument';
import addRequirementFromDocument from '@salesforce/apex/VendorPortalController.addRequirementFromDocument';
import generatePublicDocumentUrl from '@salesforce/apex/VendorPortalController.generatePublicDocumentUrl';

/**
 * scProcurementConsole — Procurement (Team Member · "Executor") workspace.
 *
 * Three screens from the Pre-contract wireframes:
 *   P1  New supplier      — intake + AI checklist + human-oversight level
 *   P2  Supplier queue    — in-review / drafts / awaiting docs / handed-to-analyst
 *   P3  Documents & screening — bulk upload + AI auto-match + run screening → handoff
 *
 * SKELETON PASS: layout + navigation + empty/placeholder states. New
 * interactions (oversight slider, doc auto-match, hand-to-analyst) are
 * placeholders pending backend glue (B1, B2, B4, B6). No mock demo data —
 * empty tables and disabled controls with "wired later" notes.
 */

const BREADCRUMBS = {
    p1: '/New supplier',
    p2: '/Supplier queue',
    p3: '/Supplier queue / Documents & screening',
    p4: '/Supplier queue / Submission summary'
};

// Country list
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

// Engagement type taxonomy — mirrors Account.Engagement_Type__c picklist.
const ENGAGEMENT_TYPES = [
    'Direct Material - Production (Tier 1)',
    'Direct Material - Production (Tier 2)',
    'Indirect / Non-production (MRO)',
    'Raw Materials / Commodities',
    'Services / Consulting',
    'Logistics / Distribution',
    'Capital Equipment / Tooling'
];

// Industry taxonomy — restricted to industries the policy corpus grounds
// DETERMINISTICALLY (they return industry-specific compliance domains, not just
// the general baseline). Aerospace & Defense and Food & Beverage are omitted
// until the corpus has matching policies (they currently fall to baseline-only).
const INDUSTRIES = [
    'Automotive',
    'Pharmaceutical',
    'Medical Devices',
    'Electronics / Semiconductors',
    'Chemicals',
    'Industrial Equipment',
    'Energy / Utilities',
    'Logistics & Distribution',
    'Other'
];

// Optional fine-tuning inputs (procurement feedback: sharpen which compliance
// domains apply beyond what Industry + Engagement Type alone imply). Values
// MUST match app.py's MATERIAL_TYPE_DOMAINS / SERVICE_CATEGORY_DOMAINS keys
// exactly — engine does an exact-match lookup, not substring/fuzzy.
const MATERIAL_TYPES = [
    'conflict-mineral-bearing metals',
    'chemicals',
    'electronics components',
    'packaging',
    'textiles'
];

const SERVICE_CATEGORIES = [
    'logistics',
    'it/software',
    'professional services',
    'manufacturing-subcontract'
];

export default class ScProcurementConsole extends NavigationMixin(LightningElement) {

    logoUrl = complianceLogo;

    // ── Logged-in user ────────────────────────────────────────────────────────
    _userInitials = '??';
    _userName = '';
    @track _showUserMenu = false;

    @wire(getRecord, { recordId: userId, fields: [FIRSTNAME_FIELD, LASTNAME_FIELD] })
    wiredUser({ data, error }) {
        if (data) {
            const first = getFieldValue(data, FIRSTNAME_FIELD) || '';
            const last = getFieldValue(data, LASTNAME_FIELD) || '';
            this._userInitials = (first.charAt(0) + last.charAt(0)).toUpperCase() || '??';
            this._userName = `${first} ${last}`.trim();
        } else if (error) {
            // eslint-disable-next-line no-console
            console.error('[Procurement] Could not load user:', error);
        }
    }

    get userInitials() { return this._userInitials; }
    get userName() { return this._userName; }
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
    @track activeScreen = 'p1';
    @track breadcrumb = BREADCRUMBS.p1;

    get isP1() { return this.activeScreen === 'p1'; }
    get isP2() { return this.activeScreen === 'p2'; }
    get isP3() { return this.activeScreen === 'p3'; }
    get isP4() { return this.activeScreen === 'p4'; }

    // Sidebar shows only two tabs now. When P3 is open it's a sub-context of the
    // queue, so the "Supplier queue" tab stays highlighted.
    get sbP1Active() { return this.activeScreen === 'p1' ? 'vc-sb-item active' : 'vc-sb-item'; }
    get sbP2Active() { return (this.activeScreen === 'p2' || this.activeScreen === 'p3') ? 'vc-sb-item active' : 'vc-sb-item'; }

    get dotP1() { return this.activeScreen === 'p1' ? 'vc-sb-dot curr' : 'vc-sb-dot'; }
    get dotP2() { return (this.activeScreen === 'p2' || this.activeScreen === 'p3') ? 'vc-sb-dot curr' : 'vc-sb-dot'; }

    get showSearch() { return this.activeScreen === 'p2'; }

    handleNav(event) {
        const sid = event.currentTarget.dataset.screen;
        if (!sid || !BREADCRUMBS[sid]) return;
        this.activeScreen = sid;
        this.breadcrumb = BREADCRUMBS[sid];
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const main = this.template.querySelector('.vc-main');
            if (main) main.scrollTop = 0;
        }, 0);
    }

    // ── P1 — intake form (skeleton: local state, not yet persisted) ────────────
    @track intakeName = '';
    @track intakeCountry = '';
    @track intakeIndustry = '';
    @track intakeEngagement = '';
    @track intakeSpend = '';
    @track intakeRequestedBy = '';
    @track intakeEmail = '';
    @track emailError = '';
    // Optional fine-tuning — sharpens which compliance domains /scope selects
    // beyond Industry + Engagement Type alone. Blank is a valid, complete state.
    @track intakeMaterialType = '';
    @track intakeServiceCategory = '';

    get countryOptions() {
        return COUNTRIES.map((value) => ({ value, selected: value === this.intakeCountry }));
    }
    get isCountryEmpty() { return !this.intakeCountry; }

    get engagementOptions() {
        return ENGAGEMENT_TYPES.map((value) => ({ value, selected: value === this.intakeEngagement }));
    }
    get isEngagementEmpty() { return !this.intakeEngagement; }

    get industryOptions() {
        return INDUSTRIES.map((value) => ({ value, selected: value === this.intakeIndustry }));
    }
    get isIndustryEmpty() { return !this.intakeIndustry; }

    get materialTypeOptions() {
        return [{ value: '', label: 'None / not applicable', selected: !this.intakeMaterialType }].concat(
            MATERIAL_TYPES.map((value) => ({ value, label: value, selected: value === this.intakeMaterialType }))
        );
    }
    get serviceCategoryOptions() {
        return [{ value: '', label: 'None / not applicable', selected: !this.intakeServiceCategory }].concat(
            SERVICE_CATEGORIES.map((value) => ({ value, label: value, selected: value === this.intakeServiceCategory }))
        );
    }

    get hasEmailError() { return !!this.emailError; }

    handleIntakeField(event) {
        const field = event.currentTarget.dataset.field;
        const val   = event.target.value;
        if (field) this[field] = val;
        if (field === 'intakeEmail') {
            this.emailError = val && !this._isValidEmail(val)
                ? 'Enter a valid email address (e.g. name@company.com).'
                : '';
        }
        // If the checklist was already generated and a driving input changed,
        // flag it stale so the user knows to regenerate.
        this._markChecklistStaleIfChanged();
    }

    // ── Human oversight (HITL) — AI-SET, READ-ONLY ────────────────────────────
    // The oversight level is no longer user-adjustable. It's derived from the
    // AI risk tier when the checklist is generated (recommendedHitl), matching
    // the rule that HITL is backend-set and tied to the risk tier. The slider is
    // rendered disabled purely as a visual indicator of where AI placed it.
    // Defaults to MINIMUM (auto-clear / low) until AI sets it from the risk tier.
    @track oversightLevel = 0; // 0 = Auto-clear … 100 = Full review (AI-set)

    // Map the AI tier → a slider position + label so the read-only bar reflects it.
    _applyAiOversight(tier) {
        const t = (tier || '').toLowerCase();
        if (t === 'high')        this.oversightLevel = 92;
        else if (t === 'medium') this.oversightLevel = 60;
        else if (t === 'low')    this.oversightLevel = 18;
        else                     this.oversightLevel = 0;   // no data → minimum
    }
    get oversightLabel() {
        const v = this.oversightLevel;
        if (v >= 80) return 'Full analyst review';
        if (v >= 45) return 'Partial review';
        return 'Auto-clear eligible';
    }
    // Drive the read-only indicator explicitly so position ALWAYS matches the
    // value (a disabled native <input type=range> defaults its thumb to the
    // midpoint, which read as "Medium" even when the value was 0/low).
    get oversightFillStyle() { return `width:${this.oversightLevel}%;`; }
    get oversightThumbStyle() { return `left:${this.oversightLevel}%;`; }

    // ── Checklist generation (reuses VendorPortalController.generateChecklist) ──
    @track checklistItems = [];
    @track checklistDomains = [];
    @track checklistTier = '';
    @track recommendedHitl = '';
    @track checklistLoading = false;
    @track checklistVisible = false;
    @track riskReasons = [];        // why this tier (bullets)
    @track checklistNotes = [];     // e.g. no-policy-match explanation
    @track noPolicyMatch = false;
    @track checklistStale = false;  // inputs changed since last generate
    _checklistSignature = '';
    get hasChecklist() { return this.checklistVisible && (this.checklistItems.length > 0 || this.noPolicyMatch); }
    get hasDomains() { return this.checklistDomains.length > 0; }
    get hasRiskReasons() { return this.riskReasons.length > 0; }
    get hasChecklistNotes() { return this.checklistNotes.length > 0; }
    // Button labels swap to a working state while the callout runs (spinner UI).
    get generateLabel() { return this.checklistLoading ? 'Generating…' : 'Generate checklist'; }
    get regenerateLabel() { return this.checklistLoading ? 'Generating…' : 'Regenerate'; }

    // Email format validation — block a malformed address before any "prepared".
    _isValidEmail(email) {
        return typeof email === 'string' && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim());
    }

    // A signature of the inputs that drive the checklist — change → stale.
    _intakeSignature() {
        return [this.intakeName, this.intakeCountry, this.intakeIndustry,
                this.intakeEngagement, this.intakeSpend,
                this.intakeMaterialType, this.intakeServiceCategory].join('|');
    }
    _markChecklistStaleIfChanged() {
        if (this.checklistVisible && this._intakeSignature() !== this._checklistSignature) {
            // Flag stale so the "Regenerate" banner appears — the user clicks it
            // to re-evaluate (no automatic regeneration).
            this.checklistStale = true;
        }
    }

    handleGenerateChecklist() {
        // Apex generateChecklist requires the full intake context (all 7 fields)
        // or it rejects — partial input makes /scope retrieval non-deterministic.
        const missing = [];
        if (!this.intakeName)       missing.push('Legal entity name');
        if (!this.intakeCountry)    missing.push('Country / HQ');
        if (!this.intakeIndustry)   missing.push('Industry');
        if (!this.intakeEngagement) missing.push('Engagement type');
        if (!this.intakeSpend)      missing.push('Annual spend');
        if (!this.intakeEmail)      missing.push('Supplier email');
        if (missing.length) {
            this._toast('warning', 'Complete the supplier profile', `Required: ${missing.join(', ')}.`);
            return;
        }
        if (!this._isValidEmail(this.intakeEmail)) {
            this._toast('warning', 'Invalid email', 'Enter a valid supplier email address (e.g. name@company.com).');
            return;
        }
        this.checklistLoading = true;
        generateChecklist({
            supplierName:    this.intakeName,
            country:         this.intakeCountry,
            industry:        this.intakeIndustry,
            engagementType:  this.intakeEngagement,
            annualSpend:     this.intakeSpend,
            requestedBy:     this._userName || 'Procurement',
            supplierEmail:   this.intakeEmail,
            materialType:    this.intakeMaterialType || null,
            serviceCategory: this.intakeServiceCategory || null
        })
            .then(res => {
                this.checklistLoading = false;
                this.checklistTier = res.riskTier || '';
                this.recommendedHitl = res.recommendedHitl || '';
                this._applyAiOversight(res.riskTier);   // HITL is AI-set from the tier
                this.checklistDomains = (res.domains || []).map((d, i) => ({ id: 'd' + i, label: d }));
                this.checklistItems = (res.items || []).map((it, i) => ({
                    id: 'c' + i, document: it.document, domain: it.domain || ''
                }));
                // Reasoning behind the tier + any no-policy-match explanation.
                this.riskReasons = (res.riskReasons || []).map((r, i) => ({ id: 'rr' + i, text: r }));
                this.checklistNotes = (res.notes || []).map((n, i) => ({ id: 'cn' + i, text: n }));
                this.noPolicyMatch = res.noPolicyMatch === true;
                this.checklistVisible = true;
                // Snapshot the inputs this checklist was generated from, so we can
                // tell the user it's stale when they change something.
                this._checklistSignature = this._intakeSignature();
                this.checklistStale = false;
                this._toast('success', 'Checklist ready', `${this.checklistItems.length} document(s) · ${this.checklistTier} risk`);
            })
            .catch(err => {
                this.checklistLoading = false;
                this._toast('error', 'Generation failed', (err && err.body && err.body.message) || 'Could not generate checklist.');
            });
    }

    @track emailSending = false;
    get emailLabel() { return this.emailSending ? 'Sending…' : '✉ Email supplier to request documents'; }

    handleEmailSupplier() {
        if (!this.hasChecklist) {
            this._toast('warning', 'Generate first', 'Generate the checklist before requesting documents.');
            return;
        }
        if (!this._isValidEmail(this.intakeEmail)) {
            this._toast('warning', 'Invalid email', 'Enter a valid supplier email before sending the request.');
            return;
        }
        // Actually persist the supplier + SEND the document-request email.
        const documents = this.checklistItems.map(it => it.document);
        const riskDomains = this.checklistDomains.map(d => d.label).join(',');
        this.emailSending = true;
        requestDocumentsFromSupplier({
            accountId:      null,
            supplierName:   this.intakeName,
            country:        this.intakeCountry,
            requestedBy:    this._userName || 'Procurement',
            industry:       this.intakeIndustry,
            engagementType: this.intakeEngagement,
            annualSpend:    this.intakeSpend,
            riskDomains:    riskDomains,
            supplierEmail:  this.intakeEmail,
            hitlThreshold:  this.recommendedHitl,
            documents:      documents
        })
            .then(() => {
                this.emailSending = false;
                this._toast('success', 'Request sent',
                    `Document request emailed to ${this.intakeEmail} and the supplier was added to your queue.`);
            })
            .catch(err => {
                this.emailSending = false;
                this._toast('error', 'Send failed',
                    (err && err.body && err.body.message) || 'Could not send the document request.');
            });
    }

    handleSaveDraft() {
        this._toast('info', 'Wired later', 'Save draft is wired in the backend pass.');
    }

    @track submitting = false;
    get submitLabel() { return this.submitting ? 'Submitting…' : 'Submit → documents & screening ›'; }

    handleSubmit() {
        // Require a generated checklist + valid email before submitting.
        if (!this.hasChecklist) {
            this._toast('warning', 'Generate first', 'Generate the checklist before submitting for screening.');
            return;
        }
        if (!this._isValidEmail(this.intakeEmail)) {
            this._toast('warning', 'Invalid email', 'Enter a valid supplier email before submitting.');
            return;
        }
        const riskDomains = this.checklistDomains.map(d => d.label).join(',');
        this.submitting = true;
        submitAndScreen({
            supplierName:   this.intakeName,
            country:        this.intakeCountry,
            requestedBy:    this._userName || 'Procurement',
            industry:       this.intakeIndustry,
            engagementType: this.intakeEngagement,
            annualSpend:    this.intakeSpend,
            riskDomains:    riskDomains,
            supplierEmail:  this.intakeEmail,
            hitlThreshold:  this.recommendedHitl
        })
            .then(() => {
                this.submitting = false;
                this._toast('success', 'Submitted for screening',
                    'The supplier was submitted — the AI engine is running screening now. Find them in the Supplier queue.');
                this._resetIntakeForm();
            })
            .catch(err => {
                this.submitting = false;
                this._toast('error', 'Submit failed',
                    (err && err.body && err.body.message) || 'Could not submit for screening.');
            });
    }

    // Refresh the whole intake screen after a successful submit.
    _resetIntakeForm() {
        this.intakeName = '';
        this.intakeCountry = '';
        this.intakeIndustry = '';
        this.intakeEngagement = '';
        this.intakeSpend = '';
        this.intakeEmail = '';
        this.intakeMaterialType = '';
        this.intakeServiceCategory = '';
        this.emailError = '';
        this.checklistItems = [];
        this.checklistDomains = [];
        this.checklistTier = '';
        this.recommendedHitl = '';
        this.riskReasons = [];
        this.checklistNotes = [];
        this.noPolicyMatch = false;
        this.checklistVisible = false;
        this.checklistStale = false;
        this.oversightLevel = 0;
        this.refreshQueue();
    }

    // ── P2 — queue search (skeleton) ──────────────────────────────────────────
    @track searchTerm = '';
    handleSearch(event) { this.searchTerm = event.target.value; }

    // Queue tabs — In review / Drafts / Awaiting documents / Handed to analyst.
    @track activeQueueTab = 'inReview';
    get tabInReviewClass() { return this.activeQueueTab === 'inReview' ? 'vc-tab active' : 'vc-tab'; }
    get tabDraftsClass() { return this.activeQueueTab === 'drafts' ? 'vc-tab active' : 'vc-tab'; }
    get tabAwaitingClass() { return this.activeQueueTab === 'awaiting' ? 'vc-tab active' : 'vc-tab'; }
    get tabHandedClass() { return this.activeQueueTab === 'handed' ? 'vc-tab active' : 'vc-tab'; }
    handleQueueTab(event) { this.activeQueueTab = event.currentTarget.dataset.tab; }

    // ── Live queue (reuses VendorPortalController.getScreeningQueue) ───────────
    _wiredQueue;
    @track _queue;
    @wire(getScreeningQueue)
    wiredQueue(result) {
        this._wiredQueue = result;
        if (result.data) this._queue = result.data;
    }
    get _allRows() { return (this._queue && this._queue.rows) || []; }

    // Stage buckets — MUTUALLY EXCLUSIVE so a supplier appears in exactly one tab.
    // Precedence: Draft → Handed-to-analyst → Awaiting-docs → In-review.
    _inBucket(r, tab) {
        const status  = (r.status || '').trim();
        const isDraft  = status === 'Draft';
        const isHanded = r.aiStatus === 'Needs analyst' || r.routing === 'Needs analyst'
                         || status === 'In Review';   // routed to an approver/analyst
        const isAwaiting = !isDraft && !isHanded &&
                           (status === 'Screening' || r.aiStatus === 'Screening' || status === 'Submitted');

        if (tab === 'drafts')   return isDraft;
        if (tab === 'handed')   return !isDraft && isHanded;
        if (tab === 'awaiting') return isAwaiting;
        // In review (default tab): actively in the pipeline, but NOT a draft,
        // not handed off, not still awaiting documents.
        return !isDraft && !isHanded && !isAwaiting && status !== '';
    }
    get queueRows() {
        const term = (this.searchTerm || '').trim().toLowerCase();
        let rows = this._allRows.filter(r => this._inBucket(r, this.activeQueueTab));
        if (term) {
            rows = rows.filter(r => (r.name || '').toLowerCase().includes(term)
                || (r.industry || '').toLowerCase().includes(term));
        }
        return rows.map(r => ({
            id: r.id,
            name: r.name,
            industry: r.industry || '—',
            stageLabel: r.stageLabel || r.status || '—',
            checklistLabel: r.flags > 0 ? `${r.flags} flagged` : (r.aiStatus || '—'),
            lastActivity: r.ageLabel || '—',
            durationLabel: r.durationLabel || '—',
            confidenceLabel: (r.confidence == null) ? '—' : r.confidence + '%'
        }));
    }
    get hasQueueRows() { return this.queueRows.length > 0; }

    @track _selectedSupplierName = '';
    handleOpenSupplier(event) {
        // Procurement opens the supplier's Documents & screening sub-screen (P3),
        // loading the FULL persisted snapshot for an existing record.
        this._selectedSupplierId = event.currentTarget.dataset.id;
        this._selectedSupplierName = event.currentTarget.dataset.name || '';
        this.activeScreen = 'p3';
        this.breadcrumb = BREADCRUMBS.p3;
        this._resetP3State();
        this._loadSnapshot();
    }
    get selectedSupplierId() { return this._selectedSupplierId; }
    get selectedSupplierName() { return this._selectedSupplierName; }
    refreshQueue() { if (this._wiredQueue) refreshApex(this._wiredQueue); }

    // ── Existing-supplier snapshot (detail + stored docs + past AI summaries) ──
    @track snapshotLoading = false;
    @track storedDocs = [];
    @track pastAssessments = [];
    @track snapTier = '';
    @track snapStatus = '';
    @track snapDomains = [];

    _resetP3State() {
        this.storedDocs = [];
        this.pastAssessments = [];
        this.uploadedDocs = [];
        this.complianceRows = [];
        this.rejectedDocs = [];
        this._expandedRows = new Set();
        this.snapTier = '';
        this.snapStatus = '';
        this.snapDomains = [];
        this.procNote = '';
        this.copilotMessages = [];
        this._copilotGreeted = false;
    }

    _loadSnapshot() {
        if (!this._selectedSupplierId) return;
        this.snapshotLoading = true;
        getSupplierSnapshot({ accountId: this._selectedSupplierId })
            .then(s => {
                this.snapshotLoading = false;
                if (!this._selectedSupplierName) this._selectedSupplierName = s.name || '';
                this.snapTier = s.riskTier || '';
                this.snapStatus = s.onboardingStatus || '';
                this.recommendedHitl = s.recommendedHitl || this.recommendedHitl;
                this._applyAiOversight(s.riskTier);
                this.snapDomains = (s.domains || []).map((d, i) => ({ id: 'sd' + i, label: d }));
                const docAssessments = (s.assessments || []).filter(
                    x => !((x.requirementLabel || '').startsWith('Screening — '))
                );
                this.storedDocs = (s.documents || []).map((d, i) => {
                    // Backend may already carry status/badgeClass on the doc object.
                    // Otherwise do a best-effort fuzzy match against assessment labels.
                    let complianceStatus = d.status || 'Pending';
                    let complianceBadgeClass = 'vc-badge ' + (d.badgeClass || 'neutral');
                    if (!d.status) {
                        const titleKey = (d.title || '').toLowerCase()
                            .replace(/\.[^.]+$/, '')       // strip extension
                            .replace(/[\s_-]+/g, '');      // collapse separators
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
                this.pastAssessments = all.map((x, i) => {
                    const parsed = this._parseSummary(x.reason);
                    return {
                        id: 'as' + i,
                        label: x.requirementLabel,
                        status: x.status,
                        severity: x.severity,
                        reason: x.reason || 'No summary recorded.',
                        headline: parsed.headline,
                        hasHeadline: !!parsed.headline,
                        facts: parsed.facts.map((t, j) => ({ id: 'af' + i + '_' + j, text: t })),
                        hasFacts: parsed.facts.length > 0,
                        concerns: parsed.concerns.map((t, j) => ({ id: 'ac' + i + '_' + j, text: t })),
                        hasConcerns: parsed.concerns.length > 0,
                        checks: parsed.checks.map((t, j) => ({
                            id: 'ak' + i + '_' + j, text: t.text, pass: t.pass,
                            chkClass: t.pass ? 'vc-chkline pass' : 'vc-chkline fail'
                        })),
                        hasChecks: parsed.checks.length > 0,
                        validUntil: x.validUntil,
                        evaluatedLabel: x.evaluatedLabel,
                        badgeClass: 'vc-badge ' + (x.badgeClass || 'neutral'),
                        confidence: (x.aiConfidence == null) ? '—' : x.aiConfidence + '%'
                    };
                });
                // ── Compliance documents: ONE row per requirement that joins the
                // requirement + upload/tick state + the AI verdict & structured
                // summary + the linked file (for inline preview/remove). This is
                // the merge of the old "Required checklist" + "Documents" panels.
                const reqRows = all.filter(x =>
                    !(x.requirementLabel || '').startsWith('Screening — ') &&
                    !(x.requirementLabel || '').includes('Manual verification'));
                this.complianceRows = reqRows.map((x, i) => this._buildComplianceRow(x, i));

                // ── Rejected documents: files the user UPLOADED that don't map to
                // any checklist requirement (i.e. not in the merged compliance
                // rows). Listed with a one-line reason and promotable via
                // "Add to checklist" so a genuinely-relevant doc isn't lost.
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
                // STORED screening results — surface prior screening so the user
                // doesn't have to re-run it every time (a "Screening —" label =
                // a persisted screening row). Re-run stays available.
                const screenRows = all.filter(x => (x.requirementLabel || '').startsWith('Screening — '));
                this.screeningResults = screenRows
                    .map((x, i) => ({
                        id: 'st' + i,
                        label: (x.requirementLabel || '').replace('Screening — ', ''),
                        status: x.status,
                        detail: x.reason || '',
                        badgeClass: 'vc-badge ' + (x.badgeClass || 'neutral')
                    }))
                    .filter(r => this._keepScreening(r.label));
                this.screeningRan = this.screeningResults.length > 0;
            })
            .catch(err => {
                this.snapshotLoading = false;
                this._toast('error', 'Could not load supplier',
                    (err && err.body && err.body.message) || 'Snapshot failed.');
            });
    }
    get hasStoredDocs() { return this.storedDocs.length > 0; }
    get hasPastAssessments() { return this.pastAssessments.length > 0; }
    get storedDocsCount() { return this.storedDocs.length; }

    // ── Compliance documents (merged checklist + documents) + rejected docs ───
    @track complianceRows = [];
    @track rejectedDocs = [];
    _expandedRows = new Set();   // requirementLabels whose AI detail is expanded

    get hasComplianceRows() { return this.complianceRows.length > 0; }
    get hasRejectedDocs() { return this.rejectedDocs.length > 0; }
    get checklistProgressLabel() {
        const done = this.complianceRows.filter(d => d.ticked).length;
        return `${done}/${this.complianceRows.length} uploaded`;
    }

    // Build one merged row: requirement + tick state + AI verdict/summary + file.
    _buildComplianceRow(x, i) {
        const ticked = x.uploaded === true;   // B1: tick on upload, validated or not
        const parsed = this._parseSummary(x.reason);
        // Match the linked file (for preview/remove) by fuzzy title, same rule the
        // snapshot uses elsewhere.
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
            uploaded: x.uploaded === true,
            boxClass: ticked ? 'vc-chk ticked' : 'vc-chk',
            rowClass: ticked ? 'vc-cdoc-row done' : 'vc-cdoc-row',
            statusText: ticked ? 'Uploaded' : 'Awaiting upload',
            // AI verdict chip (only meaningful once a doc is assessed)
            verdict: x.uploaded ? (x.status || 'Pending') : '',
            verdictBadgeClass: 'vc-badge ' + (x.badgeClass || 'neutral'),
            hasVerdict: x.uploaded === true,
            // AI confidence (0-100) — shows the engine's certainty in its verdict
            confidence: (x.aiConfidence == null) ? null : x.aiConfidence,
            confidenceLabel: (x.aiConfidence == null) ? '' : x.aiConfidence + '% confidence',
            hasConfidence: x.aiConfidence != null,
            // structured AI summary (expand on demand)
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
            // linked file → inline preview / remove + the uploaded file's name
            fileId: file ? file.id : '',
            contentDocumentId: file ? file.contentDocumentId : '',
            hasFile: !!file,
            fileName: file ? file.title : (x.documentTitle || ''),
            hasFileName: !!(file ? file.title : x.documentTitle)
        };
    }

    // Expand / collapse a row's AI reasoning.
    handleToggleDetail(event) {
        const key = event.currentTarget.dataset.key;
        if (!key) return;
        if (this._expandedRows.has(key)) this._expandedRows.delete(key);
        else this._expandedRows.add(key);
        // Re-derive rows with the new expand state.
        this.complianceRows = this.complianceRows.map(r =>
            r.key === key
                ? { ...r, expanded: !r.expanded,
                    toggleLabel: !r.expanded ? 'Hide AI detail ▴' : 'Show AI detail ▾' }
                : r);
    }

    // Promote a rejected/unmatched document into the checklist so it flows forward.
    handlePromoteRejected(event) {
        const id = event.currentTarget.dataset.id;
        const rej = this.rejectedDocs.find(r => r.id === id);
        if (!rej || !this._selectedSupplierId) return;
        this.rejectedDocs = this.rejectedDocs.map(r =>
            r.id === id ? { ...r, promoting: true } : r);
        addRequirementFromDocument({
            accountId: this._selectedSupplierId,
            documentTitle: rej.title,
            requirementKey: rej.requirementKey
        })
            .then(() => {
                this._toast('success', 'Added to checklist',
                    `"${rej.title}" is now a tracked requirement and will flow to the analyst.`);
                this._loadSnapshot();
            })
            .catch(err => {
                this.rejectedDocs = this.rejectedDocs.map(r =>
                    r.id === id ? { ...r, promoting: false } : r);
                this._toast('error', 'Could not add',
                    (err && err.body && err.body.message) || 'Failed to add the document to the checklist.');
            });
    }
    // Normalise a filename for matching (strip extension + separators), the same
    // rule used to join requirements ↔ files in _buildComplianceRow.
    _fileKey(name) {
        return (name || '').toLowerCase().replace(/\.[^.]+$/, '').replace(/[\s_-]+/g, '');
    }
    _shortReason(reason) {
        if (!reason) return '';
        const first = String(reason).split(/\r?\n/)[0].split(/[.!?]\s/)[0];
        return first.length > 140 ? first.slice(0, 137) + '…' : first;
    }
    // Parse the structured AI summary blob (DocAssessQueueable.buildDetail) into
    // headline / key facts (•) / concerns (⚠) / clause checks ([PASS]/[FAIL]) so
    // the UI renders clean structure instead of a bracketed text wall.
    _parseSummary(reason) {
        const out = { headline: '', facts: [], concerns: [], checks: [] };
        if (!reason) return out;
        const lines = String(reason).split(/\r?\n/).map(l => l.trim()).filter(Boolean);
        let inChecks = false;
        for (const line of lines) {
            if (/^clause checks:/i.test(line)) { inChecks = true; continue; }
            if (/^concerns:/i.test(line)) { inChecks = false; continue; }
            if (/^policy citations:/i.test(line)) { inChecks = false; continue; }
            if (line.startsWith('•')) { out.facts.push(line.replace(/^•\s*/, '')); continue; }
            if (line.startsWith('⚠')) { out.concerns.push(line.replace(/^⚠\s*/, '')); continue; }
            const m = line.match(/^\[(PASS|FAIL)\]\s*(.*)$/i);
            if (m) { out.checks.push({ pass: /pass/i.test(m[1]), text: m[2] }); continue; }
            if (inChecks) { out.checks.push({ pass: !/fail/i.test(line), text: line }); continue; }
            if (!out.headline) {
                out.headline = line.replace(/^\[[^\]]*\]\s*/, '');   // strip any leftover [tag]
            } else if (/^(extracted|expiry|registry)\b/i.test(line)) {
                out.facts.push(line.replace(/^[A-Za-z]+\s·\s*/, ''));
            }
        }
        return out;
    }

    // Documents tab: only checklist assessments, no screening rows.
    get docOnlyAssessments() {
        return this.pastAssessments.filter(a => !(a.label || '').startsWith('Screening — '));
    }
    get hasDocOnlyAssessments() { return this.docOnlyAssessments.length > 0; }

    // P4 submission table: non-screening assessments carry the real per-document
    // AI confidence (from /assess, persisted on the assessment); '—' when absent.
    get submissionRows() {
        return this.docOnlyAssessments;
    }
    get hasSubmissionRows() { return this.submissionRows.length > 0; }

    // Shape the checklist assessments for the shared dashboard: map each doc's
    // compliance status to a decision the dashboard scores deterministically.
    get dashboardDocs() {
        return this.docOnlyAssessments.map(a => ({
            decision: this._statusToDecision(a.status),
            confidence: a.confidence
        }));
    }
    _statusToDecision(status) {
        const s = (status || '').toLowerCase();
        if (s === 'compliant') return 'approved';
        if (s === 'non-compliant') return 'rejected';
        return 'pending';   // Needs Analyst / Pending / unknown
    }

    // ── Inline document preview (Procurement) ─────────────────────────────────
    @track _previewUrl = null;
    @track _previewTitle = '';
    @track _previewIsImage = false;
    @track _previewDocId = '';
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

    handlePreviewDoc(event) {
        const origin = window.location.origin;
        const id = event.currentTarget.dataset.id;
        const doc = this.storedDocs.find(d => d.id === id);
        if (!doc) return;
        // Toggle: clicking the same doc's Preview again closes the panel.
        if (this._previewDocId === id && this._previewUrl) {
            this.closePreview();
            return;
        }
        if (!doc.versionId) {
            this._toast('warning', 'No preview available', 'This document has no previewable file reference.');
            return;
        }
        // Pick the right inline URL by file type. A PDF rendition only EXISTS for
        // PDF/Office files — requesting rendition=PDF for a .txt/.csv returns
        // nothing (the "broken preview" bug). So:
        //   image  → ORIGINAL_Jpg rendition (inline)
        //   pdf/doc/docx/ppt/xls → PDF rendition (inline in the browser viewer)
        //   everything else (txt/csv/json/…) → direct file download served inline
        const imageTypes = ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'svg', 'webp'];
        const pdfRenderable = ['pdf', 'doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx','txt'];
        const ft = (doc.fileType || '').toLowerCase();
        const isImage = imageTypes.includes(ft);
        this._previewIsImage = isImage;
        if (isImage) {
            this._previewUrl = `/sfc/servlet.shepherd/version/renditionDownload?rendition=ORIGINAL_Jpg&versionId=${doc.versionId}`;
        } else if (pdfRenderable.includes(ft)) {
            this._previewUrl = `/sfc/servlet.shepherd/version/renditionDownload?rendition=PDF&versionId=${doc.versionId}`;
        } else {
            // Plain-text/other: serve the original file inline (no rendition exists).
            // this._previewUrl = `/sfc/servlet.shepherd/version/download/${doc.versionId}`;
            // this._previewUrl = `/sfc/servlet.shepherd/version/renditionDownload?rendition=PDF&versionId=${doc.versionId}`;
            this._previewUrl =`${origin}/sfc/servlet.shepherd/version/renditionDownload?rendition=PDF&versionId=${doc.versionId}`;
        }
        console.log('previewURL : ' , this._previewUrl);
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
        iframe.style.height = '700px';
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

    handleRemoveDoc(event) {
        const id = event.currentTarget.dataset.id;
        const doc = this.storedDocs.find(d => d.id === id);
        if (!doc || !doc.contentDocumentId) {
            this._toast('warning', 'Cannot remove', 'This document has no removable file reference.');
            return;
        }
        // eslint-disable-next-line no-alert
        removeSupplierDocument({ accountId: this._selectedSupplierId, contentDocumentId: doc.contentDocumentId })
            .then(() => {
                if (this._previewUrl === doc.previewUrl) this.closePreview();
                this._toast('success', 'Document removed', `${doc.title} was removed from the supplier.`);
                this._loadSnapshot();
            })
            .catch(err => this._toast('error', 'Remove failed',
                (err && err.body && err.body.message) || 'Could not remove the document.'));
    }
    get previewBtnLabel() { return 'Preview'; }

    // Back from P3 → the queue (P3 is a sub-context of the queue, not a tab).
    handleBackToQueue() {
        this.activeScreen = 'p2';
        this.breadcrumb = BREADCRUMBS.p2;
        this._closeAssign();
        this.copilotOpen = false;
        this._stopAssessPoll();
    }

    // P3 has its own two tabs: Documents and Screening.
    @track p3Tab = 'documents';
    get isDocsTab() { return this.p3Tab === 'documents'; }
    get isScreeningTab() { return this.p3Tab === 'screening'; }
    get docsTabClass() { return this.p3Tab === 'documents' ? 'vc-tab active' : 'vc-tab'; }
    get screeningTabClass() { return this.p3Tab === 'screening' ? 'vc-tab active' : 'vc-tab'; }
    handleP3Tab(event) { this.p3Tab = event.currentTarget.dataset.tab; }

    // P3/P4 are sub-items under "Supplier queue" in the left nav.
    get showP3SubNav() { return this.activeScreen === 'p3' || this.activeScreen === 'p4'; }
    get sbP3SubActive() { return this.activeScreen === 'p3' ? 'vc-sb-subitem active' : 'vc-sb-subitem'; }
    get sbP4SubActive() { return this.activeScreen === 'p4' ? 'vc-sb-subitem active' : 'vc-sb-subitem'; }
    handleP3NavClick() {
        this.activeScreen = 'p3';
        this.breadcrumb = BREADCRUMBS.p3;
    }
    handleP4NavClick() {
        this.activeScreen = 'p4';
        this.breadcrumb = BREADCRUMBS.p4;
    }
    handleGoToSubmission() {
        this.activeScreen = 'p4';
        this.breadcrumb = BREADCRUMBS.p4;
    }
    handleBackToDocuments() {
        this.activeScreen = 'p3';
        this.breadcrumb = BREADCRUMBS.p3;
    }

    // ── P3 — documents & screening ────────────────────────────────────────────
    // Single bulk file picker (one button handles one OR many files).
    handleAddFiles() {
        const picker = this.template.querySelector('.vc-file-input');
        if (picker) picker.click();
    }
    @track uploadedDocs = [];
    get hasUploadedDocs() { return this.uploadedDocs.length > 0; }

    handleFilesPicked(event) {
        const files = Array.from(event.target.files || []);
        if (!files.length) return;
        if (!this._selectedSupplierId) {
            this._toast('warning', 'No supplier', 'Open a supplier before uploading documents.');
            return;
        }
        // Upload each file FOR REAL: ContentVersion+CDL on the supplier, then
        // link it to a Compliance Document so it's stored, visible, and assessed.
        files.forEach(f => this._uploadOne(f));
        event.target.value = '';   // allow re-picking the same file
    }

    _uploadOne(file) {
        const tempId = 'u' + Date.now() + Math.floor(Math.random() * 1000);
        // Optimistic row while it uploads.
        this.uploadedDocs = [...this.uploadedDocs, {
            id: tempId, name: file.name,
            sizeLabel: `${Math.max(1, Math.round(file.size / 1024))} KB`,
            status: 'Uploading…'
        }];
        const reader = new FileReader();
        reader.onload = () => {
            const base64 = (reader.result || '').toString().split(',')[1];
            saveFile({ recordId: this._selectedSupplierId, fileName: file.name, base64Data: base64 })
                .then(contentDocumentId =>
                    linkDocumentToCompliance({
                        accountId: this._selectedSupplierId,
                        contentDocumentId,
                        documentType: file.name,   // best-effort; analyst/AI resolves the match
                        assessmentId: null,
                        fileName: file.name
                    })
                )
                .then(() => {
                    this._setUploadStatus(tempId, 'Uploaded · AI assessing');
                    this._toast('success', 'Uploaded', `${file.name} stored on the supplier and queued for AI assessment.`);
                    // Refresh now so the doc shows immediately, then poll for the
                    // async AI verdict so the row updates itself when /assess returns.
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

    // Auto-refresh after upload: the AI assessment runs async (queueable), so the
    // first snapshot still shows "Pending". Poll a few times until the pending
    // uploaded docs resolve (verdict lands), then stop. No manual refresh needed.
    _pendingUploaded() {
        return (this.complianceRows || []).filter(
            r => r.uploaded && (!r.verdict || r.verdict === 'Pending')).length;
    }
    _pollForAssessment() {
        if (this._assessPoll) return;   // a poll is already running
        let tries = 0;
        const MAX = 8;                  // ~8 × 3s = up to 24s
        const baseline = this._pendingUploaded();
        this._assessPoll = setInterval(() => {
            tries++;
            this._loadSnapshot();
            // Stop when a pending doc has resolved, or we run out of tries, or the
            // user left the screen.
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                const stillPending = this._pendingUploaded();
                if (stillPending < baseline || stillPending === 0 || tries >= MAX
                    || this.activeScreen !== 'p3') {
                    this._stopAssessPoll();
                }
            }, 400);
        }, 3000);
    }
    _stopAssessPoll() {
        if (this._assessPoll) { clearInterval(this._assessPoll); this._assessPoll = null; }
    }

    _setUploadStatus(id, status) {
        const i = this.uploadedDocs.findIndex(d => d.id === id);
        if (i >= 0) {
            const copy = [...this.uploadedDocs];
            copy[i] = { ...copy[i], status };
            this.uploadedDocs = copy;
        }
    }

    // Procurement note that travels with the handoff.
    @track procNote = '';
    handleNoteChange(event) { this.procNote = event.target.value; }

    // ── Procurement co-pilot — FLOATING action button + panel (P3 only) ───────
    // Grounded over the supplier's persisted assessments + screening (askCopilot).
    @track copilotMessages = [];   // { id, who: 'you'|'ai', text, rowClass }
    @track copilotInput = '';
    @track copilotBusy = false;
    @track copilotOpen = false;
    get hasCopilotMessages() { return this.copilotMessages.length > 0; }
    // Show the floating co-pilot on Documents & screening (P3) and Submission summary (P4).
    get showCopilotFab() { return this.activeScreen === 'p3' || this.activeScreen === 'p4'; }
    // Red-dot nudge when there's something to ask about but no conversation yet.
    get copilotHasNudge() { return this.hasPastAssessments && !this.hasCopilotMessages; }
    get copilotFabClass() { return this.copilotHasNudge ? 'vc-cp-fab nudge' : 'vc-cp-fab'; }
    toggleCopilot() {
        this.copilotOpen = !this.copilotOpen;
        // Seed a persona-aware greeting the first time it's opened for this case.
        if (this.copilotOpen && !this._copilotGreeted) {
            this._copilotGreeted = true;
            this._pushMsg('ai', this._copilotGreeting());
        }
    }
    _copilotGreeted = false;
    _copilotGreeting() {
        const who = this.selectedSupplierName || 'this supplier';
        return `Hi — I'm your VERA co-pilot for **${who}**. I'm grounded in this case's `
            + `documents, screening results, and the policy clauses behind them. I can summarise a `
            + `document, explain a finding, or check what's still missing. What do you need?`;
    }
    closeCopilot() { this.copilotOpen = false; }

    // Persona-aware suggested actions. Actions flagged `local` are answered
    // INSTANTLY from already-stored assessment data (no engine callout) — this is
    // what kills the 504 on "pull all key fields from a document". The rest go to
    // the grounded engine co-pilot. Chips stay visible so the co-pilot is always
    // suggestive, not a blank prompt.
    get copilotSuggestions() {
        const onSubmission = this.activeScreen === 'p4';
        const list = [
            { id: 's1', text: 'What documents are still missing?', local: true, action: 'missing' },
            { id: 's2', text: 'Show the key fields from the documents', local: true, action: 'fields' },
            { id: 's3', text: 'Which findings would block handoff?', local: true, action: 'blockers' }
        ];
        list.push(onSubmission
            ? { id: 's4', text: 'Draft a handoff note for the analyst', local: false }
            : { id: 's4', text: 'Is this supplier ready to hand to an analyst?', local: false });
        return list;
    }
    // Chips persist (suggestive co-pilot), shown whenever the panel is open.
    get showCopilotSuggestions() { return true; }

    handleSuggestion(event) {
        const text = event.currentTarget.dataset.text;
        const local = event.currentTarget.dataset.local === 'true';
        const action = event.currentTarget.dataset.action;
        if (!text) return;
        if (local) {
            // Answer from stored data — instant, deterministic, no callout.
            this._pushMsg('you', text);
            this._pushMsg('ai', this._localAnswer(action));
            return;
        }
        this.copilotInput = text;
        this.handleCopilotSend();
    }

    // ── Instant answers from already-stored assessment data (no engine call) ──
    _localAnswer(action) {
        if (action === 'fields')   return this._answerFields();
        if (action === 'missing')  return this._answerMissing();
        if (action === 'blockers') return this._answerBlockers();
        return 'I can answer that from this case — ask me anything specific.';
    }
    _answerFields() {
        const rows = this.docOnlyAssessments.filter(a => a.hasFacts || a.hasChecks);
        if (!rows.length) return 'No documents have been AI-assessed yet — upload a document and I\'ll extract its key fields.';
        const out = ['Here are the **key fields** the AI extracted, by document:'];
        rows.forEach(a => {
            out.push(`\n**${a.label}** — ${a.status}`);
            (a.facts || []).forEach(f => out.push(`- ${f.text}`));
            (a.checks || []).forEach(k => out.push(`- ${k.pass ? '✓' : '✕'} ${k.text}`));
        });
        return out.join('\n');
    }
    _answerMissing() {
        const missing = (this.complianceRows || []).filter(r => !r.uploaded);
        if (!missing.length) return 'All required documents have been uploaded. ✓';
        return ['These required documents are **still missing**:',
            ...missing.map(r => `- ${r.label}`)].join('\n');
    }
    _answerBlockers() {
        const bad = this.docOnlyAssessments.filter(a => (a.status || '').toLowerCase() === 'non-compliant');
        if (!bad.length) return 'No documents are currently Non-Compliant — nothing is blocking handoff on the document side.';
        const out = ['These findings would **block analyst handoff**:'];
        bad.forEach(a => {
            out.push(`\n**${a.label}** — Non-Compliant`);
            (a.concerns || []).forEach(c => out.push(`- ⚠ ${c.text}`));
            (a.checks || []).filter(k => !k.pass).forEach(k => out.push(`- ✕ ${k.text}`));
        });
        return out.join('\n');
    }

    get copilotSendDisabled() { return this.copilotBusy || !this.copilotInput.trim() || !this._selectedSupplierId; }
    handleCopilotInput(event) { this.copilotInput = event.target.value; }
    handleCopilotKey(event) { if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); this.handleCopilotSend(); } }

    _pushMsg(who, text) {
        this.copilotMessages = [...this.copilotMessages, {
            id: 'm' + this.copilotMessages.length,
            who, text,
            blocks: this._formatMessage(text),
            rowClass: who === 'you' ? 'vc-cp-msg you' : 'vc-cp-msg ai'
        }];
    }

    // Parse light markdown (bullets, numbered lists, **bold**) into renderable
    // blocks so co-pilot answers aren't a wall of plain text.
    _formatMessage(text) {
        const lines = String(text || '').split(/\r?\n/);
        const blocks = [];
        let k = 0;
        for (let raw of lines) {
            const line = raw.trim();
            if (!line) continue;
            const bullet = /^[-*•]\s+/.test(line) || /^\d+[.)]\s+/.test(line);
            const content = line.replace(/^[-*•]\s+/, '').replace(/^\d+[.)]\s+/, '');
            blocks.push({
                id: 'b' + (k++),
                isBullet: bullet,
                blockClass: bullet ? 'vc-cp-line bullet' : 'vc-cp-line',
                runs: this._boldRuns(content)
            });
        }
        return blocks.length ? blocks
            : [{ id: 'b0', isBullet: false, blockClass: 'vc-cp-line', runs: this._boldRuns(text) }];
    }
    // Split a string into plain / bold runs on **...**.
    _boldRuns(s) {
        const parts = String(s || '').split(/(\*\*[^*]+\*\*)/g);
        return parts.filter(p => p !== '').map((p, i) => {
            const bold = /^\*\*[^*]+\*\*$/.test(p);
            return { id: 'r' + i, bold, text: bold ? p.slice(2, -2) : p };
        });
    }

    handleCopilotSend() {
        const q = this.copilotInput.trim();
        if (!q || !this._selectedSupplierId) return;
        this._pushMsg('you', q);
        this.copilotInput = '';
        this.copilotBusy = true;
        askCopilot({ accountId: this._selectedSupplierId, question: q })
            .then(res => {
                this.copilotBusy = false;
                const answer = (res && (res.answer || res.response)) || 'No answer returned.';
                this._pushMsg('ai', answer);
            })
            .catch(err => {
                this.copilotBusy = false;
                this._pushMsg('ai', 'Co-pilot error: ' +
                    ((err && err.body && err.body.message) || 'request failed.'));
            });
    }

    // ── Assign-to-analyst modal ───────────────────────────────────────────────
    @track showAssign = false;
    @track selectedAnalystId = '';
    // Real assignable users (current admin floated to top, labelled "(you)").
    @track analystOptions = [];
    @wire(getAnalystUsers)
    wiredAnalysts({ data }) {
        if (data) this.analystOptions = data;
    }
    get analystRows() {
        return this.analystOptions.map(a => ({
            ...a,
            rowClass: a.id === this.selectedAnalystId ? 'vc-assign-row selected' : 'vc-assign-row'
        }));
    }
    get assignDisabled() { return !this.selectedAnalystId; }

    // ── Screening tab — runs /verify and PERSISTS results as assessment rows ───
    @track screeningBusy = false;
    // Keep only the three demo screening categories — Sanctions, Financials,
    // Media. Conflict-minerals and "Manual verification required" are excluded.
    _keepScreening(label) {
        const l = (label || '').toLowerCase();
        if (l.includes('conflict') || l.includes('manual verification')) return false;
        return l.includes('sanction') || l.includes('financ') || l.includes('media');
    }

    @track screeningResults = [];   // { id, label, status, detail, badgeClass }
    @track screeningRan = false;
    @track manualChecksNote = '';   // prose: portals the analyst must check by hand
    get hasScreeningResults() { return this.screeningResults.length > 0; }
    get hasManualChecks() { return !!this.manualChecksNote; }

    handleRunScreening() {
        if (!this._selectedSupplierId) { this._toast('warning', 'No supplier', 'Open a supplier first.'); return; }
        this.screeningBusy = true;
        runScreeningAndPersist({ accountId: this._selectedSupplierId })
            .then(res => {
                this.screeningBusy = false;
                this.screeningRan = true;
                const results = (res && res.results) || [];
                this.screeningResults = results
                    .map((r, i) => ({
                        id: 'sc' + i,
                        label: r.label,
                        status: r.status,
                        detail: r.detail || '',
                        badgeClass: 'vc-badge ' + (r.badgeClass || 'neutral')
                    }))
                    .filter(r => this._keepScreening(r.label));
                // Fold screening into the AI summary by reloading the snapshot —
                // the persisted screening rows now appear in the AI summaries panel.
                this._loadSnapshot();
                this._toast('success', 'Screening complete',
                    `${this.screeningResults.length} check(s) run and added to the AI summary.`);
            })
            .catch(err => {
                this.screeningBusy = false;
                this._toast('error', 'Screening failed',
                    (err && err.body && err.body.message) || 'Could not run screening.');
            });
    }

    // Assign-to-analyst (now its own button on the Screening tab).
    handleOpenAssign() {
        if (!this._selectedSupplierId) { this._toast('warning', 'No supplier', 'Open a supplier first.'); return; }
        this.showAssign = true;
    }
    handlePickAnalyst(event) { this.selectedAnalystId = event.currentTarget.dataset.id; }
    _closeAssign() { this.showAssign = false; this.selectedAnalystId = ''; }
    handleCancelAssign() { this._closeAssign(); }

    @track assigning = false;
    handleConfirmAssign() {
        if (!this.selectedAnalystId || !this._selectedSupplierId) return;
        const analyst = this.analystOptions.find(a => a.id === this.selectedAnalystId);
        this.assigning = true;
        assignToAnalyst({
            accountId: this._selectedSupplierId,
            analystUserId: this.selectedAnalystId,
            note: this.procNote
        })
            .then(() => {
                this.assigning = false;
                this._toast('success', 'Routed to analyst',
                    `${this._selectedSupplierName || 'Supplier'} assigned to ${analyst ? analyst.name : 'the analyst'} — now in their queue.`);
                this._closeAssign();
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => { this.handleBackToQueue(); this.refreshQueue(); }, 700);
            })
            .catch(err => {
                this.assigning = false;
                this._toast('error', 'Assign failed',
                    (err && err.body && err.body.message) || 'Could not assign to the analyst.');
            });
    }

    // ── Toast helper ──────────────────────────────────────────────────────────
    _toast(variant, title, message) {
        // Lightweight inline notice; replace with lightning/toast when wired.
        // eslint-disable-next-line no-console
        console.info(`[Procurement] ${variant}: ${title} — ${message}`);
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