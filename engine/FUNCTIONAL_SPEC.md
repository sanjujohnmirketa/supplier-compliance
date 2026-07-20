# Functional Specification — Supplier Compliance Automation

**Product:** Mirketa Supplier Compliance Automation
**Platform:** Salesforce (Lightning console) + provider-agnostic AI compliance engine
**Phase:** Phase 1 — Supplier onboarding, due diligence, risk decision & approver sign-off
**Status:** Implemented & demo-ready

---

## 1. Purpose & Scope

### 1.1 Purpose
Automate the manual, slow, and inconsistent work of onboarding and risk-assessing suppliers. The platform lets a procurement analyst initiate a supplier request and have an AI "club of agents" scope the required compliance documents, verify each document, screen the entity against authoritative registries, score the risk, and route the case to the correct human approver — with every AI output grounded in company policy and a human in control of every decision.

### 1.2 In scope (Phase 1)
- Procurement-initiated supplier intake and AI-scoped document checklist.
- Document upload + AI document-intelligence assessment (extract + verify).
- Live registry/entity screening (identity, sanctions, conflict minerals, adverse media).
- AI risk scoring, synthesis, and human-in-the-loop routing.
- A grounded co-pilot Q&A and an analyst feedback/learning loop.
- Approver review and the final "Ready for Purchase / Failed" decision.

### 1.3 Out of scope (Phase 2+)
- Purchase Requisition → Purchase Order creation/execution (the "Ready for Purchase" hand-off marks the boundary).
- Continuous post-onboarding monitoring / periodic re-screening automation.
- Supplier self-service vendor portal beyond document upload.

---

## 2. Actors / Personas

| Actor | Description | Primary screens |
|---|---|---|
| **Procurement Analyst** | Initiates the supplier request, runs due diligence, makes the first-line decision (approve or route). | Intake, Queue, Due Diligence, Decision |
| **Compliance Approver** | Reviews routed (higher-risk) cases and makes the final Phase-1 call. | Queue ("Awaiting review"), Due Diligence (read), Decision |
| **AI Engine (system actor)** | Scopes, assesses, screens, scores, and recommends — never decides. | All |
| **Supplier (external)** | Submits the requested documents (current scope: documents only). | — |

---

## 3. Solution Overview (End-to-End Workflow)

1. **Intake** — Analyst enters supplier attributes → AI scopes risk domains + required-document checklist + recommended human-review threshold.
2. **Document collection** — Analyst requests documents; supplier submits them.
3. **Due diligence** — Each document is AI-assessed (extract + deterministic verify + clause checks); entity is screened (identity, sanctions, conflict, media); a live risk score and grounded summary are produced.
4. **Decision** — Analyst confirms the AI-recommended tier + mitigations and either **approves** (low risk → onboarded) or **routes** to an approver (higher risk → In Review).
5. **Approver review** — Approver opens the routed case from a dedicated queue section, reviews the dashboard + co-pilot, and marks **Ready for Purchase** (→ Reviewed) or **Failed** (→ Rejected). Phase 1 ends here.

---

## 4. Functional Requirements by Module

### 4.1 Intake / Generate Checklist (Screen 1)
- **FR-1.1** The analyst shall enter: legal entity name, country, industry, engagement type, annual spend, requested-by, supplier email. All intake fields are mandatory before checklist generation.
- **FR-1.2** On **Generate Checklist**, the engine shall scope the supplier via policy-grounded retrieval and return: detected risk domains, required documents (each citing a policy clause), a preliminary risk tier, and an AI-set human-review threshold.
- **FR-1.3** The risk/scope domains shall be read-only and reflect the AI scoping (not manually selected).
- **FR-1.4** Checklist generation shall be deterministic for a given (industry + engagement + spend + country); non-scoping fields (e.g. email) shall not change the checklist.
- **FR-1.5** The human-review threshold shall be backend-derived from the risk tier (High/Critical → tighter), displayed read-only with a plain-language explanation.
- **FR-1.6** The analyst shall request documents from the supplier (email) in one action.

### 4.2 Screening Queue (Screen 2)
- **FR-2.1** Display all supplier records (Supplier record type) with: name, age, industry, risk tier, risk score, AI status, stage, flags, requested-by.
- **FR-2.2** Display KPIs: total suppliers, AI auto-cleared, needs-analyst, onboarded, average time-to-onboard.
- **FR-2.3** Provide a distinct **"Awaiting your review"** section listing cases in `In Review` status (routed to an approver); clicking opens the case for review.
- **FR-2.4** A search box (this screen only) filters by name/industry.

### 4.3 Due Diligence — Documents & AI Risk Summary (Screen 3)
- **FR-3.1** The analyst shall upload a document per checklist item; uploads are non-blocking (other documents can be uploaded while one is assessed); the latest filename is shown with a Replace option.
- **FR-3.2** Each uploaded document shall be AI-assessed in the background and persisted; results survive page refresh.
- **FR-3.3** Per document, the system shall produce a verdict (Compliant | Non-Compliant | Needs Analyst), a confidence level, grounded reasoning, extracted fields, clause-level PASS/FAIL checks, and a registry-validation result.
- **FR-3.4** Critical gates (expiry, minimum coverage, identifier presence) shall be decided deterministically; a document failing a hard gate cannot be Compliant.
- **FR-3.5** The **AI Risk Summary** shall show a live risk score (adjusting to document verdicts + screening), risk tier, per-document verdict+confidence, screening signals, and flagged findings.
- **FR-3.6** **Screening** shall run on case open and be viewable per category — Sanctions, Financials (identity), Conflict, Media — each with status and detail; failures surface an explicit error.
- **FR-3.7** A grounded **co-pilot** shall let the user ask free-text questions answered from this case's documents, screening, and policy clauses, with citations.
- **FR-3.8** The analyst shall **Accept** or **Override** the AI summary with a note (captured for the learning loop).

### 4.4 Risk Domains (Screen 4)
- **FR-4.1** Display the scoped domains grouped from the assessments with per-domain compliant/failed/pending counts.

### 4.5 Agent Review (Screen 5)
- **FR-5.1** Display the append-only activity/audit log of agent and human actions for the case.

### 4.6 Decision (Screen 6)
- **FR-6.1** Present the AI-recommended risk tier (highlighted on the matching tier card), editable required mitigations (AI-derived from findings + screening, with add/remove), and routing options mapped to approvers.
- **FR-6.2** Provide a rationale field carried to the approver.
- **FR-6.3 (Procurement)** The primary action shall be dynamic: **Approve & onboard** (low → `Approved`) or **Route to {approver}** (higher → `In Review`).
- **FR-6.4 (Approver)** For a case already `In Review`, the actions shall be **Ready for Purchase** (→ `Reviewed`) or **Failed** (→ `Rejected`).
- **FR-6.5** After any decision, the user is redirected to the Screening Queue; the decision is audit-logged.

### 4.7 AI Engine Capabilities (system)
- **FR-E.1 Scoping** — policy-grounded RAG retrieval → domains + checklist + preliminary tier.
- **FR-E.2 Document Intelligence** — LLM extraction + deterministic verification gates + clause validation + registry validation.
- **FR-E.3 Screening** — GLEIF identity, OpenSanctions sanctions/PEP, RMI conflict-minerals gate, GDELT adverse media; LLM entity disambiguation to suppress false positives.
- **FR-E.4 Synthesis** — weighted risk score → tier + confidence, from document findings + screening signal.
- **FR-E.5 Routing** — tier → approver + SLA (delegation of authority).
- **FR-E.6 Co-pilot** — grounded Q&A over case context + policies.
- **FR-E.7 Learning loop** — analyst overrides/ratings become few-shot calibration examples.

---

## 5. Status / State Model (Account.Onboarding_Status)

| Status | Set by | Meaning |
|---|---|---|
| **Draft** | Intake | Created, not yet submitted |
| **In Review** | Procurement (Route) / scope trigger | Awaiting approver sign-off |
| **Approved** | Procurement (Approve, low risk) | Onboarded (auto-approve path) |
| **Reviewed · Ready for Purchase** | Approver (Ready for Purchase) | Phase-1 complete → Phase-2 purchase |
| **Rejected** | Approver (Failed) | Did not pass review |

---

## 6. Data Model (key objects/fields)

| Object | Key fields | Purpose |
|---|---|---|
| **Account (Supplier RT)** | Risk_Tier__c, Risk_Score__c, Risk_Domains__c, Onboarding_Status__c, HITL_Threshold__c, Engagement_Type__c, Supplier_Contact_Email__c, Annual_Spend_Est__c | The supplier case |
| **Compliance_Assessment__c** | Requirement_Key__c, Requirement_Label__c, Status__c, Severity__c, Reason_Detail__c, Compliance_Document__c | One per required document (verdict + grounded reasoning) |
| **Compliance_Document__c** | Document_Type__c, Status__c, Account__c | An uploaded document record |
| **Audit_Log__c** | Event_Type__c, New_Value__c, Actor_Type__c, Event_DateTime__c | Append-only activity/decision trail |
| **Compliance_Domain__mdt / Compliance_Requirement__mdt / Compliance_Verification_Source__mdt** | — | Domain catalogue, requirement→doc-type mapping, registry config |
| **policy_chunk (Postgres/pgvector)** | source, version, clause_id, domain, text, embedding(384) | The searchable policy corpus (RAG) |

---

## 7. Integrations

| Integration | Direction | Notes |
|---|---|---|
| **Salesforce → Compliance Engine** | Outbound callout | Named Credential `Local_Compliance_Service` + External Credential bearer token; endpoints `/scope`, `/assess`, `/verify`, `/copilot` |
| **GLEIF** | Engine → external | Legal-entity identity (free, keyless) |
| **OpenSanctions** | Engine → external | Sanctions/PEP (API key; demo watchlist fallback) |
| **RMI conflict minerals** | Manual | No public API → routed to analyst |
| **GDELT** | Engine → external | Adverse-media news (free, keyless) |
| **Policy corpus (SFTP → pgvector)** | Ingestion | `ingest_policies.py`: SFTP `/upload` → parse → chunk → embed → `policy_chunk` |
| **LLM provider** | Engine → external/local | Provider-agnostic (OpenAI/Azure/Anthropic/Ollama/vLLM) |

---

## 8. Non-Functional Requirements

### 8.1 Security & Governance
- **NFR-S.1** Every LLM call over untrusted supplier content is PII-tokenized (Presidio), injection-scanned, and wrapped in untrusted-content framing.
- **NFR-S.2** A document attempting prompt injection can never auto-pass; it is forced to the human gate.
- **NFR-S.3** All model responses are schema-validated (no free-text trust).
- **NFR-S.4** No secrets are bundled; each deployment supplies its own keys, or runs a local model needing none. Salesforce↔engine auth uses a bearer token.

### 8.2 Reliability
- **NFR-R.1** Transient failures retry; any unrecoverable failure degrades gracefully to "Needs Analyst" — never a silent wrong verdict.
- **NFR-R.2** Workflow state is checkpointed so a case can pause at the human gate and resume intact.

### 8.3 Determinism & Trust
- **NFR-D.1** Critical compliance gates are rule-based, not model-judged.
- **NFR-D.2** Scoping is deterministic for identical scope inputs.
- **NFR-D.3** Every AI verdict cites the policy clause(s) it relied on.

### 8.4 Adaptability & Performance
- **NFR-A.1** LLM provider is swappable via configuration with no agent-code change; on-prem deployable.
- **NFR-A.2** Local embeddings keep the policy corpus in-environment.
- **NFR-A.3** Indicative latency: scope ~instant (pre-warmed), document assessment ~4–8 s, full screening ~10–15 s.

### 8.5 Auditability
- **NFR-AU.1** Every agent action and human decision is recorded in `Audit_Log__c` with actor, timestamp, and value.

### 8.6 Continuous Evaluation
- **NFR-E.1** A golden regression set + harness validates the deterministic guarantees on every prompt/code change.

---

## 9. Assumptions & Constraints
- The compliance engine is reachable from Salesforce (dev: VS Code tunnel; prod: hosted/containerized endpoint).
- The policy corpus is curated and ingested before go-live; checklist quality depends on corpus coverage.
- Registries without a public API (e.g. RMI) require manual analyst verification by design.
- Phase 1 ends at "Ready for Purchase"; PR→PO execution is Phase 2.

---

## 10. Glossary
- **HITL threshold** — Human-in-the-loop review threshold; cases above it route to an approver.
- **Club of agents** — the orchestrated set of specialized AI agents (intake, screening, documents, risk, synthesis, routing).
- **Deterministic gate** — a hard-coded rule (expiry, coverage, identifier) that decides pass/fail regardless of the model.
- **Grounding** — answers/verdicts restricted to and citing the retrieved policy clauses + case context.
- **Disambiguation** — LLM step that picks the true legal entity and suppresses false-positive sanctions matches.
