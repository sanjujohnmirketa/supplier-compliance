# VERA — Functional Process (One-Pager)

**VERA · Vendor Evaluation & Risk Agent** — Supplier Compliance Automation
*Phase 1: pre-contract supplier onboarding, due diligence, risk decision & approver sign-off.*
Salesforce Lightning console (front end) + a provider-agnostic AI compliance engine (back end). Every AI output is policy-grounded; a human decides at every gate.

---

## The process, end to end

**Two owners, one pipeline.** A Procurement Team Member gathers and submits evidence; a Risk Analyst assesses and recommends; an Approver signs off. The AI scopes, validates, screens, scores, and drafts — it never decides.

```
PROCUREMENT (Executor)                    │ handoff │     ANALYST (Advisor)                    →  APPROVER
P1 New supplier   → P2 Supplier queue → P3 Documents & screening ═══►  A1 Analyst queue → A2 Risk analysis → A3 Decision & route → sign-off
```

| # | Screen | Who | What happens |
|---|--------|-----|--------------|
| **P1** | New supplier | Human | Enter legal entity, country, industry, engagement type, annual spend, email. AI **scopes** the supplier → risk domains + a required-document **checklist** (each citing a policy clause) + a recommended human-oversight level. |
| **P2** | Supplier queue | Human/Track | Procurement home base — track in-review suppliers, resume drafts, chase missing documents (auto-email request, auto-chase). |
| **P3** | Documents & screening | Human + AI | Bulk-upload documents → AI **assesses each** (extract + deterministic verify + clause checks) and matches it to the checklist. Run **screening** (identity, sanctions, conflict minerals, adverse media), then **hand off** to an analyst. |
| **A1** | Analyst queue | Human/Triage | Risk register of handed-over suppliers — triage by AI tier, flags, and document count. |
| **A2** | Risk analysis | Human + AI | One workspace: per-document AI summary + analyst comment + **mark-validated**; co-pilot drafts comments from observations. Live risk view + audit trail. |
| **A3** | Decision & route | Human/Decides | Confirm or override the AI tier, attach required mitigations, and **route** to the right approver (delegation of authority). |
| — | Sign-off | Approver | Reviews the 1-page packet → **Ready for Purchase** (Phase-1 complete) or **Failed**. |

**Status model** (`Account.Onboarding_Status__c`): Draft → In Review → Approved *(auto, low risk)* → Reviewed · Ready for Purchase → Rejected.

---

## Front end — Salesforce Lightning (LWC)

- **`scComplianceConsole`** — VERA shell; persona switch between the two workspaces.
  - **`scProcurementConsole`** (P1–P3) — intake, checklist, queue, bulk upload, screening run, handoff. No co-pilot.
  - **`scAnalystConsole`** (A1–A3) — analyst queue, per-document validation, decision & route. **Action-driving co-pilot on A2/A3 only.**
- **Apex bridge** — `VendorPortalController` (orchestrator) + service clients. Key methods: `generateChecklist`, `submitAndScreen`, `runScreeningAndPersist`, `getSupplierSnapshot`, `assignToAnalyst`, `getAnalystQueue`, `getCaseForAnalyst`, `saveDocValidation`, `askCopilot` / `copilotDraftComment`, `saveDecision`.
- **Data model** — Account (Supplier RT: `Risk_Tier/Score/Domains__c`, `HITL_Threshold__c`, `Onboarding_Status__c`), `Compliance_Assessment__c` (one verdict per required doc), `Compliance_Document__c`, `Audit_Log__c` (append-only trail).

## Back end — provider-agnostic AI engine (`app.py`, FastAPI)

Reached from Salesforce over **Named Credential `callout:Local_Compliance_Service`** (bearer token). Four endpoints map to the screens:

| Endpoint | Used by | Function |
|----------|---------|----------|
| `POST /scope` | P1 | Policy-grounded RAG retrieval (pgvector + local MiniLM embeddings) → risk domains + checklist + preliminary tier. **Deterministic** for the same profile. |
| `POST /assess` | P3 | Document intelligence: LLM **extracts** structured fields; **hard-coded gates decide** expiry / min-coverage / identifier (an expired or under-limit doc can never auto-pass) + clause validation + registry check. |
| `POST /verify` | P3 | Screening: GLEIF identity, OpenSanctions sanctions/PEP (+ LLM disambiguation to kill false positives), RMI conflict minerals (→ analyst), GDELT adverse media. |
| `POST /copilot` | A2/A3 | Grounded Q&A / comment drafting over case context + policy clauses, with citations. |

**Engine pillars** — *Adaptable* (`llm.py`: OpenAI/Azure/Anthropic/Ollama/vLLM, swap by config, on-prem capable). *Governed* (`governance.py`: PII tokenization + injection scan + untrusted framing on every external-content call; a doc that attempts injection can't auto-pass). *Reliable* (`reliability.py`: transient retry; any failure degrades to **"Needs Analyst"**, never a silent wrong verdict; case state checkpointed in Postgres). *Deterministic & grounded* (critical gates are rules, not model judgment; every verdict cites its clause). *Self-improving* (`eval_harness.py` golden suite locks the guarantees; analyst overrides become few-shot examples).

---

**Trust boundary:** the AI scopes, validates, screens, scores, and drafts — **a human signs every decision.** Critical compliance gates are rule-based; every AI verdict is grounded in and cites company policy.
