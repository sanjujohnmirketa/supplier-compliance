import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import getComplianceFunnel      from '@salesforce/apex/IntelligenceDashboardController.getComplianceFunnel';
import getScoreDistribution     from '@salesforce/apex/IntelligenceDashboardController.getScoreDistribution';
import getHitlPriorityQueue     from '@salesforce/apex/IntelligenceDashboardController.getHitlPriorityQueue';
import getDocumentDiscrepancyMatrix from '@salesforce/apex/IntelligenceDashboardController.getDocumentDiscrepancyMatrix';
import getRegulatorySanctionsFeed   from '@salesforce/apex/IntelligenceDashboardController.getRegulatorySanctionsFeed';
import getSupplierAlerts        from '@salesforce/apex/IntelligenceDashboardController.getSupplierAlerts';
import sendRenewalAlert         from '@salesforce/apex/ComplianceEmailController.sendRenewalAlert';

export default class ScIntelligenceDashboard extends NavigationMixin(LightningElement) {

    // ── Supplier alerts (existing suppliers — compliance breaks / expiring docs) ──
    _alertsResult;
    alertRows = [];
    alertsLoading = true;

    @wire(getSupplierAlerts)
    wiredAlerts(result) {
        this._alertsResult = result;
        this.alertsLoading = false;
        if (result.data) {
            this.alertRows = result.data.map((a, i) => ({
                id: 'al' + i,
                accountId: a.accountId,
                assessmentId: a.assessmentId,
                supplierName: a.supplierName,
                riskTierBadgeClass: 'vc-badge ' + this._tierBadgeClass(a.riskTier),
                riskTier: a.riskTier || 'Not scored yet',
                reason: a.reason,
                reasonBadgeClass: 'vc-badge ' + this._reasonBadgeClass(a.reasonType),
                reasonTypeLabel: this._reasonTypeLabel(a.reasonType),
                notifying: false
            }));
        }
    }

    // ── Notify supplier (the "trigger the alert" action) ───────────────────────
    // Sends a renewal/attention email naming this SPECIFIC flagged item —
    // distinct from the generic "documents required" onboarding email — via
    // the SAME durable portal link every other supplier email in this org
    // uses (ComplianceEmailController.sendRenewalAlert →
    // VendorPortalController.generateSupplierPortalUrl). No new identity
    // mechanism for existing vs. new suppliers; the link always resolves to
    // live current data on open.
    handleNotifySupplier(event) {
        const accountId = event.currentTarget.dataset.accountId;
        const assessmentId = event.currentTarget.dataset.assessmentId;
        if (!accountId || !assessmentId) return;
        this.alertRows = this.alertRows.map(r =>
            r.assessmentId === assessmentId ? { ...r, notifying: true } : r);
        sendRenewalAlert({ accountId, assessmentId })
            .then(() => {
                this._toast('success', 'Supplier notified', 'Renewal alert email sent.');
                this.alertRows = this.alertRows.map(r =>
                    r.assessmentId === assessmentId ? { ...r, notifying: false } : r);
            })
            .catch(err => {
                this._toast('error', 'Could not notify supplier',
                    (err && err.body && err.body.message) || 'The alert email failed to send.');
                this.alertRows = this.alertRows.map(r =>
                    r.assessmentId === assessmentId ? { ...r, notifying: false } : r);
            });
    }

    // ── Inline notice (matches scProcurementConsole's pattern) ─────────────────
    _showNotice = false;
    _notice = { title: '', message: '' };
    get showNotice()    { return this._showNotice; }
    get noticeTitle()   { return this._notice.title; }
    get noticeMessage() { return this._notice.message; }
    _toast(variant, title, message) {
        this._notice = { title, message };
        this._showNotice = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this._showNotice = false; }, 3200);
    }
    get hasAlerts() { return this.alertRows.length > 0; }
    get alertCount() { return this.alertRows.length; }

    _tierBadgeClass(tier) {
        if (tier === 'Critical' || tier === 'High') return 'bad';
        if (tier === 'Medium') return 'warn';
        if (tier === 'Low') return 'ok';
        return 'neutral';
    }
    _reasonBadgeClass(reasonType) {
        if (reasonType === 'break' || reasonType === 'expired') return 'bad';
        if (reasonType === 'expiring') return 'warn';
        return 'neutral';
    }
    _reasonTypeLabel(reasonType) {
        if (reasonType === 'break') return 'Compliance break';
        if (reasonType === 'expired') return 'Expired';
        if (reasonType === 'expiring') return 'Expiring soon';
        return 'Flagged';
    }

    // Native Account record page — no custom drilldown screen.
    handleOpenAccount(event) {
        const accountId = event.currentTarget.dataset.id;
        if (!accountId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: accountId,
                objectApiName: 'Account',
                actionName: 'view'
            }
        });
    }

    // ── Compliance funnel ─────────────────────────────────────────────────────
    funnelRows = [];
    funnelLoading = true;

    _funnelResult;

    @wire(getComplianceFunnel)
    wiredFunnel(result) {
        this._funnelResult = result;
        const { data } = result;
        if (data) {
            const max = Math.max(1, ...data.map(s => s.count));
            this.funnelRows = data.map((s, i) => {
                const pct = Math.round((s.count / max) * 100);
                const prevCount = i > 0 ? data[i - 1].count : s.count;
                const conv = prevCount > 0 ? Math.round((s.count / prevCount) * 100) : 100;
                return {
                    id: 'fn' + i,
                    label: s.label,
                    count: s.count,
                    widthStyle: `width:${pct}%`,
                    isDrop: i > 0 && conv < 70,
                    convLabel: i === 0 ? '100%' : `${conv}%`
                };
            });
            this.funnelLoading = false;
        }
    }
    get hasFunnelData() { return this.funnelRows.some(r => r.count > 0); }

    // ── Score distribution ────────────────────────────────────────────────────
    scoreBuckets = [];
    scoreLoading = true;

    _scoreResult;

    @wire(getScoreDistribution)
    wiredScoreDist(result) {
        this._scoreResult = result;
        const { data } = result;
        if (data) {
            const max = Math.max(1, ...data.map(b => b.count));
            this.scoreBuckets = data.map((b, i) => ({
                id: 'sb' + i,
                heightStyle: `height:${Math.round((b.count / max) * 100)}%`,
                cls: 'dist-bar ' + b.severity
            }));
            this.scoreLoading = false;
        }
    }
    get hasScoreData() { return this.scoreBuckets.length > 0; }

    // ── HITL priority queue ───────────────────────────────────────────────────
    hitlRows = [];
    hitlLoading = true;

    _hitlResult;

    @wire(getHitlPriorityQueue)
    wiredHitl(result) {
        this._hitlResult = result;
        const { data } = result;
        if (data) {
            this.hitlRows = data.map((h, i) => ({
                id: 'ht' + i,
                supplierName: h.supplierName,
                requirementLabel: h.requirementLabel,
                sevBarClass: 'hitl-sev-bar ' + (h.severity === 'Critical' ? 'crit' : 'high'),
                reasonLabel: (h.status === 'Non-Compliant' ? 'Non-Compliant' : 'At Risk') + ', ' + (h.severity || 'Medium'),
                waitLabel: this._waitLabel(h.waitHours),
                isOverdue: h.waitHours >= 24
            }));
            this.hitlLoading = false;
        }
    }
    get hasHitlRows() { return this.hitlRows.length > 0; }

    _waitLabel(hours) {
        if (hours == null) return 'Not set';
        if (hours < 1) return Math.round(hours * 60) + 'm';
        if (hours < 48) return Math.round(hours) + 'h';
        return Math.round(hours / 24) + 'd';
    }

    // ── Document discrepancy matrix ───────────────────────────────────────────
    discrepancyRows = [];
    discrepancyLoading = true;

    _discrepancyResult;

    @wire(getDocumentDiscrepancyMatrix)
    wiredDiscrepancy(result) {
        this._discrepancyResult = result;
        const { data } = result;
        if (data) {
            this.discrepancyRows = data.map((d, i) => ({
                id: 'dr' + i,
                requirement: d.requirement,
                failingLabel: d.failingSupplierCount + ' supplier' + (d.failingSupplierCount === 1 ? '' : 's')
            }));
            this.discrepancyLoading = false;
        }
    }
    get hasDiscrepancyRows() { return this.discrepancyRows.length > 0; }

    // ── Regulatory & sanctions feed ───────────────────────────────────────────
    feedRows = [];
    feedLoading = true;

    _feedResult;

    @wire(getRegulatorySanctionsFeed)
    wiredFeed(result) {
        this._feedResult = result;
        const { data } = result;
        if (data) {
            this.feedRows = data.map((f, i) => ({
                id: 'fd' + i,
                supplierName: f.supplierName,
                checkLabel: f.checkLabel,
                detail: f.detail,
                icoClass: (f.status === 'Compliant') ? 'feed-ico clear' : 'feed-ico watch',
                icoSymbol: (f.status === 'Compliant') ? '✓' : '!',
                whenLabel: this._relativeTime(f.evaluatedDate)
            }));
            this.feedLoading = false;
        }
    }
    get hasFeedRows() { return this.feedRows.length > 0; }

    _relativeTime(iso) {
        if (!iso) return '';
        const then = new Date(iso).getTime();
        const mins = Math.max(0, Math.round((Date.now() - then) / 60000));
        if (mins < 60) return mins + 'm ago';
        if (mins < 60 * 24) return Math.round(mins / 60) + 'h ago';
        return Math.round(mins / (60 * 24)) + 'd ago';
    }

    // ── Refresh everything (pull-to-refresh style, all @wire cacheable) ────────
    // Each refreshApex call is isolated so one failing/stale wire result can't
    // leave a sibling widget's loading flag stuck forever.
    handleRefresh() {
        this._refreshOne('_alertsResult', 'alertsLoading');
        this._refreshOne('_funnelResult', 'funnelLoading');
        this._refreshOne('_scoreResult', 'scoreLoading');
        this._refreshOne('_hitlResult', 'hitlLoading');
        this._refreshOne('_discrepancyResult', 'discrepancyLoading');
        this._refreshOne('_feedResult', 'feedLoading');
    }

    _refreshOne(resultProp, loadingProp) {
        const wireResult = this[resultProp];
        if (!wireResult) {
            return;
        }
        this[loadingProp] = true;
        refreshApex(wireResult)
            .catch((err) => {
                // eslint-disable-next-line no-console
                console.error('[Intelligence Dashboard] refresh failed:', err);
                const detail = (err && err.body && err.body.message) || '';
                this._toast('error', 'Refresh failed',
                    detail || 'Could not reload this widget. Please try again.');
            })
            .finally(() => {
                this[loadingProp] = false;
            });
    }
}