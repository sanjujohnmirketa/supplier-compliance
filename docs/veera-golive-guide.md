# Veera Supplier Compliance — Go-Live Guide

**Project:** Supplier Compliance Automation ("Veera")
**Package name:** *Veera_SupplierCompliance* (proposed — confirm before packaging)
**Namespace:** *TBD — must be registered once, permanently, before first package version*
**Last updated:** July 2026
**Status:** pre-go-live — engine currently runs on local Docker; this guide documents the
target state after moving the engine to Azure and packaging Salesforce as 2GP.

---

## 1. Architecture Overview

- **Subscriber side:** an installed Salesforce package contains the `scComplianceConsole`
  parent LWC (embedding `scProcurementConsole`, `scAnalystConsole`) plus the public-site
  `scSupplierPortal` LWC, and `VendorPortalController` (Apex). These render **embedded
  UI inside Salesforce** — there is no "Launch Application" tab-out. Every user action
  (generate checklist, run screening, ask the co-pilot) is an `@AuraEnabled` Apex call
  that, in turn, makes an HTTP callout to the compliance engine via a Named Credential.
- **Engine side:** a FastAPI application (the "compliance engine") holds all AI/RAG/
  agentic logic — `/scope`, `/assess`, `/verify`, `/copilot`, `/cases`. It is
  provider-agnostic for the LLM and owns its own Postgres database.
- **Knowledge base + vector store:** the policy/regulation corpus and its embeddings
  (`pgvector`) live **entirely on the engine side**, in Postgres. **Salesforce never
  stores, uploads, or touches policy documents or vectors** — the package ships UI +
  Apex + the Named Credential only. This is the single biggest structural difference
  from a typical "custom app" packaging project: there is a knowledge base and a vector
  database to provision and keep fresh, and that provisioning happens entirely on the
  Azure/engine side, never in the package.

---

## Part A — Compliance Engine (Outside Salesforce)

### 2. GitHub Repository
- Private repo (monorepo), layout:
  ```
  /engine       — FastAPI app, requirements.txt, Dockerfile, schema.sql,
                  policies/, prompts/, fewshot/, eval/, ingest_local.py
  /salesforce   — the 2GP package source (force-app)
  /docs         — this guide + technical documentation + diagrams
  .gitignore    — .env, .venv, __pycache__, node_modules, .sfdx
  ```
- **Never commit `.env`** — `.env.example` (placeholders only) is the committed template.
- Branching: `main` (production), `develop`, `feature/*`, `release/*`, `hotfix/*`.
- CI: build the engine image, run the eval harness (8/8 gate) before any deploy; validate
  the Salesforce package source (`sf project deploy validate`) on PRs touching `/salesforce`.
- **Status today:** repo staging is parked (secrets already scrubbed from a prior pass —
  see `github-repo-prep-parked`); `git init` + first commit are outstanding.

### 3. Container Setup
- **Engine:** Python/FastAPI, `uvicorn`, exposed on port **8000**.
- **Database:** Postgres **with the `pgvector` extension** — this is not optional
  infrastructure, it *is* the knowledge base's storage layer.
- `docker-compose.yml` (local dev) orchestrates engine + db + sftp (legacy, unused by
  `ingest_local.py`). Production target replaces this with **Azure Container Apps**
  (engine) + **Azure Database for PostgreSQL — Flexible Server** (db) — see §5.
- Common commands (local): `docker compose up -d`, `docker compose logs -f engine`,
  `docker compose cp <file> engine:/app/<file>` (fast-iterate without rebuild).

### 4. Environment Files
- `.env.example` is committed (placeholders only); real `.env` is never committed.
- Key variables: `DB_URL`, `INBOUND_TOKEN` (the Bearer token Salesforce presents),
  `EMBED_BACKEND` (local), `LLM_PROVIDER` + provider key
  (`OPENAI_API_KEY`/`ANTHROPIC_API_KEY`/…), `OPENSANCTIONS_API_KEY` (optional),
  `CSL_API_KEY` (optional).
- Production: secrets in **Azure Key Vault**, injected as container env vars at runtime —
  never baked into the image or `docker-compose.yml`.

### 5. Knowledge Base & pgvector — Provisioning (the section a generic go-live guide omits)

This is the part specific to Veera: the engine is useless without a populated, current
vector store, and that has its own go-live steps, separate from "is the container up."

1. **Provision Postgres with `pgvector` enabled.** On Azure: Database for PostgreSQL
   Flexible Server → enable the `vector` extension → run `schema.sql` once (creates
   `policy_chunk`, the `ivfflat` cosine index, and the domain index).
2. **Decide where policy source files live.** Today: baked into the image at
   `./policies` (git-tracked `.md` files). **Recommended for go-live:** move to
   **Azure Blob Storage** (a `policies` container) so a new regulation can be added
   without a container rebuild — `POLICIES_DIR` already supports this pattern
   (`ingest_local.py` reads from any directory; point it at a mounted blob path).
3. **Run the ingest job** (`python ingest_local.py`) — parses each policy file, chunks
   by clause, embeds with `all-MiniLM-L6-v2` (384-dim, local — no external embedding
   API key), and upserts into `policy_chunk`. **Idempotent**: `content_hash` skips
   re-embedding chunks that haven't changed, so re-running after adding *one* new
   regulation only embeds the new content.
4. **Refreshing the knowledge base post-go-live** (no redeploy required): drop the new/
   updated policy file into the Blob container → re-run the ingest job (manually, or on
   a schedule/webhook — not yet automated, flag as a fast-follow) → new clauses are
   immediately retrievable by `/scope`, `/assess`, `/copilot` on the next request.
5. **Health check specific to RAG** (add to whatever "is it healthy" step you run):
   `SELECT count(*) FROM policy_chunk;` should be non-zero, and a test `POST /scope`
   call should return `checklist` items with `justificationClauseId` values — that
   proves retrieval is actually returning grounded clauses, not just that the container
   booted.

### 6. Go-Live Deployment Steps (Engine)
1. Provision the Azure resources: **Container Apps** (or App Service) for the engine,
   **Azure Database for PostgreSQL — Flexible Server** with `pgvector` enabled, **Key
   Vault** for secrets.
2. Run `schema.sql` against the Flexible Server instance.
3. Deploy the engine container; inject env vars from Key Vault.
4. Run the ingest job against the production database (§5, steps 2–3).
5. Verify: `/health`, `/ready`, then the RAG-specific check in §5 step 5.
6. Point the production **Named Credential** at the Azure engine's stable HTTPS URL
   (replacing the local dev tunnel used today).
7. Confirm `INBOUND_TOKEN` in Key Vault matches the token configured in the Salesforce
   **External Credential** principal.

---

## Part B — Salesforce 2GP Package

### 7. Prerequisites and Org Setup
- Two orgs: **Dev Hub** (owns the package) and a **Namespace/Packaging org** (holds the
  registered namespace, if using a managed package — see §9).
- Install Salesforce CLI; authenticate both orgs (`sf org login web`).
- In Dev Hub, enable: **Dev Hub**, **Second-Generation Managed Packages**, **Source
  Tracking**.

### 8. Package Type Decision — Unlocked vs. Managed
Unlike a typical AppExchange ISV package, Veera today is deployed to **one org**
(no external subscribers yet). This changes the calculus from a template like RevARIA's:

| | Unlocked 2GP | Managed 2GP |
|---|---|---|
| Namespace required | No | Yes (permanent, one-time registration) |
| Best for | Single-org / internal deployment, easier iteration | Multi-subscriber-org / AppExchange distribution |
| **Recommendation for Veera today** | **Yes — start here** | Revisit only if/when this ships to other orgs |

**Decision to confirm before §9:** proceed **unlocked, no namespace**, unless there's a
concrete near-term plan to distribute to other Salesforce orgs.

### 9. Namespace Org Setup — *only if Managed (§8) is chosen*
- Set the namespace prefix **once** in the packaging org — this is permanent.
- Register/link the namespace in the Dev Hub (one-time operation).
- *(Skip entirely if proceeding unlocked per §8's recommendation.)*

### 10. Dev Hub Setup
- `sfdx-project.json` defines the package name and version. **Current state (verified):**
  one package directory (`force-app`), no namespace, `sourceApiVersion: 66.0` — already
  ≥ the 66.0 floor a 2GP package needs.
- Target: add `packageDirectories[].package` (the package alias), keep
  `sourceApiVersion` current.

### 11. Authentication — Named Credential + Bearer (not an ECA/OAuth flow)
Veera's engine uses a **static Bearer token**, not per-subscriber OAuth — simpler,
appropriate for a single-org deployment, and already built:
- **`Local_Compliance_Service`** — Named Credential, URL = the engine endpoint (dev
  tunnel today, Azure URL post-migration — update this at go-live, §6 step 6).
- **`Local_Compliance_Auth`** — External Credential, Bearer token principal
  (`INBOUND_TOKEN`, matched on the engine side — §6 step 7).
- **`Local_Compliance_Callout`** — permission set granting callers access to the Named
  Credential.
- All three are **already present in `force-app`** and package normally — no ECA,
  no OAuth callback URL, no Consumer Key/Secret to manage.
- **Forward note (not required now):** if Veera later becomes a multi-subscriber-org
  managed package distributed via AppExchange, revisit an External Client App / OAuth
  flow so each subscriber org can hold its own credential instead of one shared Bearer
  token. Not needed for the current single-org go-live.

### 12. Salesforce CLI Project Configuration
- **`.forceignore`** — not `package.xml` — controls what's excluded from a 2GP package
  version. Review it to ensure the Named/External Credential metadata *is* included
  (they're first-party config, not org-specific secrets — the Bearer token value itself
  lives in the External Credential's principal, set post-install per org, not baked in).
- Confirm the four target components are included: `scComplianceConsole`,
  `scProcurementConsole`, `scAnalystConsole`, `scSupplierPortal`, plus
  `VendorPortalController` and the full compliance data model (`Account` custom fields,
  `Compliance_Assessment__c`, `Compliance_Document__c`, `Document_Extraction__c`,
  `Audit_Log__c`, the three `__mdt` config objects).
- Update the Named Credential URL to the production Azure endpoint **before** creating
  the go-live package version (§14) — an installed package's Named Credential URL is
  easiest to set correctly at source before packaging, not patched post-install.

### 13. Create the 2GP Package (one-time)
```
sf package create --name "Veera Supplier Compliance" \
  --package-type Unlocked --path force-app --target-dev-hub devhub
```
Populates `packageAliases` in `sfdx-project.json`. (Use `--package-type Managed` only if
§8's decision changes.)

### 14. Create Package Version
- `sf package version create` builds a new version (auto-incrementing, e.g. `0.1.0.NEXT`).
- Verify the four LWCs, `VendorPortalController`, and the full data model are included —
  `sf package version list` or a Tooling API query against `Package2VersionCreateRequest`.
- Verify the Named Credential/External Credential/permission set are present (§12).

### 15. Install and Test
- Install into a scratch org or sandbox first.
- Verify: package appears under **Installed Packages**; `scComplianceConsole` renders
  with the persona left-rail; **Generate checklist** returns a real, non-empty checklist
  (proves the Named Credential reaches the Azure engine and `/scope` returns grounded
  clauses — the RAG health check from §5 step 5, exercised end-to-end through Salesforce);
  document upload → AI review populates a structured `Compliance_Assessment__c` summary;
  the analyst console shows the routed queue.
- Post-install, an admin must set the **External Credential's Bearer token** principal
  value (it does not ship with a value — that's org-specific, set after install).

### 16. Promote and Distribute
- Promote to **Released** when ready for production install (irreversible for that
  version). For unlocked packages staying single-org, this may simply mean "install
  directly into the production org" rather than AppExchange listing.
- If distribution to other orgs becomes real later: revisit §8 (managed + namespace),
  §9 (namespace registration), §11 (ECA/OAuth), and AppExchange listing via Partner
  Community.

---

## Reference: Org and Package Details

| Item | Value |
|---|---|
| Dev Hub Alias | *TBD* |
| Package Org Alias | *TBD (only if Managed)* |
| Namespace | *none (Unlocked, recommended) — or TBD if Managed* |
| Package Name | Veera Supplier Compliance |
| Package Type | Unlocked (recommended) |
| Named Credential | `Local_Compliance_Service` |
| External Credential | `Local_Compliance_Auth` |
| Permission Set | `Local_Compliance_Callout` |
| Parent LWC | `scComplianceConsole` |
| Child LWCs | `scProcurementConsole`, `scAnalystConsole`, `scSupplierPortal` |
| Apex Controller | `VendorPortalController` |
| Engine Auth | Static Bearer (`INBOUND_TOKEN`) — no OAuth/ECA |
| API Version | 66.0 |
| Vector DB | pgvector on Azure Database for PostgreSQL — Flexible Server (engine-side, **not packaged**) |
| Embedding Model | `all-MiniLM-L6-v2`, 384-dim, local (no external key) |

---

## Troubleshooting Quick Reference

| Error | Fix |
|---|---|
| `NOT_FOUND` on `sf package create` | Enable Second-Generation Managed Packages in Dev Hub |
| `NoDefaultDevHubError` | Add `--target-dev-hub devhub` to the command |
| Checklist generation returns empty/500 in a fresh install | Named Credential URL not yet updated to Azure endpoint, or External Credential Bearer value not set post-install (§15) |
| `/scope` returns clauses with no `justificationClauseId` / generic-only checklist | `policy_chunk` empty or stale on the target Postgres — re-run the ingest job (§5) against that environment |
| Checklist looks identical across different industries | Dense floor / industry-domain rule regression — see the RAG determinism section of the technical documentation, not a packaging issue |
| "Not available for deploy" errors | Exclude non-packageable metadata types in `.forceignore` |
| Named/External Credential missing after install | Check `.forceignore` didn't exclude them (§12) — unlike an ECA, these should ship *with* the package (values are set post-install, but the shells must be present) |
| Bearer token 401 after go-live | `INBOUND_TOKEN` in Key Vault ≠ the value set in the subscriber org's External Credential principal |

---

## Open decisions to confirm before proceeding
1. **Package name + Unlocked vs. Managed** (§8) — recommend Unlocked, no namespace, for
   the current single-org deployment.
2. **Policy file storage** (§5.2) — recommend migrating from image-baked files to Azure
   Blob Storage so the knowledge base can be refreshed without a rebuild.
3. **Ingest scheduling** — currently manual (`python ingest_local.py`); decide whether
   go-live needs an automated trigger (schedule or webhook on Blob upload) or manual is
   acceptable for v1.

*Document maintained by the Veera Supplier Compliance team.*
