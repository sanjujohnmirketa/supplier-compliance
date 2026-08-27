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
    # Clinical/genetic testing lab — split fine-grained (one domain per document
    # type) rather than one combined "clinical_lab" bucket, so build_checklist()
    # naturally emits one checklist row per domain: CLIA cert, CAP accreditation,
    # CAP scope match, proficiency testing, and lab personnel are five genuinely
    # different documents a lab submits, not five facets of one document.
    "clinical_lab_cert": ["clia", "clia certificate", "clia number",
                           "clinical laboratory improvement amendments"],
    "clinical_lab_accred": ["cap accreditation", "college of american pathologists",
                             "cap number", "cap laboratory accreditation"],
    "clinical_lab_scope": ["accredited scope", "scope of accreditation",
                            "discipline-specific checklist", "accreditation checklist"],
    "clinical_lab_pt": ["proficiency testing", "pt event", "pt provider",
                         "capa", "corrective action plan", "unsatisfactory"],
    "clinical_lab_person": ["laboratory director", "competency assessment",
                             "six-element competency", "clia personnel category"],
    # Compounding pharmacy / IV therapy — one domain covers USP <795>/<797>/<800>
    # plus DEA, since these are near-always assessed together off the same
    # compounding-pharmacy license file, unlike the lab domains above.
    "pharmacy_compound": ["usp <795>", "usp <797>", "usp <800>", "usp 795", "usp 797",
                           "usp 800", "compounding", "sterile preparation",
                           "503a", "503b", "hazardous drug", "dea registration",
                           "controlled substance"],
    "supplement_gmp": ["21 cfr 111", "21 cfr part 111", "dietary supplement",
                        "nsf gmp", "nsf/ansi 173", "supplement", "vitamin manufacturer"],
    # Medical device / diagnostics QMS (H1). Collision risk: "capa",
    # "nonconformance", "internal audit" also appear in the lab and supplement
    # domains above — deliberately anchored on ISO 13485/21 CFR 820/510(k)/UDI
    # instead of generic QMS language so a device doc doesn't get misfiled as
    # clinical_lab_pt or supplement_gmp just because it also mentions CAPA.
    "device_diagnostics_qms": ["iso 13485", "21 cfr 820", "qmsr", "510(k)", "510k",
                                "premarket approval", "pma", "unique device identification",
                                "udi", "gudid", "notified body", "ce marking",
                                "design history file", "mdr reportable event",
                                "eu mdr 2017/745"],
    # Health IT / digital health (H2). Deliberately split from "cyber" — a
    # plain signed BAA belongs in cyber; a SOC2/HITRUST report or subprocessor
    # disclosure is a materially different, heavier evidentiary bar. "baa" is
    # intentionally NOT a keyword here so a bare BAA doesn't get pulled out of
    # the cyber domain by mistake.
    "health_it_digital": ["soc 2 type ii", "soc 2 type 2", "hitrust", "hitrust csf",
                           "bridge letter", "subprocessor", "sub-processor",
                           "trust services criteria", "penetration test",
                           "onc certified health it", "information blocking",
                           "hl7", "fhir", "tefca"],
    # Credentialing & exclusion screening (H3) — centered on verifying PEOPLE
    # (licensed practitioners, counselors), distinct from every other domain
    # here which verifies a FACILITY or PRODUCT.
    "provider_credentialing": ["oig leie", "list of excluded individuals",
                                "sam.gov exclusion", "npdb",
                                "national practitioner data bank",
                                "primary source verification", "malpractice",
                                "board certification", "privileging",
                                "sanction screening", "health care staffing"],
    # Payer / delegated-entity oversight (H4) — CMS FDR + NCQA delegation,
    # distinct from provider_credentialing: this is about a PLAN overseeing a
    # DELEGATED ENTITY's compliance program, not verifying an individual.
    "payer_delegation": ["first tier, downstream", "first tier downstream",
                          "fdr", "medicare advantage", "part d sponsor",
                          "fwa training", "fraud, waste and abuse",
                          "delegation agreement", "pre-delegation audit",
                          "ncqa delegation", "medicare compliance program"],
    # Behavioral health / SUD confidentiality (H5) — 42 CFR Part 2 imposes a
    # stricter, legally distinct instrument (QSOA) from a standard BAA;
    # "42 cfr part 2" and "redisclosure" weighted so this wins over cyber on
    # a Part 2 vendor contract that also mentions PHI/BAA-adjacent language.
    "behavioral_health_part2": ["42 cfr part 2", "qsoa",
                                 "qualified service organization agreement",
                                 "substance use disorder records",
                                 "prohibition on redisclosure",
                                 "patient identifying information", "samhsa",
                                 "carf accreditation", "part 2 program"],
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
    """Turn raw file bytes into plain text, based on file extension.
    Raises ValueError (not a silent "") for anything this can't parse, so a
    caller never mistakes "wrong format" for "empty document"."""
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

    if ext in ("xlsx", "xlsm"):
        return _parse_excel(data)

    raise ValueError(f"Unsupported file type '.{ext}' — supported formats: .txt, .md, .pdf, .docx, .xlsx")


def _parse_excel(data):
    """Render every sheet as readable 'Header: value' rows, not a flat cell
    dump. A chemical-composition/threshold-limits sheet only means anything
    with its column headers attached to each value (e.g. "Substance: Lead" /
    "Threshold (ppm): 100" / "Result: 42" on the same row) — flattening all
    cells into one blob would strip exactly the structure that gives a
    threshold number its meaning, for both guess_domain()'s keyword scoring
    and the LLM's later field extraction."""
    import openpyxl
    wb = openpyxl.load_workbook(io.BytesIO(data), data_only=True, read_only=True)

    sheet_parts = []
    for ws in wb.worksheets:
        rows = list(ws.iter_rows(values_only=True))
        if not rows:
            continue
        header = [str(c).strip() if c is not None else "" for c in rows[0]]
        lines = [f"## Sheet: {ws.title}"]
        for row in rows[1:]:
            if all(c is None or str(c).strip() == "" for c in row):
                continue
            pairs = []
            for col_name, val in zip(header, row):
                if val is None or str(val).strip() == "":
                    continue
                label = col_name if col_name else "Value"
                pairs.append(f"{label}: {val}")
            if pairs:
                lines.append(" | ".join(pairs))
        if len(lines) > 1:
            sheet_parts.append("\n".join(lines))
    wb.close()
    return "\n\n".join(sheet_parts)


POLICY_CHUNK_UPSERT_SQL = """
INSERT INTO policy_chunk
    (source, version, clause_id, domain, industry, chunk_index, text, content_hash, embedding, is_current)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s::vector, true)
ON CONFLICT (source, version, clause_id, chunk_index)
DO UPDATE SET
    text         = EXCLUDED.text,
    domain       = EXCLUDED.domain,
    industry     = EXCLUDED.industry,
    content_hash = EXCLUDED.content_hash,
    embedding    = EXCLUDED.embedding,
    is_current   = true;
"""

# Retired: a re-ingest of the same source file must supersede whatever version(s)
# already exist for it, otherwise every re-upload leaves the OLD version's chunks
# sitting in the index as equally-eligible search candidates forever (this was a
# real, confirmed bug — the same 7 automotive files had accumulated 4-5 stale
# duplicate versions each with no way for retrieve() to prefer the latest one).
POLICY_CHUNK_RETIRE_OLD_VERSIONS_SQL = """
UPDATE policy_chunk SET is_current = false
WHERE source = %s AND version <> %s AND is_current = true;
"""

POLICY_CHUNK_LATEST_VERSION_SQL = """
SELECT version FROM policy_chunk WHERE source = %s ORDER BY created_at DESC LIMIT 1;
"""


def next_semantic_version(current_version, content_changed):
    """v1.0 -> v1.1 (content-only re-upload) or v1.0 -> v2.0 (domain/category
    change signaled by the caller). No prior version -> v1.0.

    content_changed=True bumps the MINOR version (same document, refreshed
    text). Domain/category reassignment is a MAJOR bump — callers that know
    the domain changed should pass content_changed=False and handle the major
    bump themselves if that distinction matters later; today every re-ingest
    via the standard paths is a minor bump, which matches how a customer
    actually uses this (re-upload a refreshed policy PDF), not a full domain
    remap (which would go through delete + fresh upload instead).
    """
    if not current_version or not re.match(r"^v\d+\.\d+$", current_version):
        return "v1.0"
    major, minor = current_version.lstrip("v").split(".")
    if content_changed:
        return f"v{major}.{int(minor) + 1}"
    return f"v{int(major) + 1}.0"


class ImplausiblePolicyDocument(ValueError):
    """Raised when check_policy_plausibility() rejects a document before it
    ever reaches the corpus — distinct from a plain ValueError (unparseable
    file) so callers can tell "wrong format" apart from "not policy content"
    if they want to handle them differently."""
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def check_policy_plausibility(name: str, text: str):
    """Coarse LLM gate: does this text plausibly belong in a compliance policy
    corpus at all? Confirmed live (2026-08-13) that /policy/ingest had NO
    content check whatsoever — a grocery list + recipe was accepted, chunked,
    embedded, and became permanently retrievable as real "policy" for every
    future /scope and /assess call. Unlike a bad SUPPLIER document (one wrong
    checklist row for one supplier, and the LLM judge already refuses to be
    fooled there — see judge_compliance), a bad POLICY document corrupts the
    ground truth every future assessment in that industry is checked against.

    Runs BEFORE chunk/embed/DB work — no point spending that cost on
    something about to be rejected. Uses the same governed_judge() chokepoint
    as every other LLM call over untrusted content (PII tokenization,
    injection scanning, fail-safe framing) so a malicious upload can't talk
    its way past this gate either.

    Fails OPEN (returns None, meaning "skip the gate") when no LLM is
    configured, rather than blocking every ingest on a missing API key — this
    is a quality gate, not the only line of defense (file-type/size/page
    limits still apply either way).

    Raises ImplausiblePolicyDocument if the LLM confidently rejects it.
    Silently returns None (accept) if plausible, unconfigured, or on any
    LLM/parse error — a transient failure here should never block a
    legitimate upload."""
    import llm
    if not llm.is_configured():
        return None

    import governance
    import prompts
    try:
        system = prompts.load("policy_plausibility")
        task = f"FILENAME: {name}\n\nJudge whether the TEXT below belongs in a compliance policy corpus."
        result = governance.governed_judge(system, task, text[:4000])
    except Exception:
        return None  # never let a plausibility-check failure block a real upload

    data = result["data"]
    plausible = data.get("plausible")
    reason = (data.get("reason") or "").strip()
    try:
        confidence = int(data.get("confidence", 0))
    except (TypeError, ValueError):
        confidence = 0

    # Only reject on a CONFIDENT, explicit "false" — an ambiguous or
    # low-confidence call defers to the human uploader, matching the prompt's
    # own "when unsure, lean ACCEPT" instruction with a second guard here.
    if plausible is False and confidence >= 60:
        raise ImplausiblePolicyDocument(
            reason or "This does not appear to be compliance/policy content.")
    return None


def ingest_policy_document(name, data, industry="general", domain_override=None, version=None):
    """Parse, chunk, embed, and upsert one policy document into policy_chunk.

    Shared by the SFTP bulk script and the single-file HTTP endpoint so a
    policy uploaded through Salesforce is indistinguishable, once ingested,
    from one ingested via the older SFTP path.

    version: pass an explicit version (e.g. for a one-time backfill/migration);
    normally left None so this function computes the next semantic version
    itself (v1.0 on first ingest, v1.1 on every re-upload of the same source
    file thereafter) and retires the previous version's rows so retrieve()
    never has more than one current version of any document to search.

    Returns {"domain": ..., "chunkCount": ..., "version": ..., "industry": ...}
    or raises ValueError if the file has no extractable text, or
    ImplausiblePolicyDocument if the content doesn't belong in a policy corpus.
    """
    text = parse_file(name, data)
    if not text.strip():
        raise ValueError(f"No extractable text in '{name}' (unsupported or empty file)")

    check_policy_plausibility(name, text)

    chunks = chunk_text(text)
    domain = domain_override or guess_domain(text)
    embeddings = embed_texts(chunks)

    conn = get_conn()
    cur = conn.cursor()

    if version is None:
        cur.execute(POLICY_CHUNK_LATEST_VERSION_SQL, (name,))
        row = cur.fetchone()
        version = next_semantic_version(row[0] if row else None, content_changed=True)

    for i, (chunk, emb) in enumerate(zip(chunks, embeddings)):
        cur.execute(POLICY_CHUNK_UPSERT_SQL, (
            name, version, f"{name}#chunk{i}", domain, industry, i,
            chunk, content_hash(chunk), to_pgvector(emb),
        ))
    cur.execute(POLICY_CHUNK_RETIRE_OLD_VERSIONS_SQL, (name, version))
    conn.commit()
    cur.close()
    conn.close()

    return {"domain": domain, "chunkCount": len(chunks), "version": version, "industry": industry}
