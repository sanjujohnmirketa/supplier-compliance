# Supplier Compliance Engine — Azure Deployment (as deployed 2026-07-21)

Compute path: **Azure App Service for Containers**, on a **new, dedicated Linux
App Service Plan** (not the shared `MirketaAI` plan, and not Azure Container
Instances — both were considered and superseded; see history below for why).

## What's live right now

| Resource | Name | SKU | Notes |
|---|---|---|---|
| Resource group | `AzureML-Dev` | — | reused, consistent with the rest of the Mirketa AI stack |
| Container registry | `mirketamldevcontainerregistry.azurecr.io` | Standard | reused (already shared across the team) |
| Postgres Flexible Server | `supplier-compliance-db` | Burstable B1ms, 32GB, `vector` extension | admin user `complianceadmin` — password given at creation time, not stored in this repo |
| Database | `compliance` | — | schema applied from `engine/schema.sql`; 77 policy chunks ingested across 10 files |
| App Service Plan | `supplier-compliance-plan` | **B1** (1 vCPU / 1.75GB), Linux | dedicated — not shared with the other 9 apps on `MirketaAI` |
| Web App | `supplier-compliance-engine` | Docker container from the ACR above | `https://supplier-compliance-engine.azurewebsites.net` |

**Verified working end-to-end:** `/health`, `/ready` (confirms live DB
connectivity), and `/scope` (returned a grounded checklist citing real ingested
clauses, e.g. `std_conflict_minerals_responsible_sourcing.md#chunk1`, with
correct industry-based domain selection and risk tiering).

## Image optimization (found during this deployment)

The first build was **6.38GB** — `docker history` showed the `pip install`
layer alone at 5.72GB, of which `nvidia/*` CUDA libraries (2.7GB), `torch`
(1.2GB) and `triton` (691MB) accounted for ~4.6GB. This is the default PyPI
`torch` wheel, which bundles full CUDA support that is **never used** — this
service only ever runs on CPU (App Service, ACI, and local Docker all lack a
GPU). Fixed in `requirements.txt` by pointing `torch` at PyTorch's CPU-only
wheel index:
```
--index-url https://download.pytorch.org/whl/cpu
--extra-index-url https://pypi.org/simple
torch
```
Result: **2.38GB** (~63% smaller), verified functionally identical (offline
model loading, non-root user, `torch.cuda.is_available() == False` as
expected) before pushing.

## Known limitations of this configuration

- **B1 plan (1 vCPU / 1.75GB)** was chosen for lowest cost over B2, accepting
  the memory-headroom risk for this stack (torch + spaCy + sentence-transformers
  + presidio). First real request after a deploy/restart took **several
  minutes** (image pull + model load + Postgres burst-credit ramp-up on the
  also-B1ms database) — steady-state requests after that were ~5 seconds.
  **Watch memory/CPU metrics after go-live**; resize to B2 if you see OOM
  restarts or sustained high memory (`az appservice plan update --sku B2
  --name supplier-compliance-plan --resource-group AzureML-Dev` — no data
  loss, the Web App doesn't need to be recreated).
- **`OPENAI_API_KEY` is currently blank** — `/assess` and `/copilot` will
  return `"Needs Analyst"` / a degraded response until a real key is set:
  ```bash
  az webapp config appsettings set --resource-group AzureML-Dev \
    --name supplier-compliance-engine --settings OPENAI_API_KEY='sk-...'
  ```
  No redeploy needed; the app restarts automatically when settings change.
- **Postgres firewall currently allows `0.0.0.0` (all Azure services) plus the
  deploying machine's IP** — fine for now since App Service (Basic tier)
  doesn't have a fixed outbound IP to lock down to. Revisit if this needs
  tightening later (e.g. VNET integration + private endpoint).

## Decision history (why App Service, not ACI or the shared plan)

1. Considered reusing the existing `MirketaAI` plan (free marginal compute
   cost) — rejected in favor of isolation: that plan already runs 9 other
   apps at ~57% memory on a single instance, and this stack's memory profile
   was an unknown risk to introduce there.
2. Considered Azure Container Instances — worked through a full ACI + `caddy`
   sidecar design (for free TLS, since ACI has no built-in managed HTTPS), but
   pivoted back to a **new, dedicated App Service Plan** instead: same
   isolation benefit as ACI, but with managed HTTPS, health-check-driven
   restarts, and `alwaysOn` included for free — advantages ACI doesn't have.

## Redeploying after a code change

```bash
az acr login --name mirketamldevcontainerregistry
docker build -t mirketamldevcontainerregistry.azurecr.io/supplier-compliance-engine:latest engine/
docker push mirketamldevcontainerregistry.azurecr.io/supplier-compliance-engine:latest
az webapp restart --resource-group AzureML-Dev --name supplier-compliance-engine
```

**If this change touched `schema.sql`, also apply it to the live database.**
`schema.sql` only runs automatically via `docker-entrypoint-initdb.d` for a
*local* `docker compose up` against an empty data directory — the Azure
Postgres Flexible Server is never touched by a container restart, so any
schema change (new column, index, constraint) has to be applied by hand or it
silently drifts (this is exactly how the DB ended up missing `industry` /
`is_current` / `content_hash` / `text_tsv`, fixed by
`engine/migrate_azure_schema.sql`). From Azure Cloud Shell (inside the
`AllowAllAzureServices` firewall rule, so no firewall changes needed):

```bash
DB_URL=$(az webapp config appsettings list --resource-group AzureML-Dev \
  --name supplier-compliance-engine --query "[?name=='DB_URL'].value" -o tsv)
psql "$DB_URL" -f engine/schema.sql   # every statement must stay IF NOT EXISTS / ADD COLUMN IF NOT EXISTS
```

If a change adds a column to an *existing* table, add an `ALTER TABLE ...
ADD COLUMN IF NOT EXISTS ...` for it directly in `schema.sql` (not just the
inline `CREATE TABLE` definition, which is a no-op once the table exists) so
this one command stays sufficient going forward.

## Point Salesforce at it

- Named Credential target URL: `https://supplier-compliance-engine.azurewebsites.net`
- External Credential principal: Bearer token = the `INBOUND_TOKEN` app setting.

---

## App variables reference

### Required
| Variable | Status |
|---|---|
| `INBOUND_TOKEN` | ✅ set |
| `DB_URL` | ✅ set — points at `supplier-compliance-db.postgres.database.azure.com` |

### LLM provider
| Variable | Status |
|---|---|
| `LLM_PROVIDER` | ✅ `openai` |
| `LLM_MODEL` | ✅ `gpt-4o` |
| `LLM_TEMPERATURE` / `LLM_TIMEOUT` | ✅ `0` / `45` |
| `OPENAI_API_KEY` | ⚠️ **blank — add before relying on `/assess` or `/copilot`** |

### Optional (safe to leave blank)
| Variable | Effect if blank |
|---|---|
| `OPENSANCTIONS_API_KEY` | falls back to the free keyless tier |
| `CSL_API_KEY` | not set — Trade.gov CSL check degrades to manual |

### Not needed for this deployment
`SFTP_*`, `POLICIES_DIR` — only used by the legacy `ingest_policies.py` SFTP
path; this deployment uses `ingest_local.py` against the policies baked into
the image.
