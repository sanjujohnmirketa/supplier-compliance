"""
app.py — the local compliance service Salesforce calls.

POST /scope         -> RAG retrieval over policy_chunk -> {riskTier, riskSummary, checklist[]}
POST /policy/ingest -> parse/chunk/embed/upsert an uploaded company policy doc into policy_chunk
POST /extract       -> (stub) pull structured fields out of an uploaded document

Run:  uvicorn app:app --reload --port 8000
"""
import os
import io
import json
import base64
import threading
import time
import uuid
from typing import List, Optional

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from dotenv import load_dotenv

from common import get_conn, embed_text, to_pgvector, guess_domain, ingest_policy_document
from config import settings
import llm

# All configuration (secrets, DB, LLM provider) is centralized in config.py and
# validated at import. The LLM is provider-agnostic via llm.py — /assess abstains
# ("Needs Analyst") when the active provider isn't configured, rather than failing.
INBOUND_TOKEN = settings.INBOUND_TOKEN

app = FastAPI(title="Supplier Compliance Service")


@app.on_event("startup")
def _prewarm_models():
    """Load the local models (embedder + PII NER) at boot so the FIRST request
    isn't penalised by a 10-20s lazy load. Failures are non-fatal."""
    try:
        from common import get_model
        get_model().encode(["warmup"])
    except Exception as e:  # pragma: no cover
        print(f"[startup] embedder pre-warm skipped: {e}")
    try:
        import pii
        pii.tokenize_pii("warmup")
    except Exception as e:  # pragma: no cover
        print(f"[startup] PII pre-warm skipped: {e}")


# ---------------------------------------------------------------------------
# Request/response shapes
# ---------------------------------------------------------------------------
class ScopeRequest(BaseModel):
    supplierId: str
    legalName: str
    country: Optional[str] = None
    commodity: Optional[str] = None
    jurisdictions: List[str] = []
    # Optional — sharpen domain selection beyond what industry/engagement text
    # alone implies (e.g. an "Electronics" supplier whose actual raw material is
    # conflict-mineral-bearing metal vs. one that only assembles plastics).
    # Additive: when blank, behavior is identical to before these fields existed.
    materialType: Optional[str] = None
    serviceCategory: Optional[str] = None
    # Domains resolved Salesforce-side from Material_Type__mdt (the admin-
    # configurable catalog — see MaterialTypeController.cls). When the caller
    # sends this, it's used directly and MATERIAL_TYPE_DOMAINS/
    # SERVICE_CATEGORY_DOMAINS below are NOT consulted — so a new material for
    # any industry, added only as a Salesforce Custom Metadata record, takes
    # effect with no engine deploy. Falls back to the hardcoded dicts only for
    # callers that don't send this (e.g. local testing without Salesforce).
    materialDomains: List[str] = []
    # Clean industry key (e.g. "automotive", "healthcare") — used to STRICTLY
    # filter which corpus retrieve() searches, once more than one industry's
    # policy documents are loaded. Distinct from `commodity` (free-text, used
    # for the RAG query itself and for industry_domains()'s guaranteed-domain
    # matching) because that field is a loose blob not safe to filter on
    # directly. Optional for back-compat; when blank, retrieval is unfiltered
    # (matches pre-multi-industry behavior).
    industry: Optional[str] = None


# ---------------------------------------------------------------------------
# Auth — Salesforce sends "Authorization: Bearer <INBOUND_TOKEN>"
# ---------------------------------------------------------------------------
def require_token(authorization: Optional[str]):
    if authorization != f"Bearer {INBOUND_TOKEN}":
        raise HTTPException(status_code=401, detail="Invalid or missing token")


# ---------------------------------------------------------------------------
# Retrieval — HYBRID search: dense (pgvector cosine) + sparse (Postgres FTS),
# fused with Reciprocal Rank Fusion (RRF).
#
# Why hybrid: compliance queries are full of exact tokens ("ISO 27001", "OFAC",
# "REACH", a TIN) that dense vectors blur. FTS nails those; vectors catch
# paraphrase/semantics. RRF fuses the two rank lists without having to reconcile
# their incompatible score scales (cosine vs ts_rank) — it scores each doc by
# 1/(rrf_k + rank) summed across both lists. rrf_k=60 is the common default.
# ---------------------------------------------------------------------------
RRF_K = 60  # rank-fusion smoothing constant (standard default)


def retrieve(query: str, k: int = 8, pool: int = 20, industry: str = None):
    """Return the top-k policy chunks by fused dense+sparse relevance.

    `pool` is how many candidates each retriever contributes before fusion;
    larger pool = more chance a doc strong in only one retriever still surfaces.

    `industry` is a STRICT filter, not a ranking signal: every policy chunk is
    tagged to exactly one industry at ingest time, and once more than one
    industry's corpus is loaded, retrieval must never cross that boundary — a
    Healthcare supplier's checklist should never surface an Automotive IATF
    clause just because it scored close on embedding similarity. Pass None
    only for back-compat/single-industry deployments; every real caller in
    /scope and /assess passes the supplier's actual industry.
    is_current = true is always enforced so a superseded policy version is
    never an eligible search result once a newer version has been ingested.
    """
    emb = to_pgvector(embed_text(query))
    conn = get_conn()
    cur = conn.cursor()

    industry_clause = " AND industry = %s" if industry else ""
    industry_param = (industry,) if industry else ()

    # Dense candidates (semantic) — ordered by cosine distance.
    cur.execute(
        f"""
        SELECT clause_id, domain, text,
               1 - (embedding <=> %s::vector) AS score
        FROM policy_chunk
        WHERE is_current = true{industry_clause}
        ORDER BY embedding <=> %s::vector
        LIMIT %s
        """,
        (emb, *industry_param, emb, pool),
    )
    dense = cur.fetchall()

    # Sparse candidates (lexical / BM25-style) — ordered by ts_rank_cd.
    # websearch_to_tsquery tolerates raw user phrasing; if the query has no
    # indexable terms the result is simply empty and we fall back to dense.
    cur.execute(
        f"""
        SELECT clause_id, domain, text,
               ts_rank_cd(text_tsv, websearch_to_tsquery('english', %s)) AS score
        FROM policy_chunk
        WHERE text_tsv @@ websearch_to_tsquery('english', %s)
          AND is_current = true{industry_clause}
        ORDER BY score DESC
        LIMIT %s
        """,
        (query, query, *industry_param, pool),
    )
    sparse = cur.fetchall()
    cur.close()
    conn.close()

    # Reciprocal Rank Fusion. Keyed by clause_id; keep the row payload + the
    # per-retriever scores for transparency/debugging.
    fused = {}

    def fold(rows, which):
        for rank, r in enumerate(rows):
            cid = r[0]
            entry = fused.setdefault(cid, {
                "clauseId": cid, "domain": r[1], "text": r[2],
                "rrf": 0.0, "dense": 0.0, "sparse": 0.0,
            })
            entry["rrf"] += 1.0 / (RRF_K + rank)
            entry[which] = float(r[3])

    fold(dense, "dense")
    fold(sparse, "sparse")

    ranked = sorted(fused.values(), key=lambda e: e["rrf"], reverse=True)[:k]

    # Keep the historical return shape: `score` is the fused RRF score; expose
    # the component scores too (callers that ignore them are unaffected).
    return [
        {
            "clauseId": e["clauseId"],
            "domain": e["domain"],
            "text": e["text"],
            "score": e["rrf"],
            "denseScore": e["dense"],
            "sparseScore": e["sparse"],
        }
        for e in ranked
    ]


# ---------------------------------------------------------------------------
# Risk + checklist logic (deterministic, explainable — no LLM needed here)
# ---------------------------------------------------------------------------
HIGH_RISK_TERMS = ["cobalt", "drc", "congo", "conflict", "3tg", "sanction",
                   "ofac", "embargo", "tantalum", "tungsten"]
MEDIUM_RISK_TERMS = ["import", "export", "chemical", "reach", "rohs", "hazard",
                     "mineral", "tin", "gold"]

# One required document label per (industry, domain) pair — the checklist item
# NAME shown to Procurement/the supplier, distinct from which policy CLAUSE
# grounds it (that's already correctly industry-scoped via retrieve()'s strict
# filter). Without this split, every industry's "conflict" domain item showed
# the automotive label "Conflict Minerals Due Diligence (OECD/CMRT)" even when
# grounded in a healthcare clause — the citation was right, the checklist item
# NAME was wrong. "_default" is the fallback for any industry with no entry
# here yet (keeps a brand-new industry usable before its labels are curated).
DOMAIN_TO_DOCUMENT = {
    "automotive": {
        "conflict": "Conflict Minerals Due Diligence (OECD/CMRT)",
        "trade": "Sanctions / Denied-Party Screening Certificate",
        "finance": "KYC + Beneficial Ownership Declaration",
        "quality": "ISO 9001 Certificate / Certificate of Analysis",
        "material": "Material Safety Data Sheet (SDS) + REACH/RoHS Declaration",
        "cyber": "Information Security Attestation (ISO 27001 / GDPR)",
        "general": "General Supplier Self-Assessment Questionnaire",
    },
    "healthcare": {
        "conflict": "Conflict Minerals Due Diligence — Device Components (OECD/CMRT)",
        "trade": "OIG/SAM Exclusion & Sanctions Screening Certificate",
        "finance": "Tax Identity, LEI & Fraud-Waste-Abuse Attestation",
        "quality": "ISO 13485 Certificate / Accreditation Evidence",
        "material": "Device Regulatory Clearance & Material Safety Declaration",
        "cyber": "HIPAA Business Associate Agreement / Security Attestation",
        "general": "General Supplier Self-Assessment Questionnaire",
        # Clinical/genetic testing lab — fine-grained, one label per domain so
        # build_checklist() emits one row per document type (see common.py's
        # DOMAIN_KEYWORDS comment for why these 5 aren't one combined domain).
        "clinical_lab_cert": "CLIA Certificate",
        "clinical_lab_accred": "CAP Laboratory Accreditation Certificate",
        "clinical_lab_scope": "CAP Accreditation Scope Document",
        "clinical_lab_pt": "Proficiency Testing Results",
        "clinical_lab_person": "Lab Director Credentials & Personnel Competency File",
        # Compounding pharmacy / IV therapy
        "pharmacy_compound": "Compounding Standards Attestation (USP <795>/<797>/<800>, DEA Registration)",
        # Supplement / vitamin manufacturer
        "supplement_gmp": "Dietary Supplement GMP Compliance (21 CFR Part 111)",
        # Medical device / diagnostics manufacturer (H1)
        "device_diagnostics_qms": "ISO 13485 / 21 CFR 820 QMS Certificate + UDI/510(k) Evidence",
        # Health IT / digital health (H2) — distinct from the plain BAA in "cyber"
        "health_it_digital": "SOC 2 Type II / HITRUST Report & Subprocessor Disclosure",
        # Provider / counselor credentialing (H3)
        "provider_credentialing": "Exclusion Screening (OIG-LEIE/NPDB) & Credentialing Attestation",
        # Payer / delegated-entity oversight (H4)
        "payer_delegation": "CMS FDR Delegation Agreement & Compliance Program Attestation",
        # Behavioral health / SUD confidentiality (H5)
        "behavioral_health_part2": "42 CFR Part 2 Qualified Service Organization Agreement (QSOA)",
    },
    "_default": {
        "conflict": "Conflict Minerals Due Diligence Declaration",
        "trade": "Sanctions / Denied-Party Screening Certificate",
        "finance": "Financial & Tax Identity Declaration",
        "quality": "Quality Certification / Accreditation Evidence",
        "material": "Material Safety / Regulatory Compliance Declaration",
        "cyber": "Information Security Attestation",
        "general": "General Supplier Self-Assessment Questionnaire",
    },
}


def document_label_for(industry, domain):
    table = DOMAIN_TO_DOCUMENT.get(industry) or DOMAIN_TO_DOCUMENT["_default"]
    return table.get(domain, table["general"])

# Deterministic industry → required compliance domains. The policy corpus alone
# can't differentiate industries (they all embed near the same generic clauses),
# so an explicit rule layer GUARANTEES each industry's core domains. Matched by
# substring on the supplier's commodity/industry text (case-insensitive).
# Domains here are unioned with whatever RAG retrieves above the relevance floor.
INDUSTRY_DOMAINS = {
    "electronics":   ["material", "cyber", "conflict", "quality"],   # RoHS/REACH, infosec, 3TG, IPC
    "semiconductor": ["material", "cyber", "conflict", "quality"],
    "automotive":    ["quality", "material", "conflict"],            # IATF/PPAP, SDS, minerals
    "aerospace":     ["quality", "trade", "material"],               # AS9100, ITAR/export, materials
    "defense":       ["quality", "trade", "cyber"],
    "pharmaceutical":["quality", "material", "finance"],             # GMP/GDP, substances, financial health
    "pharma":        ["quality", "material", "finance"],
    "medical":       ["quality", "material", "cyber"],               # ISO 13485, substances, data
    "chemical":      ["material", "conflict", "trade"],              # REACH/SDS, minerals, export
    "food":          ["quality", "material"],                        # HACCP/quality, substances
    "energy":        ["material", "quality", "trade"],
    "utilities":     ["material", "quality", "cyber"],
    "industrial":    ["quality", "material", "conflict"],
    "logistics":     ["trade", "quality"],                           # customs/sanctions, service quality
    "distribution":  ["trade", "quality"],
    # Healthcare sub-verticals — matched BEFORE "pharma"/"medical" would catch
    # them (dict order matters for industry_domains()'s substring scan), each
    # guaranteeing its own document-type-specific domain set so the checklist
    # doesn't collapse a lab's 5 distinct document types into one generic
    # "quality" row the way "medical" alone would.
    "clinical lab":  ["clinical_lab_cert", "clinical_lab_accred", "clinical_lab_scope",
                       "clinical_lab_pt", "clinical_lab_person", "cyber", "finance"],
    "diagnostic lab":["clinical_lab_cert", "clinical_lab_accred", "clinical_lab_scope",
                       "clinical_lab_pt", "clinical_lab_person", "cyber", "finance"],
    "genetic testing":["clinical_lab_cert", "clinical_lab_accred", "clinical_lab_scope",
                        "clinical_lab_pt", "clinical_lab_person", "cyber", "finance"],
    "compounding pharmacy": ["pharmacy_compound", "cyber", "finance", "quality"],
    "infusion supply":      ["pharmacy_compound", "cyber", "finance", "quality"],
    "supplement":    ["supplement_gmp", "quality", "material"],
    "vitamin manufacturer": ["supplement_gmp", "quality", "material"],
    # Medical device / diagnostics manufacturer (H1) — matched BEFORE "medical"
    # would catch it, since "medical" alone routes to the old generic
    # quality/material/cyber set, not the device-specific QMS domain.
    "device manufacturer":     ["device_diagnostics_qms", "quality", "material", "cyber"],
    "diagnostics manufacturer":["device_diagnostics_qms", "quality", "material", "cyber"],
    "medical device":          ["device_diagnostics_qms", "quality", "material", "cyber"],
    # Health IT / digital health (H2) — Genomic Life's own category: a
    # benefits-navigation/data platform, not a lab or device maker.
    "health it":       ["health_it_digital", "finance", "general"],
    "digital health":  ["health_it_digital", "finance", "general"],
    "health data":     ["health_it_digital", "finance", "general"],
    # Provider / counselor credentialing (H3) — genetic counselors, physician
    # networks, staffing agencies; verifying PEOPLE, not a facility/product.
    "genetic counsel":       ["provider_credentialing", "cyber", "finance"],
    "provider network":      ["provider_credentialing", "cyber", "finance"],
    "staffing":              ["provider_credentialing", "cyber", "finance"],
    "credentialing":         ["provider_credentialing", "cyber", "finance"],
    # Payer / delegated-entity oversight (H4)
    "health plan": ["payer_delegation", "finance", "cyber", "general"],
    "payer":       ["payer_delegation", "finance", "cyber", "general"],
    # Behavioral health / SUD confidentiality (H5)
    "behavioral health": ["behavioral_health_part2", "cyber", "finance", "quality"],
    "substance use":     ["behavioral_health_part2", "cyber", "finance", "quality"],
    "mental health":     ["behavioral_health_part2", "cyber", "finance", "quality"],
}


def industry_domains(commodity: str):
    """Return the guaranteed domains for the supplier's industry (substring match
    on the commodity/industry text), or [] when no rule applies."""
    hay = (commodity or "").lower()
    for key, domains in INDUSTRY_DOMAINS.items():
        if key in hay:
            return domains
    return []


# Maps the fine-grained INDUSTRY_DOMAINS keys (which describe what a supplier
# MAKES, e.g. "semiconductor", "pharma", "medical") onto which CORPUS a
# customer actually ingests (each customer's corpus is tagged at ingest time
# with one industry key of their choosing — see /policy/ingest's `industry`
# field). Multiple fine-grained keys can share one corpus tag: a healthcare
# system's corpus covers both "pharmaceutical" and "medical" suppliers, for
# example. Add an entry here whenever a customer's corpus should be reachable
# under more than one industry_domains() match.
INDUSTRY_CORPUS_TAG = {
    "automotive":     "automotive",
    "electronics":    "automotive",   # shares the automotive corpus in this demo
    "semiconductor":  "automotive",
    "aerospace":      "automotive",
    "defense":        "automotive",
    "industrial":     "automotive",
    "pharmaceutical": "healthcare",
    "pharma":         "healthcare",
    "medical":        "healthcare",
    "clinical lab":         "healthcare",
    "diagnostic lab":       "healthcare",
    "genetic testing":      "healthcare",
    "compounding pharmacy": "healthcare",
    "infusion supply":      "healthcare",
    "supplement":            "healthcare",
    "vitamin manufacturer":  "healthcare",
    "device manufacturer":      "healthcare",
    "diagnostics manufacturer": "healthcare",
    "medical device":           "healthcare",
    "health it":       "healthcare",
    "digital health":  "healthcare",
    "health data":     "healthcare",
    "genetic counsel":  "healthcare",
    "provider network": "healthcare",
    "staffing":          "healthcare",
    "credentialing":     "healthcare",
    "health plan": "healthcare",
    "payer":       "healthcare",
    "behavioral health": "healthcare",
    "substance use":     "healthcare",
    "mental health":     "healthcare",
}


def industry_key(commodity: str):
    """Resolve the supplier's commodity/industry text to the CORPUS tag used to
    strictly filter retrieve() — distinct from industry_domains()'s per-domain
    guarantees, though both match against the same INDUSTRY_DOMAINS keys so
    there's one source of truth for "what industry is this supplier in."
    Returns None when no rule matches (retrieval falls back to unfiltered,
    matching pre-multi-industry behavior for an unrecognized industry)."""
    hay = (commodity or "").lower()
    for key in INDUSTRY_DOMAINS:
        if key in hay:
            return INDUSTRY_CORPUS_TAG.get(key)
    return None


def resolve_corpus_industry(industry_field: Optional[str], commodity: Optional[str]) -> Optional[str]:
    """Resolve /scope's corpus_industry consistently everywhere it's computed.

    Salesforce's Industry__c sends its raw picklist LABEL (e.g. "Pharmaceutical",
    "Clinical / Diagnostic Lab") as req.industry — never the ingested corpus TAG
    ("healthcare"). Using req.industry as-is (the previous behavior) made
    retrieve()'s strict industry filter match zero rows for every Salesforce
    caller, silently falling through to unfiltered RAG + the generic
    DOMAIN_TO_DOCUMENT["_default"] labels — confirmed live: industry="Pharmaceutical"
    produced "Material Safety / Regulatory Compliance Declaration" instead of the
    healthcare-specific label, with no real policy citation. Always translate
    through the same INDUSTRY_DOMAINS/INDUSTRY_CORPUS_TAG substring match used for
    commodity, checking the industry field first (it's the more reliable signal
    when present) and falling back to commodity — never trust either value
    literally as a corpus tag."""
    resolved = industry_key(industry_field) if industry_field else None
    if resolved:
        return resolved
    return industry_key(commodity)


# Deterministic material/service-category → required domains. Industry text
# alone can be generic ("Electronics") while the ACTUAL raw material tells you
# far more precisely which domains apply (e.g. conflict minerals vs. plastics-only
# assembly). Optional and additive to INDUSTRY_DOMAINS — never replaces it.
MATERIAL_TYPE_DOMAINS = {
    "conflict-mineral-bearing metals": ["conflict", "material", "trade"],
    "chemicals":                       ["material", "quality"],
    "electronics components":          ["material", "cyber", "quality"],
    "packaging":                       ["material", "quality"],
    "textiles":                        ["material", "quality"],
}

SERVICE_CATEGORY_DOMAINS = {
    "logistics":                ["trade", "quality"],
    "it/software":              ["cyber", "finance"],
    "professional services":    ["cyber", "finance"],
    "manufacturing-subcontract":["quality", "material"],
}


def material_domains(material_type: Optional[str], service_category: Optional[str]):
    """Return the guaranteed domains implied by the supplier's declared raw
    material type and/or service category (exact match against the picklist
    values above). Either or both may be blank — returns [] when neither is set
    or matches, same 'no-op when absent' behavior as industry_domains."""
    domains = set()
    if material_type and material_type in MATERIAL_TYPE_DOMAINS:
        domains.update(MATERIAL_TYPE_DOMAINS[material_type])
    if service_category and service_category in SERVICE_CATEGORY_DOMAINS:
        domains.update(SERVICE_CATEGORY_DOMAINS[service_category])
    return sorted(domains)


# ── Engagement-type rules (deterministic, explainable) ──────────────────────
# The KIND of relationship changes what evidence matters, independent of industry:
#   - Services / Consulting / MRO: no physical goods → drop material/conflict;
#     they handle DATA and money → add cyber + finance.
#   - Logistics / Distribution: customs/sanctions exposure → add trade.
#   - Direct production / tooling / raw materials: physical product → keep the
#     full industry set (no change).
# Each rule is (add_domains, remove_domains); matched by substring on the
# engagement text. First matching rule wins.
ENGAGEMENT_DOMAIN_RULES = [
    (["services", "consulting"],            (["cyber", "finance"], ["material", "conflict"])),
    (["indirect", "non-production", "mro"], (["cyber"],            ["conflict"])),
    (["logistics", "distribution"],         (["trade"],            ["conflict"])),
]


def engagement_domains(commodity: str):
    """Return (add_set, remove_set) of domains implied by the engagement type.
    `commodity` carries the engagement text (e.g. 'engagement: Services / Consulting').
    Returns (set(), set()) when no engagement rule applies."""
    hay = (commodity or "").lower()
    for terms, (add, remove) in ENGAGEMENT_DOMAIN_RULES:
        if any(t in hay for t in terms):
            return set(add), set(remove)
    return set(), set()


# Spend thresholds (USD) that nudge the tier upward — bigger relationships carry
# more financial/operational exposure regardless of commodity.
SPEND_HIGH = 5_000_000
SPEND_MED  = 1_000_000

# Engagement types that inherently raise exposure (direct production / tooling
# touch the product; services/MRO are lower).
HIGH_ENGAGEMENT_TERMS = ["tier 1", "tier-1", "direct material", "production",
                         "capital equipment", "tooling", "raw material", "commodit"]


def _spend_value(commodity_or_spend: str):
    """Pull a rough USD number out of the enriched commodity/spend string."""
    import re
    if not commodity_or_spend:
        return None
    s = commodity_or_spend.lower().replace(",", "")
    m = re.search(r"(\d+(?:\.\d+)?)\s*([mk]?)", s)
    if not m:
        return None
    val = float(m.group(1))
    unit = m.group(2)
    if unit == "m" or "million" in s:
        val *= 1_000_000
    elif unit == "k":
        val *= 1_000
    return val


def assess_risk(req: ScopeRequest, hits):
    """Tier reasons about the SUPPLIER'S OWN PROFILE (what they supply, where,
    how big, how deep the engagement) — NOT the retrieved policy text (which
    always mentions sanctions/conflict and would force everything to High).
    Returns (tier, summary, reasons[])."""
    import re as _re
    profile = " ".join([
        req.country or "", req.commodity or "", " ".join(req.jurisdictions),
    ]).lower()

    def _word_hit(terms):
        """Whole-word match so short tokens (tin, gold) don't match inside
        'consulting' / 'goldsmith' etc."""
        for t in terms:
            if _re.search(r"\b" + _re.escape(t) + r"\b", profile):
                return t
        return None

    reasons = []
    score = 0

    # 1. Commodity/geography risk signals (from the supplier, not policy text).
    hi = _word_hit(HIGH_RISK_TERMS)
    md = _word_hit(MEDIUM_RISK_TERMS)
    if hi:
        score += 2
        reasons.append(f"High-risk signal in profile (“{hi}”) — conflict-minerals / sanctions exposure.")
    elif md:
        score += 1
        reasons.append(f"Medium-risk signal in profile (“{md}”) — regulated material / trade exposure.")

    # 2. Annual spend — bigger relationships carry more exposure.
    spend = _spend_value(req.commodity)
    if spend is not None:
        if spend >= SPEND_HIGH:
            score += 2
            reasons.append(f"Annual spend ≈ ${spend:,.0f} (≥ ${SPEND_HIGH:,}) raises financial exposure.")
        elif spend >= SPEND_MED:
            score += 1
            reasons.append(f"Annual spend ≈ ${spend:,.0f} (≥ ${SPEND_MED:,}) is a moderate commitment.")

    # 3. Engagement depth — direct/production touches the product.
    if any(t in profile for t in HIGH_ENGAGEMENT_TERMS):
        score += 1
        hit = next((t for t in HIGH_ENGAGEMENT_TERMS if t in profile), None)
        reasons.append(f"Engagement depth (“{hit}”) — direct/production relationship increases scrutiny.")

    tier = "High" if score >= 3 else ("Medium" if score >= 1 else "Low")
    if not reasons:
        reasons.append("No elevated risk signals in the supplier profile — baseline onboarding applies.")

    summary = f"{tier} risk. " + " ".join(reasons)
    return tier, summary, reasons


def build_checklist(hits, industry=None):
    """One checklist item per distinct domain, justified by its best-scoring clause."""
    seen = {}
    for h in hits:
        d = h["domain"]
        if d not in seen:  # hits are already ordered best-first
            seen[d] = h
    checklist = []
    for domain, hit in seen.items():
        checklist.append({
            "document": document_label_for(industry, domain),
            "domain": domain,
            "justificationClauseId": hit["clauseId"],
            "justification": hit["text"][:300],
        })
    return checklist


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/health")
def health():
    """Liveness — the process is up. Also surfaces the active config."""
    return {"ok": True, "config": settings.summary()}


@app.get("/ready")
def ready():
    """Readiness — dependencies reachable (DB). 503 if not, so a load balancer
    can route around an unhealthy replica."""
    try:
        conn = get_conn()
        cur = conn.cursor()
        cur.execute("SELECT 1")
        cur.close()
        conn.close()
        db_state = "ok"
    except Exception as e:
        return JSONResponse(status_code=503,
                            content={"ready": False, "db": f"error: {e}",
                                     "config": settings.summary()})
    return {"ready": True, "db": db_state, "config": settings.summary()}


@app.post("/scope")
def scope(req: ScopeRequest, authorization: Optional[str] = Header(None)):
    require_token(authorization)

    # Domain scoping is driven by WHAT the supplier provides and WHERE — not the
    # company's NAME (which only matters for identity/sanctions screening, not for
    # which compliance domains apply). Excluding the name keeps the domain set
    # stable across different supplier names with the same profile.
    query = " ".join(filter(None, [
        req.commodity, req.country, " ".join(req.jurisdictions),
    ]))
    # Strict corpus filter: translate the industry field (Salesforce's raw
    # picklist label) and the commodity text through the same corpus-tag
    # resolution — see resolve_corpus_industry's docstring for why neither can
    # be trusted literally.
    corpus_industry = resolve_corpus_industry(req.industry, req.commodity)
    # Retrieve broadly (corpus is small) so every domain has a candidate clause.
    hits = retrieve(query, k=30, industry=corpus_industry)
    tier, summary, tier_reasons = assess_risk(req, hits)

    # Best-scoring policy clause per domain.
    best_by_domain = {}
    for h in hits:                       # hits are ordered best-first
        if h["domain"] not in best_by_domain:
            best_by_domain[h["domain"]] = h

    # The universal baseline every supplier must satisfy per policy
    # (financial/identity governance + general onboarding).
    BASELINE_DOMAINS = {"finance", "general"}

    # Relevance floor: a domain only attaches if its best clause is a GENUINE
    # semantic match. RRF ratios compress (a barely-related clause still ranks
    # ~1.0 relative to the next), so we floor on the underlying DENSE COSINE
    # score instead — a real match scores well above ~0.30; an off-topic profile
    # like "basket weaving" tops out around 0.15 ("retrieval always returns
    # *something*"). This is what stops irrelevant domains from leaking in.
    DENSE_FLOOR = 0.32
    non_baseline = {
        d: h for d, h in best_by_domain.items() if d not in BASELINE_DOMAINS
    }
    matched_specific = {
        d for d, h in non_baseline.items()
        if h.get("denseScore", 0.0) >= DENSE_FLOOR
    }

    # Deterministic industry rules GUARANTEE each industry's core domains, so the
    # checklist genuinely differs by industry (the corpus alone can't differentiate
    # them — every industry embeds near the same generic clauses). RAG-matched
    # domains are unioned on top, so retrieval still contributes.
    ind_domains = set(industry_domains(req.commodity))

    # Engagement type refines the set: a Services/Consulting relationship needs
    # different evidence than Tier-1 production (data/finance vs material/conflict).
    eng_add, eng_remove = engagement_domains(req.commodity)

    # Material type / service category, if the caller supplied them, sharpen the
    # set further — e.g. an "Electronics" supplier whose declared material is
    # conflict-mineral-bearing metal guarantees 'conflict' even if the blended
    # industry/engagement text alone wouldn't have surfaced it strongly enough.
    # Prefer Salesforce-resolved materialDomains (from the admin-configurable
    # Material_Type__mdt catalog) when sent — this is what makes a NEW material
    # for any industry take effect via Custom Metadata alone, no engine deploy.
    # Fall back to the hardcoded dicts only when the caller doesn't send it.
    if req.materialDomains:
        mat_domains = set(req.materialDomains)
    else:
        mat_domains = set(material_domains(req.materialType, req.serviceCategory))

    no_specific_match = (len(matched_specific) == 0 and len(ind_domains) == 0
                         and len(eng_add) == 0 and len(mat_domains) == 0)
    # Union industry + RAG + engagement adds + material/service adds + baseline,
    # then subtract the engagement removals — but NEVER drop a baseline domain.
    selected = (set(matched_specific) | ind_domains | eng_add | mat_domains | BASELINE_DOMAINS)
    selected -= (eng_remove - BASELINE_DOMAINS)

    ordered = [h for d, h in sorted(best_by_domain.items(), key=lambda kv: -kv[1]["score"])
               if d in selected]
    checklist = build_checklist(ordered, industry=corpus_industry)

    # Ensure EVERY selected domain produces a checklist item — including
    # industry-mandated and baseline domains whose clause wasn't retrieved.
    # Otherwise the checklist silently drops required docs.
    present_domains = {item["domain"] for item in checklist}
    for d in sorted(selected):
        if d not in present_domains:
            hit = best_by_domain.get(d)
            if d in BASELINE_DOMAINS:
                why = f"Mandatory baseline requirement for all suppliers ({d})."
            elif d in ind_domains:
                why = f"Required for this industry — domain '{d}'."
            else:
                why = f"Applicable compliance domain '{d}'."
            checklist.append({
                "document": document_label_for(corpus_industry, d),
                "domain": d,
                "justificationClauseId": hit["clauseId"] if hit else f"rule:{d}",
                "justification": hit["text"][:300] if hit else why,
            })

    # Per-domain reasoning so the UI can explain WHY each item is on the list.
    domain_reasons = {
        d: f"Matched policy domain “{d}” (clause {best_by_domain[d]['clauseId']})."
        for d in matched_specific
    }
    for d in BASELINE_DOMAINS:
        domain_reasons[d] = f"Baseline requirement — every supplier must satisfy “{d}”."
    for d in eng_add:
        if d in selected:
            domain_reasons[d] = f"Added by engagement type — this relationship requires “{d}”."
    for d in mat_domains:
        if d in selected:
            domain_reasons[d] = f"Added by declared material/service type — requires “{d}”."

    notes = []
    if no_specific_match:
        prof = req.commodity or "this profile"
        notes.append(
            f"No industry-specific policy matched {prof!r} — applying the general "
            f"onboarding + financial baseline only. An analyst may add requirements."
        )

    return {
        "supplierId": req.supplierId,
        "riskTier": tier,
        "riskSummary": summary,
        "riskReasons": tier_reasons,        # bullet reasoning behind the tier
        "scope": sorted(selected),          # scoped risk domains (UI highlights these)
        "checklist": checklist,
        "domainReasons": domain_reasons,    # why each domain is on the list
        "noPolicyMatch": no_specific_match, # true → only baseline applied
        "notes": notes,                     # human-readable explanations
        "corpusVersion": settings.CORPUS_VERSION,
    }


# ---------------------------------------------------------------------------
# /policy/ingest — internal Procurement upload path for company policy docs.
#
# Same parse -> chunk -> embed -> upsert pipeline as the SFTP bulk script
# (ingest_policies.py), reused via common.ingest_policy_document() so a policy
# uploaded through Salesforce is indistinguishable, once ingested, from one
# ingested via SFTP. /scope's retrieval is unaware of and unaffected by which
# path a chunk came from.
# ---------------------------------------------------------------------------
class PolicyIngestRequest(BaseModel):
    fileName: str
    documentBase64: str
    domainHint: Optional[str] = None   # None/blank -> engine auto-detects via guess_domain
    # Which corpus this document belongs to (e.g. "automotive", "healthcare") —
    # a STRICT retrieval filter, not a hint. Defaults to "general" only for
    # back-compat with any caller that predates multi-industry support; a real
    # customer upload should always send this explicitly.
    industry: Optional[str] = None


# ---------------------------------------------------------------------------
# Ingest is ASYNC: parsing (esp. pdfplumber on a 40-100 page PDF) plus
# embedding every chunk can take well beyond Salesforce's 120s hard callout
# ceiling, so /policy/ingest must not block on the actual work. It enqueues a
# background thread and returns immediately with a jobId; the caller polls
# /policy/ingest/status/{jobId} (same shape the LWC already polls
# Policy_Document__c.Status__c on, just one hop earlier). Single-process
# in-memory dict is sufficient here — this engine runs as one Docker
# container, not horizontally scaled.
# ---------------------------------------------------------------------------
_ingest_jobs = {}          # jobId -> {"status": "queued"|"processing"|"done"|"failed", ...}
_ingest_jobs_lock = threading.Lock()

# Hard guard on input size BEFORE spending any time parsing — a bad/huge
# upload should fail fast and clearly, not silently churn for minutes.
# ~15MB covers a genuinely large (100+ page) text-heavy PDF; scanned-image
# PDFs of that size are rare and would fail extraction anyway (see
# PAGE_COUNT_LIMIT below for the more common "too many pages" case).
MAX_UPLOAD_BYTES = 15 * 1024 * 1024
PDF_PAGE_LIMIT = 150   # generous — real policy docs described (40-100pp) fit comfortably


def _run_ingest_job(job_id, file_name, data, industry, domain_override):
    with _ingest_jobs_lock:
        _ingest_jobs[job_id]["status"] = "processing"
    try:
        result = ingest_policy_document(file_name, data, industry, domain_override)
        with _ingest_jobs_lock:
            _ingest_jobs[job_id].update(status="done", result=result)
    except Exception as e:
        with _ingest_jobs_lock:
            _ingest_jobs[job_id].update(status="failed", error=str(e))


@app.post("/policy/ingest")
def policy_ingest(req: PolicyIngestRequest, authorization: Optional[str] = Header(None)):
    require_token(authorization)

    try:
        data = base64.b64decode(req.documentBase64)
    except Exception:
        raise HTTPException(status_code=422, detail="documentBase64 is not valid base64")

    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(
            status_code=422,
            detail=f"'{req.fileName}' is {len(data) // (1024*1024)}MB, over the "
                   f"{MAX_UPLOAD_BYTES // (1024*1024)}MB limit for policy uploads. "
                   f"Split it into smaller documents or reduce embedded images.")

    ext = req.fileName.lower().rsplit(".", 1)[-1] if "." in req.fileName else ""
    if ext not in ("txt", "md", "pdf", "docx", "xlsx", "xlsm"):
        raise HTTPException(
            status_code=422,
            detail=f"Unsupported file type '.{ext}'. Supported formats: .txt, .md, .pdf, .docx, .xlsx")

    if ext == "pdf":
        try:
            import pdfplumber
            with pdfplumber.open(io.BytesIO(data)) as pdf:
                page_count = len(pdf.pages)
            if page_count > PDF_PAGE_LIMIT:
                raise HTTPException(
                    status_code=422,
                    detail=f"'{req.fileName}' has {page_count} pages, over the "
                           f"{PDF_PAGE_LIMIT}-page limit. Split it into smaller documents.")
        except HTTPException:
            raise
        except Exception:
            raise HTTPException(
                status_code=422,
                detail=f"Could not open '{req.fileName}' as a PDF — the file may be corrupt "
                       f"or password-protected.")

    domain_override = req.domainHint if req.domainHint and req.domainHint != "Auto-Detect" else None
    industry = req.industry or "general"

    job_id = str(uuid.uuid4())
    with _ingest_jobs_lock:
        _ingest_jobs[job_id] = {"status": "queued", "fileName": req.fileName, "startedAt": time.time()}
    threading.Thread(
        target=_run_ingest_job,
        args=(job_id, req.fileName, data, industry, domain_override),
        daemon=True,
    ).start()

    return {"jobId": job_id, "status": "queued", "fileName": req.fileName}


@app.get("/policy/ingest/status/{job_id}")
def policy_ingest_status(job_id: str, authorization: Optional[str] = Header(None)):
    require_token(authorization)
    with _ingest_jobs_lock:
        job = _ingest_jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Unknown ingest job id")

    resp = {"jobId": job_id, "status": job["status"], "fileName": job["fileName"]}
    if job["status"] == "done":
        result = job["result"]
        resp.update(
            domain=result["domain"], industry=result["industry"],
            chunkCount=result["chunkCount"], version=result["version"],
        )
    elif job["status"] == "failed":
        resp["error"] = job["error"]
    return resp


class PolicyDeleteRequest(BaseModel):
    fileName: str   # must match policy_chunk.source exactly (the uploaded filename)


@app.post("/policy/delete")
def policy_delete(req: PolicyDeleteRequest, authorization: Optional[str] = Header(None)):
    """Hard-delete every chunk (all versions, current and retired) for one
    source file. Called when a Policy_Document__c is deleted in Salesforce so
    a removed policy stops influencing every future /scope and /assess call —
    previously delete only removed the Salesforce record and the underlying
    policy_chunk rows stayed live in the index forever."""
    require_token(authorization)

    conn = get_conn()
    cur = conn.cursor()
    cur.execute("DELETE FROM policy_chunk WHERE source = %s", (req.fileName,))
    deleted = cur.rowcount
    conn.commit()
    cur.close()
    conn.close()

    return {"fileName": req.fileName, "chunksDeleted": deleted}


# ---------------------------------------------------------------------------
# /verify — Stage-02 due-diligence screening (registry verification)
#
# Runs the free, keyless verifiers (GLEIF identity + OpenSanctions sanctions/PEP)
# and returns normalized results per category. Conflict-minerals (RMI) is gated
# until the smelter list is ingested → routes to the human gate. Screening only
# flags; it never takes adverse action.
# ---------------------------------------------------------------------------
class VerifyRequest(BaseModel):
    legalName: str
    country: Optional[str] = None
    commodity: Optional[str] = None
    domains: List[str] = []


def _vr(authority, category, status, summary, evidence=None):
    return {"authority": authority, "category": category, "status": status,
            "summary": summary, "evidence": evidence or []}


@app.post("/verify")
def verify(req: VerifyRequest, authorization: Optional[str] = Header(None)):
    require_token(authorization)
    from screening import gleif_lookup, sanctions_screen, disambiguate
    results = []

    gleif = gleif_lookup(req.legalName, req.country)
    sanc  = sanctions_screen(req.legalName)
    disambig = disambiguate(
        {"legalName": req.legalName, "country": req.country, "commodity": req.commodity},
        gleif, sanc)

    # ── Identity / financial — GLEIF (prefer the disambiguated true entity) ──
    best_lei = disambig.get("best_lei")
    if best_lei:
        st = disambig.get("best_lei_status") or "ISSUED"
        results.append(_vr("GLEIF", "Financials",
            "Verified" if str(st).upper() == "ISSUED" else "Review",
            f"Disambiguated entity: LEI {best_lei} (registration {st}) for {req.legalName}",
            evidence=gleif.get("matches", [])[:3]))
    else:
        gleif_status = str(gleif.get("status") or "")
        if gleif_status.startswith("error"):
            # A provider error (e.g. 429 rate limit) is NOT "no match" — we could
            # not verify, so route to an analyst rather than implying anything.
            results.append(_vr("GLEIF", "Financials", "Review",
                f"GLEIF could not be checked ({gleif_status}) — screening incomplete, analyst review."))
        else:
            best = gleif["matches"][0] if gleif.get("matches") else None
            if best and best.get("status") == "ISSUED":
                results.append(_vr("GLEIF", "Financials", "Verified",
                    f"LEI {best['lei']} — {best['legalName']} ({best.get('country')}), registration ISSUED",
                    evidence=gleif["matches"][:3]))
            elif best:
                results.append(_vr("GLEIF", "Financials", "Review",
                    f"LEI found but registration status is {best.get('status')} — analyst review",
                    evidence=gleif["matches"][:3]))
            else:
                results.append(_vr("GLEIF", "Financials", "NotFound",
                    f"No LEI match for '{req.legalName}' (status: {gleif.get('status')})"))

    # ── Sanctions — disambiguation suppresses false positives ────────────────
    assess    = disambig.get("sanctions_assessment") or []
    true_hits = [a for a in assess if a.get("likely_true")]
    if sanc.get("hits"):
        if true_hits:
            results.append(_vr("OpenSanctions", "Sanctions", "Flag",
                f"{len(true_hits)} likely-TRUE sanctions/PEP match(es) after disambiguation — review required",
                evidence=true_hits))
        elif assess:
            results.append(_vr("OpenSanctions", "Sanctions", "Clear",
                f"{len(sanc['hits'])} raw match(es) assessed as false positives by disambiguation",
                evidence=[]))
        else:
            results.append(_vr("OpenSanctions", "Sanctions", "Flag",
                f"{len(sanc['hits'])} potential sanctions/PEP match(es) — review required",
                evidence=sanc["hits"][:5]))
    else:
        note = str(sanc.get("status") or "")
        if note.startswith("error"):
            # CRITICAL: a provider error (429 rate-limit, timeout, 5xx) means we
            # could NOT screen — it must NOT read as "Clear". Route to analyst.
            results.append(_vr("OpenSanctions", "Sanctions", "Review",
                f"Sanctions screening could not be completed ({note}) — analyst must screen manually.",
                evidence=[]))
        else:
            results.append(_vr("OpenSanctions", "Sanctions", "Clear",
                "No sanctions/PEP match" + (f" ({note})" if note and note != "ok" else ""), evidence=[]))

    # ── Conflict minerals — RMI gate ─────────────────────────────────────────
    if "conflict" in (req.domains or []):
        results.append(_vr("RMI", "Conflict Minerals", "NotConfigured",
            "Smelter/refiner CID cross-check requires the RMI conformant-smelter list — routed to analyst.",
            evidence=[]))

    # ── Adverse media — GDELT (keyless) + LLM classification ─────────────────
    import media
    am = media.adverse_media_screen(req.legalName, req.country)
    results.append(_vr("GDELT adverse media", "Media", am["status"], am["summary"],
                       evidence=am.get("articles", [])[:5]))

    # Overall signal: prefer the disambiguation recommendation; else derive.
    signal = disambig.get("recommended_signal")
    if signal not in ("clear", "review", "flag"):
        signal = "clear"
        if any(r["status"] == "Flag" for r in results):
            signal = "flag"
        elif any(r["status"] in ("Review", "NotFound", "NotConfigured") for r in results):
            signal = "review"
    # SAFETY OVERRIDE: a Flag always wins; and any Review (e.g. a provider that
    # could not be checked — 429/timeout) must never be reported as fully clear,
    # regardless of what disambiguation recommended on partial data.
    if any(r["status"] == "Flag" for r in results):
        signal = "flag"
    elif signal == "clear" and any(r["status"] == "Review" for r in results):
        signal = "review"

    return {"legalName": req.legalName, "signal": signal,
            "results": results, "disambiguation": disambig}


# ═══════════════════════════════════════════════════════════════════════════
# Co-pilot Q&A — grounded chat over policies + the case context
# ═══════════════════════════════════════════════════════════════════════════
import time as _time

# LATENCY: a small in-memory TTL cache (Microsoft Copilot's "cache the prompt"
# trick). Identical (case/supplier + question) → instant repeat, zero LLM call.
_COPILOT_CACHE = {}
_COPILOT_TTL = 1800   # 30 minutes


def _copilot_cache_get(key):
    hit = _COPILOT_CACHE.get(key)
    if hit and (_time.time() - hit[0]) < _COPILOT_TTL:
        return hit[1]
    if hit:
        _COPILOT_CACHE.pop(key, None)   # expired
    return None


def _copilot_cache_put(key, value):
    _COPILOT_CACHE[key] = (_time.time(), value)
    if len(_COPILOT_CACHE) > 500:       # bound memory
        oldest = min(_COPILOT_CACHE.items(), key=lambda kv: kv[1][0])[0]
        _COPILOT_CACHE.pop(oldest, None)


class CopilotRequest(BaseModel):
    question: str
    supplierName: Optional[str] = None
    context: Optional[str] = None      # case findings + screening summary from Salesforce
    caseId: Optional[str] = None       # if set, enrich context from the live agent case
    role: Optional[str] = None         # 'Procurement Manager' | 'Analyst' | ... (role-aware next step)


def _empty_copilot(answer: str) -> dict:
    """Structured empty/degraded co-pilot response (fixed schema for the UI)."""
    return {"answer": answer, "verdict": "", "keyFindings": [], "blockers": [],
            "recommendedAction": "", "nextStep": "", "citations": []}


def _case_context_block(case_id: str) -> str:
    """Render the live agent CaseState as grounding context so the co-pilot narrates
    the SAME case the agent is driving (not a separate, stale snapshot)."""
    try:
        snap = compliance_graph.get_state({"configurable": {"thread_id": case_id}})
        if not snap or not snap.values:
            return ""
        v = snap.values
        syn = v.get("synthesis", {}) or {}
        sc = v.get("screening", {}) or {}
        lines = [f"AGENT CASE STATUS: {v.get('status','?')}",
                 f"SCOPED DOMAINS: {', '.join(v.get('scope', []) or []) or '(none)'}",
                 f"SCREENING SIGNAL: {sc.get('preliminary_signal','pending')}",
                 f"SYNTHESIZED TIER: {syn.get('suggested_tier') or syn.get('prelim_tier') or '?'}"
                 f" (score {syn.get('risk_score','?')}, confidence {syn.get('confidence','?')})"]
        findings = v.get("findings", []) or []
        if findings:
            lines.append("DOCUMENT FINDINGS:")
            for f in findings[:12]:
                lines.append(f"  - {f.get('documentType','document')}: {f.get('verdict')}"
                             f" ({(f.get('reasons') or ['—'])[0]})")
        return "\n".join(lines)
    except Exception:
        return ""


@app.post("/copilot")
def copilot(req: CopilotRequest, authorization: Optional[str] = Header(None)):
    require_token(authorization)
    if not (req.question or "").strip():
        return _empty_copilot("Ask a question about this supplier's compliance.")

    clauses = retrieve(req.question, k=6)
    policy_block = "\n\n".join(f"[{c['clauseId']}] {c['text']}" for c in clauses)

    if not llm.is_configured():
        return _empty_copilot("AI co-pilot isn't configured (no LLM in this deployment).")

    # Ground in the LIVE agent case if a caseId is supplied (the co-pilot then
    # narrates the same case the agent drives); else use the passed-in context.
    case_block = _case_context_block(req.caseId) if req.caseId else ""
    context = "\n\n".join(filter(None, [case_block, req.context])) or "(none provided)"

    # Cache key folds in the case context so a case that has MOVED re-answers.
    cache_key = (req.caseId or req.supplierName or "", (req.role or "pm").lower(),
                 req.question.strip().lower(), hash(context))
    cached = _copilot_cache_get(cache_key)
    if cached is not None:
        return cached

    import prompts
    system = prompts.load("copilot")
    role = req.role or "Procurement Manager"   # procurement screen default
    user = (f"ROLE: {role}\n"
            f"SUPPLIER: {req.supplierName or 'the supplier'}\n\n"
            f"CASE CONTEXT (the agent's live state — findings + screening):\n{context}\n\n"
            f"RELEVANT POLICY CLAUSES:\n{policy_block or '(none retrieved)'}\n\n"
            f"QUESTION: {req.question}")
    try:
        # Cap output (latency + can't ramble) → short, structured narration.
        data = llm.chat_json(system, user, max_tokens=500)
    except Exception as e:
        return _empty_copilot(f"Co-pilot is temporarily unavailable: {e}")

    def _slist(x):
        return [str(s) for s in x] if isinstance(x, list) else []
    result = {
        "answer": (data.get("answer") or "")[:600],
        "verdict": data.get("verdict") or "",
        "keyFindings": _slist(data.get("key_findings"))[:5],
        "blockers": _slist(data.get("blockers"))[:5],
        "recommendedAction": data.get("recommended_action") or "",
        # Role-appropriate next concrete action (drives the procurement "next step").
        "nextStep": data.get("next_step") or data.get("recommended_action") or "",
        "citations": data.get("citations") or [c["clauseId"] for c in clauses],
    }
    _copilot_cache_put(cache_key, result)
    return result


class ExtractRequest(BaseModel):
    documentText: str


@app.post("/extract")
def extract(req: ExtractRequest, authorization: Optional[str] = Header(None)):
    """Stub: returns fields you'd later parse from an uploaded supplier document."""
    require_token(authorization)
    return {
        "fields": {
            "legalName": None,
            "registrationNumber": None,
            "country": None,
        },
        "note": "extract endpoint is a stub — wire in Azure Document Intelligence or an LLM later.",
        "receivedChars": len(req.documentText),
    }


# ---------------------------------------------------------------------------
# RAG-based document assessment (/assess)
#
# Replaces the Azure extract→validate→evaluate pipeline. Given an uploaded
# supplier document (text or base64 file) and the policy domain it is meant to
# satisfy, it:
#   1. Extracts text (pdfplumber / python-docx / plain)
#   2. Retrieves the most relevant policy clauses (pgvector RAG)
#   3. Asks an LLM to judge Compliant / Non-Compliant / Needs Analyst, grounded
#      ONLY in the retrieved clauses + the document, with citations, severity,
#      and confidence.
#
# Autonomy L2: this DRAFTS a finding. The verdict is advisory — an analyst
# accepts/dismisses it in Salesforce. When evidence is insufficient (or no LLM
# key is configured) it abstains with verdict "Needs Analyst".
# ---------------------------------------------------------------------------
VALID_VERDICTS = {"Compliant", "Non-Compliant", "Needs Analyst"}
VALID_SEVERITY = {"Critical", "High", "Medium", "Low"}


class AssessRequest(BaseModel):
    supplierId: str
    domain: Optional[str] = None          # policy domain (conflict/trade/...)
    requirementKey: Optional[str] = None  # SF Compliance_Assessment key (echoed back)
    documentType: Optional[str] = None    # human label, e.g. "ISO 9001 Certificate"
    documentText: Optional[str] = None    # raw text, OR
    documentBase64: Optional[str] = None  # base64-encoded file bytes
    fileName: Optional[str] = None        # used to pick the extractor
    # Same strict corpus filter as ScopeRequest.industry — without this, a
    # Healthcare document's compliance verdict could cite an Automotive policy
    # clause once more than one industry's corpus is loaded. Optional for
    # back-compat; blank means unfiltered (matches pre-multi-industry behavior).
    industry: Optional[str] = None


def extract_document_text(req: "AssessRequest") -> str:
    """Return the document's text from raw text or a base64-encoded file."""
    if req.documentText and req.documentText.strip():
        return req.documentText
    if not req.documentBase64:
        return ""
    raw = base64.b64decode(req.documentBase64)
    name = (req.fileName or "").lower()
    if name.endswith(".pdf"):
        import pdfplumber
        with pdfplumber.open(io.BytesIO(raw)) as pdf:
            return "\n".join((page.extract_text() or "") for page in pdf.pages)
    if name.endswith(".docx"):
        import docx
        document = docx.Document(io.BytesIO(raw))
        return "\n".join(p.text for p in document.paragraphs)
    if name.endswith(".xlsx") or name.endswith(".xlsm"):
        import common
        return common._parse_excel(raw)
    return raw.decode("utf-8", errors="ignore")  # fallback: plain text


# ── Document Intelligence: deterministic verify pass over LLM-extracted fields ──
# Production principle (your research, Pillar 1): the LLM only EXTRACTS structured
# values; hard-coded logic DECIDES the critical temporal/numeric gates. The model
# never gets to "creatively" pass an expired cert or under-limit coverage.
def _parse_date(s):
    from datetime import datetime
    if not s:
        return None
    s = str(s).strip()[:10]
    for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%d/%m/%Y", "%d-%m-%Y", "%Y/%m/%d", "%m-%d-%Y"):
        try:
            return datetime.strptime(s, fmt).date()
        except ValueError:
            continue
    return None


# Minimum general-liability coverage for insurance certificates (USD).
_COI_MIN_COVERAGE = 2_000_000


def _doc_intelligence(fields: dict, document_type: str):
    """Deterministic gates over the LLM-extracted fields.
    Returns (key_dates, deterministic_checks, hard_override_verdict|None)."""
    from datetime import date
    fields = fields or {}
    today = date.today()
    key_dates, checks, override = {}, [], None

    # 1) Expiration detection — an expired document can never be Compliant.
    expiry = _parse_date(fields.get("expiry_date"))
    issue = _parse_date(fields.get("issue_date"))
    if issue:
        key_dates["issue_date"] = issue.isoformat()
    if expiry:
        days = (expiry - today).days
        key_dates.update({"expiry_date": expiry.isoformat(),
                          "is_expired": days < 0, "days_to_expiry": days})
        # requirement + found are rendered together as "requirement — found"
        # (see DocAssessQueueable's clauseChecks merge) — keeping the
        # requirement label a plain, neutral statement of what's being
        # checked and putting the actual finding entirely in `found` avoids
        # a redundant/contradictory-reading line like "Document EXPIRED —
        # 2026-06-14 — 2026-06-14 (EXPIRED)". A failed check states the
        # failure outright in found ("EXPIRED as of <date>, N days ago")
        # instead of a bare date the reader has to notice is in the past.
        expired = days < 0
        checks.append({
            "requirement": "Document expiration",
            "found": (f"EXPIRED as of {expiry.isoformat()} ({abs(days)}d ago)" if expired
                      else f"Valid until {expiry.isoformat()} ({days}d remaining)"),
            "pass": not expired
        })
        if days < 0:
            override = "Non-Compliant"

    # 2) Minimum-coverage gate for insurance certificates (COI).
    dt = (document_type or "").lower()
    cov = fields.get("coverage_amount")
    if cov is not None and any(k in dt for k in ("insurance", "coi", "liability")):
        try:
            cov_n = float(str(cov).replace(",", "").replace("$", "").strip())
            ok = cov_n >= _COI_MIN_COVERAGE
            checks.append({"requirement": f"Coverage ≥ ${_COI_MIN_COVERAGE:,.0f}",
                           "found": f"${cov_n:,.0f}", "pass": ok})
            if not ok and override is None:
                override = "Non-Compliant"
        except (TypeError, ValueError):
            pass

    # 3) Identifier presence (e.g., W-9 TIN / certificate number).
    ident = fields.get("identifier")
    if any(k in dt for k in ("w-9", "w9", "tax", "tin")):
        ok = bool(ident and str(ident).strip())
        checks.append({"requirement": "Tax identifier (TIN) present",
                       "found": str(ident) if ident else "missing", "pass": ok})
        if not ok and override is None:
            override = "Needs Analyst"

    # 4) Accreditation/certification SCOPE self-exclusion — a deterministic
    # backstop for the "scope mismatch" failure mode (a CLIA/CAP-style
    # accreditation exists and is valid, but its own stated scope explicitly
    # says a specific discipline/test is NOT covered). Unlike checks 1-3, this
    # doesn't compare against a known target test (the engine has no per-
    # requirement "test being contracted for" field yet) — it catches the
    # document contradicting itself: an extracted scope value that admits
    # exclusion language should never be waved through by an LLM that only
    # noticed "a scope document exists." A real scope document says outright
    # when something isn't covered ("not currently listed", "not included",
    # "undergoing validation for inclusion") — this is presence-of-language
    # detection, not judgment, so it belongs here next to the other hard gates.
    scope_text = fields.get("scope")
    if scope_text and any(k in dt for k in ("scope", "accreditation", "cap", "clia", "certif")):
        exclusion_phrases = (
            "not currently listed", "not included", "not covered", "excluded from",
            "not yet accredited", "not within the current", "undergoing validation",
            "pending accreditation", "outside the accredited scope", "is not accredited",
        )
        hit = next((p for p in exclusion_phrases if p in str(scope_text).lower()), None)
        checks.append({"requirement": "Accredited scope contains no self-excluded discipline",
                       "found": f"scope text flags: \"{hit}\"" if hit else "no exclusion language found",
                       "pass": hit is None})
        if hit and override is None:
            override = "Non-Compliant"

    return key_dates, checks, override


# Keyword groups used to detect a checks_passed bullet that CONTRADICTS a
# failed deterministic gate — e.g. the LLM writes "valid until 2026-06-14" as
# a positive bullet for a document _doc_intelligence has already determined
# is expired. Rule 3 in prompts/document_intelligence.md tells the model not
# to judge expiry/coverage/identifier itself, but instruction-following isn't
# guaranteed — this is the code-level backstop for a compliance product,
# not a substitute for the prompt rule.
_GATE_KEYWORDS = {
    "Document expiration": ("expir", "valid until", "valid to", "validity"),
    "Tax identifier (TIN) present": ("tin", "tax id", "identifier"),
}


def _contradicts_failed_gate(text: str, failed_gates: list) -> bool:
    """True if `text` (a checks_passed bullet or a clause_check's own
    requirement+found text) overlaps a FAILED deterministic gate's subject —
    e.g. any mention of expiry/validity when the expiry gate failed."""
    t_lower = str(text or "").lower()
    for check in failed_gates:
        req = str(check.get("requirement") or "")
        keywords = _GATE_KEYWORDS.get(req)
        if keywords is None:
            # Dynamic requirement text (coverage threshold, scope exclusion)
            # — match on the requirement's own significant words rather than
            # a fixed list.
            keywords = tuple(w for w in req.lower().split() if len(w) > 4)
        if any(k in t_lower for k in keywords):
            return True
    return False


def _reconcile_summary_with_gates(summary: dict, det_checks: list) -> dict:
    """Drop any checks_passed bullet that contradicts a FAILED deterministic
    gate, instead of trusting the model's own framing verbatim. The gate's own
    concern line (added separately from det_checks/clause_checks) is already
    the correct, grounded statement of that fact — no need to also surface
    the model's wrong version, which would just duplicate the same point."""
    checks_passed = list(summary.get("checks_passed") or [])
    failed = [c for c in (det_checks or []) if c.get("pass") is False]
    if not checks_passed or not failed:
        return summary

    summary["checks_passed"] = [
        b for b in checks_passed if not _contradicts_failed_gate(b, failed)
    ]
    return summary


def _reconcile_clause_checks_with_gates(model_clause_checks: list, det_checks: list) -> list:
    """Same reconciliation as _reconcile_summary_with_gates, but for the
    LLM's OWN clause_checks array (structured {requirement, found, pass}
    entries the model returns alongside summary.checks_passed) — a separate
    list with the exact same failure mode: the model can mark its own
    clause check pass:true for a requirement a deterministic gate has
    already determined fails (e.g. "Active status and valid expiration
    date" — pass:true — for a document _doc_intelligence found expired).
    Flips the contradicting entry to pass:false rather than dropping it, so
    the reader still sees the model raised the topic, just corrected."""
    failed = [c for c in (det_checks or []) if c.get("pass") is False]
    if not model_clause_checks or not failed:
        return model_clause_checks or []

    reconciled = []
    for check in model_clause_checks:
        if not isinstance(check, dict):
            reconciled.append(check)
            continue
        text = str(check.get("requirement") or "") + " " + str(check.get("found") or "")
        if check.get("pass") is True and _contradicts_failed_gate(text, failed):
            check = dict(check)
            check["pass"] = False
            check["found"] = (str(check.get("found") or "")
                               + " — contradicted by a failed policy check").strip(" —")
        reconciled.append(check)
    return reconciled


def judge_compliance(domain, document_type, doc_text, clauses):
    """
    Ask the LLM to judge the document against the retrieved policy clauses.
    Returns verdict/severity/confidence/reasons/citations. Abstains ("Needs
    Analyst") when no OPENAI_API_KEY is configured.
    """
    import governance

    if not llm.is_configured():
        return {
            "verdict": "Needs Analyst",
            "severity": "Medium",
            "confidence": 0,
            "reasons": f"No LLM configured (provider '{settings.LLM_PROVIDER}') — routed to analyst.",
            "citations": [c["clauseId"] for c in clauses],
        }

    policy_block = "\n\n".join(
        f"[{c['clauseId']} | domain={c['domain']}]\n{c['text']}" for c in clauses
    )
    import prompts
    import fewshot
    system = prompts.load("document_intelligence")  # SOP in prompts/document_intelligence.md
    task = (
        f"DOMAIN: {domain or 'general'}\n"
        f"DOCUMENT TYPE: {document_type or 'unspecified'}\n\n"
        f"POLICY CLAUSES:\n{policy_block or '(none retrieved)'}\n\n"
        "Judge the SUPPLIER DOCUMENT below against these clauses."
        + fewshot.block("document_intelligence")   # learning loop: analyst-override examples
    )

    # Centralized governance: PII tokenization + injection scan + untrusted
    # framing all happen inside governed_judge — every LLM call over external
    # content is governed the same way.
    try:
        # Explicit budget: the schema asks for a lot (summary + extracted_fields
        # + clause_checks all in one response) — without a cap, a provider that
        # defaults conservatively can truncate mid-object, and models under
        # implicit length pressure were observed deprioritizing summary (the
        # most synthesis-heavy field) in favor of the more mechanical
        # extracted_fields/clause_checks — producing exactly the "field dump,
        # no judgment" summaries this was fixed for. 1500 comfortably covers a
        # full response (5 checks_passed + 4 concerns + 6 key_facts + 12
        # extracted fields + reasons) with headroom, not a hard squeeze.
        result = governance.governed_judge(system, task, doc_text, max_tokens=1500)
    except llm.LLMUnavailable:
        return {
            "verdict": "Needs Analyst", "severity": "Medium", "confidence": 0,
            "reasons": f"LLM provider '{settings.LLM_PROVIDER}' not configured — routed to analyst.",
            "citations": [c["clauseId"] for c in clauses],
        }
    except Exception as e:
        # Reliability: any provider/parse failure degrades to a human gate.
        return {
            "verdict": "Needs Analyst", "severity": "Medium", "confidence": 0,
            "reasons": f"LLM error — routed to analyst: {e}",
            "citations": [c["clauseId"] for c in clauses],
        }

    data = result["data"]
    injection_flags = result["governance"]["injection_flags"]

    verdict = data.get("verdict") if data.get("verdict") in VALID_VERDICTS else "Needs Analyst"
    severity = data.get("severity") if data.get("severity") in VALID_SEVERITY else "Medium"
    try:
        confidence = max(0, min(100, int(data.get("confidence", 0))))
    except (TypeError, ValueError):
        confidence = 0
    reasons = (data.get("reasons") or "")[:600]
    # Fail-safe: a document that tried to manipulate the model must never auto-pass.
    if injection_flags and verdict == "Compliant":
        verdict = "Needs Analyst"
        reasons = ("[Prompt-injection suspected -> routed to analyst] " + reasons)[:600]

    # Document Intelligence: deterministic gates over the extracted fields.
    extracted_fields = data.get("extracted_fields") or {}
    key_dates, det_checks, hard_override = _doc_intelligence(extracted_fields, document_type)
    # Reconcile the MODEL's own clause_checks against the deterministic gates
    # before merging — det_checks themselves are already correct by
    # construction and never need reconciling against each other.
    model_clause_checks = _reconcile_clause_checks_with_gates(data.get("clause_checks"), det_checks)
    clause_checks = model_clause_checks + det_checks
    # Hard rule wins over an LLM "Compliant": expired / under-limit / missing TIN.
    if hard_override and verdict == "Compliant":
        verdict = hard_override
        reasons = ("[Deterministic gate failed — see clause checks] " + reasons)[:600]

    # Structured summary (headline + key facts + concerns). If the model didn't
    # supply one, synthesize it from the extracted fields so the UI always gets a
    # field-grounded summary instead of bare prose.
    summary = data.get("summary") or {}
    if not summary.get("headline"):
        summary = _synth_summary(verdict, document_type, extracted_fields, reasons)
    summary["key_facts"] = _fields_to_facts(extracted_fields, summary.get("key_facts"))
    # Reconcile against ALL failed deterministic gates (not just the one that
    # triggered a hard override, if any) — a model bullet can contradict a
    # failed gate even when a different failure already drove the verdict.
    summary = _reconcile_summary_with_gates(summary, det_checks)

    return {
        "verdict": verdict,
        "severity": severity,
        "confidence": confidence,
        "reasons": reasons,
        "summary": summary,
        "citations": data.get("citations") or [c["clauseId"] for c in clauses],
        "injectionFlags": injection_flags,
        "extractedFields": extracted_fields,
        "keyDates": key_dates,
        "clauseChecks": clause_checks,
    }


def _fields_to_facts(fields: dict, existing) -> list:
    """Turn extracted fields into 'Label: value' fact strings. Uses the model's
    key_facts if it supplied them, else derives from the fields."""
    if isinstance(existing, list) and existing:
        return [str(f) for f in existing][:6]
    fields = fields or {}
    label_map = [
        ("issuer", "Issuer"), ("subject_company", "Subject"),
        ("identifier", "Identifier"), ("policy_number", "Policy #"),
        ("registration_number", "Registration #"),
        ("coverage_amount", "Coverage"), ("issue_date", "Issued"),
        ("expiry_date", "Valid until"), ("scope", "Scope"),
        ("jurisdiction", "Jurisdiction"), ("signatory", "Signatory"),
    ]
    facts = []
    for key, label in label_map:
        val = fields.get(key)
        if val in (None, "", "null"):
            continue
        if key == "coverage_amount":
            try:
                cur = fields.get("currency") or "$"
                val = f"{cur}{float(str(val).replace(',','').replace('$','')):,.0f}"
            except (TypeError, ValueError):
                pass
        facts.append(f"{label}: {val}")
        if len(facts) >= 6:
            break
    return facts


def _synth_summary(verdict, document_type, fields, reasons) -> dict:
    """Build a field-grounded structured summary when the model omitted one."""
    facts = _fields_to_facts(fields, None)
    head = (document_type or (fields or {}).get("document_type") or "Document")
    issuer = (fields or {}).get("issuer")
    head_parts = [head]
    if issuer:
        head_parts.append(f"from {issuer}")
    head_parts.append(f"— {verdict}.")
    # Fallback checks_passed: without the model's own reasoning we can only
    # state what was mechanically confirmed present — still better than an
    # empty "what checks out" section on a synthesized summary.
    checks_passed = [f"{label.split(': ')[0]} on file" for label in facts[:3]] if verdict != "Needs Analyst" else []
    return {"headline": " ".join(head_parts),
            "key_facts": facts,
            "checks_passed": checks_passed,
            "concerns": [] if verdict == "Compliant" else [reasons[:120]] if reasons else []}


@app.post("/assess")
def assess(req: AssessRequest, authorization: Optional[str] = Header(None)):
    require_token(authorization)

    doc_text = extract_document_text(req)

    # Resolve the policy domain: caller-supplied wins; otherwise infer it from the
    # document text so Salesforce can always route the verdict to the right
    # requirement (and the RAG service owns domain classification).
    resolved_domain = req.domain or (guess_domain(doc_text) if doc_text else "general")

    # Retrieve the policy clauses most relevant to this document + domain.
    # industry_key() translates Salesforce's raw picklist label into the
    # ingested corpus tag — see resolve_corpus_industry's docstring. Without
    # this, req.industry ("Pharmaceutical", "Clinical / Diagnostic Lab", ...)
    # never matches any ingested chunk's industry='healthcare' tag, silently
    # falling back to unfiltered retrieval across every industry's corpus.
    query = " ".join(filter(None, [resolved_domain, req.documentType, doc_text[:1500]])) \
        or (req.documentType or resolved_domain)
    clauses = retrieve(query, k=6, industry=industry_key(req.industry)) if query else []

    result = judge_compliance(resolved_domain, req.documentType, doc_text, clauses)

    # Stage-03b: validate the extracted document against its issuing registry
    # (live API where one exists, else manual_required → human gate).
    import registry
    registry_validation = registry.validate(
        req.documentType, resolved_domain, result.get("extractedFields", {}))

    return {
        "supplierId": req.supplierId,
        "requirementKey": req.requirementKey,
        "domain": resolved_domain,
        "verdict": result["verdict"],
        "severity": result["severity"],
        "confidence": result["confidence"],
        "reasons": result["reasons"],
        "summary": result.get("summary", {}),
        "citations": result["citations"],
        "extractedFields": result.get("extractedFields", {}),
        "keyDates": result.get("keyDates", {}),
        "clauseChecks": result.get("clauseChecks", []),
        "registryValidation": registry_validation,
        "evidence": [
            {"clauseId": c["clauseId"], "domain": c["domain"], "score": c["score"]}
            for c in clauses
        ],
        "model": llm.active_model(),
        "corpusVersion": settings.CORPUS_VERSION,
        "extractionChars": len(doc_text),
    }


# ═══════════════════════════════════════════════════════════════════════════
# Case orchestration (LangGraph) — wraps /scope and /assess as agent nodes
# ═══════════════════════════════════════════════════════════════════════════
import uuid
import orchestrator


def scope_supplier(supplier: dict) -> dict:
    """Intake/Scope agent: run the /scope logic for a case supplier dict."""
    req = ScopeRequest(
        supplierId=str(supplier.get("supplierId", "CASE")),
        legalName=supplier.get("legalName", ""),
        country=supplier.get("country"),
        commodity=supplier.get("commodity"),
        jurisdictions=supplier.get("jurisdictions") or [],
        industry=supplier.get("industry"),
    )
    query = " ".join(filter(None, [req.legalName, req.commodity, req.country,
                                   " ".join(req.jurisdictions)]))
    corpus_industry = resolve_corpus_industry(req.industry, req.commodity)
    hits = retrieve(query, k=8, industry=corpus_industry)
    tier, summary, reasons = assess_risk(req, hits)
    checklist = build_checklist(hits, industry=corpus_industry)
    domains = sorted({h["domain"] for h in hits})
    return {"riskTier": tier, "riskSummary": summary, "riskReasons": reasons,
            "checklist": checklist, "scope": domains}


def assess_document(doc: dict) -> dict:
    """Document/Risk agent: run the /assess logic for a case document dict."""
    req = AssessRequest(
        supplierId=str(doc.get("supplierId", "CASE")),
        domain=doc.get("domain"),
        documentType=doc.get("documentType"),
        documentText=doc.get("documentText"),
        documentBase64=doc.get("documentBase64"),
        fileName=doc.get("fileName"),
        industry=doc.get("industry"),
    )
    doc_text = extract_document_text(req)
    resolved_domain = req.domain or (guess_domain(doc_text) if doc_text else "general")
    query = " ".join(filter(None, [resolved_domain, req.documentType, doc_text[:1500]])) \
        or (req.documentType or resolved_domain)
    clauses = retrieve(query, k=6, industry=industry_key(req.industry)) if query else []
    r = judge_compliance(resolved_domain, req.documentType, doc_text, clauses)
    return {"domain": resolved_domain, "documentType": req.documentType,
            "verdict": r["verdict"], "severity": r["severity"],
            "confidence": r["confidence"], "reasons": r["reasons"],
            "citations": r["citations"]}


orchestrator.set_agents(scope_supplier, assess_document)

# ── Durable case state in Postgres (survives restarts) + human gate ─────────
from langgraph.checkpoint.postgres import PostgresSaver
from psycopg_pool import ConnectionPool

_pool = ConnectionPool(
    conninfo=os.environ["DB_URL"], max_size=10, open=True,
    kwargs={"autocommit": True, "prepare_threshold": 0},
)
_checkpointer = PostgresSaver(_pool)
_checkpointer.setup()  # idempotent: creates checkpoint tables on first boot

compliance_graph = orchestrator.build_graph(
    checkpointer=_checkpointer,
    interrupt_before=["screening"],   # GATE 1 (Stage 01): procurement confirms scope
)


class CaseRequest(BaseModel):
    supplier: dict
    documents: List[dict] = []


def _case_view(case_id: str, state: dict) -> dict:
    """Normalized, UI-facing case view (progress rail + per-step agent reports +
    live audit timeline + recommended next action). The raw `state` is still
    included under `state` for callers that need it (tests / debugging)."""
    snap = compliance_graph.get_state({"configurable": {"thread_id": case_id}})
    next_stages = list(snap.next)
    awaiting = bool(snap.next)
    # GATE 2 is a conditional stop (status ROUTED, no decision) — not an interrupt,
    # so snap.next is empty there. Treat it as awaiting the human decision.
    if state.get("status") == "ROUTED" and not (state.get("decision") or {}).get("verdict"):
        awaiting = True
        next_stages = ["decision"]
    view = orchestrator.case_report(case_id, state, awaiting_gate=awaiting,
                                    next_stages=next_stages)
    view["state"] = state   # raw blackboard, for backward-compatible callers
    return view


@app.get("/agents")
def list_agents(authorization: Optional[str] = Header(None)):
    """The agent registry (the 'club of agents') — for observability / the UI
    to label the timeline and progress rail consistently with the engine."""
    require_token(authorization)
    return {"agents": orchestrator.agent_registry()}


@app.post("/cases")
def create_case(req: CaseRequest, authorization: Optional[str] = Header(None)):
    require_token(authorization)
    case_id = str(uuid.uuid4())
    config = {"configurable": {"thread_id": case_id}}
    initial = {"case_id": case_id, "supplier": req.supplier,
               "documents": req.documents, "audit": []}
    state = compliance_graph.invoke(initial, config)  # runs intake, then pauses at the gate
    return _case_view(case_id, state)


@app.get("/cases/{case_id}")
def get_case(case_id: str, authorization: Optional[str] = Header(None)):
    require_token(authorization)
    snap = compliance_graph.get_state({"configurable": {"thread_id": case_id}})
    if not snap or not snap.values:
        raise HTTPException(status_code=404, detail="case not found")
    return _case_view(case_id, snap.values)


class ResumeRequest(BaseModel):
    # Optional human decision injected at GATE 2 (analyst sign-off).
    decision: Optional[dict] = None     # {verdict: approved|rejected|needs_info, by, note}
    # Oversight level for THIS case. 'auto' lets a clean, low-risk case clear Gate 2
    # without a human; 'partial'/'full' always require analyst sign-off. Mirrors the
    # HITL slider (the supervisor's authority dial).
    oversight: Optional[str] = "full"   # auto | partial | full


@app.post("/cases/{case_id}/resume")
def resume_case(case_id: str, req: ResumeRequest = ResumeRequest(),
                authorization: Optional[str] = Header(None)):
    """Advance the case to the NEXT human gate, or finalize it.

    GATE 2 is a conditional edge after `routing` (see orchestrator.build_graph):
    the case STOPS at status ROUTED until a decision is injected. So:
      • Paused at GATE 1 (before screening) → confirm scope: run screening→…→routing.
        The case then HOLDS at ROUTED for analyst sign-off — UNLESS oversight=='auto'
        and the case is clean, in which case we auto-approve.
      • Held at ROUTED:
          - `decision` supplied → inject it, run the decision node, finalize.
          - else oversight=='auto' AND clean → auto-approve.
          - else → keep holding.
    """
    require_token(authorization)
    config = {"configurable": {"thread_id": case_id}}
    snap = compliance_graph.get_state(config)
    if not snap or not snap.values:
        raise HTTPException(status_code=404, detail="case not found")

    def _finalize_with(decision: dict):
        compliance_graph.update_state(config, {"decision": decision})
        return compliance_graph.invoke(None, config)   # routing→decision→END

    vals = snap.values
    at_gate2 = vals.get("status") == "ROUTED" and not (vals.get("decision") or {}).get("verdict")

    # ── Held at GATE 2 (ROUTED, no decision) ────────────────────────────────
    if at_gate2:
        if req.decision:
            return _case_view(case_id, _finalize_with(req.decision))
        if (req.oversight or "full").lower() == "auto" and not orchestrator._case_is_flagged(vals):
            return _case_view(case_id, _finalize_with(
                {"verdict": "approved", "by": "auto (oversight: auto-clear)"}))
        return _case_view(case_id, vals)               # hold for analyst

    # ── At GATE 1 (before screening): confirm scope → run to routing ─────────
    state = compliance_graph.invoke(None, config)      # screening→…→routing (stops via cond. edge)
    snap2 = compliance_graph.get_state(config)
    v2 = snap2.values
    if v2.get("status") == "ROUTED" and not (v2.get("decision") or {}).get("verdict"):
        if (req.oversight or "full").lower() == "auto" and not orchestrator._case_is_flagged(v2):
            return _case_view(case_id, _finalize_with(
                {"verdict": "approved", "by": "auto (oversight: auto-clear)"}))
        return _case_view(case_id, v2)                 # hold for analyst sign-off
    return _case_view(case_id, state)
