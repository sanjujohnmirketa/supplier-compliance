/**
 * AgentCaseService — HTTP client for the engine's AGENTIC case lifecycle.
 *
 * This is what makes the platform feel agent-DRIVEN instead of feeling like a set
 * of AI features the user pokes one at a time. Instead of calling /scope, /assess,
 * /verify separately, Salesforce starts a CASE and the LangGraph agent supervisor
 * in the engine drives it through its stages (intake → screening → documents →
 * synthesis → routing → decision), pausing at human gates.
 *
 *   startCase()       → POST /cases        (runs intake, pauses at GATE 1)
 *   getCase()         → GET  /cases/{id}   (timeline + per-step reports + next action)
 *   confirmScope()    → POST /cases/{id}/resume  (past GATE 1, holds at GATE 2)
 *   decide()          → POST /cases/{id}/resume with a decision (analyst sign-off)
 *
 * Same Named Credential + tunnel header as the other engine callouts.
 */
public with sharing class AgentCaseService {

    @TestVisible private static final String  NAMED_CRED = 'callout:Local_Compliance_Service';
    @TestVisible private static final Integer TIMEOUT_MS = 120000;

    // ── Wire types returned to the LWC (mirror the engine case_report view) ──
    public class StepReport {
        @AuraEnabled public String  stage;
        @AuraEnabled public String  agent;
        @AuraEnabled public String  label;
        @AuraEnabled public String  state;        // done | active | pending
        @AuraEnabled public String  headline;
        @AuraEnabled public String  verdict;
        @AuraEnabled public String  badge;        // ok | warn | bad | neutral
        @AuraEnabled public Integer confidence;
        @AuraEnabled public List<String> keyFindings;
        @AuraEnabled public List<String> blockers;
    }
    public class TimelineRow {
        @AuraEnabled public String  ts;
        @AuraEnabled public String  actor;
        @AuraEnabled public String  action;
        @AuraEnabled public String  detail;
        @AuraEnabled public Boolean gate;
    }
    public class NextAction {
        @AuraEnabled public String  agent;
        @AuraEnabled public String  label;
        @AuraEnabled public String  action;
        @AuraEnabled public Boolean awaitingHuman;
        @AuraEnabled public List<String> blockers;
    }
    public class CaseView {
        @AuraEnabled public String  caseId;
        @AuraEnabled public String  status;
        @AuraEnabled public Boolean awaitingGate;
        @AuraEnabled public List<String> next;
        @AuraEnabled public List<StepReport>  steps;
        @AuraEnabled public List<TimelineRow> timeline;
        @AuraEnabled public NextAction nextAction;
    }

    // ── Public lifecycle methods ────────────────────────────────────────────
    public static CaseView startCase(Map<String, Object> supplier, List<Object> documents) {
        Map<String, Object> body = new Map<String, Object>{
            'supplier'  => supplier,
            'documents' => documents == null ? new List<Object>() : documents
        };
        return parse(call('POST', '/cases', body));
    }

    public static CaseView getCase(String caseId) {
        return parse(call('GET', '/cases/' + caseId, null));
    }

    /** Confirm scope at GATE 1 → engine runs screening…routing, holds at GATE 2.
     *  oversight: 'auto' | 'partial' | 'full' (mirrors the HITL slider). */
    public static CaseView confirmScope(String caseId, String oversight) {
        return parse(call('POST', '/cases/' + caseId + '/resume',
            new Map<String, Object>{ 'oversight' => oversight }));
    }

    /** Analyst sign-off at GATE 2. verdict: approved | rejected | needs_info. */
    public static CaseView decide(String caseId, String verdict, String decidedBy, String note) {
        return parse(call('POST', '/cases/' + caseId + '/resume',
            new Map<String, Object>{
                'decision' => new Map<String, Object>{
                    'verdict' => verdict, 'by' => decidedBy, 'note' => note }
            }));
    }

    // ── HTTP plumbing ───────────────────────────────────────────────────────
    private static String call(String method, String path, Object body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CRED + path);
        req.setMethod(method);
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('X-Tunnel-Skip-AntiPhishing-Page', 'true');
        req.setTimeout(TIMEOUT_MS);
        if (body != null) req.setBody(JSON.serialize(body));
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new CalloutException('Agent case engine returned HTTP '
                + res.getStatusCode() + ': ' + res.getBody());
        }
        return res.getBody();
    }

    // Engine returns snake_case + nested objects; map to the typed CaseView with
    // deserializeUntyped (typed deserialize chokes on the nested shape).
    private static CaseView parse(String responseBody) {
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
        CaseView v = new CaseView();
        v.caseId       = (String)  root.get('case_id');
        v.status       = (String)  root.get('status');
        v.awaitingGate = (Boolean) root.get('awaiting_gate');
        v.next         = strList(root.get('next'));
        v.steps        = new List<StepReport>();
        for (Object o : (List<Object>) safeList(root.get('steps'))) {
            Map<String, Object> s = (Map<String, Object>) o;
            StepReport sr = new StepReport();
            sr.stage       = (String)  s.get('stage');
            sr.agent       = (String)  s.get('agent');
            sr.label       = (String)  s.get('label');
            sr.state       = (String)  s.get('state');
            sr.headline    = (String)  s.get('headline');
            sr.verdict     = (String)  s.get('verdict');
            sr.badge       = (String)  s.get('badge');
            Object conf = s.get('confidence');
            sr.confidence  = (conf == null) ? null
                                : Integer.valueOf(String.valueOf(conf));
            sr.keyFindings = strList(s.get('key_findings'));
            sr.blockers    = strList(s.get('blockers'));
            v.steps.add(sr);
        }
        v.timeline = new List<TimelineRow>();
        for (Object o : (List<Object>) safeList(root.get('timeline'))) {
            Map<String, Object> t = (Map<String, Object>) o;
            TimelineRow tr = new TimelineRow();
            tr.ts     = (String)  t.get('ts');
            tr.actor  = (String)  t.get('actor');
            tr.action = (String)  t.get('action');
            tr.detail = (String)  t.get('detail');
            tr.gate   = (Boolean) t.get('gate');
            v.timeline.add(tr);
        }
        Map<String, Object> na = (Map<String, Object>) root.get('next_action');
        if (na != null) {
            NextAction n = new NextAction();
            n.agent         = (String)  na.get('agent');
            n.label         = (String)  na.get('label');
            n.action        = (String)  na.get('action');
            n.awaitingHuman = (Boolean) na.get('awaiting_human');
            n.blockers      = strList(na.get('blockers'));
            v.nextAction = n;
        }
        return v;
    }

    private static List<Object> safeList(Object o) {
        return o == null ? new List<Object>() : (List<Object>) o;
    }
    private static List<String> strList(Object o) {
        List<String> out = new List<String>();
        for (Object x : safeList(o)) out.add(String.valueOf(x));
        return out;
    }
}