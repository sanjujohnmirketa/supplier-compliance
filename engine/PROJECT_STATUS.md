# Project Status & Handoff — supplier-compliance-local

_Last updated: 2026-06-11 — Phase 1 functionally complete on `scVendorConsole`; persona-split consoles (`scProcurementConsole` + `scAnalystConsole`) built as skeletons, not yet wired._

A supplier-compliance platform: **Salesforce** (Lightning console) captures suppliers + documents and drives the workflow; a **provider-agnostic Python engine** (FastAPI over an SFTP-sourced policy corpus in pgvector) scopes the checklist, assesses documents, screens the entity, scores risk, and answers a grounded co-pilot — with a human gate on every decision.

> **Two UI threads right now:**
> 1. **`scVendorConsole`** — the **fully functional** Phase-1 console (reference implementation). Everything below in "Current state" runs on it.
> 2. **`scProcurementConsole` + `scAnalystConsole`** — **new persona-split skeletons** built in the console-revamp session (UI only, no backend glue yet). The intended go-forward UI.

---

## 0. Org connection & deploy — RESOLVED
- Default org: **`supplierCompliance`** (🍁 in `sf org list`; set in `.sf/config.json` as `target-org`). Deploys go straight to it.
- Manifest exists at `manifest/package.xml`. Nothing to re-create — earlier "no org" was just the project default not being read.
- Deploy command used all session:
  `sf project deploy start --source-dir <path> --target-org suppliermanagement_aisj@mirketa.com`

---

## 1. CURRENT STATE — Phase 1 complete & demo-ready (on `scVendorConsole`)

### Engine (System B) — all endpoints live & verified
| Endpoint | Capability |
|---|---|
| `/scope` | RAG checklist + risk domains + preliminary tier (local embeddings) |
| `/assess` | **Document Intelligence** — LLM extract → **deterministic verify gates** (expiry / coverage / TIN) + clause checks + registry validation |
| `/verify` | **Screening** — GLEIF identity · OpenSanctions sanctions/PEP · RMI conflict gate · **GDELT adverse media** · LLM entity disambiguation |
| `/copilot` | **Grounded co-pilot Q&A** over case context + policies |
| `/cases` | LangGraph club-of-agents (human gate + resume + Postgres checkpointer) |
| `/health` `/ready` | liveness + DB readiness |

Cross-cutting: provider-agnostic LLM (**currently gpt-4o**, swappable), governance (Presidio PII + injection scanning + schema validation), reliability (retry → degrade to "Needs Analyst"), **eval harness 8/8**, few-shot learning loop, externalized SOP prompts (`prompts/*.md`), startup model pre-warm.

### Salesforce (System A) — full flow working on `scVendorConsole`
- **Screens:** Intake → Queue → Due Diligence → Risk Domains → Agent Review → Decision.
- **Document assessment chain works:** upload → direct-enqueue `DocAssessQueueable` → `/assess` → verdict + confidence **persisted** (survives refresh).
- **Screening tabs** (Sanctions / Financials / Conflict / Media) populate; **co-pilot chat** on the AI risk summary (both personas).
- **Live risk score** (adjusts to verdicts + screening), score-hero summary, per-doc verdict + confidence; **HITL threshold** AI-set + tied to the risk tier.
- **Decision = the deciding factor:** procurement → **Approve & onboard** (Approved) / **Route to {approver}** (In Review); approver → **Ready for Purchase** (Reviewed) / **Failed** (Rejected). Decisions redirect to the queue.
- **Approver flow:** queue has an **"Awaiting your review"** section → opens the dashboard + co-pilot → final outcome.

### The headline fix (this session)
Apex `JSON.deserialize "Object unsupported in JSON: Object"` in `DocAssessService` + `ScreeningService` was silently breaking the AI summary **and** screening. Fixed with `deserializeUntyped` + manual mapping → both restored. (Plus: replaced the misfiring `Document_Uploaded__e` platform-event hop with a direct queueable enqueue.)

### Connectivity & config
- **VS Code dev tunnel** (stable URL) → Named Credential `Local_Compliance_Service`; **External Credential token corrected** (was a placeholder → caused 401). All callouts verified `200` from Salesforce.
- `.env` cleaned (a stacked multi-provider block had silently selected Ollama → fixed to OpenAI/gpt-4o).

---

## 2. NEW DIRECTION — two persona consoles (built as skeletons, not wired)

Built as **sibling LWCs** (skeleton, empty-state, no mock data), reusing the existing `vc-` design system, self-contained, structurally verified (bindings + templates + data-attrs check out). `scVendorConsole` left untouched as the reference.

| Console | Screens |
|---|---|
| **`scProcurementConsole`** (+ `scProcurementDocumentUploader`) | P1 New supplier · P2 Supplier queue · P3 Documents & screening |
| **`scAnalystConsole`** | A1 Analyst queue · A2 Risk analysis (3 tabs) · A3 Decision & route + floating **Analyst-only co-pilot** |

Status: **UI only — no backend glue, nothing deployed or committed.** Memory: `revamp-two-console-skeleton.md` (+ MEMORY.md index) captures the locked decisions, the build, deferred glue, reusable Apex, and the open questions.

### Deferred backend glue (B1–B7)
The wiring needed to make the persona consoles live (to be picked up next). The good news: **most backing Apex already exists** from `scVendorConsole` and can be reused directly.

### Reusable existing Apex (already built & working)
`VendorPortalController` (generateChecklist, getScreeningQueue, getSupplierSnapshot, runScreening, askCopilot, saveDecision, setReviewOutcome, saveCopilotFeedback) · `SupplierRiskDashboardController.getSupplierSnapshot` · `ScopeService` / `DocAssessService` / `ScreeningService` / `CopilotService` (engine callouts, now using `deserializeUntyped`) · `DocAssessQueueable` (direct-enqueue) · `ComplianceChecklistController`.

---

## 3. OPEN QUESTIONS — decide next session
1. **Wire the persona consoles to the existing Apex first** (lights up most of the flow with zero new backend) **before** tackling the B1–B7 glue?
2. **Surface both consoles as Lightning App tabs / FlexiPages** so they're clickable in the org for the pitch?
3. **Consolidate or keep both** — does `scVendorConsole` retire once the two persona consoles are wired, or stay as the all-in-one reference?

---

## 4. Local stack & daily startup (System B)
Postgres 16 + pgvector (`compliance-db`) · local SFTP (`compliance-sftp` :2222) · local `all-MiniLM-L6-v2` embeddings · `app.py` on :8000 · policy corpus in `policy_chunk`. **Full ops, smoke tests, and troubleshooting live in `DAILY_RUNBOOK.md`** (and `ARCHITECTURE.md`).

**Interpreter pin (important):** conda `(base)` coexists with `(.venv)` — always launch via the venv interpreter:
```powershell
$py = "C:\Users\johns\supplier-compliance-local\.venv\Scripts\python.exe"
& $py -m uvicorn app:app --port 8000        # no --reload for demos (more stable)
```
Engine restart gotcha: an orphaned worker can hold port 8000 — kill all python, confirm `Get-NetTCPConnection -LocalPort 8000` is free, then restart. **Never `docker compose down -v`** (wipes pgdata = policies + case checkpoints).

---

## 5. Documents produced
`ARCHITECTURE.md` (engine + agents + governance + key-supply) · `FUNCTIONAL_SPEC.md` (FSD) · `DEMO_SCRIPT.md` + `DEMO_SCRIPT_STAGE.md` (narration + stage directions) · `test-data/E2E_TEST_SCENARIOS.md` · `DAILY_RUNBOOK.md` (ops).

---

## 6. Remaining / next
- **Wire the persona consoles** (Q1/Q2) — reuse the existing Apex; deploy + surface as app tabs.
- **Phase 2:** PR → PO (simulated in Salesforce first).
- Optional: **backend layering refactor** (api / application / domain / infrastructure — design drafted).
- Drop in a real **`OPENSANCTIONS_API_KEY`** (currently a placeholder → sanctions unreliable).
- **Dormant (not deleted):** the legacy CMT rule engine (`ComplianceRuleEngineService`, etc.); `Compliance_Requirement__mdt` (45 records) **must stay** — it's the requirement catalog several controllers still read.
