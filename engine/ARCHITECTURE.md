# Supplier Compliance Engine — Architecture & Ops

The product is a **provider-agnostic compliance engine + a club of agents**, surfaced
through a Salesforce console. It is built to be **adaptable** (any LLM, on-prem),
**reliable** (graceful degradation to a human gate), **secure/governed** (PII
tokenization + injection scanning), and **self-improving** (eval harness + few-shot
feedback loop). **No secrets are bundled** — each deployment supplies its own keys, or
runs a local model that needs none.

## Topology
```
[ Salesforce console (scVendorConsole LWC) ]
        │  Named Credential: callout:Local_Compliance_Service  (bearer INBOUND_TOKEN)
        ▼
[ FastAPI engine (app.py) ]
   /scope  /verify  /assess  /cases  /health  /ready
        │
   ┌────┴───────────────┬───────────────────────┐
[ RAG knowledge base ]  [ Document Intelligence ]  [ Screening / Registry ]
  pgvector + MiniLM       extract → deterministic    GLEIF (live) · OpenSanctions
  (local embeddings)      verify (expiry/coverage)   · registry.py (API|manual)
```

## The club of agents (LangGraph — `orchestrator.py`)
A shared `CaseState` blackboard flows through ordered nodes; each node owns its slice,
`findings`/`audit` accumulate, and a `PostgresSaver` checkpointer survives the human gate.

| Stage | Agent | Role |
|------|-------|------|
| 01 | intake | scope + checklist via `/scope` (policy RAG) |
| 02 | screening | identity (GLEIF) + sanctions (OpenSanctions) + LLM disambiguation |
| 03 | documents | document compliance judgment via `/assess` (governed) |
| 03b | registry | validate cert against issuing body (`registry.py`) |
| 04 | risk | per-domain evidence review |
| 05 | synthesis | **deterministic** weighted score → tier + confidence |
| 06 | routing | tier → approver + SLA (delegation of authority) |

## Document Intelligence (Pillar: deterministic execution)
`/assess` runs **extract → verify**: the LLM only *extracts* structured fields
(issuer, identifier, dates, coverage); hard-coded logic *decides* the critical gates —
expiry (`is_expired`/`days_to_expiry`), minimum coverage (≥ $2M COI), TIN presence.
An expired or under-limit document is force-failed regardless of the model's opinion.

## Registry validation (`registry.py`)
Per document type: sources with a real API are validated **live** (GLEIF for
entity/registration docs); sources without one (IATF, ISO bodies, insurers, tax
authorities) return **`manual_required`** → analyst; an unconfigured source
**auto-routes to the human gate**. Pluggable: set `method='api'` + a validator to add one.

## Governance & reliability
- `governance.py` — every LLM call over external content is PII-tokenized (Presidio),
  injection-scanned, and wrapped in untrusted-content framing. A document that attempts
  prompt-injection can never auto-pass.
- `reliability.py` — `with_retry` on transient errors only; any provider/parse failure
  degrades to **"Needs Analyst"** (never a silent wrong answer).

## Provider-agnostic LLM + deployment (Pillar: adaptability)
`llm.py` exposes one `chat_json()` across `openai | azure | anthropic | ollama | vllm |
local`. Swap providers per deployment via `LLM_PROVIDER` with **no agent change**;
on-prem points at a local OpenAI-compatible server and needs no external key. Progressive
param-drop tolerates models that reject `temperature`/`response_format` (gpt-5/o-series).

**Supplying keys (per deployment):** copy `.env.example` → `.env` and set `INBOUND_TOKEN`,
`DB_URL`, `LLM_PROVIDER`/`LLM_MODEL`, and the provider key (`OPENAI_API_KEY`, etc.).
Optional: `OPENSANCTIONS_API_KEY` for live sanctions (else a demo watchlist). Nothing is
committed; local providers need no key.

## Prompts as SOPs (Pillar: separation of concerns)
Agent instructions live as git-tracked Markdown in `prompts/*.md` (`document_intelligence.md`,
`disambiguation.md`), loaded by `prompts.py`. Edit/version/A-B them without touching code.

## Continuous evaluation + learning loop (Pillar: eval)
- `eval/golden.jsonl` + `eval_harness.py` — regression suite locking the deterministic
  guarantees (verdict, expiry, coverage, registry). **Run after every prompt/code change.**
  Current: **8/8 (100%)**.
- `fewshot/*.jsonl` + `fewshot.py` — analyst overrides (captured by the co-pilot feedback
  block → `Audit_Log__c`) become few-shot examples that calibrate the agent. Grows without
  code changes.

## Ops
```bash
# Run the engine (venv)
./.venv/Scripts/python.exe -m uvicorn app:app --host 127.0.0.1 --port 8000
# or containerized
docker compose up engine

# Regression suite (engine must be running)
./.venv/Scripts/python.exe eval_harness.py

# Health
curl localhost:8000/health     # config summary
curl localhost:8000/ready      # DB connectivity (200/503)
```
Salesforce deploy: `sf project deploy start --source-dir force-app/main/default --target-org <org>`.
