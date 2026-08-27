-- Runs automatically on first container start (see docker-compose.yml).
 
-- 1. Turn on the vector type.
CREATE EXTENSION IF NOT EXISTS vector;
 
-- 2. The policy corpus, one row per chunk of a policy/regulatory document.
--    embedding dimension MUST match your embedding model:
--      Azure OpenAI text-embedding-3-small -> 1536   (default below)
--      local sentence-transformers all-MiniLM-L6-v2 -> 384  (change vector(1536) -> vector(384))
CREATE TABLE IF NOT EXISTS policy_chunk (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source       TEXT        NOT NULL,          -- file name the chunk came from
    version      TEXT        NOT NULL,          -- semantic corpus version, e.g. v1.0, v1.1, v2.0
    clause_id    TEXT        NOT NULL,          -- heading / clause ref for provenance
    domain       TEXT        NOT NULL,          -- finance | quality | material | conflict | cyber | trade | general
    industry     TEXT        NOT NULL DEFAULT 'general',  -- automotive | healthcare | ... — STRICT retrieval filter,
                                                 -- one industry per chunk; every industry keeps its own copy of
                                                 -- generic domains (finance/general) rather than sharing chunks.
    chunk_index  INT         NOT NULL,          -- order within the file
    text         TEXT        NOT NULL,
    content_hash TEXT        NOT NULL,          -- to skip re-embedding unchanged chunks
    embedding    vector(384),         -- local all-MiniLM-L6-v2 = 384 dims
    is_current   BOOLEAN     NOT NULL DEFAULT true,  -- false once superseded by a newer version of the same source;
                                                       -- retrieve() only searches is_current = true rows
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (source, version, clause_id, chunk_index)
);

-- 3. Approximate-nearest-neighbour index for fast retrieval.
--    cosine distance (<=>) pairs with normalized embeddings.
CREATE INDEX IF NOT EXISTS policy_chunk_embedding_idx
    ON policy_chunk USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- Helpful filters for retrieval-by-domain / retrieval-by-industry.
CREATE INDEX IF NOT EXISTS policy_chunk_domain_idx ON policy_chunk (domain);
CREATE INDEX IF NOT EXISTS policy_chunk_industry_idx ON policy_chunk (industry);
CREATE INDEX IF NOT EXISTS policy_chunk_current_idx ON policy_chunk (source, is_current) WHERE is_current;

-- 4. Sparse (lexical / BM25-style) retrieval column for HYBRID SEARCH.
--    Dense vectors blur exact tokens ("ISO 27001", "OFAC", a TIN); full-text
--    search nails them. We keep a generated tsvector of the chunk text and fuse
--    the two rankings (RRF) at query time. GENERATED ALWAYS = auto-maintained,
--    so ingestion needs no extra work.
ALTER TABLE policy_chunk
    ADD COLUMN IF NOT EXISTS text_tsv tsvector
    GENERATED ALWAYS AS (to_tsvector('english', text)) STORED;

CREATE INDEX IF NOT EXISTS policy_chunk_tsv_idx
    ON policy_chunk USING gin (text_tsv);