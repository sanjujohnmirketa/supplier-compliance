import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getSupplierSnapshot from '@salesforce/apex/SupplierRiskDashboardController.getSupplierSnapshot';

export default class ScSupplierRiskDashboard extends NavigationMixin(LightningElement) {

    @api recordId;

    snapshot;
    isLoading = true;
    errorMessage;

    @wire(getSupplierSnapshot, { accountId: '$recordId' })
    wiredSnapshot({ data, error }) {
        this.isLoading = false;
        if (data) {
            this.snapshot = this.enrichSnapshot(data);
            console.log('Loaded supplier snapshot:', JSON.stringify(this.snapshot));
            this.errorMessage = null;
        } else if (error) {
            this.errorMessage = this.extractError(error);
            this.snapshot = null;
        }
    }

    // Enrich the snapshot with display-ready computed fields per row.
    // Doing it here (not in Apex) keeps the controller pure SOQL/JSON.
    enrichSnapshot(snap) {
        if (!snap) return snap;

        // Create a new object to avoid mutating the @wire proxy
        const enriched = { ...snap };

        if (enriched.documents) {
            enriched.documents = enriched.documents.map(d => {
                const conf = d.confidence;
                const sv = d.statusVariant;
                const parsed = this.parseReason(d.validationReasoning);
                return {
                    ...d,
                    ...parsed,
                    confidenceLabel: conf == null ? '—' : `${Math.round(conf * 100)}%`,
                    statusVariantClass: sv === 'success' ? 'badge-success'
                                      : sv === 'error'   ? 'badge-error'
                                      : sv === 'warning' ? 'badge-warning'
                                      : 'badge-status',
                    uploadedLabel: d.uploadedAt ? new Date(d.uploadedAt).toLocaleDateString() : null,
                    // Show actual file name only when it differs from the requirement label
                    hasFileName: !!(d.documentName && d.documentName !== d.documentType)
                };
            });
        }

        if (enriched.assessments) {
            enriched.assessments = enriched.assessments.map(a => {
                const parsed = this.parseReason(a.reasonDetail);
                return {
                    ...a,
                    lastEvaluatedLabel: a.lastEvaluated ? new Date(a.lastEvaluated).toLocaleDateString() : null,
                    confidenceLabel: a.aiConfidence == null ? null : `${a.aiConfidence}%`,
                    ...parsed
                };
            });
        }

        return enriched;
    }

    // Parse Reason_Detail__c using the same line-based logic as _parseSummary in
    // scProcurementConsole — handles [PASS]/[FAIL] checks, Clause checks: sections,
    // • bullet facts, ⚠ concerns, and Extracted · / Registry · metadata lines.
    parseReason(reasonStr) {
        const out = { headline: '', facts: [], concerns: [], checks: [] };
        if (!reasonStr) {
            return { ...out, hasHeadline: false, hasFacts: false, hasChecks: false, hasConcerns: false };
        }
        const lines = String(reasonStr).split(/\r?\n/).map(l => l.trim()).filter(Boolean);
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
        const facts    = out.facts.map((t, i)    => ({ id: `f${i}`,  text: t }));
        const concerns = out.concerns.map((t, i) => ({ id: `cc${i}`, text: t }));
        const checks   = out.checks.map((c, i)   => ({
            id: `k${i}`, text: c.text, pass: c.pass,
            chkClass: `req-check ${c.pass ? 'req-check-pass' : 'req-check-fail'}`
        }));
        return {
            headline:    out.headline || null,
            hasHeadline: !!out.headline,
            facts,    hasFacts:    facts.length > 0,
            checks,   hasChecks:   checks.length > 0,
            concerns, hasConcerns: concerns.length > 0
        };
    }

    // ── Display helpers ─────────────────────────────────────────────────────
    get hasSnapshot() {
        // Check for actual data content instead of relying solely on hasRiskData flag
        // Data is present if there are assessments or documents
        if (!this.snapshot) return false;
        const hasAssessments = this.snapshot.assessments && this.snapshot.assessments.length > 0;
        const hasDocuments = this.snapshot.documents && this.snapshot.documents.length > 0;
        return hasAssessments || hasDocuments;
    }
    get hasNoSnapshot()  { return !!this.snapshot && !this.hasSnapshot; }
    get hasError()       { return !!this.errorMessage; }
    get riskScoreLabel() {
        if (!this.snapshot || this.snapshot.riskScore == null) return '—';
        return Math.round(this.snapshot.riskScore);
    }
    get riskScorePercent() {
        if (!this.snapshot || this.snapshot.riskScore == null) return '—';
        return `${Math.round(this.snapshot.riskScore)}%`;
    }
    get riskTierLabel()  { return this.snapshot?.riskTier || 'Unknown'; }
    get riskTierBadge() {
        const map = {
            Critical: 'tier-critical',
            High:     'tier-high',
            Medium:   'tier-medium',
            Low:      'tier-low'
        };
        return `risk-tier ${map[this.snapshot?.riskTier] || 'tier-unknown'}`;
    }

    // ── Cascading risk (docs/multi-tier-risk-rollup.md) ────────────────────
    // Distinct from riskTier above: worst-case tier across this supplier's
    // whole sub-tree (self + all T2/T3 descendants), not just its own docs.
    get hasSubTierSuppliers() { return (this.snapshot?.subTierSupplierCount || 0) > 0; }
    get cascadingRiskLabel()  { return this.snapshot?.cascadingRiskTier || 'Unknown'; }
    get cascadingRiskBadge() {
        const map = {
            Critical: 'tier-critical',
            High:     'tier-high',
            Medium:   'tier-medium',
            Low:      'tier-low'
        };
        return `risk-tier cascading ${map[this.snapshot?.cascadingRiskTier] || 'tier-unknown'}`;
    }
    get isCascadingWorseThanOwn() {
        const rank = { Low: 0, Medium: 1, High: 2, Critical: 3 };
        const own = rank[this.snapshot?.riskTier] ?? -1;
        const cascading = rank[this.snapshot?.cascadingRiskTier] ?? -1;
        return cascading > own;
    }
    get cascadingRiskSourceLabel() { return this.snapshot?.cascadingRiskSource || null; }
    get subTierSupplierCountLabel() {
        const n = this.snapshot?.subTierSupplierCount || 0;
        return `${n} sub-tier supplier${n === 1 ? '' : 's'}`;
    }

    get riskRingDasharray() {
        const score = this.snapshot?.riskScore ?? 0;
        const filled = (score / 100) * 282.74;
        return `${filled} 282.74`;
    }

    get riskRingStyle() {
        const tier = this.snapshot?.riskTier;
        let color = '#706e6b';
        if (tier === 'Critical') color = '#c23934';
        else if (tier === 'High') color = '#fe9339';
        else if (tier === 'Medium') color = '#fab526';
        else if (tier === 'Low') color = '#4bca81';
        return `stroke: ${color};`;
    }

    get hasRawMaterials()      { return this.snapshot?.rawMaterials?.length > 0; }
    get hasCriticalFailures()  { return this.snapshot?.criticalFailures?.length > 0; }
    get hasRemediation()       { return !!this.snapshot?.remediationSteps; }
    get avgConfidenceLabel() {
        const c = this.snapshot?.avgConfidence;
        return c == null ? '—' : `${Math.round(c * 100)}%`;
    }
    get lastComputedLabel() {
        const d = this.snapshot?.riskLastComputed;
        if (!d) return 'Never';
        return new Date(d).toLocaleString();
    }

    // ── Class mappers ───────────────────────────────────────────────────────
    verdictClass(v) {
        if (v === 'Valid')   return 'badge-success';
        if (v === 'Invalid') return 'badge-error';
        if (v) return 'badge-warning';
        return '';
    }

    complianceClass(s) {
        if (s === 'Compliant')     return 'badge-success';
        if (s === 'Non-Compliant') return 'badge-error';
        if (s) return 'badge-warning';
        return '';
    }

    confidenceBarClass(c) {
        if (c == null) return 'bar bar-unknown';
        if (c >= 0.85) return 'bar bar-high';
        if (c >= 0.6)  return 'bar bar-med';
        return 'bar bar-low';
    }

    // ── Drill-down navigation ──────────────────────────────────────────────
    handleDocumentClick(event) {
        const docId = event.currentTarget.dataset.docId;
        if (!docId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: docId,
                objectApiName: 'ContentDocument',
                actionName: 'view'
            }
        });
    }

    handleAssessmentClick(event) {
        const aId = event.currentTarget.dataset.assessmentId;
        if (!aId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: aId,
                objectApiName: 'Compliance_Assessment__c',
                actionName: 'view'
            }
        });
    }

    extractError(err) {
        if (err?.body?.message) return err.body.message;
        if (err?.message)        return err.message;
        return 'Unable to load supplier risk data.';
    }
}