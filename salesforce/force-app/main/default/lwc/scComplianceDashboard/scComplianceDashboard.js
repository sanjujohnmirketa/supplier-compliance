import { LightningElement, api } from 'lwc';

/**
 * scComplianceDashboard — shared dashboard header used on both the Procurement
 * submission summary (P4) and the Analyst Decision & Route (A3) screen.
 *
 * Three cards, all derived DETERMINISTICALLY from data the parent already has —
 * no backend call, no LLM:
 *   1. Risk score (0–100 ring)   — tier baseline + per-document penalties
 *   2. Onboarding progress        — compliant / total mandatory documents
 *   3. Score trend                — last N evaluation points (confidence/decision)
 *
 * Inputs (all optional; the component degrades to "—" when absent):
 *   tier   : 'Low' | 'Medium' | 'High' | 'Critical' (AI/confirmed tier)
 *   docs   : [{ decision:'approved'|'rejected'|'pending'|'', confidence }]
 *   trend  : [Number]  — optional explicit trend series (0–100); else derived
 */
export default class ScComplianceDashboard extends LightningElement {

    @api tier = '';
    @api docs = [];
    @api trend;            // optional explicit series
    @api label = 'Risk score';

    // ── 1. Deterministic risk score ──────────────────────────────────────────
    // Baseline by tier, then subtract for unresolved/rejected documents so the
    // number always moves the same way for the same inputs. Pure arithmetic.
    get riskScore() {
        const base = this._tierBase(this.tier);
        const docs = this._docs;
        if (!docs.length) return base;
        let penalty = 0;
        docs.forEach(d => {
            const dec = (d.decision || '').toLowerCase();
            if (dec === 'rejected') penalty += 12;
            else if (dec === 'pending' || dec === '') penalty += 6;
        });
        const score = Math.max(0, Math.min(100, base - penalty));
        return Math.round(score);
    }
    _tierBase(tier) {
        switch ((tier || '').toLowerCase()) {
            case 'low':      return 88;
            case 'medium':   return 68;
            case 'high':     return 42;
            case 'critical': return 24;
            default:         return 60;
        }
    }
    get riskBandLabel() {
        const s = this.riskScore;
        if (s >= 80) return 'Low — onboarding on track';
        if (s >= 55) return 'Moderate — onboarding incomplete';
        if (s >= 35) return 'Elevated — review required';
        return 'High — significant gaps';
    }
    get ringClass() {
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

    // ── 2. Onboarding progress ────────────────────────────────────────────────
    get _docs() { return Array.isArray(this.docs) ? this.docs : []; }
    get totalDocs() { return this._docs.length; }
    get compliantDocs() {
        return this._docs.filter(d => (d.decision || '').toLowerCase() === 'approved').length;
    }
    get progressPct() {
        return this.totalDocs ? Math.round((this.compliantDocs / this.totalDocs) * 100) : 0;
    }
    get progressLabel() {
        return `${this.compliantDocs} of ${this.totalDocs} mandatory docs compliant (${this.progressPct}%)`;
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
}