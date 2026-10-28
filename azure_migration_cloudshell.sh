#!/usr/bin/env bash
# Run this in Azure Cloud Shell (shell.azure.com) — Bash environment.
# Already inside Azure's network, so it's covered by the AllowAllAzureServices
# firewall rule on the Postgres server; no firewall changes needed.
set -euo pipefail

RG="AzureML-Dev"
WEBAPP="supplier-compliance-engine"

echo "== Fetching DB_URL from the Web App =="
DB_URL=$(az webapp config appsettings list --resource-group "$RG" --name "$WEBAPP" \
  --query "[?name=='DB_URL'].value" -o tsv)

if [ -z "$DB_URL" ]; then
  echo "DB_URL came back empty — check RG/app name." >&2
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "== psql not found, installing postgresql-client =="
  sudo apt-get update -qq && sudo apt-get install -y -qq postgresql-client
fi

echo "== Step 1: checking embedding column dimension (must be 384) =="
DIM=$(psql "$DB_URL" -tAc "SELECT atttypmod FROM pg_attribute WHERE attrelid = 'policy_chunk'::regclass AND attname = 'embedding';")
echo "atttypmod = $DIM"
if [ "$DIM" != "384" ]; then
  echo "STOP: embedding dimension is not 384 (got '$DIM'). Do NOT run the migration —" >&2
  echo "the table needs to be rebuilt for a 1536-dim model instead. Report this back." >&2
  exit 1
fi
echo "OK — embedding is vector(384), safe to proceed."

echo "== Step 2: running migrate_azure_schema.sql =="
cat > /tmp/migrate_azure_schema.sql <<'SQLEOF'
BEGIN;
CREATE EXTENSION IF NOT EXISTS vector;
ALTER TABLE policy_chunk ADD COLUMN IF NOT EXISTS industry TEXT NOT NULL DEFAULT 'general';
ALTER TABLE policy_chunk ADD COLUMN IF NOT EXISTS is_current BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE policy_chunk ADD COLUMN IF NOT EXISTS content_hash TEXT NOT NULL DEFAULT '';
ALTER TABLE policy_chunk ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE policy_chunk ADD COLUMN IF NOT EXISTS text_tsv tsvector
    GENERATED ALWAYS AS (to_tsvector('english', text)) STORED;
CREATE INDEX IF NOT EXISTS policy_chunk_embedding_idx
    ON policy_chunk USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
CREATE INDEX IF NOT EXISTS policy_chunk_domain_idx   ON policy_chunk (domain);
CREATE INDEX IF NOT EXISTS policy_chunk_industry_idx ON policy_chunk (industry);
CREATE INDEX IF NOT EXISTS policy_chunk_current_idx  ON policy_chunk (source, is_current) WHERE is_current;
CREATE INDEX IF NOT EXISTS policy_chunk_tsv_idx      ON policy_chunk USING gin (text_tsv);
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'policy_chunk'::regclass AND contype = 'u'
    ) THEN
        ALTER TABLE policy_chunk
            ADD CONSTRAINT policy_chunk_source_version_clause_chunk_key
            UNIQUE (source, version, clause_id, chunk_index);
    END IF;
END $$;
COMMIT;
SQLEOF
psql "$DB_URL" -f /tmp/migrate_azure_schema.sql
rm -f /tmp/migrate_azure_schema.sql

echo "== Step 3: verifying columns =="
psql "$DB_URL" -c "\d policy_chunk"

echo "== Step 4: current corpus counts by industry/domain (expect this to be EMPTY per the dev team) =="
psql "$DB_URL" -c "SELECT industry, domain, count(*) FROM policy_chunk WHERE is_current GROUP BY industry, domain;"

INBOUND_TOKEN=$(az webapp config appsettings list --resource-group "$RG" --name "$WEBAPP" \
  --query "[?name=='INBOUND_TOKEN'].value" -o tsv)

echo "== Step 5: verifying /scope now returns 200 =="
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "https://supplier-compliance-engine.azurewebsites.net/scope" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $INBOUND_TOKEN" \
  -d '{"supplierId":"probe","legalName":"Probe Ltd","commodity":"Steel","country":"Germany"}')
echo "HTTP $CODE"
if [ "$CODE" = "200" ]; then
  echo "SUCCESS — /scope is healthy."
else
  echo "Still failing (HTTP $CODE) — investigate before declaring done." >&2
fi

unset DB_URL INBOUND_TOKEN
