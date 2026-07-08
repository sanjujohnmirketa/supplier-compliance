# Agentic Activation — making the AI framework *drive* the procurement flow

**Status:** design / pending approval
**Date:** 2026-06-17
**Author:** engine + Salesforce
**Problem statement (user):** *"The highlight is the AI back-engine and how it drives
supply-chain procurement. Currently it looks like AI features were simply added that
respond to the request I make — the overall flow doesn't feel like our agentic AI
framework is driving it."*

---

## 0. The key finding

The agentic framework is **already built and running** — it is not missing, it is
**dormant**. `orchestrator.py` is a compiled LangGraph multi-agent supervisor with:

- a canonical `CaseState` blackboard + explicit context-sharing contract,
- a **6-agent club** (intake → screening → documents → risk → synthesis → routing),
- an **append-only `audit` trail** emitted at every step (actor / action / detail / ts),
- **durable Postgres checkpointing** (survives restarts),
- a **human-in-the-loop gate** (`interrupt_before=["screening"]`),
- real agents already wired (`set_agents(scope_supplier, assess_document)`),
- HTTP surface: `POST /cases`, `GET /cases/{id}`, `POST /cases/{id}/resume`.

**Why it still feels like "bolt-on AI":** Salesforce never calls `/cases`. The console
calls the four *raw tool* endpoints directly — `/scope`, `/assess`, `/verify`,
`/copilot` — each triggered by a human button press. So:

1. The **human** is the orchestrator (clicks Generate, Run screening, Summarize…).
2. The agent graph that is *designed* to drive the case runs **nowhere**.
3. The **audit trail** — the visible proof that an agent is driving — is **never surfaced**.

The fix is therefore **activation + surfacing**, not new construction.

---

## 1. Target experience (what "AI-driven" means here)

| Today (request → response) | Target (agent drives, human supervises) |
|---|---|
| Fill form → click **Generate checklist** | Intake saved → **agent auto-scopes**, builds checklist, sets oversight, and *narrates what it did and why* |
| Upload docs → click around per doc | **Agent assesses each doc as it lands**, advances case state, surfaces "3/7 received · 2 pass · 1 expired · blocker = X" |
| Click **Run screening** | Once identity is known, **screening runs as a planned step** and folds in |
| Read scattered cards, decide | **Agent proposes the next action** ("Ready to route — here's the dossier" / "Chase supplier for X"); human approves/overrides |
| Co-pilot answers when asked | Co-pilot **narrates the ongoing case**, grounded in the live `CaseState` |

The human's authority level is the **HITL/oversight slider you already have** — it maps
directly onto *which gates auto-pass vs. require sign-off*. That is the supervision dial.

---

## 2. The state machine (already exists — this documents it)

```
START
  └─ intake      (Stage 01)  → scope domains + checklist + prelim tier   [REAL: /scope]
        ║  ◀── GATE 1: procurement confirms scope  (interrupt_before=["screening"])
  └─ screening   (Stage 02)  → GLEIF identity + sanctions signal         [REAL: screening.py]
  └─ documents   (Stage 03)  → per-document verdicts (accumulate)        [REAL: /assess]
  └─ risk        (Stage 04)  → per-domain evidence review
  └─ synthesis   (Stage 05)  → weighted score + suggested tier + conf
  └─ routing     (Stage 06)  → tier → approver + SLA (delegation of authority)
END
```

`CaseState` keys & ownership (from `orchestrator.py`):
`supplier`, `scope`, `checklist` (intake owns) · `screening` (screening owns) ·
`documents` (input) · `findings` (**accumulate**) · `synthesis`, `routing` ·
`status` · `audit` (**accumulate**).

### Gates (HITL) — proposed
- **Gate 1 (exists):** after `intake`, before `screening` — procurement confirms the
  scoped checklist + oversight. *Already configured.*
- **Gate 2 (add):** after `synthesis`/`routing`, before final approval — analyst signs
  off (or auto-passes when oversight = Auto-clear and tier = Low). This is where the
  oversight slider gates: **Auto-clear → skip Gate 2**; **Partial/Full → require analyst**.

---

## 3. What each agent step emits (the structured-output contract)

This is where the earlier "structured output, not a wall of sentences" work lands — it
becomes **how each agent reports its step**. Every node appends to `audit` AND owns a
typed result slice. The case view exposes a normalized **step report**:

```jsonc
{
  "stage": "03",
  "agent": "documents",
  "headline": "2 of 3 documents passed; 1 expired",   // one scannable line
  "verdict": "At Risk",                                 // badge
  "key_findings": ["ISO 9001 valid to 2027", "Insurance expired 2025-04"],
  "blockers": ["Insurance certificate expired"],
  "confidence": 72,
  "next_action": "Request a current insurance certificate from the supplier",
  "citations": ["finance:INS-2M", "..."]
}
```

The UI renders this as a **fixed card** (headline → badge → findings bullets → blockers →
next action), identical shape for every agent — so all AI output across both consoles is
consistent and scannable. The LLM fills slots; it cannot ramble.

---

## 4. The agent activity timeline (surfacing the audit trail)

`audit` rows already exist: `{ts, actor, action, detail}`. We surface them as a live feed:

```
✦ 12:04  intake/scope-agent     scoped 4 domains + checklist via /scope   (finance, cyber, conflict, quality)
⏸ 12:04  — GATE: awaiting procurement confirmation of scope —
✦ 12:09  screening-agent        GLEIF=found · sanctions=clear · signal=clear
✦ 12:10  document/risk-agent    assessed ISO 9001 → Compliant
✦ 12:10  document/risk-agent    assessed Insurance → Non-Compliant (expired)
✦ 12:11  synthesis-agent        score=48 tier=Medium conf=72
✦ 12:11  routing-agent          tier Medium → Sr. Compliance Approver (SLA 2d)
```

This is the single most important UI change: it makes the agent **visibly drive the case**.

---

## 5. Salesforce repoint (discrete tools → case lifecycle)

| Now | After |
|---|---|
| `generateChecklist` → `/scope` | `submit intake` → `POST /cases` (runs intake, pauses at Gate 1) |
| `runScreeningAndPersist` → `/verify` | `confirm scope` → `POST /cases/{id}/resume` (runs screening→…→routing) |
| `linkDocumentToCompliance` → `/assess` per doc | docs added to the case → re-invoke; `documents` node assesses them |
| `askCopilot` → `/copilot` | co-pilot reads the live `CaseState` for the supplier |

- Persist `case_id` on the `Account` (new field `Compliance_Case_Id__c`) to bind a
  supplier to its durable case thread.
- Existing per-row `Compliance_Assessment__c` writes are **kept** — they're populated
  *from* the case `findings`/`screening` so the queue & summaries still work. The case is
  the driver; the rows are the projection.
- Backward-compatible: the raw endpoints stay (tests, on-prem direct use); the console
  moves to the lifecycle.

---

## 6. How the other two workstreams fold in

- **Structured output (Phase 1 of the earlier plan):** becomes §3 — the per-step report
  schema. Co-pilot, /assess, disambiguation all emit slot-filled JSON; one render card.
- **Latency / model tiering:** `synthesis` and `routing` are deterministic Python (no LLM
  — already fast). LLM calls are intake-scope, per-doc assess, disambiguation, co-pilot.
  Apply: `max_tokens` caps, `gpt-4o-mini` for disambiguation/classify, parallelize the
  screening sub-calls (GLEIF + sanctions + adverse-media via `asyncio.gather`), cache
  identical co-pilot prompts. Doing this *inside* the agent steps means latency wins apply
  to the whole flow, not just one box.

---

## 7. Build order (each step shippable)

1. **Engine — step reports:** add a normalized `step_report` to each node's output +
   expose a `GET /cases/{id}` view that returns `{status, timeline[], steps[], next_action,
   awaiting_gate}`. (No behavior change yet; just surface what's there.)
2. **Engine — close the loop:** add Gate 2 + oversight-driven auto-pass; ensure
   `documents` node re-runs as docs arrive.
3. **Salesforce — repoint:** `Compliance_Case_Id__c`, intake → `/cases`, confirm →
   `/resume`, project `findings`→assessment rows.
4. **UI — timeline + next-action panel** in both consoles (the headline change).
5. **Co-pilot as narrator** (structured, reads CaseState).
6. **Latency pass.**

---

## 8. Risks / decisions to confirm

- **Dual-write window:** while repointing, both the old per-endpoint writes and the new
  case-driven writes exist. Plan: case becomes source of truth; old endpoints kept but the
  console stops calling them directly. Confirm we keep the raw endpoints for tests.
- **Gate 2 placement:** after `synthesis` (recommend) vs. after `routing` (post-DOA).
  Proposed: after `routing`, so the analyst sees the proposed approver + SLA when signing off.
- **Re-running documents node:** LangGraph re-invoke semantics as docs trickle in — confirm
  we append findings (reducer = add) without double-counting (dedup by documentType+key).
