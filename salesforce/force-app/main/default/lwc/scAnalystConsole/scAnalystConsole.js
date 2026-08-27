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
import closeComplianceCase from '@salesforce/apex/VendorPortalController.closeComplianceCase';
import sendCaseBackToProcurement from '@salesforce/apex/VendorPortalController.sendCaseBackToProcurement';

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
        this._restoreScreenState();
    }
    disconnectedCallback() { document.removeEventListener('click', this._boundDocClick); }

    // ── Screen-position persistence across a hard refresh ──────────────────────
    // LWC keeps activeScreen/_caseId purely in memory, so a browser refresh
    // always dropped the analyst back to the queue (a1) mid-review, with no
    // way back to the document/decision screen they were just on. This mirrors
    // just enough state (which case, which screen) into sessionStorage — a new
    // tab/session still correctly starts at the queue; only a reload of the
    // SAME tab restores position. _docDecisions/co-pilot state are NOT
    // persisted here on purpose — _loadCase() re-derives the real decision
    // state from the server (see _mapDoc's d.aiStatus fix above), which is the
    // source of truth, not the in-memory click cache.
    _screenStateKey = 'sc_analyst_console_screen';
    _saveScreenState() {
        try {
            if (this._caseId && (this.activeScreen === 'a2' || this.activeScreen === 'a3')) {
                sessionStorage.setItem(this._screenStateKey, JSON.stringify({
                    caseId: this._caseId,
                    screen: this.activeScreen
                }));
            } else {
                sessionStorage.removeItem(this._screenStateKey);
            }
        } catch (e) { /* storage unavailable (private mode, etc.) — fall back to queue silently */ }
    }
    _restoreScreenState() {
        let saved = null;
        try {
            saved = JSON.parse(sessionStorage.getItem(this._screenStateKey) || 'null');
        } catch (e) { /* ignore — corrupt/blocked storage, start at queue */ }
        if (!saved || !saved.caseId) return;
        this._caseId = saved.caseId;
        this._loadCase();
        this.activeScreen = saved.screen === 'a3' ? 'a3' : 'a2';
        this.breadcrumb = BREADCRUMBS[this.activeScreen];
    }
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
        this._saveScreenState();
    }
    handleBackToQueue() {
        this.activeScreen = 'a1';
        this.breadcrumb = BREADCRUMBS.a1;
        this.copilotOpen = false;
        this._selectedDocId = null;
        this._saveScreenState();
    }

    // ── A1 — analyst queue (existing supplier requests) ───────────────────────
    // Defaults to MY assigned cases only — showTeamQueue opts into the full
    // shared view (every analyst's cases) for supervisors who need oversight.
    _wiredQueue;
    @track queueRows = [];
    @track queueLoading = true;
    @track showTeamQueue = false;
    @wire(getAnalystQueue, { showTeamQueue: '$showTeamQueue' })
    wiredQueue(result) {
        this._wiredQueue = result;
        this.queueLoading = false;
        if (result.data) {
            this.queueRows = result.data.map(r => ({
                id: r.id,
                name: r.name,
                industry: r.industry || 'Not set',
                aiTier: r.aiTier || 'Not scored yet',
                tierClass: 'vc-badge ' + this._tierBadge(r.aiTier),
                flags: r.flags,
                flagLabel: r.flags > 0 ? `${r.flags} flagged` : 'none',
                docLabel: `${r.validatedCount}/${r.docCount} validated`,
                stageLabel: r.stageLabel || r.status || 'Not set',
                requestedBy: r.requestedBy || 'Not set',
                ageLabel: r.ageLabel || 'Just now',
                isMine: r.isMine === true,
                stageAgeLabel: r.stageAgeLabel || 'Just now',
                isStalled: r.isStalled === true
            }));
        }
    }
    get hasQueueRows() { return this.queueRows.length > 0; }
    refreshQueue() { if (this._wiredQueue) refreshApex(this._wiredQueue); }

    get teamQueueToggleLabel() { return this.showTeamQueue ? 'Showing: Team queue' : 'Showing: My queue'; }
    handleToggleTeamQueue() { this.showTeamQueue = !this.showTeamQueue; }

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
    @track caseRiskScore = 0;
    // Handoff context — who assigned this case, when, and why. Previously the
    // analyst opened a case with zero indication anything happened before them.
    @track assignedByName = '';
    @track assignedDateLabel = '';
    @track assignmentReason = '';
    @track hasAssignment = false;
    // "Approved by" — wired to Account.Case_Closed_By__c/_DateTime__c (set by
    // closeComplianceCase). hasApproval stays false for any still-open case —
    // that's the correct, honest state, not a placeholder bug.
    @track approvedByName = '';
    @track approvedDateLabel = '';
    @track hasApproval = false;
    get approvedByInitials() {
        const parts = (this.approvedByName || '').trim().split(/\s+/).filter(Boolean);
        if (!parts.length) return '??';
        const first = parts[0].charAt(0);
        const last = parts.length > 1 ? parts[parts.length - 1].charAt(0) : '';
        return (first + last).toUpperCase() || '??';
    }
    get handoffBannerText() {
        if (!this.hasAssignment) return '';
        const who = this.assignedByName || 'Procurement';
        const when = this.assignedDateLabel ? ` · ${this.assignedDateLabel}` : '';
        const why = this.assignmentReason ? ` — "${this.assignmentReason}"` : '';
        return `Assigned by ${who}${when}${why}`;
    }
    handleOpenCase(event) {
        this._caseId = event.currentTarget.dataset.id;
        this._loadCase();
        this.activeScreen = 'a2';
        this.breadcrumb = BREADCRUMBS.a2;
        this._saveScreenState();
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
                this.caseIndustry = c.industry || 'Not set';
                this.caseCountry = c.country || 'Not set';
                this.caseTier = c.aiTier || '';
                this.caseRiskScore = (c.riskScore == null) ? 0 : Math.round(c.riskScore);
                this.confirmedTier = this._uiTier(c.aiTier);
                this.caseDocCount = c.docCount;
                this.caseValidatedCount = c.validatedCount;
                this.assignedByName = c.assignedByName || '';
                this.assignedDateLabel = c.assignedDateLabel || '';
                this.assignmentReason = c.assignmentReason || '';
                this.hasAssignment = c.hasAssignment === true;
                this.approvedByName = c.approvedByName || '';
                this.approvedDateLabel = c.approvedDateLabel || '';
                this.hasApproval = c.hasApproval === true;
                this.docs = (c.docs || []).map(d => this._mapDoc(d));
            })
            .catch(err => {
                this.caseLoading = false;
                this._toast('Load failed', (err && err.body && err.body.message) || 'Could not load the case.');
            });
    }

    // Re-fetches the docs list from the server after a save (Approve/Reject/
    // mark-validated) so every field — Stage (procurementDecision), audit
    // history (commentHistory), Status, everything — reflects real DB state,
    // not a hand-rebuilt partial object. Previously handleApproveDoc/
    // handleRejectDoc patched the row client-side by constructing a NEW
    // object with only ~9 fields copied over, silently dropping
    // procurementDecision/commentHistory (and anything else added to the
    // Apex DTO since) — the Stage column would show "No action" and the
    // audit thread would go empty immediately after clicking, even though
    // the actual save succeeded and the real data was untouched. Unlike
    // _loadCase(), this does NOT reset _selectedDocId/_docDecisions/co-pilot
    // state — the analyst stays exactly where they were.
    _refreshDocs() {
        if (!this._caseId) return Promise.resolve();
        return getCaseForAnalyst({ accountId: this._caseId })
            .then(c => {
                this.caseDocCount = c.docCount;
                this.caseValidatedCount = c.validatedCount;
                this.docs = (c.docs || []).map(d => this._mapDoc(d));
            });
    }

    // Parse the AI summary blob (DocAssessQueueable.buildDetail) into a
    // headline plus two flat lists — checksPassed (✓, green) and concerns
    // (⚠, red) — matching the reference design's "What checks out" / "What's
    // wrong" split. Deterministic gates (expiry/coverage/TIN/scope) and
    // registry results are already folded into these same two lists
    // server-side, by their own pass/fail — same format as Procurement
    // Console and the Supplier Portal, no separate clause-checks list.
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

    // The AI's own verdict, normalized — drives what "Confirm"/"Override" actually
    // mean so the buttons never present a generic, ambiguous "Approve/Reject" that
    // could be mistaken for approving the FILE rather than judging its compliance.
    // Canonical form is 'Non-Compliant' (hyphenated) — matches Status__c's actual
    // picklist label and what DocAssessQueueable.mapVerdict writes; this used to
    // normalize to 'Non_Compliant' (underscore) instead, which meant every
    // analyst Confirm/Override wrote a DIFFERENT spelling into Status__c than the
    // AI's own initial verdict did — RiskScoreService's aggregate query (and
    // ComplianceEmailController's renewal-email branch) match one spelling, not
    // both, so whichever wrote the "wrong" one silently vanished from anything
    // reading Status__c downstream.
    _normalizedAiStatus(aiStatus) {
        const s = (aiStatus || '').toLowerCase();
        if (s === 'compliant') return 'Compliant';
        if (s === 'non-compliant' || s === 'non_compliant') return 'Non-Compliant';
        return null; // Needs Analyst / Pending / At Risk / unknown — no confirmable AI verdict yet
    }

    // Stage column — Procurement's own Approve/Reject/Defer call, distinct
    // from the AI/Analyst verdict shown in the Status column next to it.
    _stageLabel(procurementDecision) {
        if (procurementDecision === 'Approved') return 'Accepted';
        if (procurementDecision === 'Rejected') return 'Rejected';
        if (procurementDecision === 'Deferred') return 'Deferred';
        return 'No action';
    }
    _stageClass(procurementDecision) {
        if (procurementDecision === 'Approved') return 'approved';
        if (procurementDecision === 'Rejected') return 'rejected';
        if (procurementDecision === 'Deferred') return 'deferred';
        return 'none';
    }

    // Audit-thread badge color — covers BOTH decision vocabularies that land
    // in the same history list: Procurement's Approved/Rejected/Deferred and
    // the Analyst's own Compliant/Non-Compliant.
    _historyBadgeClass(decision) {
        if (decision === 'Rejected' || decision === 'Non-Compliant') return 'bad';
        if (decision === 'Deferred') return 'warn';
        return 'ok'; // Approved, Compliant, Uploaded, or a plain reply
    }

    _mapDoc(d) {
        // The analyst's saved decision, straight from the SERVER's real
        // Status__c (d.aiStatus — despite the name, this is the live status
        // field, already flipped to Compliant/Non-Compliant by
        // saveDocValidation) once Analyst_Validated__c (d.validated) is true.
        // Previously this read d.finalStatus, a property that only ever
        // existed as a saveDocValidation() PARAMETER name and a local JS
        // variable name inside the click handlers — it was never actually
        // returned by getCaseForAnalyst on the AnalystDoc DTO, so d.finalStatus
        // was always undefined here. That worked by accident within a single
        // session because this._docDecisions (an in-memory-only cache set at
        // click time) covered for it — but a refresh wipes that cache, the
        // undefined fallback kicked in, and every validated decision reverted
        // to "no decision" (0 Approved / 0 Rejected, buttons unchecked) even
        // though the real DB state — and the audit trail — was untouched.
        const decision = this._docDecisions[d.assessmentId]
            || (d.validated && (d.aiStatus === 'Compliant' || d.aiStatus === 'Non-Compliant') ? d.aiStatus : '');
        const parsed = this._parseSummary(d.aiSummary);
        // Static labels/positions — previously these swapped ("Confirm
        // Non-Compliant" vs. "Override — Mark Compliant", flipping to the
        // opposite depending on the AI's own verdict), which read as
        // confusing since the SAME physical button changed meaning between
        // documents. Now the left button always means "this document is
        // Compliant" and the right button always means "this document is
        // Non-Compliant" — the analyst is stating their own final call, full
        // stop, regardless of what the AI originally said. isConfirmed/
        // isOverridden are kept as their existing names (other code reads
        // them) but now just mean "the analyst's saved decision is Compliant"
        // / "...is Non-Compliant."
        const confirmLabel = 'Compliant';
        const overrideLabel = 'Non-Compliant';
        const confirmStatus  = 'Compliant';
        const overrideStatus = 'Non-Compliant';
        const isConfirmed = decision === confirmStatus && !!decision;
        const isOverridden = decision === overrideStatus && !!decision;
        // decision (approved/rejected/pending) is the FINAL compliance call, not
        // which button was clicked — an override to Compliant must count as
        // 'approved' for the risk score / verdict tally, exactly like a straight
        // confirm of an AI Compliant verdict would. This is the actual bug fix:
        // previously "approved" meant only "the analyst clicked Approve," with no
        // regard for whether the document was ever judged compliant at all.
        const finalDecision = decision === 'Compliant' ? 'approved'
                             : decision === 'Non-Compliant' ? 'rejected'
                             : '';
        return {
            assessmentId: d.assessmentId,
            label: d.requirementLabel,
            aiStatus: d.aiStatus,
            severity: d.severity,
            aiSummary: d.aiSummary || 'No AI summary recorded.',
            headline: parsed.headline,
            hasHeadline: !!parsed.headline,
            checksPassed: parsed.checksPassed.map((t, j) => ({ id: 'cp_' + d.assessmentId + '_' + j, text: t })),
            hasChecksPassed: parsed.checksPassed.length > 0,
            concerns: parsed.concerns.map((t, j) => ({ id: 'cn_' + d.assessmentId + '_' + j, text: t })),
            hasConcerns: parsed.concerns.length > 0,
            comment: d.analystComment || '',
            validated: d.validated,
            // Stage — Procurement's own Accepted/Rejected/Deferred call
            // (Apex already sends d.procurementDecision; it just wasn't
            // consumed here before). Replaces the old Conf. column — AI
            // confidence is still available via aiConfidence if ever needed
            // elsewhere, but isn't shown in the list anymore.
            stageLabel: this._stageLabel(d.procurementDecision),
            stageClass: 'vc-a2-list-stage ' + this._stageClass(d.procurementDecision),
            decision: finalDecision,
            wasOverridden: isOverridden,
            finalStatus: decision || '',
            confirmStatus, overrideStatus,
            badgeClass: 'vc-badge ' + (d.badgeClass || 'neutral'),
            rowClass: d.validated ? 'vc-doc-card validated' : 'vc-doc-card',
            listItemClass: this._selectedDocId === d.assessmentId ? 'vc-a2-list-item selected' : 'vc-a2-list-item',
            // Left (Compliant) button: blue/primary always, filled-active
            // state once selected. Right (Non-Compliant) button: carries the
            // same red identity in EITHER state now (not just when clicked)
            // per the static-color request — vc-doc-rejected is applied
            // unconditionally, with vc-doc-rejected-active layered on top
            // only once selected, so its color never changes meaning.
            approveBtnClass: isConfirmed ? 'vc-btn-pri vc-btn-sm vc-doc-approved-active' : 'vc-btn-pri vc-btn-sm',
            approveLabel: isConfirmed ? '✓ ' + confirmLabel : confirmLabel,
            rejectBtnClass: isOverridden ? 'vc-btn-sec vc-btn-sm vc-doc-rejected vc-doc-rejected-active' : 'vc-btn-sec vc-btn-sm vc-doc-rejected',
            rejectLabel: isOverridden ? '✓ ' + overrideLabel : overrideLabel,
            versionId: d.versionId,
            contentDocumentId: d.contentDocumentId,
            docUrl: d.docUrl,
            fileType: (d.fileType || '').toLowerCase(),
            docTitle: d.docTitle,
            hasDoc: !!(d.versionId || d.docUrl),
            isPreviewing: this._previewDocId === d.assessmentId,
            // Provenance: who last reviewed THIS specific document, and when —
            // was captured server-side but never shown before.
            evaluatedByName: d.evaluatedByName || '',
            evaluatedDateLabel: d.evaluatedDateLabel || '',
            hasEvaluation: !!(d.evaluatedByName && d.evaluatedDateLabel),
            // Procurement Deferred this document — their note is Analyst-only
            // (never shown to the supplier, see getSupplierSnapshot's
            // isSupplierRunningUser filter) and only makes sense to surface
            // once the case actually reaches an Analyst, which is exactly
            // when this console is being used.
            isDeferred: d.isDeferred === true,
            deferralReason: d.procurementDecisionReason || '',
            // Full dated history (newest first) — same Audit_Log__c thread
            // Procurement's own console shows via AssessmentSummary.
            // procurementComments, now given to the Analyst too instead of
            // only the single latest deferralReason above.
            commentHistory: (d.commentHistory || []).map((c, j) => ({
                id: 'ch_' + d.assessmentId + '_' + j,
                decision: c.decision,
                reason: c.reason,
                actorName: c.actorName || 'Procurement',
                dateLabel: c.dateLabel || '',
                // Two decision vocabularies land in this SAME thread —
                // Procurement's Approved/Rejected/Deferred and the Analyst's
                // own Compliant/Non-Compliant (Analyst_Decision_Recorded) —
                // both need their bad/warn/ok color read correctly, not just
                // the Procurement set (Non-Compliant used to fall through to
                // the 'ok'/green default, which read as a Non-Compliant
                // decision being shown as if it were a pass).
                badgeClass: 'vc-badge ' + this._historyBadgeClass(c.decision),
                isSupplierComment: c.isSupplierComment === true
            })),
            hasCommentHistory: (d.commentHistory || []).length > 0,
            // Supplier's own upload path is never locked post-handoff (see
            // VendorPortalController.assertNotHandedOff) — this flags a
            // document that landed AFTER handoff, so it doesn't blend in
            // silently with what Procurement actually reviewed before
            // assigning the case.
            isNewSinceHandoff: d.isNewSinceHandoff === true,
            // Multi-document-per-requirement — see VendorPortalController.
            // AssessmentSummary.documentLinks. Each linked file's own
            // AI summary is parsed the same way the single-document
            // aiSummary above is, so it renders as its own What-checks-out/
            // What's-wrong pair distinct from the requirement-level rollup.
            documentLinks: (d.documentLinks || []).map((dl, j) => this._buildLinkedDocRow(dl, j)),
            hasDocumentLinks: (d.documentLinks || []).length > 0
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
            confidenceLabel: dl.aiConfidence == null ? '' : dl.aiConfidence + '% confidence',
            hasConfidence: dl.aiConfidence != null,
            headline: parsed.headline,
            hasHeadline: !!parsed.headline,
            checksPassed: parsed.checksPassed.map((t, k) => ({ id: 'dlcp' + j + '_' + k, text: t })),
            hasChecksPassed: parsed.checksPassed.length > 0,
            concerns: parsed.concerns.map((t, k) => ({ id: 'dlco' + j + '_' + k, text: t })),
            hasConcerns: parsed.concerns.length > 0,
            contentDocumentId: dl.contentDocumentId || '',
            hasFile: !!dl.versionId
        };
    }
    get hasDocs() { return this.docs.length > 0; }
    get hasSelectedDoc() { return !!this._selectedDocId; }
    get selectedDoc() { return this.docs.find(d => d.assessmentId === this._selectedDocId) || null; }
    get validationProgress() {
        return this.caseDocCount ? `${this.caseValidatedCount}/${this.caseDocCount} documents validated` : 'No documents yet';
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

    // Confirms the AI's verdict as final (or, when the AI had no confirmable
    // verdict yet — Needs Analyst/Pending — records the analyst's own first
    // compliance call as Compliant). Either way this writes Status__c, so the
    // risk score only ever credits a document once it's genuinely Compliant —
    // not merely "an analyst clicked a button."
    handleApproveDoc() {
        const doc = this.selectedDoc;
        if (!doc) return;
        const id = doc.assessmentId;
        const finalStatus = doc.confirmStatus;
        this._docDecisions[id] = finalStatus;
        saveDocValidation({ assessmentId: id, comment: doc.comment, validated: true, finalStatus })
            .then(() => this._refreshDocs())
            .then(() => {
                this._toast(finalStatus === 'Compliant' ? 'Confirmed compliant' : 'Confirmed non-compliant',
                    `${doc.label}: ${finalStatus === 'Compliant' ? 'Compliant' : 'Non-Compliant'} confirmed as final.`);
            })
            .catch(err => this._toast('Save failed', (err && err.body && err.body.message) || 'Could not save.'));
    }

    // Overrides the AI's verdict — the analyst's judgment always wins over the
    // AI's. Writes the OPPOSITE of whatever the AI/current status says.
    handleRejectDoc() {
        const doc = this.selectedDoc;
        if (!doc) return;
        const id = doc.assessmentId;
        const finalStatus = doc.overrideStatus;
        this._docDecisions[id] = finalStatus;
        saveDocValidation({ assessmentId: id, comment: doc.comment, validated: true, finalStatus })
            .then(() => this._refreshDocs())
            .then(() => {
                this._toast('Overridden',
                    `${doc.label}: overridden to ${finalStatus === 'Compliant' ? 'Compliant' : 'Non-Compliant'}.`);
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

    // Multi-document-per-requirement: preview for a specific linked document
    // (Compliance_Document_Link__c), keyed by contentDocumentId directly
    // rather than assessmentId — a requirement's document list holds several
    // files, each independently previewable.
    handlePreviewLinkedDoc(event) {
        const contentDocumentId = event.currentTarget.dataset.id;
        if (!contentDocumentId) return;
        if (this._previewDocId === contentDocumentId && this._previewUrl) {
            this.closePreview();
            return;
        }
        this._previewIsImage = false;
        this._previewTitle = 'Document preview';
        this._previewDocId = contentDocumentId;
        this._iframeLoading = true;
        generatePublicDocumentUrl({ contentDocumentId })
            .then(publicUrl => {
                this._publicDocumentUrl = publicUrl;
                this._showIframe = true;
                this._iframeLoading = false;
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => this._setupIframe(), 0);
            })
            .catch(err => {
                this._iframeLoading = false;
                console.warn('Failed to generate public URL for linked document:', err);
                this._toast('Preview failed', 'Could not load this document.');
            });
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
        saveDocValidation({ assessmentId: id, comment: doc.comment, validated: newValidated, finalStatus: null })
            .then(() => this._refreshDocs())
            .then(() => {
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
        // Same stale-response guard as handleCopilotSend below — if the
        // analyst navigates to a different case before this resolves, the
        // (correctly-scoped) draft must not silently land nowhere or spawn a
        // misleading toast for a case that's no longer open.
        const askedForCaseId = this._caseId;
        this._summarizing = true;
        copilotDraftComment({
            accountId: askedForCaseId,
            requirementLabel: doc.label,
            aiSummary: doc.aiSummary,
            observation
        })
            .then(text => {
                if (this._caseId !== askedForCaseId) return;
                this._summarizing = false;
                this.docs = this.docs.map(d => d.assessmentId !== id ? d : { ...d, comment: text });
                this._toast('Comment drafted', 'GRACE polished your observation — edit or save.');
            })
            .catch(err => {
                if (this._caseId !== askedForCaseId) return;
                this._summarizing = false;
                this._toast('Draft failed', (err && err.body && err.body.message) || 'GRACE is unavailable.');
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
        this._saveScreenState();
    }

    // ── A3 — Final Verdict computed state ─────────────────────────────────────
    // Shape the case documents for the shared dashboard (decision + confidence).
    get dashboardDocs() {
        // Every row here is already a document routed to the Analyst for a
        // final call — there's no "not yet uploaded" state on this screen
        // (unlike the checklist-based consoles), so uploaded is always true.
        return this.docs.map(d => ({ decision: d.decision || 'pending', confidence: d.confidence, uploaded: true }));
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
    // Same gate as verdictStatus === 'ready' (no rejected, no pending docs —
    // every checklist item is Compliant), named separately so the close-case
    // UI's intent reads clearly against the route-to-approver UI it sits next to.
    get isReadyToClose() { return this.verdictStatus === 'ready'; }
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
    handleSendBack() {
        if (!this._caseId) { this._toast('No case', 'Open a supplier first.'); return; }
        sendCaseBackToProcurement({ accountId: this._caseId, note: this.rationale })
            .then(() => {
                this._toast('Sent back', `${this.caseName} returned to Procurement.`);
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => { this.handleBackToQueue(); this.refreshQueue(); }, 800);
            })
            .catch(err => this._toast('Send back failed', (err && err.body && err.body.message) || 'Could not send back.'));
    }

    // ── Close case (A3, only once every checklist document is Compliant) ───────
    @track closingRemarks = '';
    handleClosingRemarksInput(event) { this.closingRemarks = event.target.value; }
    handleCloseCase() {
        if (!this._caseId) { this._toast('No case', 'Open a supplier first.'); return; }
        closeComplianceCase({ accountId: this._caseId, closingRemarks: this.closingRemarks })
            .then(() => {
                this._toast('Case closed', `${this.caseName}'s compliance case is closed.`);
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => { this.handleBackToQueue(); this.refreshQueue(); }, 800);
            })
            .catch(err => this._toast('Close failed', (err && err.body && err.body.message) || 'Could not close the case.'));
    }

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
        return `Hi — I'm GRACE, your Vendor Governance, Risk and Compliance Engine, for **${who}**. How may I help?`;
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
        const rows = (this.docs || []).filter(a => a.hasChecksPassed || a.hasConcerns);
        if (!rows.length) return 'No documents have been AI-assessed yet.';
        const out = ['Here are the **key fields** the AI extracted, by document:'];
        rows.forEach(a => {
            out.push(`\n**${a.label}** — ${a.aiStatus}`);
            (a.checksPassed || []).forEach(c => out.push(`- ✓ ${c.text}`));
            (a.concerns || []).forEach(c => out.push(`- ⚠ ${c.text}`));
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
        // Capture which case this question was actually asked about — if the
        // analyst switches to a different case before the callout resolves,
        // the answer (correctly scoped server-side) must not land in whatever
        // case happens to be open when the response arrives.
        const askedForCaseId = this._caseId;
        this._pushMsg('you', q);
        this.copilotInput = '';
        this.copilotBusy = true;
        askCopilot({ accountId: askedForCaseId, question: q })
            .then(res => {
                if (this._caseId !== askedForCaseId) return;
                this.copilotBusy = false;
                this._pushMsg('ai', (res && (res.answer || res.response)) || 'No answer returned.');
            })
            .catch(err => {
                if (this._caseId !== askedForCaseId) return;
                this.copilotBusy = false;
                this._pushMsg('ai', 'GRACE error: ' + ((err && err.body && err.body.message) || 'request failed.'));
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