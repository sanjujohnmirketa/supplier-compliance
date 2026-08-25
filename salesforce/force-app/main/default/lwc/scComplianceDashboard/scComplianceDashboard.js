import { LightningElement, api } from 'lwc';

/**
 * scComplianceDashboard — shared dashboard header used on the Procurement
 * submission summary (P4), the Analyst Decision & Route (A3) screen, and the
 * Supplier Portal compliance summary.
 *
 * Cards, all derived DETERMINISTICALLY from data the parent already has —
 * no backend call, no LLM:
 *   1. Risk score (0–100 ring) — evidence-based: 0 until documents are
 *      actually evaluated, then rises ONLY as documents are confirmed
 *      compliant. Deliberately gives ZERO credit for a document that is
 *      merely uploaded-and-awaiting-evaluation, or that the AI has flagged
 *      Non-Compliant — crediting either of those made the score jump (e.g.
 *      0 -> 40 off a single upload) before any real compliance was
 *      established, which is misleading regardless of who's looking at it.
 *   2. Onboarding progress   — compliant / total mandatory documents
 *   3. Compliance status     — one-word overall verdict
 *   4. Score trend           — OPT-IN (showTrend), Procurement-only by
 *      request — last N evaluation points. Not shown to the Analyst or the
 *      supplier since neither said it helped them decide anything.
 *
 * Inputs (all optional; the component degrades to "—" when absent):
 *   tier      : 'Low' | 'Medium' | 'High' | 'Critical' (AI/confirmed tier —
 *               used only for the trend-derivation ramp, never as a scoring
 *               baseline)
 *   docs      : [{ decision:'approved'|'rejected'|'pending'|'', confidence }]
 *   trend     : [Number]  — optional explicit trend series (0–100); else derived
 *   showTrend : Boolean   — render the Score trend card (default false)
 */
export default class ScComplianceDashboard extends LightningElement {

    @api tier = '';
    @api docs = [];
    @api trend;            // optional explicit series
    @api label = 'Compliance Score';
    @api showTrend = false;
    // Supplier Portal only, opt-in — a plain "N/M uploaded" card computed by
    // the parent (scSupplierPortal.checklistProgressLabel), not derived here,
    // since "uploaded" and "compliant" are different counts (this dashboard's
    // own Onboarding progress card already covers the compliant one).
    @api showChecklistProgress = false;
    @api checklistProgressLabel = '';

    // ── 1. Risk score — the REAL server-computed number ──────────────────────
    // Account.Risk_Score__c, computed by RiskScoreService.recompute() —
    // additive per-document scoring starting from 0, severity-weighted (see
    // that class's own header comment for the full model). Passed in directly
    // rather than re-derived client-side —
    // this component used to compute its OWN separate score from `docs`
    // (credit only for decision==='approved'), which quietly diverged from
    // the real score any time Procurement's own Approve/Reject fed into
    // RiskScoreService without an equivalent change here: the account's
    // stored score would move (confirmed correct in the database) while this
    // ring kept showing a stale, differently-derived number. One source of
    // truth now — whatever Account.Risk_Score__c says is what renders.
    @api riskScore = 0;
    // riskScore is an ADDITIVE COMPLIANCE score (higher = more compliant), so
    // the band label names the COMPLIANCE level directly — "High" means highly
    // compliant, not high risk — increasing with the score, same direction as
    // the green/yellow/red ring below.
    get riskBandLabel() {
        if (!this._docs.length && !this.riskScore) return 'Not yet assessed';
        const s = this.riskScore;
        if (s >= 80) return 'High';
        if (s >= 55) return 'Elevated';
        if (s >= 35) return 'Moderate';
        return 'Low';
    }
    get ringClass() {
        if (!this._docs.length && !this.riskScore) return 'cd-ring neutral';
        const s = this.riskScore;
        if (s >= 80) return 'cd-ring ok';
        if (s >= 55) return 'cd-ring warn';
        return 'cd-ring bad';
    }
    // SVG stroke-dashoffset for the ring (circumference ≈ 2πr, r=34 → ~213.6).
    get ringDashStyle() {
        const circ = 213.6;
        const filled = (this.riskScore / 100) * circ;
        return `stroke-dasharray:${filled} ${circ};`;
    }

    // ── Compliance status (overall one-word verdict) ─────────────────────────
    get complianceStatusLabel() {
        const docs = this._docs;
        if (!docs.length) return 'Not started';
        if (docs.some(d => (d.decision || '').toLowerCase() === 'rejected')) return 'Non-compliant';
        if (docs.every(d => (d.decision || '').toLowerCase() === 'approved')) return 'Compliant';
        return 'In review';
    }
    get complianceStatusClass() {
        const s = this.complianceStatusLabel;
        if (s === 'Compliant')     return 'cd-status ok';
        if (s === 'Non-compliant') return 'cd-status bad';
        if (s === 'In review')     return 'cd-status warn';
        return 'cd-status neutral';
    }
    // Now carries the "X of N compliant" breakdown that used to sit on the
    // Onboarding progress card — Compliance status is the "are they actually
    // good" verdict, so its own detail line reads more naturally as the
    // compliant-count breakdown than the rejected/outstanding phrasing that
    // used to live here (that phrasing is dropped, not moved elsewhere).
    get complianceStatusDetail() {
        if (!this.totalDocs) return 'No documents assessed yet';
        return `${this.compliantDocs} of ${this.totalDocs} mandatory docs compliant (${this.compliantPct}%)`;
    }

    // ── 2. Onboarding progress — now "how much of the checklist has been
    // submitted" (uploaded/total), not "how much is compliant" — that's what
    // Compliance status is for. `uploaded` comes through on each doc from the
    // parent (an upload/link exists, regardless of AI/decision verdict).
    get _docs() { return Array.isArray(this.docs) ? this.docs : []; }
    get totalDocs() { return this._docs.length; }
    get compliantDocs() {
        return this._docs.filter(d => (d.decision || '').toLowerCase() === 'approved').length;
    }
    get compliantPct() {
        return this.totalDocs ? Math.round((this.compliantDocs / this.totalDocs) * 100) : 0;
    }
    get submittedDocs() {
        return this._docs.filter(d => d.uploaded === true).length;
    }
    get progressPct() {
        return this.totalDocs ? Math.round((this.submittedDocs / this.totalDocs) * 100) : 0;
    }
    get progressLabel() {
        return `${this.submittedDocs} of ${this.totalDocs} documents submitted (${this.progressPct}%)`;
    }
    get progressStatus() {
        if (!this.totalDocs) return 'Not started';
        return this.progressPct === 100 ? 'Complete' : 'In Progress';
    }
    get progressStatusClass() {
        return this.progressPct === 100 ? 'cd-status ok' : 'cd-status warn';
    }
    get progressBarStyle() { return `width:${this.progressPct}%;`; }

    // ── 3. Score trend (last N evaluations) ───────────────────────────────────
    // Use an explicit series if the parent supplies one; otherwise derive a
    // simple monotone series ending at the current score so the bars read as a
    // "last N evaluations" trend without inventing data.
    get trendBars() {
        let series = Array.isArray(this.trend) && this.trend.length
            ? this.trend.slice(-5)
            : this._derivedTrend();
        const max = Math.max(...series, 1);
        return series.map((v, i) => ({
            id: 'tb' + i,
            style: `height:${Math.max(8, Math.round((v / max) * 100))}%;`,
            barClass: i === series.length - 1 ? 'cd-trend-bar last' : 'cd-trend-bar'
        }));
    }
    _derivedTrend() {
        const end = this.riskScore;
        // Five points ramping up to the current score (visual trend only).
        return [Math.max(0, end - 24), Math.max(0, end - 16),
                Math.max(0, end - 8), Math.max(0, end - 3), end];
    }
    get hasTrend() { return this.totalDocs > 0 || (Array.isArray(this.trend) && this.trend.length > 0); }
    get rowClass() {
        return (this.showTrend || this.showChecklistProgress) ? 'cd-row cd-row-4' : 'cd-row cd-row-3';
    }
    get hasChecklistProgressLabel() { return !!this.checklistProgressLabel; }
}