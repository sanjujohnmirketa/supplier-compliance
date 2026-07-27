# GOAP Plan — Technical Documentation + Policy-Driven Rule Engine

Produced with the GOAP methodology (goal → current state → gap → actions with
preconditions/effects/cost → ordered plan → risks → fallback). Two workstreams.

**Grounding (verified against the org, not assumed):**
- ✅ `Compliance_Requirement__mdt` exists as a rule table (Rule_ID, Document_Type,
  Required_For_Industry/Tier/Region/Criticality, Is_Mandatory, Governing_Body,
  Effective_From/To, Renewal_Frequency_Days, Severity_on_Failure).
- ✅ **A Salesforce rule engine ALREADY EXISTS**: `ComplianceRuleEngineService`
  (`getApplicableRules()` + `generateChecklist()`, *"zero hardcoded rules — all live in
  Compliance_Requirement__mdt"*), `ComplianceRequirementSelector` (caches active rules),
  `ComplianceChecklistController`.
- ❌ **Gap:** the LWC checklist today comes from the **engine `/scope` (RAG + hardcoded
  `DOMAIN_TO_DOCUMENT` / `INDUSTRY_DOMAINS` in `app.py`)**, NOT from the SF rule engine.
  And there is **no policy-upload → extract → populate-rule-table** path.
- ⛔ **Hard constraint:** **CMDT records cannot be written by runtime Apex DML** (Metadata
  API only). "On upload, store rules in the table" cannot target a CMDT directly at
  runtime — this forces a rule-store decision (see WS-B, Decision D1).

---

# WORKSTREAM A — Technical Documentation

### Goal state (what "done" looks like)
A single technical document (in the repo) that a new engineer or architect can read to
understand:
1. **Current system interaction** — the LWC consoles, `VendorPortalController` Apex, the
   Named-Credential callout to the FastAPI engine, the per-requirement
   `Compliance_Assessment__c` model, and the agentic LangGraph flow with human gates.
2. **Future state** — FastAPI engine on **Azure**, Salesforce metadata as a **2GP managed/
   unlocked package**, everything in a **git repo**, with the deployment topology.
3. **RAG mechanism** — how we vectorize (all-MiniLM-L6-v2, 384-dim), where embeddings live
   (Postgres `pgvector` `policy_chunk` today), and how outcomes are made **deterministic**
   (deterministic risk+checklist logic, hybrid BM25+dense+RRF, relevance floor).

### Current state
- Consoles + Apex + engine all exist and run; many docs already written this session
  (agentic-activation-design, data-model, datacloud-eval, sequence diagrams) — **reuse,
  don't rewrite.**
- Engine runs **locally in Docker**; no Azure, no 2GP package, repo staging is **parked**
  (`github-repo-prep-parked`).

### Gap
- No single consolidated technical doc; Azure + 2GP are **design intents not yet built**,
  so the doc's future-state section is **forward-looking / target-architecture**, clearly
  labelled as such.

### Actions (precondition → effect · cost)

| # | Action | Precondition | Effect | Cost |
|---|---|---|---|---|
| A1 | **Outline the doc** (sections: overview · current interaction · sequence · data model · RAG · future-state Azure+2GP+repo · deployment · security) | goal agreed | skeleton exists | S |
| A2 | **Current interaction section** — component map (4 LWCs → VendorPortalController → Named Cred → engine endpoints /scope /assess /verify /cases /copilot), the assessment model, the agent gates | code retrieved (done) | current state documented | M |
| A2b | **Generate the high-level interaction diagram via Claude/design** — use the ready prompt in Appendix 1 to produce a current-state system-interaction diagram (LWCs → Apex → Named Cred → engine → pgvector), for the doc's current-state section | A2 outline | interaction diagram produced | S |
| A3 | **Reuse existing diagrams** — embed/link the sequence diagrams + data model + Data Cloud ERD already produced | those docs exist (done) | visuals in place | S |
| A4 | **RAG section** — vectorize (MiniLM-384), store (pgvector `policy_chunk`: source/version/clause_id/domain/text/embedding), retrieve (dense `<=>` + sparse tsvector + RRF k=60 + dense floor 0.32), determinism (rule-based risk/checklist; LLM narrates, math decides) | engine facts verified (done) | RAG explained | M |
| A5 | **Future-state: Azure** — target topology: engine container → Azure Container Apps / App Service; Postgres → Azure DB for PostgreSQL **Flexible Server + pgvector**; secrets → Key Vault; Salesforce → Named Credential/External Credential points at the Azure URL (replaces the dev tunnel) | none (design) | Azure target documented | M |
| A6 | **Future-state: 2GP packaging** — convert `force-app` to a 2GP **unlocked** (or managed) package; namespace decision; dependency ordering (objects → Apex → LWC → perm sets); `sfdx-project.json` package dirs; version/release process | none (design) | packaging path documented | M |
| A7 | **Future-state: repo** — monorepo layout (`/engine`, `/salesforce`, `/docs`), secret scrub (already staged in `github-repo-prep-parked`), CI outline | parked repo state known (done) | repo plan documented | S |
| A8 | **Deployment + security section** — auth (Bearer/JWT), PII (Presidio), determinism guarantees, HITL gates, flag-can't-auto-clear | A2,A4 done | ops/security documented | S |
| A9 | **Review pass** — verify every technical claim against code; mark forward-looking items clearly | A2–A8 done | doc accurate + labelled | S |

### Ordered plan (WS-A)
`A1 → A2 → A3 → A4 → A8` (current+RAG, all verifiable now) → `A5 → A6 → A7` (future-state,
design) → `A9` (review). Cost: **~M-L total** (mostly assembly + reuse; low code risk).

---

# WORKSTREAM B — Policy-Driven Rule Engine (the checklist change)

### Goal state
1. **Policy document uploaded** (by an admin/analyst) → its details are **extracted**
   (doc type, applicable industry/tier/region/criticality, mandatory?, governing body,
   effective dates, renewal frequency) → **rules are stored in a Salesforce rule table.**
2. **The AI/checklist generation pulls the checklist from that rule table**, not from the
   hardcoded `app.py` maps.
3. **On any policy documentation change**, the rule table is **kept in sync** (add/update/
   deactivate rules).

### Current state
- ✅ SF rule engine exists (`ComplianceRuleEngineService.generateChecklist()` reads
  `Compliance_Requirement__mdt`).
- ❌ The LWC calls the **engine `/scope`** (RAG + hardcoded maps) for the live checklist.
- ❌ No policy-upload → extract → rule-table population.
- ⛔ CMDT can't be DML-written at runtime.

### Gap → the three real changes
1. **Rule store that's runtime-writable** (Decision D1).
2. **Policy-ingest → extraction → rule-upsert** pipeline.
3. **Repoint checklist generation** to read the rule table (drop hardcoded maps).

### Decision D1 — where do runtime-written rules live? (must pick before building)
| Option | Pros | Cons |
|---|---|---|
| **D1a · New `Compliance_Rule__c` custom SObject** (recommended) | Runtime DML (Apex can upsert on upload); reportable; FLS; the "rule engine table inside Salesforce" you described | new object; migrate/mirror existing CMDT rules into it |
| **D1b · Keep `Compliance_Requirement__mdt`** | already wired to the rule engine | **cannot be written at runtime** — upload would have to call Metadata API deploy (slow, async, awkward) |
| **D1c · Hybrid** — CMDT = seeded baseline (design-time), `Compliance_Rule__c` = policy-extracted (runtime); engine unions both | best of both | two sources to merge |
**Recommendation: D1a (or D1c).** A custom object is the only clean way to satisfy "on
upload, store rules" + "on change, update the table" at runtime.

### Decision D2 — where does checklist generation run after the change?
| Option | Notes |
|---|---|
| **D2a · Salesforce-native** — LWC calls `ComplianceRuleEngineService.generateChecklist()` (reads the rule object); engine `/scope` becomes RAG-for-risk-narrative only | most aligned with "AI pulls from the object table"; removes hardcoded maps from app.py entirely |
| **D2b · Engine reads the rules** — SF passes the applicable rules to `/scope`, or the engine queries SF | keeps one checklist brain in the engine; more coupling |
**Recommendation: D2a** — matches your stated flow ("AI pulls the checklist from the
object table"); keeps the rule engine where the rules live.

### Actions (precondition → effect · cost)

| # | Action | Precondition | Effect | Cost |
|---|---|---|---|---|
| B1 | **Decide D1 + D2** (rule store + generation home) | this plan reviewed | architecture fixed | S |
| B2 | **Create `Compliance_Rule__c`** (fields mirror CMDT: Rule_ID, Document_Type, Required_For_Industry/Tier/Region/Criticality, Is_Mandatory, Governing_Body, Effective_From/To, Renewal_Frequency_Days, Severity, **Source_Policy_Document__c** lookup, **Active__c**, **Extracted_Confidence__c**) | B1=D1a/c | runtime-writable rule store | M |
| B3 | **Seed/migrate** existing `Compliance_Requirement__mdt` rows → `Compliance_Rule__c` | B2 | baseline rules in the object | S |
| B4 | **Policy upload UI/entry** — an admin uploads a policy doc (reuse `Compliance_Document__c` + Files, `doc_type='Policy'`) | B2 | policy docs land in SF | S |
| B5 | **Extraction step** — on policy upload, call the engine (`/assess` extended, or a new `/extract-policy`) to pull rule fields (doc types required, industry/tier/region applicability, mandatory, governing body, dates) → structured JSON | B4; engine reachable | extracted rule JSON | L |
| B6 | **Rule upsert (Apex)** — `PolicyRuleIngestService`: map extracted JSON → upsert `Compliance_Rule__c` by Rule_ID; deactivate rules whose policy was superseded | B2,B5 | rule table populated/updated from policy | M |
| B7 | **Repoint checklist generation** — `generateChecklist` (LWC/Apex) reads `Compliance_Rule__c` via the rule engine; **remove** reliance on `app.py` `DOMAIN_TO_DOCUMENT`/`INDUSTRY_DOMAINS` for the doc list (keep engine for risk narrative only, per D2a) | B3 (rules present) | checklist sourced from the table | M |
| B8 | **Change-sync** — on policy doc re-upload/update/delete → re-run B5–B6 (re-extract, upsert, deactivate stale); Audit_Log on every rule change | B6 | rule table stays in sync with docs | M |
| B9 | **Determinism guard** — extraction proposes rules; a human **reviews/approves** before a rule goes Active (HITL — a policy rule change is high-stakes). `Extracted_Confidence__c` low → require review | B6 | governed rule changes | S |
| B10 | **Regression** — checklist for known suppliers (Nordwind/Electronics etc.) still deterministic; eval harness green; before/after checklist diff | B7 | no checklist regression | M |

### Ordered plan (WS-B) with dependencies
```
B1 (decide)
   └─▶ B2 (Compliance_Rule__c) ──▶ B3 (seed) ──▶ B7 (repoint generation) ──▶ B10 (regression)
   └─▶ B4 (policy upload) ──▶ B5 (extract) ──▶ B6 (upsert) ──┬─▶ B8 (change-sync)
                                                             └─▶ B9 (HITL approve)
```
Critical path: **B1 → B2 → B5 → B6 → B7 → B10.** B4/B9 parallelizable.
Cost: **~L total** (B5 extraction + B7 repoint are the hard/risky parts).

---

## Cross-workstream dependency
WS-A's **future-state section should describe WS-B's target** (policy→rule-engine→
checklist). So: draft WS-A current+RAG first, build WS-B, then finalize WS-A future-state
with the rule-engine design as-built. **Doc is not fully "done" until the rule-engine
decision (B1) is made.**

---

## Risk factors (what forces a replan)
- **R1 · CMDT write constraint** → mitigated by D1a (custom object). If stakeholders insist
  on CMDT, fall back to a Metadata-API deploy pipeline (async, slower) — replan B5/B6.
- **R2 · Policy extraction accuracy** — mis-extracted rules = wrong checklists for every
  supplier. Mitigation: **B9 HITL approval gate** is non-negotiable; never auto-activate a
  rule below confidence threshold.
- **R3 · Determinism regression** — moving off the hardcoded maps could change checklists.
  Mitigation: B3 seed reproduces current maps as rules; B10 before/after diff.
- **R4 · Azure/2GP are design-only now** — WS-A future-state must be labelled target, not
  current, or the doc misleads.
- **R5 · Dual checklist sources during cutover** — engine maps AND rule table both live.
  Mitigation: feature-flag; cut over per environment; keep engine risk-narrative separate.

## Fallback
- **WS-B fallback:** if runtime extraction proves unreliable, ship **B2+B3+B7 first**
  (rule table + seed + repoint generation to read it) as a **manually-maintained** rule
  engine — immediate value (checklist from a governed SF table, no hardcoded maps) — and
  add **B5 auto-extraction** as a fast-follow. This delivers "AI pulls checklist from the
  object table" without depending on the hardest step.
- **WS-A fallback:** if Azure/2GP specifics aren't settled, ship the doc with current+RAG
  complete and future-state as an explicitly-marked "target architecture / open decisions"
  appendix.

---

## Assessment checklist (quick tick-list)

**Workstream A — Documentation**
- [ ] A1 outline · [ ] A2 current interaction · [ ] A3 reuse diagrams · [ ] A4 RAG
- [ ] A5 Azure target · [ ] A6 2GP packaging · [ ] A7 repo · [ ] A8 security · [ ] A9 review

**Workstream B — Rule engine**
- [ ] B1 decide D1+D2 · [ ] B2 `Compliance_Rule__c` · [ ] B3 seed from CMDT
- [ ] B4 policy upload · [ ] B5 extraction · [ ] B6 rule upsert · [ ] B7 repoint checklist
- [ ] B8 change-sync · [ ] B9 HITL approval · [ ] B10 regression

**Decisions to lock first:** D1 (rule store = new `Compliance_Rule__c` recommended) ·
D2 (generation = Salesforce-native recommended).

---

## Appendix 1 — Claude/design prompt: current-state system-interaction diagram

Paste this into **Claude (with the design/diagram capability)** to generate the high-level
interaction diagram for the technical-documentation's **current-state** section. It is
grounded in the verified real topology (do not let the model invent components).

> **Prompt:**
>
> Create a clean, high-level **system interaction diagram** for a supplier-compliance
> platform. Show how the pieces talk to each other at runtime. Style: minimal, boxes +
> labelled arrows, grouped into clear zones. Left-to-right or layered top-to-bottom.
>
> **Zones and components (use exactly these — do not add or invent):**
>
> 1. **Salesforce (Experience Cloud + internal app)** — zone box containing:
>    - `scComplianceConsole` (parent shell), and inside it the three consoles
>      `scProcurementConsole`, `scAnalystConsole`, and `scSupplierPortal` (public
>      self-service intake + sub-supplier invite).
>    - `VendorPortalController` (Apex) — the single controller the LWCs call via `@AuraEnabled`.
>    - `Named Credential` (Local_Compliance_Service) — the outbound auth boundary.
>    - Salesforce data: `Account` (supplier, ParentId tier cascade), `Compliance_Assessment__c`
>      (one per required document + AI verdict), `Compliance_Document__c`, `Audit_Log__c`.
>
> 2. **Compliance Engine (FastAPI, Python)** — zone box containing endpoints:
>    `/scope` (risk + checklist), `/assess` (document intelligence), `/verify` (screening),
>    `/cases` (agentic LangGraph case lifecycle), `/copilot` (grounded chat). Inside, note
>    the **LangGraph agent supervisor** (intake → screening → documents → synthesis →
>    routing → decision, with two human gates).
>
> 3. **Data & AI** — zone box: **Postgres + pgvector** (`policy_chunk` = the RAG corpus,
>    384-dim MiniLM embeddings), and an **LLM provider** (OpenAI/Azure/Anthropic, provider-
>    agnostic).
>
> 4. **External registries** — GLEIF, sanctions/watchlist, GDELT adverse media (called by
>    `/verify`).
>
> **Interactions to draw (labelled arrows):**
> - LWC consoles → `VendorPortalController` (Apex @AuraEnabled calls).
> - `VendorPortalController` → `Named Credential` → **FastAPI engine** (HTTPS, Bearer token;
>   today via a VS Code dev tunnel — label it "dev tunnel today / Azure URL in future").
> - Engine `/scope` `/assess` `/copilot` → **pgvector `policy_chunk`** (RAG retrieval) and
>   → **LLM provider** (grounded generation).
> - Engine `/verify` → **External registries**.
> - Engine writes verdicts back → Salesforce `Compliance_Assessment__c` (via the controller /
>   queueable callout pattern).
> - Every state change → `Audit_Log__c` (append-only).
>
> **Callouts to annotate on the diagram:**
> - The **Named Credential** is the trust boundary between Salesforce and the engine.
> - **Determinism note:** risk tier + checklist are computed by deterministic rules; the LLM
>   narrates, the math decides.
> - **HITL note:** two human gates (procurement confirms scope; analyst signs off) — a
>   flagged case never auto-clears.
>
> Keep it a **one-page architecture diagram** an engineer or VP can read in 30 seconds.
> Use a neutral, professional palette; label the Salesforce↔engine arrow as the key
> integration seam.

**Note for the doc:** once generated, this diagram anchors the "Current system interaction"
section (action A2/A2b). The **future-state** variant reuses the same prompt with two edits:
(a) the engine zone moves to **Azure** (Container Apps + Azure DB for PostgreSQL Flexible
Server w/ pgvector + Key Vault), and (b) the Named Credential points at the **Azure URL**
instead of the dev tunnel.
