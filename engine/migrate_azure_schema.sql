-- Vendor GRACE engine — bring an existing database up to the current schema.
--
-- Symptom this fixes:
--   /scope and /assess return HTTP 500 while /verify and /health return 200.
--   Engine log / ingest job error:
--     column "industry" of relation "policy_chunk" does not exist
--
-- Cause: the database was created from an older schema.sql. The engine now
-- filters retrieval by industry and fuses dense + sparse (full-text) ranking,
-- and both need columns the old table does not have.
--
-- Safe to run more than once: every statement is IF NOT EXISTS, and nothing
-- here drops or rewrites existing rows.
--
-- Run against the engine's Postgres, e.g.
--   psql "$DB_URL" -f migrate_azure_schema.sql

BEGIN;

-- 0. pgvector must be present before the embedding column can be used.
CREATE EXTENSION IF NOT EXISTS vector;

-- 1. Industry tag — the STRICT retrieval filter.
--    One industry per chunk. Existing rows default to 'general' so they stay
--    retrievable rather than disappearing from every filtered query.
ALTER TABLE policy_chunk
    ADD COLUMN IF NOT EXISTS industry TEXT NOT NULL DEFAULT 'general';

-- 2. Supersede flag — retrieve() only searches is_current = true.
ALTER TABLE policy_chunk
    ADD COLUMN IF NOT EXISTS is_current BOOLEAN NOT NULL DEFAULT true;

-- 3. Re-embedding guard.
ALTER TABLE policy_chunk
    ADD COLUMN IF NOT EXISTS content_hash TEXT NOT NULL DEFAULT '';

-- 4. Creation timestamp.
ALTER TABLE policy_chunk
    ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- 5. Sparse (lexical) column for hybrid search. GENERATED ALWAYS means
--    ingestion never has to maintain it.
ALTER TABLE policy_chunk
    ADD COLUMN IF NOT EXISTS text_tsv tsvector
    GENERATED ALWAYS AS (to_tsvector('english', text)) STORED;

-- 6. Indexes. ivfflat pairs with normalized embeddings under cosine distance.
CREATE INDEX IF NOT EXISTS policy_chunk_embedding_idx
    ON policy_chunk USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

CREATE INDEX IF NOT EXISTS policy_chunk_domain_idx   ON policy_chunk (domain);
CREATE INDEX IF NOT EXISTS policy_chunk_industry_idx ON policy_chunk (industry);
CREATE INDEX IF NOT EXISTS policy_chunk_current_idx  ON policy_chunk (source, is_current) WHERE is_current;
CREATE INDEX IF NOT EXISTS policy_chunk_tsv_idx      ON policy_chunk USING gin (text_tsv);

-- 7. Uniqueness that ingestion's upsert depends on. Added only if some
--    equivalent constraint is not already present.
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

-- Verification — every column below should be listed after the migration.
--   \d policy_chunk
-- or:
--   SELECT column_name, data_type
--   FROM information_schema.columns
--   WHERE table_name = 'policy_chunk'
--   ORDER BY ordinal_position;
--
-- Expected: id, source, version, clause_id, domain, industry, chunk_index,
--           text, content_hash, embedding, is_current, created_at, text_tsv
--
-- Then confirm the engine recovers:
--   curl -s -o /dev/null -w '%{http_code}\n' -X POST "$ENGINE/scope" \
--     -H 'Content-Type: application/json' -H "Authorization: Bearer $INBOUND_TOKEN" \
--     -d '{"supplierId":"x","legalName":"Probe","commodity":"Steel","country":"Germany"}'
-- Expect 200, not 500.
--
-- NOTE: the embedding column must be vector(384) to match the engine's local
-- all-MiniLM-L6-v2 model. If this database was built for a 1536-dim model, the
-- dimension cannot be altered in place — the corpus has to be re-ingested into
-- a correctly typed column.
