"""
orchestrator.py — LangGraph supervisor for the supplier-compliance case workflow.

Phase A skeleton: defines the canonical CaseState and a 7-stage graph. Nodes are
stubs that annotate state + append to the audit trail; real agent logic is wired
in A2 (intake→/scope, documents→/assess) and Phase C (screening).

Run standalone to verify a case flows end to end:
    python orchestrator.py
"""
import operator
from typing import Annotated, TypedDict
from datetime import datetime, timezone

from langgraph.graph import StateGraph, START, END
from langgraph.checkpoint.memory import MemorySaver


def _now():
    return datetime.now(timezone.utc).isoformat()


def audit(actor, action, detail=""):
    """One append-only audit row (the list reducer concatenates these)."""
    return [{"ts": _now(), "actor": actor, "action": action, "detail": detail}]

# ── Injected agent functions (set by app.py via set_agents) ─────────────────
_SCOPE_FN = None
_ASSESS_FN = None

def set_agents(scope_fn=None, assess_fn=None):
    global _SCOPE_FN, _ASSESS_FN
    _SCOPE_FN = scope_fn
    _ASSESS_FN = assess_fn

# ── Canonical Case State — the shared context that flows between agents ──────
#
# CONTEXT-SHARING CONTRACT (how agents share context accurately)
# ───────────────────────────────────────────────────────────────────────────
# CaseState is the single shared "blackboard". LangGraph guarantees:
#   1. Every node receives the FULL, current merged state — so each agent sees
#      everything written by every prior agent (intake's scope/checklist,
#      screening's signals, the documents agent's findings, …). No agent has to
#      re-fetch or re-derive context another agent already produced.
#   2. A node returns ONLY the slice it owns (a partial dict). LangGraph merges
#      that slice into the state using each key's reducer:
#        • audit, findings → REDUCER operator.add → APPENDED (accumulate, never
#          overwrite — so multiple agents/iterations contribute safely).
#        • all other keys → last-write-wins REPLACE (a node fully owns its slice:
#          intake owns scope/checklist, screening owns screening, etc.).
#   3. The checkpointer persists the entire state per thread_id (case_id), so the
#      shared context survives the human gate (interrupt_before) and resumes
#      byte-for-byte intact — the human's decision re-enters the SAME context.
# This is why context transfer between agents is accurate by construction: there
# is one authoritative state, explicit ownership per key, and append-only merge
# for the fields that accumulate.
class CaseState(TypedDict, total=False):
    case_id: str
    supplier: dict                            # normalized entity + intake attrs (intake owns)
    scope: list                               # domains in scope (intake owns)
    checklist: list                           # required documents per domain (intake owns)
    screening: dict                           # sanctions / financial / adverse-media (screening owns)
    documents: list                           # received docs + extracted fields (input)
    findings: Annotated[list, operator.add]   # per-domain findings — ACCUMULATE across docs/agents
    synthesis: dict                           # summary + suggested tier + confidence (synthesis owns)
    routing: dict                             # approver + decision packet (routing owns)
    decision: dict                            # human sign-off injected at GATE 2 (decision owns)
    status: str                               # current stage / gate
    audit: Annotated[list, operator.add]      # append-only trail (reducer = list +)


def intake_node(state: CaseState) -> dict:
    supplier = state.get("supplier", {})
    if _SCOPE_FN is None:
        return {"status": "INTAKE_DONE",
                "audit": audit("intake-agent", "stub (no scope_fn wired)",
                               supplier.get("legalName", ""))}
    r = _SCOPE_FN(supplier)  # {riskTier, riskSummary, riskReasons, checklist, scope}
    return {
        "status": "SCOPED",
        "scope": r.get("scope", []),
        "checklist": r.get("checklist", []),
        "synthesis": {"prelim_tier": r.get("riskTier"),
                      "prelim_summary": r.get("riskSummary"),
                      "prelim_reasons": r.get("riskReasons", [])},
        "audit": audit("intake/scope-agent", "scoped domains + checklist via /scope",
                       ", ".join(r.get("scope", []))),
    }


def screening_node(state: CaseState) -> dict:
    supplier = state.get("supplier", {})
    name = supplier.get("legalName", "")
    from screening import gleif_lookup, sanctions_screen
    from concurrent.futures import ThreadPoolExecutor
    # LATENCY: GLEIF and sanctions are independent network calls — run them in
    # parallel so the step takes max(t_gleif, t_sanctions), not their sum.
    with ThreadPoolExecutor(max_workers=2) as ex:
        f_gleif = ex.submit(gleif_lookup, name, supplier.get("country"))
        f_sanc  = ex.submit(sanctions_screen, name)
        gleif = f_gleif.result()
        sanctions = f_sanc.result()
    hits = sanctions.get("hits", [])
    prelim = "flag" if hits else "clear"   # any sanctions hit → flag for analyst
    return {
        "status": "SCREENED",
        "screening": {"gleif": gleif, "sanctions": sanctions, "preliminary_signal": prelim},
        "audit": audit("screening-agent",
                       f"GLEIF={gleif.get('status')} sanctions={sanctions.get('status')} signal={prelim}",
                       name),
    }


def _doc_key(d: dict) -> str:
    """Stable identity for a document, so re-invocation doesn't re-assess it.
    Prefer an explicit key, else documentType, else fileName."""
    return str(d.get("documentKey") or d.get("documentType")
               or d.get("fileName") or "").strip().lower()


def documents_node(state: CaseState) -> dict:
    """Assess any NEW documents on the case. RE-ENTRANT: the case is re-invoked
    from here each time evidence arrives, so we assess only documents we haven't
    already produced a finding for (dedup by _doc_key). `findings` has reducer
    operator.add — returning only the new findings APPENDS them, never doubles."""
    docs = state.get("documents", []) or []
    already = {_doc_key({"documentType": f.get("documentType")})
               for f in (state.get("findings", []) or [])}
    pending = [d for d in docs if _doc_key(d) and _doc_key(d) not in already]

    if _ASSESS_FN is None or not pending:
        note = ("no new documents to assess" if not pending
                else "stub (no assess_fn)")
        return {"status": "DOCS_ASSESSED",
                "audit": audit("document-agent", note,
                               f"{len(docs)} on case · {len(pending)} new")}
    findings, trail = [], []
    for d in pending:
        v = _ASSESS_FN(d)  # {verdict, severity, confidence, reasons, citations, domain, documentType}
        findings.append(v)
        trail += audit("document/risk-agent",
                       f"assessed {d.get('documentType','document')} -> {v.get('verdict')}",
                       v.get("domain", ""))
    return {"status": "DOCS_ASSESSED", "findings": findings, "audit": trail}


# ── Risk scoring helpers (deterministic — the LLM narrates, math decides) ────
TIER_RANK = {"Low": 1, "Medium": 2, "High": 3, "Critical": 4}
_SEV_WEIGHT = {"Critical": 40, "High": 25, "Medium": 12, "Low": 5}

# Delegation-of-authority: tier → approver + SLA
DOA = {
    "Low":      {"approver": "Auto-approve (analyst notify)", "sla_days": 0},
    "Medium":   {"approver": "Sr. Compliance Approver",       "sla_days": 2},
    "High":     {"approver": "Risk Committee",                "sla_days": 5},
    "Critical": {"approver": "Risk Committee + Legal",        "sla_days": 5},
}


def _tier_from_score(score: int) -> str:
    if score >= 80: return "Critical"
    if score >= 55: return "High"
    if score >= 30: return "Medium"
    return "Low"


def risk_node(state: CaseState) -> dict:
    """Per-domain evidence pass-through (synthesis does the weighting). Kept as a
    distinct stage so a future per-domain deep-dive plugs in here."""
    findings = state.get("findings", []) or []
    return {
        "status": "ANALYZED",
        "audit": audit("risk-agent", f"reviewed {len(findings)} document finding(s)"),
    }


def synthesis_node(state: CaseState) -> dict:
    """Weighted Risk & Compliance score + suggested tier + confidence, rolled up
    from the document findings, the screening signal, and the scoped domains."""
    findings  = state.get("findings", []) or []
    screening = state.get("screening", {}) or {}
    scope     = state.get("scope", []) or []
    prelim    = (state.get("synthesis") or {}).get("prelim_tier")

    score, failing = 0, 0
    for f in findings:
        v = f.get("verdict")
        if v in ("Non-Compliant", "At Risk", "Needs Analyst"):
            score += _SEV_WEIGHT.get(f.get("severity"), 12)
            if v == "Non-Compliant":
                failing += 1

    sig = (screening.get("preliminary_signal")
           or (screening.get("disambiguation") or {}).get("recommended_signal"))
    if sig == "flag":   score += 35
    elif sig == "review": score += 15

    # Never below the preliminary scope tier's baseline.
    score = min(100, max(score, TIER_RANK.get(prelim, 1) * 12))
    tier  = _tier_from_score(score)

    na = sum(1 for f in findings if f.get("verdict") == "Needs Analyst")
    confidence = max(30, 90 - na * 15 - (10 if sig in ("flag", "review") else 0))

    summary = (f"{tier} risk (score {score}/100). {len(scope)} domain(s) in scope; "
               f"{failing} failing finding(s); screening signal: {sig or 'pending'}.")
    return {
        "status": "RECOMMENDED",
        "synthesis": {"summary": summary, "suggested_tier": tier, "risk_score": score,
                      "confidence": confidence, "failing": failing,
                      "prelim_tier": prelim},
        "audit": audit("synthesis-agent", f"score={score} tier={tier} conf={confidence}"),
    }


def routing_node(state: CaseState) -> dict:
    """Map the suggested tier to an approver + SLA (delegation of authority)."""
    syn   = state.get("synthesis", {}) or {}
    tier  = syn.get("suggested_tier") or "Medium"
    route = DOA.get(tier, DOA["Medium"])
    return {
        "status": "ROUTED",
        "routing": {"tier": tier, "approver": route["approver"], "sla_days": route["sla_days"]},
        "audit": audit("routing-agent", f"tier {tier} → {route['approver']} (SLA {route['sla_days']}d)"),
    }


def _case_is_flagged(state: CaseState) -> bool:
    """True if the case carries an unresolved risk flag — meaning it must NOT
    auto-clear. Sources: a screening 'flag' signal, any Non-Compliant document
    finding, or a High/Critical synthesized tier."""
    sc = state.get("screening") or {}
    sig = (sc.get("preliminary_signal")
           or (sc.get("disambiguation") or {}).get("recommended_signal"))
    if sig == "flag":
        return True
    if any(f.get("verdict") == "Non-Compliant" for f in (state.get("findings") or [])):
        return True
    tier = (state.get("synthesis") or {}).get("suggested_tier")
    if tier in ("High", "Critical"):
        return True
    return False


def decision_node(state: CaseState) -> dict:
    """GATE 2 lands HERE. The graph pauses BEFORE this node (interrupt_before=
    ['decision']) so a human signs off on the proposed tier + approver. The
    decision the human made is injected into state (`decision`) before resume;
    this node simply records it onto the case and finalizes the status.

    Auto-pass: when the supplier's oversight is Auto-clear (Low tier), Salesforce
    resumes immediately without a human — the gate is structural but skippable by
    the supervisor's authority level (the HITL slider).

    SAFETY OVERRIDE: a case carrying an unresolved risk flag MUST NOT auto-clear.
    If there is no explicit human decision AND the case is flagged (screening
    flag, failing findings, or a High/Critical tier), the decision is forced to
    'needs_info' (returns to a human) rather than silently approving. A flag can
    never read as 'approved' without a named human signing off."""
    d = state.get("decision") or {}
    verdict = d.get("verdict")              # 'approved' | 'rejected' | 'needs_info'
    by = d.get("by") or "analyst"
    if not verdict:
        if _case_is_flagged(state):
            # Auto-pass is REFUSED on a flagged case — a human must decide.
            verdict = "needs_info"
            by = "auto-hold (flag present — human sign-off required)"
        else:
            # Clean case + oversight auto-clear → safe to auto-approve.
            verdict = "approved"
            by = d.get("by") or "auto (oversight: auto-clear)"
    return {
        "status": "APPROVED" if verdict == "approved" else
                  "REJECTED" if verdict == "rejected" else "NEEDS_INFO",
        "routing": {**(state.get("routing") or {}),
                    "decision": verdict, "decided_by": by,
                    "decision_note": d.get("note", "")},
        "audit": audit("decision (human-gate)",
                       f"{verdict} by {by}", d.get("note", "")),
    }


# ── Agent registry — the "club of agents", for observability/governance ──────
AGENTS = [
    {"id": "intake",    "stage": "01", "role": "Scope & checklist (policy RAG via /scope)"},
    {"id": "screening", "stage": "02", "role": "Identity + sanctions (GLEIF, OpenSanctions)"},
    {"id": "documents", "stage": "03", "role": "Document compliance judgment (/assess, governed)"},
    {"id": "risk",      "stage": "04", "role": "Per-domain evidence review"},
    {"id": "synthesis", "stage": "05", "role": "Weighted risk score + tier + summary"},
    {"id": "routing",   "stage": "06", "role": "Tier → approver (delegation of authority)"},
    {"id": "decision",  "stage": "07", "role": "Human sign-off (analyst approves / overrides)"},
]


def agent_registry() -> list:
    return AGENTS


# ── Case report — the normalized, UI-facing view of a running case ──────────
#
# Derives a scannable, agent-driven view from the raw CaseState. This is what
# makes the agent VISIBLY drive the flow: a timeline (the audit trail), a set of
# per-step reports (one render card each), and the single recommended next
# action. Pure derivation — it reads state, changes nothing.

# Stage labels for the human-facing timeline / progress rail.
STAGE_LABELS = {
    "intake":    "Scoping & checklist",
    "screening": "Identity & watchlist screening",
    "documents": "Document assessment",
    "risk":      "Per-domain review",
    "synthesis": "Risk synthesis",
    "routing":   "Routing & approver",
    "decision":  "Human decision",
}

# Map a verdict/signal to a UI badge class (kept here so engine + UI agree).
def _badge(verdict: str) -> str:
    v = (verdict or "").lower()
    if v in ("compliant", "clear", "low"):                 return "ok"
    if v in ("non-compliant", "flag", "critical", "high"): return "bad"
    if v in ("needs analyst", "at risk", "review",
             "medium", "pending"):                          return "warn"
    return "neutral"


def _intake_report(state):
    scope = state.get("scope", []) or []
    checklist = state.get("checklist", []) or []
    syn = state.get("synthesis", {}) or {}
    tier = syn.get("prelim_tier") or syn.get("suggested_tier") or "—"
    reasons = syn.get("prelim_reasons") or []
    # Prefer the WHY (risk reasons) over a bare domain list — more decision-useful.
    findings = list(reasons[:4]) or [f"Domain: {d}" for d in scope[:6]]
    return {
        "headline": f"{len(scope)} risk domain(s) in scope · {len(checklist)} document(s) required",
        "verdict": f"{tier} (preliminary)",
        "badge": _badge(tier),
        "key_findings": findings,
        "blockers": [],
        "confidence": None,
        "next_action": "Confirm the scoped checklist and oversight level to continue.",
    }


def _screening_report(state):
    sc = state.get("screening", {}) or {}
    gleif = (sc.get("gleif") or {}).get("status", "—")
    sanc = (sc.get("sanctions") or {}).get("status", "—")
    sig = sc.get("preliminary_signal", "pending")
    hits = (sc.get("sanctions") or {}).get("hits", []) or []
    return {
        "headline": f"Identity {gleif} · sanctions {sanc} · signal {sig}",
        "verdict": sig.capitalize() if sig else "Pending",
        "badge": _badge(sig),
        "key_findings": [f"GLEIF identity: {gleif}", f"Sanctions/denied-party: {sanc}"],
        "blockers": ([f"{len(hits)} potential sanctions match(es) — needs disambiguation"]
                     if hits else []),
        "confidence": None,
        "next_action": ("Disambiguate the sanctions match before clearing."
                        if hits else "No watchlist blockers — proceeding to documents."),
    }


def _documents_report(state):
    findings = state.get("findings", []) or []
    passed = sum(1 for f in findings if f.get("verdict") == "Compliant")
    failed = sum(1 for f in findings if f.get("verdict") == "Non-Compliant")
    needs = sum(1 for f in findings if f.get("verdict") == "Needs Analyst")
    checklist = state.get("checklist", []) or []
    required = len(checklist) or len(findings)
    blockers = [f"{f.get('documentType','document')}: {(f.get('reasons') or ['failed'])[0]}"
                for f in findings if f.get("verdict") == "Non-Compliant"][:5]
    return {
        "headline": f"{len(findings)} of {required} received · {passed} pass · {failed} fail · {needs} need review",
        "verdict": ("Non-Compliant" if failed else
                    "Needs Analyst" if needs else
                    "Compliant" if findings else "Awaiting documents"),
        "badge": _badge("Non-Compliant" if failed else "Needs Analyst" if needs else
                        "Compliant" if findings else "pending"),
        "key_findings": [f"{f.get('documentType','document')} → {f.get('verdict')}"
                         for f in findings[:8]],
        "blockers": blockers,
        "confidence": None,
        "next_action": ("Resolve failing documents or chase missing evidence."
                        if (failed or len(findings) < required)
                        else "All documents in — synthesizing the risk picture."),
    }


def _synthesis_report(state):
    syn = state.get("synthesis", {}) or {}
    return {
        "headline": syn.get("summary", "Risk synthesis pending."),
        "verdict": syn.get("suggested_tier", "—"),
        "badge": _badge(syn.get("suggested_tier")),
        "key_findings": [f"Risk score: {syn.get('risk_score','—')}/100",
                         f"Failing findings: {syn.get('failing','—')}"],
        "blockers": [],
        "confidence": syn.get("confidence"),
        "next_action": "Review the recommended tier before routing.",
    }


def _routing_report(state):
    r = state.get("routing", {}) or {}
    return {
        "headline": (f"Tier {r.get('tier','—')} → {r.get('approver','—')} "
                     f"(SLA {r.get('sla_days','—')}d)") if r else "Routing pending.",
        "verdict": r.get("tier", "—"),
        "badge": _badge(r.get("tier")),
        "key_findings": [f"Approver: {r.get('approver','—')}",
                         f"SLA: {r.get('sla_days','—')} day(s)"],
        "blockers": [],
        "confidence": (state.get("synthesis") or {}).get("confidence"),
        "next_action": "Analyst sign-off required to approve the routing.",
    }


def _decision_report(state):
    r = state.get("routing", {}) or {}
    dec = r.get("decision")
    if not dec:
        return {
            "headline": "Awaiting analyst sign-off on the recommendation.",
            "verdict": "Pending sign-off", "badge": "warn",
            "key_findings": [f"Proposed: {r.get('tier','—')} → {r.get('approver','—')}"],
            "blockers": [], "confidence": None,
            "next_action": "Approve the recommendation, or override with a reason.",
        }
    return {
        "headline": (f"{dec.capitalize()} by {r.get('decided_by','analyst')}"
                     + (f" — {r.get('decision_note')}" if r.get("decision_note") else "")),
        "verdict": dec.capitalize(),
        "badge": _badge("compliant" if dec == "approved" else
                        "non-compliant" if dec == "rejected" else "review"),
        "key_findings": [f"Decided by: {r.get('decided_by','—')}"],
        "blockers": [], "confidence": None,
        "next_action": ("Case approved — proceed to contract." if dec == "approved"
                        else "Case rejected — notify procurement." if dec == "rejected"
                        else "More information requested — returned to procurement."),
    }


_REPORTERS = {
    "intake": _intake_report, "screening": _screening_report,
    "documents": _documents_report, "synthesis": _synthesis_report,
    "routing": _routing_report, "decision": _decision_report,
}

# Has a given agent actually run? Each agent owns a distinct proof-of-completion.
# NB: intake writes synthesis.prelim_tier, so synthesis is "done" only once it has
# written its OWN slice (suggested_tier / risk_score) — not just the prelim fields.
def _stage_done(sid: str, state: dict) -> bool:
    syn = state.get("synthesis") or {}
    if sid == "intake":    return bool(state.get("scope"))
    if sid == "screening": return bool(state.get("screening"))
    if sid in ("documents", "risk"): return bool(state.get("findings"))
    if sid == "synthesis": return "suggested_tier" in syn or "risk_score" in syn
    if sid == "routing":   return bool(state.get("routing"))
    if sid == "decision":  return bool((state.get("routing") or {}).get("decision"))
    return False


def case_report(case_id: str, state: dict, awaiting_gate: bool = False,
                next_stages=None) -> dict:
    """Normalized, UI-facing case view: progress rail, per-step agent reports,
    the live audit timeline, and the single recommended next action."""
    state = state or {}
    next_stages = list(next_stages or [])

    steps = []
    for ag in AGENTS:
        sid = ag["id"]
        reporter = _REPORTERS.get(sid)
        if not reporter:
            continue
        done = _stage_done(sid, state)
        is_next = sid in next_stages
        rep = reporter(state)
        rep.update({
            "agent": sid, "stage": ag["stage"], "role": ag["role"],
            "label": STAGE_LABELS.get(sid, sid),
            "state": "done" if done else ("active" if is_next else "pending"),
        })
        steps.append(rep)

    # The recommended next action.
    #  • Paused at a human gate → the human owes a CONFIRMATION before the UPCOMING
    #    gated stage runs. Key off next_stages (robust regardless of whether prior
    #    steps wrote their proof-of-completion). e.g. gated before `screening` →
    #    procurement confirms scope (owned by `intake`); before `decision` → analyst
    #    signs off (owned by `routing`).
    #  • Otherwise → the active step, else first not-yet-done step, else last (complete).
    GATE_BEFORE = {
        "screening": ("intake",
                      "Confirm the scoped checklist + oversight level to start screening."),
        "decision":  ("routing",
                      "Sign off on the recommended tier & approver to approve, or override."),
    }
    by_agent = {s["agent"]: s for s in steps}
    head, action_text = None, None
    if awaiting_gate:
        for stage in next_stages:
            if stage in GATE_BEFORE:
                owner, prompt = GATE_BEFORE[stage]
                head, action_text = by_agent.get(owner), prompt
                break
    if head is None:
        pending = [s for s in steps if s["state"] != "done"]
        head = (next((s for s in steps if s["state"] == "active"), None)
                or (pending[0] if pending else steps[-1]))
        action_text = head["next_action"]
    next_action = {
        "agent": head["agent"], "label": head["label"],
        "action": action_text, "awaiting_human": awaiting_gate,
        "blockers": head.get("blockers", []),
    }

    timeline = [{
        "ts": row.get("ts"), "actor": row.get("actor"),
        "action": row.get("action"), "detail": row.get("detail", ""),
        "gate": False,
    } for row in (state.get("audit") or [])]
    if awaiting_gate:
        timeline.append({
            "ts": None, "actor": "— gate —",
            "action": f"awaiting human confirmation before: {', '.join(next_stages) or 'next step'}",
            "detail": "", "gate": True,
        })

    return {
        "case_id": case_id,
        "status": state.get("status", "NEW"),
        "awaiting_gate": awaiting_gate,
        "next": next_stages,
        "steps": steps,
        "timeline": timeline,
        "next_action": next_action,
        "supplier": state.get("supplier", {}),
    }


# ── Build & compile the graph ───────────────────────────────────────────────
def build_graph(checkpointer=None, interrupt_before=None):
    g = StateGraph(CaseState)
    g.add_node("intake", intake_node)
    g.add_node("screening", screening_node)
    g.add_node("documents", documents_node)
    g.add_node("risk", risk_node)
    g.add_node("synthesis", synthesis_node)
    g.add_node("routing", routing_node)
    g.add_node("decision", decision_node)   # GATE 2 lands before this node

    g.add_edge(START, "intake")
    g.add_edge("intake", "screening")
    g.add_edge("screening", "documents")
    g.add_edge("documents", "risk")
    g.add_edge("risk", "synthesis")
    g.add_edge("synthesis", "routing")

    # GATE 2 as a CONDITIONAL EDGE (reliable across a single multi-node resume):
    # after routing, only proceed to `decision` when a human decision has been
    # injected into state. Otherwise the case STOPS at routing (status ROUTED) and
    # sits there awaiting analyst sign-off — `awaiting_gate` is then derived from
    # status==ROUTED + no decision, not from interrupt_before (which doesn't halt a
    # mid-traversal node). This is what makes Gate 2 a true pause.
    def _after_routing(state: CaseState) -> str:
        return "decision" if (state.get("decision") or {}).get("verdict") else END
    g.add_conditional_edges("routing", _after_routing,
                            {"decision": "decision", END: END})
    g.add_edge("decision", END)

    # GATE 1 stays an interrupt (it halts the very first invoke cleanly).
    gates = interrupt_before if interrupt_before is not None else ["screening"]
    return g.compile(checkpointer=checkpointer or MemorySaver(),
                     interrupt_before=gates)



if __name__ == "__main__":
    import json, uuid
    graph = build_graph()   # default gates: ["screening", "decision"]
    case_id = str(uuid.uuid4())
    initial = {
        "case_id": case_id,
        "supplier": {"legalName": "Boreal Refining Oy", "country": "FI",
                     "commodity": "refined cobalt sulfate",
                     "jurisdictions": ["US", "FI", "DRC"]},
        "documents": [],
        "audit": [],
    }
    config = {"configurable": {"thread_id": case_id}}

    def show(label):
        snap = graph.get_state(config)
        view = case_report(case_id, snap.values, awaiting_gate=bool(snap.next),
                           next_stages=list(snap.next))
        print(f"\n=== {label} ===")
        print("status        :", view["status"])
        print("awaiting_gate :", view["awaiting_gate"], "| next:", view["next"])
        print("next_action   :", view["next_action"]["action"])
        for s in view["steps"]:
            print(f"  [{s['stage']} {s['state']:7}] {s['label']}")

    # 1) Start → runs intake, pauses at GATE 1 (procurement confirms scope).
    graph.invoke(initial, config)
    show("GATE 1 — procurement confirms scope")

    # 2) Confirm scope → screening…routing, pauses at GATE 2 (analyst sign-off).
    graph.invoke(None, config)
    show("GATE 2 — analyst signs off")

    # 3) Inject the human decision and resume → finalizes the case.
    graph.update_state(config, {"decision": {"verdict": "approved",
                                             "by": "demo-analyst", "note": "looks good"}})
    graph.invoke(None, config)
    show("DONE — human-approved")
