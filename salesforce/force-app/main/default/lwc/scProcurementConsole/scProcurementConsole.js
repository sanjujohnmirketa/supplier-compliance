import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import complianceLogo from '@salesforce/resourceUrl/complianceLogo';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import ACCOUNT_OBJECT from '@salesforce/schema/Account';
import INDUSTRY_FIELD from '@salesforce/schema/Account.Industry__c';
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
import onboardSupplierDirectly from '@salesforce/apex/VendorPortalController.onboardSupplierDirectly';
import saveFile from '@salesforce/apex/DocumentProcessingController.saveFile';
import linkDocumentToCompliance from '@salesforce/apex/DocumentProcessingController.linkDocumentToCompliance';
import addDocumentToCompliance from '@salesforce/apex/DocumentProcessingController.addDocumentToCompliance';
import removeSupplierDocument from '@salesforce/apex/VendorPortalController.removeSupplierDocument';
import getMaterialTypeCatalog from '@salesforce/apex/MaterialTypeController.getMaterialTypeCatalog';
import approveDocumentAsProcurement from '@salesforce/apex/VendorPortalController.approveDocumentAsProcurement';
import recordProcurementDecision from '@salesforce/apex/VendorPortalController.recordProcurementDecision';
import removeChecklistRequirement from '@salesforce/apex/VendorPortalController.removeChecklistRequirement';
import addChecklistRequirement from '@salesforce/apex/VendorPortalController.addChecklistRequirement';
import generatePublicDocumentUrl from '@salesforce/apex/VendorPortalController.generatePublicDocumentUrl';
import resendDocumentRequestEmail from '@salesforce/apex/VendorPortalController.resendDocumentRequestEmail';
import getSupplierEditDetails from '@salesforce/apex/VendorPortalController.getSupplierEditDetails';
import updateSupplierDetails from '@salesforce/apex/VendorPortalController.updateSupplierDetails';
import reassessDocument from '@salesforce/apex/VendorPortalController.reassessDocument';

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

// Industry dropdown options now come from Account.Industry__c's picklist
// metadata (loaded via getObjectInfo/getPicklistValues below), not a hardcoded
// JS array that used to silently diverge from the field it wrote to (see
// Design Review Part II §04). Industry__c is used here PURELY as an options
// catalog — the standard Account.Industry field is still what upsertSupplier()
// actually reads/writes (it's a global picklist and can't carry a custom
// valueSet), so this dropdown's labels must exactly match Industry__c's
// values, edited at Industry__c.field-meta.xml.

// Material Type / Service Category options now come from Material_Type__mdt
// (MaterialTypeController.getMaterialTypeCatalog) — loaded in connectedCallback
// — so a new material for ANY industry can be added via Custom Metadata with no
// code change here or in the engine (see MaterialTypeController.cls,
// ScopeService.cls's materialDomains field).

export default class ScProcurementConsole extends NavigationMixin(LightningElement) {

    logoUrl = complianceLogo;
    @track _materialTypeCatalog = [];

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

    // ── Industry picklist (source of truth = Account.Industry field metadata) ──
    @track _industryValues = [];

    @wire(getObjectInfo, { objectApiName: ACCOUNT_OBJECT })
    _accountObjectInfo;

    @wire(getPicklistValues, { recordTypeId: '$_accountObjectInfo.data.defaultRecordTypeId', fieldApiName: INDUSTRY_FIELD })
    wiredIndustryPicklist({ data, error }) {
        if (data) {
            this._industryValues = data.values || [];
        } else if (error) {
            // eslint-disable-next-line no-console
            console.error('[Procurement] Could not load Industry picklist values:', error);
        }
    }

    // Restores which screen (and, for P3/P4, which supplier) was open before
    // a hard browser refresh. A first attempt did this via the URL
    // (CurrentPageReference + window.history.replaceState) — but this
    // component sits on a Lightning APP PAGE, which has no Salesforce-managed
    // URL state the way a record page does, so writing to the URL directly
    // fought the platform's own router and blanked the page on opening any
    // supplier. sessionStorage never touches the URL or browser history at
    // all, so it can't conflict with anything Lightning owns — same
    // survives-a-refresh effect, none of the risk. Scoped to sessionStorage
    // (not localStorage) so it clears on tab close, same as the URL approach
    // would have — a brand-new tab still starts clean at New Supplier.
    static _STORAGE_KEY = 'vc_procurement_screen_state';

    connectedCallback() {
        this._boundDocClick = (evt) => {
            if (this._showUserMenu && !evt.composedPath().includes(this.template.host)) {
                this._showUserMenu = false;
            }
            if (this._rowMenuAccountId
                && !evt.composedPath().some((el) => el.classList && el.classList.contains('vc-row-menu-floating'))) {
                this._rowMenuAccountId = null;
            }
        };
        document.addEventListener('click', this._boundDocClick);

        getMaterialTypeCatalog()
            .then((data) => { this._materialTypeCatalog = data || []; })
            .catch((err) => {
                // eslint-disable-next-line no-console
                console.error('[Procurement] Could not load material type catalog:', err);
            });

        this._restoreScreenState();
    }

    _restoreScreenState() {
        let saved;
        try {
            saved = JSON.parse(sessionStorage.getItem(ScProcurementConsole._STORAGE_KEY) || 'null');
        } catch {
            saved = null; // corrupted/blocked storage — fall back to default p1
        }
        if (!saved || !saved.screen || !BREADCRUMBS[saved.screen]) return;
        if ((saved.screen === 'p3' || saved.screen === 'p4') && saved.supplierId) {
            this._selectedSupplierId = saved.supplierId;
            this._selectedSupplierName = saved.supplierName || '';
            this._resetP3State();
            this._loadSnapshot();
        }
        this.activeScreen = saved.screen;
        this.breadcrumb = BREADCRUMBS[saved.screen];
    }

    // Single place that changes screens AND persists the choice — so a
    // refresh on ANY screen (not just P1) lands back where the user was.
    _setScreen(sid) {
        this.activeScreen = sid;
        this.breadcrumb = BREADCRUMBS[sid];
        try {
            const state = { screen: sid };
            if ((sid === 'p3' || sid === 'p4') && this._selectedSupplierId) {
                state.supplierId = this._selectedSupplierId;
                state.supplierName = this._selectedSupplierName || '';
            }
            sessionStorage.setItem(ScProcurementConsole._STORAGE_KEY, JSON.stringify(state));
        } catch {
            // Storage blocked (private browsing, quota) — degrade to the old
            // in-memory-only behavior rather than throw.
        }
    }

    disconnectedCallback() {
        document.removeEventListener('click', this._boundDocClick);
        this._stopAssessPoll();
        this._stopBackgroundSync();
        if (this._storedNoteTimer) clearTimeout(this._storedNoteTimer);
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
        // Viewing an existing supplier on P3 (_loadSnapshot) sets oversightLevel/
        // recommendedHitl from THAT supplier's risk tier — P1 shares the same
        // tracked properties, so returning to P1 without a checklist generated
        // in this session left the previous supplier's oversight level showing
        // (e.g. "Medium") on a blank intake form. Only reset when P1 has no
        // in-progress checklist of its own to preserve.
        if (sid === 'p1' && !this.checklistVisible) {
            this.oversightLevel = 0;
            this.recommendedHitl = '';
        }
        this._setScreen(sid);
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
        return this._industryValues.map(({ value, label }) => ({ value, label, selected: value === this.intakeIndustry }));
    }
    get isIndustryEmpty() { return !this.intakeIndustry; }

    get materialTypeOptions() {
        const catalog = this._materialTypeCatalog.filter((m) => m.kind === 'Material');
        return [{ value: '', label: 'None / Not Applicable', selected: !this.intakeMaterialType }].concat(
            catalog.map((m) => ({ value: m.valueKey, label: m.label, selected: m.valueKey === this.intakeMaterialType }))
        );
    }
    get serviceCategoryOptions() {
        const catalog = this._materialTypeCatalog.filter((m) => m.kind === 'Service');
        return [{ value: '', label: 'None / Not Applicable', selected: !this.intakeServiceCategory }].concat(
            catalog.map((m) => ({ value: m.valueKey, label: m.label, selected: m.valueKey === this.intakeServiceCategory }))
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
    @track newChecklistDocName = '';
    _checklistSignature = '';
    _checklistEditCounter = 0;   // unique ids for manually added items
    get hasChecklist() { return this.checklistVisible && (this.checklistItems.length > 0 || this.noPolicyMatch); }
    // Live count next to the "Document checklist" header — checklistItems is
    // always reassigned (never mutated in place) by generate/add/remove, so
    // this recomputes automatically as items are added or removed.
    get checklistCountLabel() {
        const n = this.checklistItems.length;
        return `${n} document${n === 1 ? '' : 's'}`;
    }
    get isAddChecklistDisabled() { return !this.newChecklistDocName || !this.newChecklistDocName.trim(); }
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

    // Pre-submit checklist editing — this list is local state until Submit/
    // Email persists it (submitAndScreen / requestDocumentsFromSupplier both
    // send whatever is in checklistItems at that moment), so removing/adding
    // here is exactly what determines what actually gets sent to the
    // supplier — no separate persistence step needed for the PRE-submit case.
    handleRemoveChecklistItem(event) {
        const id = event.currentTarget.dataset.id;
        this.checklistItems = this.checklistItems.filter((it) => it.id !== id);
    }

    handleNewChecklistDocChange(event) {
        this.newChecklistDocName = event.target.value;
    }

    handleAddChecklistItem() {
        const name = (this.newChecklistDocName || '').trim();
        if (!name) return;
        this._checklistEditCounter += 1;
        this.checklistItems = [
            ...this.checklistItems,
            { id: 'manual' + this._checklistEditCounter, document: name, domain: 'general' }
        ];
        this.newChecklistDocName = '';
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
            documents:      documents,
            materialType:    this.intakeMaterialType || null,
            serviceCategory: this.intakeServiceCategory || null
        })
            .then(() => {
                this.emailSending = false;
                this._toast('success', 'Request sent',
                    `Document request emailed to ${this.intakeEmail} and the supplier was added to your queue.`);
                // Land back on Supplier queue so the newly-created supplier is
                // immediately visible — _resetIntakeForm() also clears P1's
                // fields (same reset handleSubmit already does on success) and
                // refreshes the queue wire so the new row is there when P2 renders.
                this._resetIntakeForm();
                this._setScreen('p2');
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => {
                    const main = this.template.querySelector('.vc-main');
                    if (main) main.scrollTop = 0;
                }, 0);
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
        const documents = this.checklistItems.map(it => it.document);
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
            hitlThreshold:  this.recommendedHitl,
            documents:      documents,
            materialType:    this.intakeMaterialType || null,
            serviceCategory: this.intakeServiceCategory || null
        })
            .then(() => {
                this.submitting = false;
                this._toast('success', 'Submitted for screening',
                    'Screening is running. Find this supplier in the Supplier queue.');
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

    // ── Live queue (reuses VendorPortalController.getScreeningQueue) ───────────
    _wiredQueue;
    @track _queue;
    @wire(getScreeningQueue)
    wiredQueue(result) {
        this._wiredQueue = result;
        if (result.data) this._queue = result.data;
    }
    get _allRows() { return (this._queue && this._queue.rows) || []; }

    // Single list — no tabs. Stage is now just another column (row.stageLabel,
    // from VendorPortalController.queueStage), so every supplier is visible at
    // once instead of split across 4 tabs a user had to click through. Filtering
    // by stage is intentionally parked for later (search-only for now).
    get queueRows() {
        const term = (this.searchTerm || '').trim().toLowerCase();
        let rows = this._allRows;
        if (term) {
            rows = rows.filter(r => (r.name || '').toLowerCase().includes(term)
                || (r.industry || '').toLowerCase().includes(term));
        }
        return rows.map(r => ({
            id: r.id,
            name: r.name,
            industry: r.industry || 'Not set',
            riskTier: r.riskTier || 'Not scored yet',
            riskTierBadgeClass: 'vc-badge ' + this._tierBadgeClass(r.riskTier),
            stageLabel: r.stageLabel || 'Not set',
            // Colored by risk tier (same scale as the Risk Tier column), not by stage.
            stageBadgeClass: 'vc-badge ' + this._tierBadgeClass(r.riskTier),
            // Apex's ageLabel() returns "received 59m ago" — the underlying
            // calculation stays server-side; this only trims the display prefix.
            lastActivity: (r.ageLabel || 'Just now').replace(/^received\s+/i, ''),
            // Same definition as checklistProgressLabel on Documents & Screening
            // (P3): uploaded / total checklist items, not AI-verdict-based.
            docsProgressLabel: `${r.docsUploaded || 0}/${r.docsTotal || 0}`
        }));
    }
    _tierBadgeClass(tier) {
        if (tier === 'Critical' || tier === 'High') return 'bad';
        if (tier === 'Medium')                      return 'warn';
        if (tier === 'Low')                          return 'ok';
        return 'neutral';
    }
    get hasQueueRows() { return this.queueRows.length > 0; }

    @track _selectedSupplierName = '';
    handleOpenSupplier(event) {
        // Procurement opens the supplier's Documents & screening sub-screen (P3),
        // loading the FULL persisted snapshot for an existing record.
        this._selectedSupplierId = event.currentTarget.dataset.id;
        this._selectedSupplierName = event.currentTarget.dataset.name || '';
        this._setScreen('p3');
        this._resetP3State();
        this._loadSnapshot();
    }
    get selectedSupplierId() { return this._selectedSupplierId; }
    get selectedSupplierName() { return this._selectedSupplierName; }
    refreshQueue() { if (this._wiredQueue) refreshApex(this._wiredQueue); }

    // Manual refresh for the Supplier Queue table — re-runs the same
    // @wire(getScreeningQueue) request refreshQueue already uses elsewhere.
    @track queueRefreshing = false;
    handleRefreshQueue() {
        if (!this._wiredQueue) return;
        this.queueRefreshing = true;
        refreshApex(this._wiredQueue).finally(() => { this.queueRefreshing = false; });
    }

    // ── Per-row Actions menu (Edit / Resend Email) ─────────────────────────────
    // Rendered as a SINGLE floating element (position:fixed, coordinates read
    // from the clicked ⋮ button) rather than nested inside the row — the table
    // wrapper uses overflow:hidden for its rounded corners, which would clip an
    // absolutely-positioned dropdown nested inside a row/cell. Fixed positioning
    // also guarantees it never overlaps neighboring columns, since it floats
    // independently of the grid instead of stretching a cell.
    @track _rowMenuAccountId = null;
    @track _rowMenuAccountName = '';
    @track _rowMenuStyle = '';
    get showRowMenu() { return !!this._rowMenuAccountId; }
    get rowMenuStyle() { return this._rowMenuStyle; }
    get rowMenuAccountName() { return this._rowMenuAccountName; }

    handleToggleRowMenu(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        if (this._rowMenuAccountId === id) {
            this._rowMenuAccountId = null;
            return;
        }
        const rect = event.currentTarget.getBoundingClientRect();
        this._rowMenuAccountId = id;
        this._rowMenuAccountName = event.currentTarget.dataset.name || '';
        this._rowMenuStyle = `top:${rect.bottom + 4}px; left:${Math.max(8, rect.right - 170)}px;`;
    }

    // ── Resend document-request email (confirm modal, not native confirm() —
    // matches this app's established pattern, see the assign-to-analyst modal).
    @track resendAccountId = null;
    @track resendName = '';
    @track resendSending = false;
    get showResendConfirm() { return !!this.resendAccountId; }

    handleOpenResend() {
        const id = this._rowMenuAccountId;
        const name = this._rowMenuAccountName;
        this._rowMenuAccountId = null;
        if (!id) return;
        this.resendAccountId = id;
        this.resendName = name;
    }

    // ── Documents & Screening header — "Profile Details": a single modal that
    // combines the old View + Edit + Resend Email actions. Legal entity name /
    // Annual spend / Supplier email are editable; the rest are read on load
    // and sent back unchanged on save (same reuse-upsertSupplier pattern the
    // old Edit modal used). "Send email" saves the edits via
    // updateSupplierDetails, THEN resends the document-request email — so the
    // email goes to whatever address was just typed in, not the stale one.
    @track showProfileModal = false;
    @track profileLoading = false;
    @track profileSaving = false;
    @track profileName = '';
    @track profileCountry = '';
    @track profileIndustry = '';
    @track profileEngagement = '';
    @track profileSpend = '';
    @track profileEmail = '';
    @track profileMaterialType = '';
    @track profileServiceCategory = '';
    @track profileSavingOnly = false;
    get isProfileBusy() { return this.profileSaving || this.profileSavingOnly; }
    get isSaveProfileDisabled() {
        return this.isProfileBusy || !this.profileName || !this.profileName.trim();
    }
    get isSendProfileEmailDisabled() {
        return this.isProfileBusy
            || !this.profileName || !this.profileName.trim()
            || !this.profileEmail || !this.profileEmail.trim();
    }
    // Header button swaps to its "active" look while the modal it opens is
    // showing — position never changes, only the outline/fill (see
    // .vc-profile-btn.active in CSS).
    get profileDetailsBtnClass() {
        return this.showProfileModal ? 'vc-profile-btn vc-btn-sm active' : 'vc-profile-btn vc-btn-sm';
    }

    handleOpenProfileDetails() {
        if (!this._selectedSupplierId) return;
        this.showProfileModal = true;
        this.profileLoading = true;
        getSupplierEditDetails({ accountId: this._selectedSupplierId })
            .then((d) => {
                this.profileLoading = false;
                this.profileName = d.supplierName || '';
                this.profileCountry = d.country || '—';
                this.profileIndustry = d.industry || '—';
                this.profileEngagement = d.engagementType || '—';
                this.profileSpend = d.annualSpend || '';
                this.profileEmail = d.supplierEmail || '';
                this.profileMaterialType = d.materialType || '—';
                this.profileServiceCategory = d.serviceCategory || '—';
            })
            .catch((err) => {
                this.profileLoading = false;
                this.showProfileModal = false;
                this._toast('error', 'Could not load supplier', (err && err.body && err.body.message) || 'Unknown error.');
            });
    }

    handleProfileField(event) {
        const field = event.currentTarget.dataset.field;
        const val = event.target.value;
        if (field) this[field] = val;
    }

    handleCloseProfile() {
        this.showProfileModal = false;
    }

    // Save-only — persists the edited fields without touching the supplier's
    // inbox. Shares its field-building with Send Email below.
    handleSaveProfile() {
        if (!this.profileName || !this.profileName.trim()) {
            this._toast('warning', 'Name required', 'Legal entity name cannot be blank.');
            return;
        }
        if (this.profileEmail && !this._isValidEmail(this.profileEmail)) {
            this._toast('warning', 'Invalid email', 'Enter a valid supplier email address (e.g. name@company.com).');
            return;
        }
        const accountId = this._selectedSupplierId;
        this.profileSavingOnly = true;
        updateSupplierDetails({
            accountId,
            supplierName: this.profileName,
            country: this.profileCountry,
            industry: this.profileIndustry,
            engagementType: this.profileEngagement,
            annualSpend: this.profileSpend,
            supplierEmail: this.profileEmail,
            materialType: this.profileMaterialType || null,
            serviceCategory: this.profileServiceCategory || null
        })
            .then(() => {
                this.profileSavingOnly = false;
                this.showProfileModal = false;
                this._selectedSupplierName = this.profileName;
                this._toast('success', 'Supplier updated', 'Supplier details were saved.');
                this.refreshQueue();
                this._loadSnapshot(true);
            })
            .catch((err) => {
                this.profileSavingOnly = false;
                this._toast('error', 'Could not save', (err && err.body && err.body.message) || 'Unknown error.');
            });
    }

    handleSendProfileEmail() {
        if (!this.profileName || !this.profileName.trim()) {
            this._toast('warning', 'Name required', 'Legal entity name cannot be blank.');
            return;
        }
        if (!this._isValidEmail(this.profileEmail)) {
            this._toast('warning', 'Invalid email', 'Enter a valid supplier email address (e.g. name@company.com).');
            return;
        }
        const accountId = this._selectedSupplierId;
        this.profileSaving = true;
        updateSupplierDetails({
            accountId,
            supplierName: this.profileName,
            country: this.profileCountry,
            industry: this.profileIndustry,
            engagementType: this.profileEngagement,
            annualSpend: this.profileSpend,
            supplierEmail: this.profileEmail,
            materialType: this.profileMaterialType || null,
            serviceCategory: this.profileServiceCategory || null
        })
            .then(() => resendDocumentRequestEmail({ accountId }))
            .then(() => {
                this.profileSaving = false;
                this.showProfileModal = false;
                this._selectedSupplierName = this.profileName;
                this._toast('success', 'Email sent', 'Supplier details were updated and the document request email was resent.');
                this.refreshQueue();
                this._loadSnapshot(true);
            })
            .catch((err) => {
                this.profileSaving = false;
                this._toast('error', 'Could not complete', (err && err.body && err.body.message) || 'Unknown error.');
            });
    }

    handleCancelResend() {
        this.resendAccountId = null;
        this.resendName = '';
    }
    handleConfirmResend() {
        const accountId = this.resendAccountId;
        this.resendSending = true;
        resendDocumentRequestEmail({ accountId })
            .then(() => {
                this.resendSending = false;
                this.resendAccountId = null;
                this.resendName = '';
                this._toast('success', 'Email sent', 'The document request email (with portal link) was resent.');
            })
            .catch((err) => {
                this.resendSending = false;
                this._toast('error', 'Could not resend', (err && err.body && err.body.message) || 'Unknown error.');
            });
    }


    // ── Existing-supplier snapshot (detail + stored docs + past AI summaries) ──
    @track snapshotLoading = false;
    @track storedDocs = [];
    @track pastAssessments = [];
    @track snapTier = '';
    @track snapStatus = '';
    @track snapRiskScore = 0;
    @track snapDomains = [];
    // Checklist coverage from getSupplierSnapshot (server-computed, same
    // definition as the Supplier Queue table's docsUploaded/docsTotal) — NOT
    // storedDocs.length, which counts every ContentDocument ever linked
    // (superseded/unmatched files included) and never matched the checklist
    // size shown right next to it.
    @track snapDocsUploaded = 0;
    @track snapDocsTotal = 0;
    get checklistCoverageLabel() { return `${this.snapDocsUploaded}/${this.snapDocsTotal} uploaded`; }
    // Segregation of duties: once routedToAnalyst is true, Procurement's
    // approve action is greyed out even before assignToAnalyst() has run —
    // the server also enforces this (approveDocumentAsProcurement checks
    // Analyst_Assigned_DateTime__c), this is just the proactive UI signal.
    @track routedToAnalyst = false;
    @track isAssignedToAnalyst = false;

    get procurementApproveLocked() { return this.routedToAnalyst || this.isAssignedToAnalyst; }
    get procurementApproveLockedNote() {
        if (this.isAssignedToAnalyst) return 'Handed off to the Analyst';
        if (this.routedToAnalyst) return 'This risk tier requires Analyst review';
        return '';
    }
    // WFL-06 — deliberately narrower than procurementApproveLocked above,
    // which also covers routedToAnalyst (a proactive PRE-handoff warning:
    // "this risk tier will need an Analyst," true even before assignToAnalyst
    // has actually run). The full read-only lock — Add files, Remove item,
    // and Approve/Reject/Defer all disabling — should only kick in once
    // handoff has GENUINELY happened, not on the earlier warning state.
    get isPostHandoffLocked() { return this.isAssignedToAnalyst; }
    get postHandoffLockNote() {
        return this.isAssignedToAnalyst
            ? 'This supplier has been handed off to the Analyst — Procurement can view but no longer edit this case.'
            : '';
    }
    // Same 3-state signal as procurementApproveLockedNote, phrased as a
    // status rather than a warning — surfaced in the header strip so who
    // currently owns this supplier is visible without scrolling down to the
    // compliance documents card.
    get ownerLabel() {
        if (this.isAssignedToAnalyst) return 'Analyst';
        if (this.routedToAnalyst) return 'Analyst (pending assignment)';
        return 'Procurement';
    }

    // WFL-05 — every checklist item is mandatory (no separate flag), so
    // "ready to hand off" means every row either has no open action left:
    // an uploaded document with a Procurement decision recorded, OR isn't
    // uploaded at all (that's a different, already-visible gap — "Not
    // uploaded" shows directly in the row — not something Approve/Reject/
    // Defer can act on anyway, since those buttons are gated on hasFile).
    // Undecided = uploaded but no procurementDecision yet.
    get undecidedRequirements() {
        return (this.complianceRows || []).filter(r => r.uploaded && !r.hasProcurementDecision);
    }
    get isReadyForHandoff() { return this.undecidedRequirements.length === 0; }
    get isHandoffBlocked() { return !this.isReadyForHandoff; }
    get handoffBlockedReason() {
        const n = this.undecidedRequirements.length;
        if (n === 0) return '';
        return `${n} document${n === 1 ? '' : 's'} still need${n === 1 ? 's' : ''} a decision before handoff.`;
    }

    // Issue 5/6: Approve and Defer both count as "decided" for
    // isReadyForHandoff above, but they mean different things for what
    // Procurement can do NEXT. A Deferred document means Procurement wants
    // an Analyst's judgment — that case must go to the Analyst queue
    // (Assign to analyst, existing action). Only when EVERY uploaded
    // requirement is Approved (none Deferred, nothing left undecided) can
    // Procurement onboard the supplier directly, with no Analyst involved at
    // all — see onboardSupplierDirectly's own gate (server-side re-check,
    // same as this client-side one).
    get deferredRequirements() {
        return (this.complianceRows || []).filter(r => r.uploaded && r.procurementDecision === 'Deferred');
    }
    get isReadyForDirectOnboard() {
        return this.isReadyForHandoff && this.deferredRequirements.length === 0
            && (this.complianceRows || []).some(r => r.uploaded);
    }

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
        this.snapDocsUploaded = 0;
        this.snapDocsTotal = 0;
        this.routedToAnalyst = false;
        this.isAssignedToAnalyst = false;
        this.procNote = '';
        this.copilotMessages = [];
        this._copilotGreeted = false;
    }

    // silent=true skips the loading banner — used by the passive background
    // sync so a routine 15s catch-up poll never flashes "Loading supplier
    // record…" and reads as the screen constantly reloading. The user-facing
    // loads (opening a supplier, clicking Refresh, etc.) still show it.
    _loadSnapshot(silent = false) {
        if (!this._selectedSupplierId) return;
        if (!silent) this.snapshotLoading = true;
        this._startBackgroundSync();
        getSupplierSnapshot({ accountId: this._selectedSupplierId })
            .then(s => {
                this.snapshotLoading = false;
                if (!this._selectedSupplierName) this._selectedSupplierName = s.name || '';
                this.snapTier = s.riskTier || '';
                this.snapStatus = s.onboardingStatus || '';
                this.snapRiskScore = (s.riskScore == null) ? 0 : Math.round(s.riskScore);
                this.snapDocsUploaded = s.docsUploaded || 0;
                this.snapDocsTotal = s.docsTotal || 0;
                this.routedToAnalyst = s.routedToAnalyst === true;
                this.isAssignedToAnalyst = s.isAssignedToAnalyst === true;
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
                // Only clear an open preview on a genuine reload (opening a
                // supplier, manual refresh) — NOT on the silent 15s
                // background sync (_startBackgroundSync), which was closing
                // an open PDF preview out from under the user every cycle.
                // A preview whose underlying document was actually removed
                // is still closed separately, below, once storedDocs no
                // longer contains it.
                if (!silent) {
                    this._previewUrl = null;
                    this._previewTitle = '';
                }
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
                        checksPassed: parsed.checksPassed.map((t, j) => ({ id: 'cp' + i + '_' + j, text: t })),
                        hasChecksPassed: parsed.checksPassed.length > 0,
                        concerns: parsed.concerns.map((t, j) => ({ id: 'ac' + i + '_' + j, text: t })),
                        hasConcerns: parsed.concerns.length > 0,
                        validUntil: x.validUntil,
                        evaluatedLabel: x.evaluatedLabel,
                        badgeClass: 'vc-badge ' + (x.badgeClass || 'neutral'),
                        confidence: (x.aiConfidence == null) ? 'Not scored yet' : x.aiConfidence + '%',
                        uploaded: x.uploaded === true
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
                // Requirements a rejected file could be connected to instead of
                // creating a brand-new checklist item — every checklist item is
                // offered, not just open ones: connecting to one that already has
                // a document replaces it with this file (linkDocumentToCompliance
                // unconditionally repoints Compliance_Assessment__c.Compliance_Document__c
                // and re-triggers AI assessment). Already-uploaded items are
                // labeled so procurement knows connecting will replace the file.
                const openRequirementOptions = this.complianceRows
                    .filter(r => r.assessmentId)
                    .map(r => ({
                        value: r.assessmentId,
                        label: r.uploaded ? `${r.label} (replaces current document)` : r.label
                    }));

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
                        reason: 'Uploaded but not matched to any checklist requirement - add it if relevant.',
                        connecting: false,
                        removing: false,
                        selectedRequirementId: '',
                        requirementOptions: openRequirementOptions,
                        hasRequirementOptions: openRequirementOptions.length > 0
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

    // Strips a trailing "- Approved"/"- Rejected"/"- Deferred" from a reason
    // string, so the decision note doesn't repeat the decision word already
    // shown in the badge.
    _stripDecisionSuffix(reason) {
        return (reason || '').replace(/\s*-\s*(Approved|Rejected|Deferred)\s*$/i, '');
    }

    // ok (Approved) | bad (Rejected) | warn (Deferred) — matches the same
    // 3-color severity language used everywhere else in this console.
    _decisionBadgeClass(decision) {
        if (decision === 'Rejected') return 'bad';
        if (decision === 'Deferred') return 'warn';
        return 'ok';
    }

    // Latest-decision dot shown above the filename on every checklist row —
    // blue=Approved, red=Rejected, yellow=Deferred. No dot at all when there's
    // no decision yet (hasProcurementDecision gates that in the template).
    // Distinct color language from _decisionBadgeClass above on purpose: the
    // badge above reuses the ok/warn/bad severity palette already used
    // elsewhere, but a dot needs to be legible at a glance with no label next
    // to it, so Approved gets blue (a neutral "done, on file" signal) rather
    // than green — green is already the dashboard's own "fully compliant"
    // color and would read as a stronger claim than "Procurement accepted
    // this one document."
    _decisionDotColor(decision) {
        if (decision === 'Approved') return 'vc-dot-blue';
        if (decision === 'Rejected') return 'vc-dot-red';
        if (decision === 'Deferred') return 'vc-dot-yellow';
        return '';
    }
    _decisionDotTitle(decision) {
        if (decision === 'Approved') return 'Approved';
        if (decision === 'Rejected') return 'Rejected';
        if (decision === 'Deferred') return 'Deferred';
        return '';
    }

    // Build one merged row: requirement + tick state + AI verdict/summary + file.
    _buildComplianceRow(x, i) {
        const ticked = x.uploaded === true;   // B1: tick on upload, validated or not
        const parsed = this._parseSummary(x.reason);
        // Match the linked file (for preview/remove/fileName) by its real
        // ContentDocumentId (x.contentDocumentId, sourced server-side from
        // Compliance_Document__c.Source_File__c) — NOT by fuzzy-matching
        // x.documentTitle, which is actually the requirement's own label
        // (Document_Type__c), not the uploaded file's name. A real upload's
        // filename routinely shares no substring with its requirement's
        // label — that fuzzy match was misclassifying correctly-linked
        // uploads as unmatched (Uploaded file column showing the checklist
        // name instead of the file name, Preview/Remove missing). Fuzzy
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
        // The toggle now expands the WHOLE activity panel (AI summary +
        // Approve/Reject + Decision & notes together), not just the AI
        // summary — so it must appear whenever ANY of those has something to
        // show, not only when there's an AI headline.
        const hasAiDetail = !!(parsed.headline || parsed.checksPassed.length || parsed.concerns.length);
        const hasApproveReject = !!file && x.procurementDecision !== 'Approved';
        const hasCommentHistory = (x.procurementComments || []).length > 0;
        const hasDocLinks = (x.documentLinks || []).length > 0;
        const hasDetail = hasAiDetail || hasApproveReject || hasCommentHistory || hasDocLinks;
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
            assessmentId: x.assessmentId || null,
            approved: x.approved === true,
            // Procurement's own Approve/Reject decision — separate from the AI/
            // Analyst verdict above; never touches Status__c (see recordProcurementDecision).
            // Full comment history (newest first) — every past decision stays
            // visible with its own timestamp, not just the latest.
            comments: (x.procurementComments || []).map((c, j) => ({
                id: 'pc' + i + '_' + j,
                decision: c.decision,
                reason: this._stripDecisionSuffix(c.reason),
                actorName: c.actorName || 'Procurement',
                dateLabel: c.dateLabel || '',
                badgeClass: 'vc-badge ' + this._decisionBadgeClass(c.decision),
                isSupplierComment: c.isSupplierComment === true
            })),
            hasComments: (x.procurementComments || []).length > 0,
            hasProcurementDecision: !!x.procurementDecision,
            procurementDecision: x.procurementDecision || null,
            decisionDotClass: 'vc-decision-dot ' + this._decisionDotColor(x.procurementDecision),
            decisionDotTitle: this._decisionDotTitle(x.procurementDecision),
            // WFL-03: the supplier has responded to a past rejection (re-upload
            // or reply comment) — surfaced so Procurement can tell "still
            // waiting on them" apart from "they answered, take another look."
            pendingReReview: x.pendingReReview === true,
            // Approve/Reject/Defer stay visible for as long as the row isn't
            // Approved — including after a Reject or a Defer, so re-deciding
            // on a supplier's follow-up (a reply or re-upload) is just
            // clicking one of the three again, no separate "comment" action
            // needed. They disappear ONLY once Approved — a Deferred row
            // stays actionable pre-handoff in case Procurement reconsiders
            // before an Analyst ever sees it. linkDocumentToCompliance clears
            // procurementDecision whenever the linked document is replaced,
            // so a fresh upload also brings the buttons back.
            // WFL-06: also hidden once genuinely handed off — Procurement's
            // judgment authority on this case ends at that point, same
            // reasoning as the Add files / Remove item lock.
            showApproveReject: x.procurementDecision !== 'Approved' && !this.isPostHandoffLocked,
            isDeferred: x.procurementDecision === 'Deferred',
            decisionOpen: false,
            pendingDecision: '',
            decisionPromptLabel: '',
            decisionReasonDraft: '',
            isDecisionSubmitDisabled: true,
            decisionSaving: false,
            reassessing: false,
            // AI confidence (0-100) — shows the engine's certainty in its verdict
            confidence: (x.aiConfidence == null) ? null : x.aiConfidence,
            confidenceLabel: (x.aiConfidence == null) ? '' : x.aiConfidence + '% confidence',
            hasConfidence: x.aiConfidence != null,
            // structured AI summary (expand on demand) — two-section: what
            // checks out (green) vs. what's wrong (red), matching the
            // reference design. Deterministic gates + registry results are
            // already folded into these same two lists server-side.
            headline: parsed.headline,
            hasHeadline: !!parsed.headline,
            checksPassed: parsed.checksPassed.map((t, j) => ({ id: 'cf' + i + '_' + j, text: t })),
            hasChecksPassed: parsed.checksPassed.length > 0,
            concerns: parsed.concerns.map((t, j) => ({ id: 'co' + i + '_' + j, text: t })),
            hasConcerns: parsed.concerns.length > 0,
            evaluatedLabel: x.evaluatedLabel || '',
            hasEvaluatedLabel: !!x.evaluatedLabel,
            hasAiSummary: hasAiDetail,
            hasDetail,
            expanded,
            toggleLabel: expanded ? 'Hide detail ▴' : 'Show detail ▾',
            // linked file → inline preview / remove + the uploaded file's name
            fileId: file ? file.id : '',
            contentDocumentId: file ? file.contentDocumentId : '',
            hasFile: !!file,
            fileName: file ? file.title : (x.documentTitle || ''),
            hasFileName: !!(file ? file.title : x.documentTitle),
            // Multi-document-per-requirement: each linked file gets its own
            // sub-row with its own parsed AI summary, shown distinctly rather
            // than blended into one summary — the requirement-level verdict
            // above stays the worst-wins rollup (see DocAssessQueueable.
            // rollupRequirementStatus), this is the per-file detail underneath it.
            documentLinks: (x.documentLinks || []).map((dl, j) => this._buildLinkedDocRow(dl, i, j)),
            hasDocumentLinks: (x.documentLinks || []).length > 0,
            // "Add another file" — only offered once the requirement already
            // has at least one file (single or multi), and never post-handoff.
            addFileOpen: false
        };
    }

    _buildLinkedDocRow(dl, i, j) {
        const parsed = this._parseSummary(dl.reason);
        return {
            id: 'dl' + i + '_' + j,
            docLinkId: dl.docLinkId,
            documentTitle: dl.documentTitle || 'Untitled document',
            status: dl.status || 'Pending',
            badgeClass: 'vc-badge ' + (dl.badgeClass || 'neutral'),
            hasVerdict: !!dl.status && dl.status !== 'Pending',
            confidenceLabel: dl.aiConfidence == null ? '' : dl.aiConfidence + '% confidence',
            hasConfidence: dl.aiConfidence != null,
            headline: parsed.headline,
            hasHeadline: !!parsed.headline,
            checksPassed: parsed.checksPassed.map((t, k) => ({ id: 'dlcp' + i + '_' + j + '_' + k, text: t })),
            hasChecksPassed: parsed.checksPassed.length > 0,
            concerns: parsed.concerns.map((t, k) => ({ id: 'dlco' + i + '_' + j + '_' + k, text: t })),
            hasConcerns: parsed.concerns.length > 0,
            versionId: dl.versionId || '',
            contentDocumentId: dl.contentDocumentId || '',
            hasFile: !!dl.versionId
        };
    }

    // Releases a document's AI summary for supplier-portal visibility — a
    // visibility gate, not a compliance verdict (that's the Analyst's job via
    // Confirm/Override in scAnalystConsole, which is what actually sets
    // Status__c and drives the risk score). See approveDocumentAsProcurement —
    // Apex enforces this is only allowed pre-handoff; toasts the specific
    // error if the supplier has already moved to the Analyst's queue.
    handleApproveDoc(event) {
        const assessmentId = event.currentTarget.dataset.assessmentId;
        if (!assessmentId) return;
        approveDocumentAsProcurement({ assessmentId, comment: null, approved: true })
            .then(() => {
                this.complianceRows = this.complianceRows.map((r) =>
                    r.assessmentId === assessmentId
                        ? { ...r, approved: true, approveLabel: 'Shared with supplier ✓' }
                        : r);
                this._toast('success', 'Shared with supplier', 'The supplier can now see this document\'s AI summary in their portal.');
            })
            .catch((err) => {
                this._toast('error', 'Could not approve',
                    (err && err.body && err.body.message) || 'Unknown error.');
            });
    }

    // Re-runs AI assessment for just THIS document — replaces the old
    // whole-supplier "Refresh" button that used to sit at the top of
    // Documents & Screening (removed: it silently re-summarized every
    // document at once, with no way to target the one a user actually
    // wanted re-checked). Scoped per row, next to Approve/Reject.
    handleReassessDoc(event) {
        const assessmentId = event.currentTarget.dataset.assessmentId;
        if (!assessmentId) return;
        this.complianceRows = this.complianceRows.map((r) =>
            r.assessmentId === assessmentId ? { ...r, reassessing: true } : r);
        reassessDocument({ assessmentId })
            .then(() => {
                this._toast('success', 'Re-assessment started', 'The AI is re-checking this document.');
                this._loadSnapshot();
                this._pollForAssessment();
            })
            .catch((err) => {
                this.complianceRows = this.complianceRows.map((r) =>
                    r.assessmentId === assessmentId ? { ...r, reassessing: false } : r);
                this._toast('error', 'Could not re-assess',
                    (err && err.body && err.body.message) || 'Unknown error.');
            });
    }

    // ── Procurement's own Approve/Reject/Defer decision (separate checkpoint
    // from the AI/Analyst verdict — see recordProcurementDecision). Opens a
    // required-reason box; nothing is saved until Submit.
    handleOpenApproveDecision(event) {
        this._openDecisionBox(event.currentTarget.dataset.key, 'Approved');
    }

    handleOpenRejectDecision(event) {
        this._openDecisionBox(event.currentTarget.dataset.key, 'Rejected');
    }

    // Defer: Procurement can't make the call on this document — the reason
    // is an internal note for whichever Analyst the case is later assigned
    // to (see VendorPortalController.recordProcurementDecision), never shown
    // to the supplier. Same required-reason box as Approve/Reject.
    handleOpenDeferDecision(event) {
        this._openDecisionBox(event.currentTarget.dataset.key, 'Deferred');
    }

    _decisionPromptLabel(decision) {
        if (decision === 'Deferred') return 'Why can\'t you decide on this document? (visible to the Analyst only)';
        return `Reason for ${decision.toLowerCase() === 'approved' ? 'approving' : 'rejecting'}`;
    }

    _openDecisionBox(key, decision, prefillReason = '') {
        this.complianceRows = this.complianceRows.map((r) =>
            r.key === key
                ? {
                    ...r,
                    decisionOpen: true,
                    pendingDecision: decision,
                    decisionPromptLabel: this._decisionPromptLabel(decision),
                    decisionReasonDraft: prefillReason,
                    isDecisionSubmitDisabled: !prefillReason.trim()
                }
                : { ...r, decisionOpen: false, pendingDecision: '', decisionReasonDraft: '' });
    }

    handleDecisionReasonInput(event) {
        const key = event.currentTarget.dataset.key;
        const value = event.target.value;
        this.complianceRows = this.complianceRows.map((r) =>
            r.key === key
                ? { ...r, decisionReasonDraft: value, isDecisionSubmitDisabled: !value.trim() }
                : r);
    }

    handleCancelDecision(event) {
        const key = event.currentTarget.dataset.key;
        this.complianceRows = this.complianceRows.map((r) =>
            r.key === key
                ? { ...r, decisionOpen: false, pendingDecision: '', decisionReasonDraft: '' }
                : r);
    }

    handleSubmitDecision(event) {
        const key = event.currentTarget.dataset.key;
        const row = this.complianceRows.find((r) => r.key === key);
        if (!row || !row.assessmentId || !row.decisionReasonDraft.trim()) return;
        const decision = row.pendingDecision;
        const reason = row.decisionReasonDraft.trim();
        this.complianceRows = this.complianceRows.map((r) =>
            r.key === key ? { ...r, decisionSaving: true } : r);
        recordProcurementDecision({ assessmentId: row.assessmentId, decision, reason })
            .then(() => {
                // Reload from the server instead of guessing the new comment's
                // timestamp/label on the client — Event_DateTime__c is formatted
                // Apex-side in the org's fixed timezone (see getSupplierSnapshot),
                // which never matches a client-built Date() using the browser's
                // own local timezone. Reloading guarantees this row shows the
                // exact same text a manual refresh would.
                this._loadSnapshot();
                this._toast('success', `Document ${decision.toLowerCase()}`, 'Your decision has been recorded.');
            })
            .catch((err) => {
                this.complianceRows = this.complianceRows.map((r) =>
                    r.key === key ? { ...r, decisionSaving: false } : r);
                this._toast('error', 'Could not save decision',
                    (err && err.body && err.body.message) || 'Unknown error.');
            });
    }

    // ── Post-submit (record page / P3) checklist editing ──────────────────────
    // Unlike the intake screen's PRE-submit editing (pure local state — see
    // handleRemoveChecklistItem/handleAddChecklistItem above), this checklist
    // is already persisted as Compliance_Assessment__c rows, so add/remove
    // here must call Apex — and the change is immediately visible to the
    // supplier (getSupplierSnapshot, which both this console and the portal
    // call, simply reflects the current row set on its next load/poll).
    @track newRequirementName = '';
    get isAddRequirementDisabled() { return !this.newRequirementName || !this.newRequirementName.trim(); }

    handleNewRequirementChange(event) {
        this.newRequirementName = event.target.value;
    }

    handleAddRequirement() {
        const label = (this.newRequirementName || '').trim();
        if (!label || !this._selectedSupplierId) return;
        addChecklistRequirement({ accountId: this._selectedSupplierId, documentLabel: label })
            .then(() => {
                this.newRequirementName = '';
                this._toast('success', 'Added', `"${label}" added to the checklist.`);
                this._loadSnapshot();
            })
            .catch((err) => {
                this._toast('error', 'Could not add',
                    (err && err.body && err.body.message) || 'Unknown error.');
            });
    }

    handleRemoveRequirement(event) {
        const assessmentId = event.currentTarget.dataset.assessmentId;
        if (!assessmentId) return;
        // eslint-disable-next-line no-alert
        if (!confirm('Remove this required document from the checklist? The supplier will no longer be asked for it.')) {
            return;
        }
        removeChecklistRequirement({ assessmentId })
            .then(() => {
                this._toast('success', 'Removed', 'Document removed from the checklist.');
                this._loadSnapshot();
            })
            .catch((err) => {
                this._toast('error', 'Could not remove',
                    (err && err.body && err.body.message) || 'Unknown error.');
            });
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
                    toggleLabel: !r.expanded ? 'Hide detail ▴' : 'Show detail ▾' }
                : r);
    }

    // Track which existing requirement the user picked in a rejected row's dropdown.
    handleRejectedRequirementChange(event) {
        const id = event.currentTarget.dataset.id;
        const value = event.target.value;
        this.rejectedDocs = this.rejectedDocs.map(r =>
            r.id === id ? { ...r, selectedRequirementId: value } : r);
    }

    // Connects a rejected/unmatched file to an EXISTING open requirement —
    // reuses linkDocumentToCompliance's assessmentId parameter, the same
    // mechanism the auto-fuzzy-match on upload uses (see _fuzzyMatchRequirement).
    handleConnectRejected(event) {
        const id = event.currentTarget.dataset.id;
        const rej = this.rejectedDocs.find(r => r.id === id);
        if (!rej || !rej.selectedRequirementId || !rej.contentDocumentId) return;
        this.rejectedDocs = this.rejectedDocs.map(r =>
            r.id === id ? { ...r, connecting: true } : r);
        linkDocumentToCompliance({
            accountId: this._selectedSupplierId,
            contentDocumentId: rej.contentDocumentId,
            documentType: rej.title,
            assessmentId: rej.selectedRequirementId,
            fileName: rej.title
        })
            .then(() => {
                this._toast('success', 'Connected',
                    `"${rej.title}" is now linked to the selected checklist item and queued for AI assessment.`);
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

    // Delete an unmatched upload outright — for a file that isn't relevant to
    // any checklist item and doesn't need to be "connected" anywhere. Looks
    // the doc up in rejectedDocs (its own id namespace, 'rj'+i), not
    // storedDocs, since that's what the button in this card is keyed by.
    handleRemoveRejectedDoc(event) {
        const id = event.currentTarget.dataset.id;
        const rej = this.rejectedDocs.find(r => r.id === id);
        if (!rej || !rej.contentDocumentId) {
            this._toast('warning', 'Cannot remove', 'This document has no removable file reference.');
            return;
        }
        this.rejectedDocs = this.rejectedDocs.map(r =>
            r.id === id ? { ...r, removing: true } : r);
        removeSupplierDocument({ accountId: this._selectedSupplierId, contentDocumentId: rej.contentDocumentId })
            .then(() => {
                this._toast('success', 'Document removed', `"${rej.title}" was removed.`);
                this._loadSnapshot();
            })
            .catch(err => {
                this.rejectedDocs = this.rejectedDocs.map(r =>
                    r.id === id ? { ...r, removing: false } : r);
                this._toast('error', 'Remove failed',
                    (err && err.body && err.body.message) || 'Could not remove the document.');
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
    // Parse the AI summary blob (DocAssessQueueable.buildDetail) into a
    // headline plus two flat lists — checksPassed (✓) and concerns (⚠).
    // Deterministic gates (expiry/coverage/TIN/scope) and registry results
    // are already folded into these same two lists server-side, by their own
    // pass/fail — there's no separate "clause checks" section to parse here.
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

    // Documents tab: only checklist assessments, no screening rows.
    get docOnlyAssessments() {
        return this.pastAssessments.filter(a => !(a.label || '').startsWith('Screening — '));
    }
    get hasDocOnlyAssessments() { return this.docOnlyAssessments.length > 0; }

    // P4 submission table: non-screening assessments carry the real per-document
    // AI confidence (from /assess, persisted on the assessment); "Not scored yet" when absent.
    get submissionRows() {
        return this.docOnlyAssessments;
    }
    get hasSubmissionRows() { return this.submissionRows.length > 0; }

    // Shape the checklist assessments for the shared dashboard: map each doc's
    // compliance status to a decision the dashboard scores deterministically.
    get dashboardDocs() {
        return this.docOnlyAssessments.map(a => ({
            decision: this._statusToDecision(a.status),
            confidence: a.confidence,
            uploaded: a.uploaded
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
        this._setScreen('p2');
        this._closeAssign();
        this.copilotOpen = false;
        this._stopAssessPoll();
        this._stopBackgroundSync();
    }

    // P3 has its own two tabs: Documents and Screening.
    @track p3Tab = 'documents';
    get isDocsTab() { return this.p3Tab === 'documents'; }
    get isScreeningTab() { return this.p3Tab === 'screening'; }
    get docsTabClass() { return this.p3Tab === 'documents' ? 'vc-tab active' : 'vc-tab'; }
    get screeningTabClass() { return this.p3Tab === 'screening' ? 'vc-tab active' : 'vc-tab'; }
    handleP3Tab(event) {
        this.p3Tab = event.currentTarget.dataset.tab;
        // Flash "stored results shown below" once per visit to the tab, only
        // when there's actually something stored to explain — not on every
        // background snapshot reload triggered by unrelated actions.
        if (this.p3Tab === 'screening' && this.hasScreeningResults) this._flashStoredNote();
    }

    // P3/P4 are sub-items under "Supplier queue" in the left nav.
    get showP3SubNav() { return this.activeScreen === 'p3' || this.activeScreen === 'p4'; }
    get sbP3SubActive() { return this.activeScreen === 'p3' ? 'vc-sb-subitem active' : 'vc-sb-subitem'; }
    get sbP4SubActive() { return this.activeScreen === 'p4' ? 'vc-sb-subitem active' : 'vc-sb-subitem'; }
    handleP3NavClick() {
        this._setScreen('p3');
    }
    handleP4NavClick() {
        this._setScreen('p4');
    }
    handleGoToSubmission() {
        this._setScreen('p4');
    }
    handleBackToDocuments() {
        this._setScreen('p3');
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

    // DOC-02: per-row upload — targets ONE specific requirement directly
    // instead of relying on the top dropzone's fuzzy filename match. Opens the
    // same hidden file input, but remembers which row triggered it so
    // handleRowFilePicked can pass that assessmentId straight through.
    _rowUploadAssessmentId = null;
    handleRowUpload(event) {
        if (!this._selectedSupplierId) {
            this._toast('warning', 'No supplier', 'Open a supplier before uploading documents.');
            return;
        }
        this._rowUploadAssessmentId = event.currentTarget.dataset.assessmentId || null;
        const picker = this.template.querySelector('.vc-row-file-input');
        if (picker) picker.click();
    }
    handleRowFilePicked(event) {
        const file = (event.target.files || [])[0];
        event.target.value = '';
        const assessmentId = this._rowUploadAssessmentId;
        this._rowUploadAssessmentId = null;
        if (!file || !assessmentId) return;
        this._uploadOne(file, assessmentId);
    }

    // Multi-document-per-requirement: "Add another file" on a requirement
    // that already has at least one document linked — same file-picker
    // plumbing as the single-file row upload above, but targets the ADD
    // Apex entry point so the new file becomes an additional
    // Compliance_Document_Link__c row instead of replacing what's there.
    _addFileAssessmentId = null;
    handleAddAnotherFile(event) {
        if (!this._selectedSupplierId) {
            this._toast('warning', 'No supplier', 'Open a supplier before uploading documents.');
            return;
        }
        this._addFileAssessmentId = event.currentTarget.dataset.assessmentId || null;
        const picker = this.template.querySelector('.vc-add-file-input');
        if (picker) picker.click();
    }
    handleAddFilePicked(event) {
        const file = (event.target.files || [])[0];
        event.target.value = '';
        const assessmentId = this._addFileAssessmentId;
        this._addFileAssessmentId = null;
        if (!file || !assessmentId) return;

        const tempId = 'u' + Date.now() + Math.floor(Math.random() * 1000);
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
                    addDocumentToCompliance({
                        accountId: this._selectedSupplierId,
                        contentDocumentId,
                        documentType: file.name,
                        assessmentId,
                        fileName: file.name
                    })
                )
                .then(() => {
                    this._setUploadStatus(tempId, 'Uploaded · AI assessing');
                    this._toast('success', 'Added', `${file.name} added as a second document for this requirement.`);
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

    // DOC-02: forcedAssessmentId lets a per-row upload (the user explicitly
    // picked a requirement) skip the fuzzy-matcher entirely and link straight
    // to that row — the matcher is a best-effort guess for the generic
    // top-of-screen dropzone, not needed once the user has already told us
    // which requirement this file is for.
    _uploadOne(file, forcedAssessmentId) {
        const tempId = 'u' + Date.now() + Math.floor(Math.random() * 1000);
        // Optimistic row while it uploads.
        this.uploadedDocs = [...this.uploadedDocs, {
            id: tempId, name: file.name,
            sizeLabel: `${Math.max(1, Math.round(file.size / 1024))} KB`,
            status: 'Uploading…'
        }];
        // Fuzzy-match the filename against this supplier's OPEN checklist
        // requirement labels (same substring rule already used to display a
        // linked file — see _buildComplianceRow) BEFORE uploading, so a
        // well-named file (e.g. "CMRT_ConflictMinerals_Nordwind.txt" against
        // "Conflict Minerals Due Diligence (OECD/CMRT)") links straight to
        // that requirement instead of always falling through to "Unmatched".
        // Passing assessmentId directly (not just a documentType guess) is
        // what actually makes linkDocumentToCompliance attach to THAT row —
        // documentType alone requires an exact string equality match.
        const matchedAssessmentId = forcedAssessmentId || this._fuzzyMatchRequirement(file.name);

        const reader = new FileReader();
        reader.onload = () => {
            const base64 = (reader.result || '').toString().split(',')[1];
            saveFile({ recordId: this._selectedSupplierId, fileName: file.name, base64Data: base64 })
                .then(contentDocumentId =>
                    linkDocumentToCompliance({
                        accountId: this._selectedSupplierId,
                        contentDocumentId,
                        documentType: file.name,   // best-effort label if no fuzzy match found
                        assessmentId: matchedAssessmentId,   // exact link when a plausible match exists
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

    // Returns the assessmentId of the best-matching OPEN (not yet uploaded)
    // requirement for a filename, or null if nothing plausible matches.
    // Plain substring matching (the rule used elsewhere to join an already-
    // linked file to its row for display) is too strict here — a real
    // filename like "CMRT_ConflictMinerals_Nordwind.txt" shares no substring
    // with its requirement's actual label, "Conflict Minerals Due Diligence
    // (OECD/CMRT)" ("nordwind" isn't in the label; "due diligence" isn't in
    // the filename). Token-overlap scoring catches this: split both into
    // words, count shared significant words (>=3 chars, so "the"/"and"/"of"
    // don't inflate the score), require at least 2 shared tokens so a single
    // generic word (e.g. "certificate") doesn't cause a false match.
    _fuzzyMatchRequirement(fileName) {
        const tokenize = (s) => (s || '')
            .replace(/\.[^.]+$/, '')                 // strip file extension
            .replace(/([a-z])([A-Z])/g, '$1_$2')     // split camelCase: "ConflictMinerals" -> "Conflict_Minerals"
            .toLowerCase()
            .split(/[^a-z0-9]+/)                     // split on any remaining non-alphanumeric run
            .filter((t) => t.length >= 3);
        const fileTokens = new Set(tokenize(fileName));
        if (fileTokens.size === 0) return null;

        const candidates = (this.complianceRows || []).filter((r) => !r.uploaded && r.assessmentId);
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

    // Passive background sync while P3 is open — catches a SUPPLIER
    // re-uploading a document from their own portal session while
    // Procurement is just viewing the screen, with no action of their own to
    // trigger a reload. Deliberately slower/simpler than _pollForAssessment
    // (which watches for a KNOWN pending row from the current user's own
    // action) — this has no specific target to stop early for, it just keeps
    // the snapshot from going stale during a long-open session.
    _backgroundSyncTimer = null;
    _startBackgroundSync() {
        if (this._backgroundSyncTimer) return;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._backgroundSyncTimer = setInterval(() => {
            if (this.activeScreen !== 'p3' || !this._selectedSupplierId) {
                this._stopBackgroundSync();
                return;
            }
            // Never reload out from under a user mid-composing an Approve/
            // Reject/Defer reason — _buildComplianceRow always resets
            // decisionOpen/decisionReasonDraft fresh from the server, which
            // would silently wipe unsaved text. Skip this cycle; the next
            // one retries automatically.
            const hasOpenComposer = (this.complianceRows || []).some(r => r.decisionOpen);
            if (hasOpenComposer) return;
            // Same reasoning for the Profile Details modal — a re-render
            // while it's open re-applies the last-loaded profileEmail/
            // profileName/profileSpend to their inputs, which can stomp on
            // a value the user is still mid-typing (the fields only commit
            // to these tracked properties on blur/onchange, not per keystroke).
            if (this.showProfileModal) return;
            this._loadSnapshot(true);
        }, 15000);
    }
    _stopBackgroundSync() {
        if (this._backgroundSyncTimer) { clearInterval(this._backgroundSyncTimer); this._backgroundSyncTimer = null; }
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
        return `Hi — I'm GRACE, your Vendor Governance, Risk and Compliance Engine, for **${who}**. How may I help?`;
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
        const rows = this.docOnlyAssessments.filter(a => a.hasChecksPassed || a.hasConcerns);
        if (!rows.length) return 'No documents have been AI-assessed yet — upload a document and I\'ll extract its key fields.';
        const out = ['Here are the **key fields** the AI extracted, by document:'];
        rows.forEach(a => {
            out.push(`\n**${a.label}** — ${a.status}`);
            (a.checksPassed || []).forEach(c => out.push(`- ✓ ${c.text}`));
            (a.concerns || []).forEach(c => out.push(`- ⚠ ${c.text}`));
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
        // Capture which case this question was actually asked about — if the
        // user navigates to a different supplier before the callout resolves,
        // the answer (correctly scoped server-side to THIS accountId) must not
        // land in whatever case happens to be open when the response arrives.
        const askedForSupplierId = this._selectedSupplierId;
        this._pushMsg('you', q);
        this.copilotInput = '';
        this.copilotBusy = true;
        askCopilot({ accountId: askedForSupplierId, question: q })
            .then(res => {
                if (this._selectedSupplierId !== askedForSupplierId) return;
                this.copilotBusy = false;
                const answer = (res && (res.answer || res.response)) || 'No answer returned.';
                this._pushMsg('ai', answer);
            })
            .catch(err => {
                if (this._selectedSupplierId !== askedForSupplierId) return;
                this.copilotBusy = false;
                this._pushMsg('ai', 'GRACE error: ' +
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

    // "Stored results shown below" is a one-time orientation note, not a
    // permanent fixture — it stays up 30s (loaded on open OR right after a
    // fresh run) then clears on its own, same pattern as _toast(). The
    // results LIST itself (hasScreeningResults) is untouched and stays
    // visible indefinitely — only this banner times out.
    @track showStoredNote = false;
    _storedNoteTimer = null;
    _flashStoredNote() {
        this.showStoredNote = true;
        if (this._storedNoteTimer) clearTimeout(this._storedNoteTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._storedNoteTimer = setTimeout(() => { this.showStoredNote = false; }, 30000);
    }

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

    // Onboard directly (Issue 5/6) — every uploaded requirement is Approved,
    // none Deferred, so Procurement can finish the case themselves without
    // ever routing it to an Analyst. Reuses the exact same close mechanics as
    // the Analyst's "Auto-approve & Onboard" (closeComplianceCase) — both
    // represent the same outcome, just reached via a different gate.
    @track onboarding = false;
    handleOnboardDirectly() {
        if (!this._selectedSupplierId) { this._toast('warning', 'No supplier', 'Open a supplier first.'); return; }
        this.onboarding = true;
        onboardSupplierDirectly({ accountId: this._selectedSupplierId, closingRemarks: this.procNote })
            .then(() => {
                this.onboarding = false;
                this._toast('success', 'Supplier onboarded',
                    `${this._selectedSupplierName || 'Supplier'} onboarded directly — case closed.`);
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => { this.handleBackToQueue(); this.refreshQueue(); }, 700);
            })
            .catch(err => {
                this.onboarding = false;
                this._toast('error', 'Onboard failed',
                    (err && err.body && err.body.message) || 'Could not onboard this supplier.');
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