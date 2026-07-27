"""
common.py — shared helpers used by both ingest_policies.py and app.py.

Keeps the two scripts consistent: same DB connection, same embedding model,
same chunking + domain logic. Import from here instead of duplicating code.
"""
import io
import os
import re
import hashlib
import psycopg2
from dotenv import load_dotenv

load_dotenv()  # reads the .env file into environment variables

DB_URL = os.environ["DB_URL"]
EMBED_BACKEND = os.getenv("EMBED_BACKEND", "local")

# ---------------------------------------------------------------------------
# Embeddings
# ---------------------------------------------------------------------------
# We load the sentence-transformers model lazily (only when first needed) so the
# import is fast and uvicorn --reload doesn't pay the cost on every file change.
_model = None


def get_model():
    global _model
    if _model is None:
        from sentence_transformers import SentenceTransformer
        # all-MiniLM-L6-v2 -> 384-dimensional vectors. Must match vector(384) in schema.sql.
        _model = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")
    return _model


def embed_texts(texts):
    """Return a list of 384-float vectors, one per input string. Normalized for cosine."""
    model = get_model()
    vectors = model.encode(list(texts), normalize_embeddings=True)
    return [v.tolist() for v in vectors]


def embed_text(text):
    return embed_texts([text])[0]


def to_pgvector(vec):
    """Turn a python list of floats into the literal pgvector expects: '[0.1,0.2,...]'."""
    return "[" + ",".join(str(x) for x in vec) + "]"


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
def get_conn():
    return psycopg2.connect(DB_URL)


# ---------------------------------------------------------------------------
# Text utilities
# ---------------------------------------------------------------------------
def content_hash(text):
    """Stable hash of a chunk so we can skip re-embedding unchanged content later."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# Very simple keyword -> domain classifier. Good enough for retrieval filtering.
DOMAIN_KEYWORDS = {
    "conflict": ["conflict mineral", "3tg", "tin", "tantalum", "tungsten", "gold",
                 "cobalt", "drc", "congo", "smelter", "due diligence", "oecd"],
    "trade": ["sanction", "ofac", "export", "import", "customs", "tariff",
              "embargo", "denied party", "hs code"],
    "finance": ["payment", "invoice", "credit", "financial", "tax", "vat",
                "anti-money", "kyc", "beneficial owner"],
    "quality": ["iso 9001", "quality", "defect", "inspection", "calibration",
                "audit", "certificate of analysis"],
    "material": ["reach", "rohs", "sds", "msds", "hazard", "chemical",
                 "substance", "material safety"],
    "cyber": ["cyber", "iso 27001", "data protection", "gdpr", "security",
              "breach", "encryption"],
}


def guess_domain(text):
    """Pick the domain whose keywords appear most often. Falls back to 'general'.

    Uses whole-word matching so short keywords like 'tin' or 'gold' don't match
    inside unrelated words ('routing', 'testing', 'continuity').
    """
    lower = text.lower()
    best, best_score = "general", 0
    for domain, words in DOMAIN_KEYWORDS.items():
        score = sum(len(re.findall(r"\b" + re.escape(w) + r"\b", lower)) for w in words)
        if score > best_score:
            best, best_score = domain, score
    return best


def chunk_text(text, max_chars=1000, overlap=150):
    """
    Split a document into overlapping chunks of ~max_chars.
    Overlap keeps a clause from being cut in half across two chunks, which would
    hurt retrieval. Splits on paragraph boundaries where possible.
    """
    text = text.replace("\r\n", "\n").strip()
    paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]

    chunks, current = [], ""
    for para in paragraphs:
        if len(current) + len(para) + 2 <= max_chars:
            current = (current + "\n\n" + para).strip()
        else:
            if current:
                chunks.append(current)
            # carry the tail of the previous chunk forward as overlap
            tail = current[-overlap:] if current else ""
            current = (tail + "\n\n" + para).strip()
            # a single huge paragraph: hard-split it
            while len(current) > max_chars:
                chunks.append(current[:max_chars])
                current = current[max_chars - overlap:]
    if current:
        chunks.append(current)
    return chunks


# ---------------------------------------------------------------------------
# Policy file parsing + ingestion — shared by ingest_policies.py (SFTP bulk
# pull) and app.py's /policy/ingest (single-file HTTP upload from Salesforce)
# so both paths chunk/embed/store identically.
# ---------------------------------------------------------------------------
def parse_file(name, data):
    """Turn raw file bytes into plain text, based on file extension."""
    ext = name.lower().rsplit(".", 1)[-1] if "." in name else ""

    if ext in ("txt", "md"):
        return data.decode("utf-8", errors="ignore")

    if ext == "pdf":
        import pdfplumber
        text_parts = []
        with pdfplumber.open(io.BytesIO(data)) as pdf:
            for page in pdf.pages:
                text_parts.append(page.extract_text() or "")
        return "\n\n".join(text_parts)

    if ext == "docx":
        import docx
        document = docx.Document(io.BytesIO(data))
        return "\n\n".join(p.text for p in document.paragraphs)

    return ""


POLICY_CHUNK_UPSERT_SQL = """
INSERT INTO policy_chunk
    (source, version, clause_id, domain, chunk_index, text, content_hash, embedding)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s::vector)
ON CONFLICT (source, version, clause_id, chunk_index)
DO UPDATE SET
    text         = EXCLUDED.text,
    domain       = EXCLUDED.domain,
    content_hash = EXCLUDED.content_hash,
    embedding    = EXCLUDED.embedding;
"""


def ingest_policy_document(name, data, version, domain_override=None):
    """Parse, chunk, embed, and upsert one policy document into policy_chunk.

    Shared by the SFTP bulk script and the single-file HTTP endpoint so a
    policy uploaded through Salesforce is indistinguishable, once ingested,
    from one ingested via the older SFTP path.

    Returns {"domain": ..., "chunkCount": ..., "version": ...} or raises
    ValueError if the file has no extractable text.
    """
    text = parse_file(name, data)
    if not text.strip():
        raise ValueError(f"No extractable text in '{name}' (unsupported or empty file)")

    chunks = chunk_text(text)
    domain = domain_override or guess_domain(text)
    embeddings = embed_texts(chunks)

    conn = get_conn()
    cur = conn.cursor()
    for i, (chunk, emb) in enumerate(zip(chunks, embeddings)):
        cur.execute(POLICY_CHUNK_UPSERT_SQL, (
            name, version, f"{name}#chunk{i}", domain, i,
            chunk, content_hash(chunk), to_pgvector(emb),
        ))
    conn.commit()
    cur.close()
    conn.close()

    return {"domain": domain, "chunkCount": len(chunks), "version": version}
