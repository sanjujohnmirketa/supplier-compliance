# Technical Documentation — Supplier Compliance Platform

**Audience:** engineers/architects onboarding to the codebase.
**Scope:** (1) current system interaction, (2) future state — Azure + 2GP + git repo,
(3) the RAG mechanism — vectorization, storage, deterministic retrieval.
**Status conventions:** sections marked **CURRENT** describe what's verified running
today. Sections marked **TARGET** are design intent, not yet built — do not read them as
"already done." Diagrams are SVG, in `docs/diagrams/`.

---

## 1. Overview

The platform automates supplier compliance onboarding: intake → AI-scoped document
checklist → upload → AI document review → registry/sanctions screening → risk synthesis →
human-gated decision → routing. It is two systems working together:

- **Salesforce** — the system of record. Four LWC consoles, one Apex controller, the
  data model (Account, assessments, documents, audit log).
- **Compliance Engine** — a provider-agnostic FastAPI service that owns all the AI/RAG/
  agentic logic, callable from Salesforce over a Named Credential.

---

## 2. Current System Interaction — CURRENT

**Diagram:** [`docs/diagrams/current-state-interaction.svg`](diagrams/current-state-interaction.svg)

### 2.1 Salesforce components

| Component | Type | Role |
|---|---|---|
| `scComplianceConsole` | LWC (parent shell) | left-rail persona switcher; only component exposed to the site |
| `scProcurementConsole` | LWC | intake, checklist, document upload, screening, handoff |
| `scAnalystConsole` | LWC | per-document validation, decision & route |
| `scSupplierPortal` | LWC | public self-service intake + sub-supplier invitation |
| `VendorPortalController` | Apex (`@AuraEnabled`) | the single controller all consoles call; owns every callout to the engine |

All consoles are internal-only except `scSupplierPortal`, which is exposed on the public
site for supplier self-registration and the invite-a-sub-supplier flow (SP3/SP4).

### 2.2 Data model (Salesforce = system of record)

| Object | Purpose |
|---|---|
| `Account` (Supplier RT) | the supplier case — `Risk_Tier__c`, `Risk_Score__c`, `Onboarding_Status__c`, `HITL_Threshold__c`, `Compliance_Case_Id__c` (links to the engine's agent case), `ParentId` (tier cascade, T1→T2→T3) |
| `Compliance_Assessment__c` | one row **per required document** — `Status__c`, `Severity__c`, `Reason_Detail__c` (structured AI summary), `Compliance_Document__c` (lookup to the satisfying doc). **Master-Detail to Account.** |
| `Compliance_Document__c` | an uploaded document — type, issuer, expiry, confidence, upload channel. **Master-Detail to Account.** |
| `Document_Extraction__c` | the AI's structured extraction per document (`Extracted_Fields__c` JSON, confidence, model version). **Master-Detail to Document.** |
| `Audit_Log__c` | append-only, polymorphic activity/decision trail |
| `Compliance_Domain__mdt` / `Compliance_Requirement__mdt` / `Compliance_Verification_Source__mdt` | config metadata — domain catalogue, requirement rules, registry sources |

### 2.3 The integration seam — Named Credential

Every Salesforce → engine call goes through:
- **`Local_Compliance_Service`** (Named Credential) + **`Local_Compliance_Auth`**
  (External Credential, Bearer token) + **`Local_Compliance_Callout`** (perm set).
- **Today** the credential URL points at a **VS Code dev tunnel** (must be set *Public*,
  resets to Private on restart — the single most common local-dev failure mode).
- This is the **trust boundary**: Apex never talks to Postgres, an LLM, or an external
  registry directly — only to this one HTTPS endpoint.

### 2.4 Compliance Engine (FastAPI) — endpoints

| Endpoint | Purpose |
|---|---|
| `POST /scope` | risk tier + document checklist (RAG + deterministic rules) |
| `POST /assess` | document intelligence — extract fields, judge compliance |
| `POST /verify` | registry + sanctions/watchlist screening |
| `POST /copilot` | grounded chat (structured: verdict/findings/blockers/next-step, role-aware) |
| `POST /cases`, `GET /cases/{id}`, `POST /cases/{id}/resume` | the **agentic case lifecycle** (see 2.5) |

### 2.5 The agentic layer — LangGraph supervisor

A durable, **Postgres-checkpointed** state machine drives the case end to end:

```
intake/scope → [GATE 1: procurement confirms] → screening → documents (re-entrant,
dedup-safe) → risk → synthesis → routing → [GATE 2: analyst signs off] → decision
```

- **Gate 2 is a conditional edge, not `interrupt_before`** — a single multi-node resume
  doesn't honor interrupts mid-traversal, so the case genuinely *stops* at status
  `ROUTED` until a decision is injected.
- **Safety rule:** a flagged case (sanctions hit, Non-Compliant finding, High/Critical
  tier) can **never auto-clear**, even under `oversight=auto`.
- Every step emits a structured **step report** (headline, verdict, key findings,
  blockers, confidence) and an **audit timeline row** — this is what makes the agent
  *visibly* drive the case in the UI, not just answer requests.

### 2.6 Determinism & governance (summary — detailed in §4)
Risk tier and checklist are computed by **deterministic Python rules**, not LLM judgment.
Every LLM call is **governed**: PII tokenized (Presidio), prompt-injection scanned, and a
provider failure degrades to `"Needs Analyst"` — never silently `"Compliant"`.

---

## 3. Future State — CURRENT-code-target-infra (mark clearly as design intent)

> **These three changes are independent and can land in any order.** None require
> rewriting the agent, the consoles, or the data model — they change *where things run
> and how they're packaged*, not *what they do*.

### 3.1 Engine on Azure — TARGET

**Diagram:** [`docs/diagrams/future-state-azure.svg`](diagrams/future-state-azure.svg)

| Local today | Azure target |
|---|---|
| Docker Compose (engine + Postgres + sftp) | **Azure Container Apps** (or App Service) running the same container image |
| Postgres in Docker, `pgvector` extension | **Azure Database for PostgreSQL — Flexible Server**, `pgvector` extension enabled |
| `.env` file, secrets in plaintext locally | **Azure Key Vault** — no secrets in the image or compose file |
| VS Code dev tunnel (manually kept Public) | stable **HTTPS URL**, no laptop dependency |
| Named Credential URL = tunnel | Named Credential URL = **Azure endpoint** |

**Why this matters (the actual problem it solves):** today the engine only runs when a
developer's Docker Desktop is up and their dev tunnel is Public. Moving to Azure means
the engine is **always reachable**, independent of any individual's machine — the
original ask that started this workstream ("the engine has to be up even when someone
else is using the platform").

**What doesn't change:** the FastAPI app, the LangGraph agent, `llm.py`'s
provider-agnostic design, the eval harness — all container-portable as-is.

### 3.2 Salesforce as a 2GP package — TARGET

**Current state (verified):** `sfdx-project.json` has **one unnamespaced package
directory** (`force-app`), not yet a package.

**Target:**
1. Decide **unlocked vs. managed** 2GP (unlocked = simpler, no namespace lock-in required
   for an internal/single-org deployment; managed = needed if this ever ships to other
   orgs via AppExchange).
2. Register a **namespace** (managed only) or proceed namespace-less (unlocked).
3. Split `force-app` into **dependency-ordered package directories** if multiple packages
   are wanted (e.g. `compliance-core` → `compliance-ui`), or keep one package if scope
   stays single-org.
4. Update `sfdx-project.json` `packageDirectories` with `versionNumber`, dependencies.
5. Package creation + version creation (`sf package create`, `sf package version create`).
6. Install into target orgs by package version, not raw `deploy start`.

**Why 2GP over raw deploy:** versioned, installable artifact with dependency tracking —
the same package version can be promoted through sandboxes → production with a single
install, rather than re-running `sf project deploy start` against each org.

### 3.3 Everything in a git repo — TARGET (partially staged)

**Current state:** repo staging is **parked**, not committed. Prior work (see
`github-repo-prep-parked` memory) copied the engine into a staging folder with a scrubbed
`docker-compose.yml` and `.env.example`; Salesforce copy + `.gitignore` + `git init` are
still outstanding.

**Target layout:**
```
/engine       — FastAPI app, requirements, Dockerfile, policies/, prompts/, eval/
/salesforce   — the 2GP package source (force-app or split packages)
/docs         — this documentation + diagrams
.gitignore    — .env, .venv, __pycache__, node_modules, .sfdx
```
**Secret scrub checklist before first commit:** grep for `sk-proj-`, `sk-ant-`, bearer
tokens, DB passwords; verify `.env` is gitignored, not just absent; `docker-compose.yml`
uses `${VAR}` references, not literals.

---

## 4. RAG Mechanism — CURRENT

**Diagram:** [`docs/diagrams/rag-pipeline.svg`](diagrams/rag-pipeline.svg)

### 4.1 How we vectorize
- Model: **`all-MiniLM-L6-v2`** (sentence-transformers), **384-dimension** dense vectors.
- Runs **locally** — no external embedding API key required; works fully offline/
  air-gapped (`EMBED_BACKEND=local`).
- The policy corpus (`policies/*.md`) is chunked by clause before embedding.

### 4.2 Where embeddings are stored
- **Postgres + the `pgvector` extension**, table **`policy_chunk`**:
  `source, version, clause_id, domain, text, embedding vector(384)`.
- A `tsvector` column on the same table supports sparse (keyword) search alongside the
  dense vector column — one table, two retrieval paths.
- **Today:** local Docker Postgres. **Target (§3.1):** Azure Database for PostgreSQL
  Flexible Server with `pgvector` — same schema, same queries, different host.

### 4.3 Hybrid retrieval
1. **Dense** — pgvector cosine distance (`<=>` operator), floor **0.32** to separate real
   matches (0.36–0.46 observed) from noise (0.15–0.23 observed).
2. **Sparse** — Postgres `tsvector`, BM25-style keyword ranking.
3. **Fusion** — **Reciprocal Rank Fusion (RRF, k=60)** combines both rankings into one.
4. **Deterministic domain guarantee** — `INDUSTRY_DOMAINS` (rule map) and
   `BASELINE_DOMAINS` (finance/general, always included) are **unioned** with whatever
   RAG retrieves, so a sparse policy corpus never silently drops a mandatory requirement,
   and each industry provably yields a **distinct** checklist.

### 4.4 How outcomes are made deterministic
This is the property that lets the same supplier profile always produce the same risk
tier and checklist — critical for an audit-defensible compliance product.

| Mechanism | What it guarantees |
|---|---|
| **Math decides, LLM narrates** | Risk tier + checklist come from explicit Python rules over structured attributes (spend thresholds, commodity/country risk terms, engagement depth) — the LLM is never asked to *decide* the tier, only to explain it, grounded in the retrieved clauses it must cite. |
| **Relevance floor (0.32)** | Filters embedding noise before it can influence a domain match. |
| **Baseline + industry domain guarantee** | Two rule layers (`BASELINE_DOMAINS`, `INDUSTRY_DOMAINS`) ensure required domains are present regardless of what the corpus happens to retrieve for a given query. |
| **Governed LLM calls** (`governance.py`) | PII tokenization (Presidio) + prompt-injection scan run before every LLM call over untrusted content (uploaded documents). A document that tries to manipulate the model is flagged and **can never auto-pass**. |
| **Fail-safe degradation** | No LLM configured, provider error, or low confidence → verdict degrades to `"Needs Analyst"`. A `429` or a screening-provider error is never read as `"Compliant"` — this was a real bug we found and fixed. |
| **Flag-can't-auto-clear** (agentic safety) | A sanctions hit, a Non-Compliant finding, or High/Critical tier forces Gate 2 to hold for a human, even under auto-oversight. |

---

## 5. Deployment & Security — CURRENT

- **Auth:** Bearer token (`INBOUND_TOKEN`) validated on every engine request; Salesforce
  side via Named/External Credential (Bearer NamedPrincipal).
- **PII governance:** Presidio tokenizes names/tax IDs/bank numbers before any document
  text reaches an LLM (`governance.py`).
- **Prompt-injection defense:** untrusted document/case text is scanned
  (`guardrails.scan_injection`) before being included in an LLM prompt; injection
  attempts force a `"Needs Analyst"` verdict even if the model would otherwise say
  `"Compliant"`.
- **Provider-agnostic LLM (`llm.py`):** `openai | azure | anthropic | ollama | vllm |
  local` — an on-prem deployment can run fully air-gapped with a local model, no external
  API key.
- **HITL gates:** two structural human checkpoints (procurement confirms scope; analyst
  signs off before routing) — see §2.5.
- **No secrets ship in the container image** (target — see §3.1 Key Vault); today secrets
  are environment-variable injected via `docker-compose.yml` + `.env` (gitignored, never
  committed).

---

## 6. Related documents

- Sequence diagrams — [`vendor-onboarding-sequence.md`](vendor-onboarding-sequence.md)
- Data model (current + shift deltas) — [`current-data-model.md`](current-data-model.md)
- New data model ERD (Salesforce Data Cloud) — [`new-data-model-datacloud-erd.md`](new-data-model-datacloud-erd.md)
- Multi-tier risk roll-up design — [`multi-tier-risk-rollup.md`](multi-tier-risk-rollup.md)
- Agentic activation design — [`agentic-activation-design.md`](agentic-activation-design.md)
- pgvector vs. Data Cloud evaluation — [`datacloud-vs-pgvector-evaluation.md`](datacloud-vs-pgvector-evaluation.md)
- GOAP plan (this doc + the rule-engine change) — [`goap-plan-doc-and-rule-engine.md`](goap-plan-doc-and-rule-engine.md)
