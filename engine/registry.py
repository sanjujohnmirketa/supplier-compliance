"""
registry.py — authoritative-registry document validation (Stage-03b).

After Document Intelligence extracts a certificate's fields, validate the
document against the ISSUING BODY's registry:

  • Sources that expose a real API are checked LIVE (e.g. GLEIF for legal-entity
    / registration documents — free, no key).
  • Sources WITHOUT a public API (IATF, ISO certification bodies, insurers, tax
    authorities) return 'manual_required' — routed to an analyst, never auto-passed.
  • A document whose issuing body isn't configured returns 'not_configured' and
    also routes to the human gate (the locked architecture decision).

This is a pluggable framework: a deployment that HAS an API for one of the
manual sources just sets method='api' + a validator — no caller change.
"""
import os
import requests
from screening import gleif_lookup

# Each source declares its issuing authority and whether we can call it.
# method 'api'  → we validate live (validator set below)
# method 'manual' → real registry exists but has no callable public API → analyst
#   verifies on the named portal. (Feasibility audited 2026-06: of the governing
#   bodies in the compliance corpus, only GLEIF and Trade.gov CSL expose a free,
#   automatable API. The rest are login/registration-gated or paid, so they are
#   correctly routed to the human gate — never auto-passed.)
_SOURCES = {
    # ── Live API sources ──────────────────────────────────────────────────────
    "entity":     {"authority": "GLEIF (Global LEI Index)",                 "method": "api"},
    "sanctions":  {"authority": "US Trade.gov Consolidated Screening List (OFAC SDN + BIS)", "method": "api"},

    # ── Quality & manufacturing (no public API → manual) ──────────────────────
    "iatf":       {"authority": "IATF Certificate Validity Check (iatfglobaloversight.org)", "method": "manual"},
    "iso":        {"authority": "IAF CertSearch — accredited registrar (iafcertsearch.org)", "method": "manual"},
    "as9100":     {"authority": "SAE OASIS aerospace supplier database",     "method": "manual"},
    "ppap":       {"authority": "AIAG PPAP — internal engineering review",   "method": "manual"},

    # ── Conflict minerals ─────────────────────────────────────────────────────
    "conflict":   {"authority": "RMI Conformant Smelter List (CID cross-reference)", "method": "manual"},

    # ── Material & environment ────────────────────────────────────────────────
    "reach":      {"authority": "ECHA SVHC Candidate List",                  "method": "manual"},
    "rohs":       {"authority": "EU Science Hub RoHS Directive Portal",      "method": "manual"},
    "imds":       {"authority": "International Material Data System (IMDS)",  "method": "manual"},
    "sds":        {"authority": "EPA Substance Registry Services / OSHA GHS","method": "manual"},
    "emissions":  {"authority": "EPA Federal Test Group / CARB Executive Orders", "method": "manual"},

    # ── Cybersecurity & data protection ───────────────────────────────────────
    "tisax":      {"authority": "ENX TISAX portal (registered participants)","method": "manual"},
    "soc2":       {"authority": "AICPA CPA directory (signing firm licensure)", "method": "manual"},
    "cmmc":       {"authority": "DoD SPRS / Cyber AB Marketplace",           "method": "manual"},

    # ── Trade & regulatory (export control = manual; sanctions = live above) ──
    "export":     {"authority": "BIS Commerce Control List / DDTC (ITAR/USML)", "method": "manual"},

    # ── Finance ───────────────────────────────────────────────────────────────
    "tax":        {"authority": "IRS TIN Matching System",                  "method": "manual"},
    "financial":  {"authority": "RapidRatings Financial Health Rating",      "method": "manual"},
    "banking":    {"authority": "Bank account ownership validation network", "method": "manual"},

    # ── General ───────────────────────────────────────────────────────────────
    "insurance":  {"authority": "Insurer / broker direct verification",     "method": "manual"},
    "license":    {"authority": "Corporate registry (Secretary of State / Companies House)", "method": "manual"},
}

# Keyword → source key. First match on the document type / domain wins.
# Order matters: more specific patterns before broad ones.
_ROUTES = [
    ("sanctions", ("sanction", "denied party", "watchlist", "ofac", "sdn", "screening list", "csl")),
    ("export",    ("eccn", "usml", "itar", "export control", "ccl", "ddtc")),
    ("iatf",      ("iatf", "16949")),
    ("as9100",    ("as9100", "as 9100", "oasis", "aerospace")),
    ("ppap",      ("ppap", "production part approval")),
    ("iso",       ("iso ", "iso9001", "iso 9001", "iso27001", "iso 27001", "iso14001", "iso 14001")),
    ("reach",     ("reach", "svhc", "candidate list")),
    ("rohs",      ("rohs", "restricted substance", "rohs exemption")),
    ("imds",      ("imds", "material data system", "material datasheet")),
    ("sds",       ("sds", "msds", "safety data sheet", "ghs")),
    ("emissions", ("epa", "carb", "emissions", "powertrain", "federal test group")),
    ("tisax",     ("tisax", "enx")),
    ("soc2",      ("soc 2", "soc2", "soc ii", "aicpa")),
    ("cmmc",      ("cmmc", "nist 800-171", "nist sp 800-171", "sprs")),
    ("conflict",  ("conflict", "smelter", "rmi", "cmrt", "emrt", "3tg", "cobalt", "cid")),
    ("tax",       ("w-9", "w9", "w-8", "w8", "tin", "taxpayer")),
    ("financial", ("rapidratings", "financial health", "audited financial", "fhr")),
    ("banking",   ("ach", "banking", "voided check", "eft", "bank verification")),
    ("insurance", ("insurance", "coi", "liability", "certificate of insurance")),
    ("license",   ("business license", "good standing", "registration certificate", "companies house")),
    ("entity",    ("registration", "incorporation", "lei", "commercial register",
                   "company registry", "kyc", "beneficial owner",
                   "ownership", "governance")),
]

# Free, deployer-supplied key for the Trade.gov Consolidated Screening List.
# Empty by default — nothing bundled. When unset, 'sanctions' degrades to manual.
CSL_API_KEY = os.getenv("CSL_API_KEY", "")
CSL_URL = "https://api.trade.gov/consolidated_screening_list/v1/search"


import re

def _route(document_type: str, domain: str) -> str:
    hay = f"{document_type or ''} {domain or ''}".lower()
    for source_key, needles in _ROUTES:
        for n in needles:
            # Word-boundary match for short/ambiguous tokens (e.g. 'tin' must not
            # match inside 'rapidratings'); substring match for multi-word phrases.
            if len(n) <= 4 and " " not in n:
                if re.search(r"\b" + re.escape(n) + r"\b", hay):
                    return source_key
            elif n in hay:
                return source_key
    return ""


def validate(document_type: str, domain: str, fields: dict) -> dict:
    """
    Validate an extracted document against its issuing registry.
    Returns {source, authority, method, status, detail} where status is one of
    verified | not_found | manual_required | not_configured | error.
    """
    fields = fields or {}
    subject = fields.get("subject_company") or fields.get("issuer")
    identifier = fields.get("identifier")

    source_key = _route(document_type, domain)
    if not source_key:
        return {"source": None, "authority": "(none configured)", "method": "manual",
                "status": "not_configured",
                "detail": "No registry configured for this document — routed to analyst."}

    src = _SOURCES[source_key]
    authority = src["authority"]

    if src["method"] != "api":
        return {"source": source_key, "authority": authority, "method": "manual",
                "status": "manual_required",
                "detail": f"{authority} has no public API — analyst verifies "
                          f"{('id ' + str(identifier)) if identifier else 'the certificate'} on the portal."}

    # ── Live API validators ──────────────────────────────────────────────────
    if source_key == "entity":
        if not subject:
            return {"source": source_key, "authority": authority, "method": "api",
                    "status": "manual_required",
                    "detail": "No entity name extracted — analyst verifies."}
        g = gleif_lookup(subject, fields.get("country"))
        matches = g.get("matches", [])
        active = [m for m in matches if (m.get("status") or "").upper() == "ISSUED"]
        if active:
            m = active[0]
            return {"source": source_key, "authority": authority, "method": "api",
                    "status": "verified",
                    "detail": f"GLEIF ISSUED — LEI {m.get('lei')} ({m.get('legalName')})"}
        if matches:
            m = matches[0]
            return {"source": source_key, "authority": authority, "method": "api",
                    "status": "not_found",
                    "detail": f"GLEIF match found but status {m.get('status')} — analyst review."}
        return {"source": source_key, "authority": authority, "method": "api",
                "status": "not_found",
                "detail": "No GLEIF record matched the extracted entity — analyst review."}

    if source_key == "sanctions":
        return _validate_csl(subject or fields.get("legal_name"), fields.get("country"), authority)

    return {"source": source_key, "authority": authority, "method": "manual",
            "status": "manual_required", "detail": "Analyst verification required."}


def _validate_csl(name: str, country: str, authority: str) -> dict:
    """Live screen against the US Trade.gov Consolidated Screening List (OFAC
    SDN + BIS Entity/Denied lists). Free, but needs a deployer-supplied key
    (CSL_API_KEY via api.data.gov). Without a key it degrades to manual."""
    if not name:
        return {"source": "sanctions", "authority": authority, "method": "api",
                "status": "manual_required", "detail": "No entity name extracted — analyst screens."}
    if not CSL_API_KEY:
        return {"source": "sanctions", "authority": authority, "method": "manual",
                "status": "manual_required",
                "detail": "CSL_API_KEY not configured — analyst screens on trade.gov. "
                          "(Set a free api.data.gov key to enable live screening.)"}
    try:
        resp = requests.get(
            CSL_URL,
            params={"name": name, "fuzzy_name": "true"},
            headers={"subscription-key": CSL_API_KEY},
            timeout=10,
        )
        if resp.status_code != 200:
            return {"source": "sanctions", "authority": authority, "method": "api",
                    "status": "manual_required",
                    "detail": f"CSL returned HTTP {resp.status_code} — analyst screens."}
        data = resp.json()
        total = data.get("total", 0)
        if total and total > 0:
            top = (data.get("results") or [{}])[0]
            who = top.get("name", "a listed party")
            src = top.get("source", "CSL")
            return {"source": "sanctions", "authority": authority, "method": "api",
                    "status": "flag",
                    "detail": f"CSL match ({total}) — e.g. '{who}' on {src}. Analyst must adjudicate."}
        return {"source": "sanctions", "authority": authority, "method": "api",
                "status": "verified",
                "detail": "No match on the Consolidated Screening List (OFAC/BIS)."}
    except Exception as e:
        return {"source": "sanctions", "authority": authority, "method": "api",
                "status": "manual_required",
                "detail": f"CSL screen failed ({type(e).__name__}) — analyst screens."}
