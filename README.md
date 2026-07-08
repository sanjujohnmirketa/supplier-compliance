# Supplier Compliance — Veera

AI-powered, agentic supplier compliance automation. A Salesforce Lightning Experience
Cloud console (procurement + analyst personas) backed by a provider-agnostic Python/
FastAPI compliance engine (RAG + LangGraph agent supervisor).

## Structure

```
salesforce/   — the Salesforce project (LWC consoles, Apex, data model) — 2GP package source
engine/       — the FastAPI compliance engine (RAG, LangGraph agent, screening)
docs/         — technical documentation, architecture decisions, diagrams
```

## Quick start

**Engine (local dev):**
```
cd engine
cp .env.example .env      # fill in your own values — never commit .env
docker compose up --build
docker compose exec engine python ingest_local.py   # first run only
```

**Salesforce:**
```
cd salesforce
sf project deploy start --target-org <your-org-alias>
```

## Documentation

Start with [`docs/technical-documentation.md`](docs/technical-documentation.md) for the
current system interaction, the RAG mechanism, and the Azure/2GP future state. See
[`docs/veera-golive-guide.md`](docs/veera-golive-guide.md) for the packaging + go-live
process.

## Security

Never commit `.env`, API keys, or credentials. `engine/.env.example` and the
Salesforce Named Credential are placeholders only — real secrets are injected at
deploy time (local `.env`, or Azure Key Vault in production).
