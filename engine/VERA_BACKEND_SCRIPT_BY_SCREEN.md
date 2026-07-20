# VERA — Backend Engine, Screen by Screen (technical script)

A narration script for walking a technical audience through what the backend
*actually does* behind each screen. Each section: **the screen → the call it
makes → what the engine does → what comes back**. Grounded in the live code
(`app.py`, `governance.py`, `screening.py`, `registry.py`, `VendorPortalController.cls`).

**Transport for every engine call:** Salesforce LWC → Apex service class →
`HttpRequest` to **Named Credential `callout:Local_Compliance_Service`** (bearer
token) → FastAPI (`app.py`). The engine is provider-agnostic (`llm.py`:
OpenAI/Azure/Anthropic/Ollama/vLLM) and degrades to "Needs Analyst" on any failure.

---

## P1 — New Supplier (intake → AI checklist)

**Call:** `generateChecklist` (Apex `VendorPortalController`) → `ScopeService.getScope` → **`POST /scope`**

**What the engine does (`app.py:/scope`):**
1. Builds a retrieval query from the supplier *profile* — `commodity` (which carries
   `industry; engagement: …; annual spend …`), `country`, `jurisdictions`. The legal
   **name is deliberately excluded** so the domain set is stable across suppliers with
   the same profile.
2. **RAG retrieval** — `retrieve(query, k=30)`: embeds the query with a **local
   MiniLM** model, runs cosine search over `policy_chunk` (Postgres + **pgvector**),
   returns the best-scoring policy clauses.
3. **Domain selection** (deterministic + RAG, three sources unioned):
   - **RAG-matched domains** — kept only above a **dense-cosine floor (0.32)** so
     off-topic clauses can't leak in.
   - **Industry rules** (`INDUSTRY_DOMAINS`) — guarantee each industry's core domains
     (the corpus alone can't differentiate industries; they embed near-identically).
   - **Engagement rules** (`ENGAGEMENT_DOMAIN_RULES`) — refine by relationship type
     (Services/Consulting → add cyber+finance, drop material/conflict; Logistics → add
     trade), then subtract removals **but never drop the baseline** (finance, general).
4. **Risk tier** (`assess_risk`) — reasons over the supplier's *own profile* (country,
   commodity, spend, engagement depth via `HIGH_ENGAGEMENT_TERMS` + spend thresholds),
   NOT the retrieved policy text (which always mentions sanctions/conflict and would
   force everything to High). Returns tier + bullet reasons.
5. **Checklist build** — one document per selected domain (`DOMAIN_TO_DOCUMENT`), each
   carrying its **justification clause id + text** so the UI can show *why*.

**Returns:** `riskTier`, `riskSummary`, `riskReasons[]`, `scope[]` (domains),
`checklist[]` (doc + domain + justification), `domainReasons{}`, `noPolicyMatch`,
`notes[]`. Apex maps tier → recommended HITL (oversight) level.

**Determinism note:** identical (industry + engagement + spend + country) → identical
checklist. The oversight slider is backend-derived from the tier, not hand-set.

---

## P3 — Documents & Screening · Documents tab (upload → AI validation)

**Call:** file upload (`DocumentProcessingController.saveFile` + `linkDocumentToCompliance`)
queues **`DocAssessQueueable`** → `DocAssessService` → **`POST /assess`** (async).

**What the engine does (`app.py:/assess`):**
1. **Extract text** — `extract_document_text`: pdfplumber (PDF), python-docx (DOCX),
   or plain text from the uploaded bytes.
2. **Resolve domain** — caller-supplied, else `guess_domain(text)`.
3. **RAG retrieve** the 6 most relevant policy clauses for this document + domain.
4. **Governed LLM judgment** (`judge_compliance` → `governance.governed_judge`):
   - **PII tokenization** (Presidio) — PII spans replaced with tokens before the model
     sees the text.
   - **Injection scan** — `scan_injection` flags prompt-injection attempts; a flagged
     doc can **never auto-pass** (forced to "Needs Analyst").
   - **Untrusted-content framing** — the document is wrapped in explicit
     `BEGIN/END UNTRUSTED CONTENT` markers.
   - The LLM **only EXTRACTS** structured fields (issuer, identifier, dates, coverage)
     and proposes a verdict — it does **not** get the final say on the hard gates.
5. **Deterministic gates** (`_doc_intelligence`, hard-coded — the trust core):
   - **Expiry** — an expired document is force-failed regardless of the model.
   - **Minimum coverage** — COI under $2M is force-failed.
   - **Identifier presence** — missing TIN/cert number → routed to analyst.
   A hard-gate failure **overrides** an LLM "Compliant".
6. **Registry validation** (`registry.validate`, Stage-03b) — routes the extracted doc
   to its issuing registry: live API where one exists (e.g. **GLEIF**), else
   `manual_required` / `not_configured` → human gate.

**Returns:** `verdict` (Compliant | Non-Compliant | Needs Analyst), `severity`,
**`confidence` (0–100)**, `reasons`, structured `summary` (headline/facts/concerns),
`extractedFields`, `keyDates`, `clauseChecks[]` (PASS/FAIL per clause), `citations`,
`registryValidation`, `evidence[]` (clause ids + scores), `model`.

**Persistence:** `DocAssessQueueable` writes verdict + **`AI_Confidence__c`** +
structured detail to `Compliance_Assessment__c`, and audits the AI call
(`AuditLogService`). The UI **auto-refreshes** (polls the snapshot) until the async
verdict lands.

---

## P3 — Documents & Screening · Screening tab (entity due diligence)

**Call:** `runScreeningAndPersist` (Apex) → `ScreeningService` → **`POST /verify`**

**What the engine does (`app.py:/verify`):**
- **Identity / Financials — GLEIF** (`screening.gleif_lookup`, free/keyless): confirms
  the legal entity, registration status, ownership structure.
- **Sanctions / PEP — OpenSanctions** (`sanctions_screen`): OFAC/EU/UN + PEP lists. Uses
  a demo watchlist fallback when no API key is configured.
- **LLM disambiguation** (`disambiguate`): resolves the true legal entity and
  **suppresses false-positive** sanctions matches (common-name noise), returning a
  recommended signal (clear | review | flag).
- **Adverse media — GDELT** (`media.adverse_media_screen`, keyless): scans global news,
  LLM-classifies relevance/tone.
- **Conflict minerals — RMI**: no public API → `NotConfigured` → analyst (this category
  is filtered out of the demo UI).

**Returns:** per-category `{authority, category, status, summary, evidence[]}` + overall
`signal`. Apex persists each result as a `Compliance_Assessment__c` "Screening —" row so
it folds into the supplier's AI summary. UI shows three: **Sanctions, Financials, Media**.

---

## P4 — Submission Summary (dashboard + per-doc rollup)

**No new engine call** — this screen is a **deterministic, application-side rollup** of
data already persisted by `/assess` and `/verify`.

- **Risk score (0–100 ring)** — pure app-logic (`scComplianceDashboard`, no LLM):
  tier baseline (Low 88 / Med 68 / High 42 / Critical 24) minus penalties (rejected −12,
  pending −6), clamped. Reproducible and explainable.
- **Onboarding progress** — compliant ÷ total required documents.
- **Score trend** — last-N evaluation points.
- **Per-document confidence** — the `AI_Confidence__c` persisted from `/assess`,
  surfaced through `AssessmentSummary.aiConfidence`.

**Point:** the engine produced the *evidence*; this screen does *arithmetic* on it — so
the headline numbers are auditable, never model-guessed.

---

## A2 — Risk Analysis (analyst document validation + co-pilot)

**Document validation** reads the persisted `/assess` output via `getCaseForAnalyst`
(Apex) — the analyst sees the same structured AI summary (headline / clause PASS-FAIL /
concerns / confidence) the engine produced, and Approves/Rejects each.

**Co-pilot — two answer paths:**
1. **Instant local answers** (no engine call) — "show key fields", "which findings need
   judgement", "summarise non-compliant" read straight from the **already-stored**
   assessment data. This is the deterministic, zero-latency path (and why the old
   "extract all fields" 504 is gone — nothing is re-extracted).
2. **Grounded free-text** → `askCopilot` (Apex) → **`POST /copilot`**:
   - RAG-retrieves policy clauses for the question.
   - Builds context from the supplier's persisted assessments + screening (separating
     "uploaded" from "still missing").
   - **Governed** LLM call, **capped at 500 tokens**, **cached** by (case, role,
     question, context-hash) so a moved case re-answers but repeats are instant.
   - Returns `answer`, `verdict`, `keyFindings[]`, `blockers[]`, `recommendedAction`,
     `nextStep`, `citations[]` — grounded, with policy citations.

---

## A3 — Decision & Route (recommendation, no new AI)

**Call:** `saveDecision` / `routeDecision` (Apex) — **deterministic routing**, no engine
call. Tier → approver + SLA (delegation of authority): Low → auto-approve, Med → single
approver (2-day SLA), High → committee + legal (5-day SLA). The co-pilot can **draft the
rationale** from the validated findings (`/copilot`), but the analyst confirms the tier
and the routing is rule-based.

---

## Cross-cutting engine pillars (say these once, up front)

- **Adaptable** — `llm.py` exposes one `chat_json()` across 5+ providers; swap via
  `LLM_PROVIDER`, on-prem capable, no agent-code change.
- **Deterministic & governed** — critical gates (expiry, coverage, identifier) are
  rule-based, not model-judged; every external-content LLM call is PII-tokenized +
  injection-scanned + untrusted-framed; a doc that attempts injection can never auto-pass.
- **Grounded** — every verdict/answer cites the policy clause(s) it relied on (RAG over
  `policy_chunk`).
- **Reliable** — transient retry; any provider/parse failure degrades to "Needs Analyst",
  never a silent wrong verdict; case state checkpointed in Postgres (LangGraph).
- **Self-improving** — `eval_harness.py` golden suite locks the deterministic guarantees
  on every change; analyst overrides become few-shot calibration examples.

---

### One-line per screen (for a fast pass)
- **P1** → `/scope`: RAG + industry + engagement rules → tier + checklist (deterministic).
- **P3 docs** → `/assess`: governed extract → **hard gates decide** → confidence + structured verdict.
- **P3 screening** → `/verify`: GLEIF + OpenSanctions + GDELT + LLM disambiguation.
- **P4** → no call: deterministic rollup of persisted evidence (score/progress/confidence).
- **A2** → stored data + `/copilot` (governed, cached, cited).
- **A3** → deterministic tier→approver routing; co-pilot drafts the rationale.
