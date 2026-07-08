"""
screening.py — Stage-02 screening sub-agents.

  gleif_lookup(name)    — GLEIF LEI verification (free, no key): confirms the legal
                          entity exists + registration status.
  sanctions_screen(name)— OFAC/EU/UK + PEP screening via OpenSanctions if
                          OPENSANCTIONS_API_KEY is set; otherwise a small DEMO
                          watchlist so the hit-path is demoable offline.

Deterministic list matching. Every hit carries its source. No automated adverse
action — screening only flags; the human gate decides.
"""
import requests
from config import settings
from reliability import with_retry

GLEIF_URL = "https://api.gleif.org/api/v1/lei-records"
OPENSANCTIONS_URL = "https://api.opensanctions.org/match/default"
# Free, zero-auth sanctions API (OFAC SDN + UN + EU). No key, no self-hosting.
# Used as the DEFAULT provider so we don't hit OpenSanctions' rate-limited free
# tier (429). PostgREST RPC: /rpc/search_sanctions?name=<query>.
SANCTIONS_NETWORK_URL = "https://api.sanctions.network/rpc/search_sanctions"

# Offline demo watchlist (clearly fake) — used only when no OpenSanctions key is set.
_DEMO_WATCHLIST = [
    {"name": "evil corp", "list": "DEMO-OFAC-SDN", "topic": "sanction"},
    {"name": "specially designated test entity", "list": "DEMO-OFAC-SDN", "topic": "sanction"},
    {"name": "boreal sanctioned holdings", "list": "DEMO-EU-CONSOLIDATED", "topic": "sanction"},
]


def gleif_lookup(legal_name: str, country: str = None) -> dict:
    if not legal_name:
        return {"matches": [], "status": "no_name"}
    try:
        def _call():
            resp = requests.get(GLEIF_URL,
                                params={"filter[fulltext]": legal_name, "page[size]": 5},
                                timeout=15)
            resp.raise_for_status()
            return resp
        r = with_retry(_call)
        out = []
        for rec in r.json().get("data", []):
            a = rec.get("attributes", {})
            ent = a.get("entity", {})
            out.append({
                "lei": a.get("lei"),
                "legalName": (ent.get("legalName") or {}).get("name"),
                "status": (a.get("registration") or {}).get("status"),
                "country": (ent.get("legalAddress") or {}).get("country"),
            })
        return {"matches": out, "status": "ok" if out else "no_match"}
    except Exception as e:
        return {"matches": [], "status": f"error: {e}"}


def sanctions_screen(name: str) -> dict:
    """OFAC/UN/EU sanctions screening. Provider order:
       1. OpenSanctions (only if OPENSANCTIONS_API_KEY is set — paid/rate-limited)
       2. sanctions.network — FREE, zero-auth (default; avoids the 429)
       3. Offline demo watchlist (last resort).
    A provider error returns status 'error: ...' so the caller routes to an
    analyst rather than implying 'Clear'."""
    if not name:
        return {"hits": [], "status": "no_name"}

    # 1. OpenSanctions only when a key is explicitly configured.
    if settings.OPENSANCTIONS_API_KEY:
        r = _screen_opensanctions(name, settings.OPENSANCTIONS_API_KEY)
        if not str(r.get("status", "")).startswith("error"):
            return r
        # fall through to the free provider on error (e.g. 429)

    # 2. Free sanctions.network (default — no key, no self-hosting).
    r = _screen_sanctions_network(name)
    if not str(r.get("status", "")).startswith("error"):
        return r

    # 3. Offline demo fallback.
    low = name.lower()
    hits = [
        {"name": w["name"], "score": 0.95, "source": w["list"], "topic": w["topic"]}
        for w in _DEMO_WATCHLIST
        if w["name"] in low or low in w["name"]
    ]
    return {"hits": hits, "status": "demo_fallback",
            "note": "live providers unavailable — demo watchlist used"}


def _screen_opensanctions(name: str, api_key: str) -> dict:
    try:
        def _call():
            resp = requests.post(
                OPENSANCTIONS_URL,
                headers={"Authorization": f"ApiKey {api_key}", "Content-Type": "application/json"},
                json={"queries": {"q1": {"schema": "Company", "properties": {"name": [name]}}}},
                timeout=20,
            )
            resp.raise_for_status()
            return resp
        r = with_retry(_call)
        results = r.json().get("responses", {}).get("q1", {}).get("results", [])
        hits = [{
            "name": res.get("caption"),
            "score": res.get("score"),
            "source": res.get("datasets"),
            "topic": (res.get("properties", {}) or {}).get("topics"),
            "id": res.get("id"),
        } for res in results if (res.get("score") or 0) >= 0.7]
        return {"hits": hits, "status": "ok"}
    except Exception as e:
        return {"hits": [], "status": f"error: {e}"}


def _norm_name(s: str) -> set:
    """Significant tokens of a name (drop punctuation + common corporate suffixes)
    for overlap scoring."""
    import re
    stop = {"the", "and", "co", "company", "corp", "corporation", "inc", "ltd",
            "llc", "gmbh", "ag", "sa", "oy", "ab", "bv", "plc", "group", "holdings",
            "international", "global", "industries", "industrial", "manufacturing",
            "precision", "systems", "solutions", "services", "technologies", "tech"}
    toks = re.findall(r"[a-z0-9]+", (s or "").lower())
    return {t for t in toks if t not in stop and len(t) > 1}


def _name_match_score(query: str, candidate_aliases: list) -> float:
    """Best Jaccard-style token overlap between the query name and any alias.
    1.0 = all significant query tokens present in an alias; 0 = no overlap."""
    q = _norm_name(query)
    if not q:
        return 0.0
    best = 0.0
    for alias in (candidate_aliases or []):
        c = _norm_name(alias)
        if not c:
            continue
        overlap = len(q & c)
        if not overlap:
            continue
        # Coverage of the QUERY's significant tokens (so "Nordwind Electronics" only
        # truly matches an entry that actually contains "nordwind").
        score = overlap / len(q)
        best = max(best, score)
    return best


# A real hit needs strong name coverage; weaker overlaps are "review", not "flag".
SANCTIONS_HIT_THRESHOLD = 0.75      # ≥ this → treat as a sanctions hit (flag)
SANCTIONS_REVIEW_THRESHOLD = 0.40   # in [review, hit) → potential, needs review


def _screen_sanctions_network(name: str) -> dict:
    """Query the free sanctions.network API (OFAC SDN + UN + EU). Zero-auth.
    PostgREST RPC search_sanctions(name) returns rows whose `names` array (loose
    token match) — so we MUST re-score each record against the query name and
    keep only strong matches as hits, else every multi-word supplier flags."""
    try:
        def _call():
            resp = requests.get(SANCTIONS_NETWORK_URL, params={"name": name}, timeout=15)
            resp.raise_for_status()
            return resp
        r = with_retry(_call)
        records = r.json()
        if not isinstance(records, list):
            records = records.get("results", records.get("data", [])) or []
        hits, reviews = [], []
        for rec in records:
            aliases = rec.get("names") or ([rec.get("name")] if rec.get("name") else [])
            score = _name_match_score(name, aliases)
            display = aliases[0] if aliases else (rec.get("name") or "")
            entry = {
                "name": display,
                "aliases": aliases[:5],
                "score": round(score, 2),
                "source": (rec.get("source") or "sanctions.network").upper(),
                "sourceId": rec.get("source_id"),
                "topic": rec.get("target_type") or "sanction",
                "id": rec.get("id"),
            }
            if score >= SANCTIONS_HIT_THRESHOLD:
                hits.append(entry)
            elif score >= SANCTIONS_REVIEW_THRESHOLD:
                reviews.append(entry)
        # Strong matches → hits (flag). Weaker → potential matches (review), surfaced
        # but NOT auto-flagged. No strong/weak match at all → clean.
        return {"hits": hits, "potential": reviews[:10],
                "status": "ok_free",
                "checked": len(records)}
    except Exception as e:
        return {"hits": [], "status": f"error: {e}"}


def disambiguate(supplier: dict, gleif: dict, sanctions: dict) -> dict:
    """
    LLM disambiguation: pick the TRUE GLEIF entity (prefer ISSUED/active that
    matches name+country) and judge each sanctions hit as a real match vs a
    false positive. Provider-agnostic via llm.py. Degrades deterministically
    (flag-if-any-hit) when no LLM is configured.

    NOTE: entity NAMES are the signal here, so PII is intentionally NOT tokenized
    (that is the one screening exception); injection framing is still applied.
    """
    import json as _json
    import llm
    import prompts

    name = supplier.get("legalName", "")
    has_hits = bool(sanctions.get("hits"))
    has_matches = bool(gleif.get("matches"))

    if not llm.is_configured():
        return {"status": "skipped_no_llm",
                "recommended_signal": "flag" if has_hits else "clear",
                "best_lei": None}

    # Nothing to disambiguate (no GLEIF candidates, no sanctions hits) → skip the
    # LLM call entirely. Saves a round-trip on clean entities.
    if not has_matches and not has_hits:
        return {"status": "ok", "recommended_signal": "clear", "best_lei": None,
                "best_lei_status": None, "sanctions_assessment": [], "confidence": 90}

    ctx = {
        "supplier": {"legalName": name, "country": supplier.get("country"),
                     "commodity": supplier.get("commodity")},
        "gleif_candidates": gleif.get("matches", []),
        "sanctions_hits": sanctions.get("hits", []),
    }
    system = prompts.load("disambiguation")  # SOP in prompts/disambiguation.md
    user = "UNTRUSTED ENTITY DATA:\n" + _json.dumps(ctx)[:6000]
    try:
        # Narrow classification task → fast model + capped output (latency win).
        data = llm.chat_json(system, user, fast=True, max_tokens=400)
    except Exception as e:
        return {"status": f"error: {e}",
                "recommended_signal": "flag" if has_hits else "clear", "best_lei": None}

    if data.get("recommended_signal") not in ("clear", "review", "flag"):
        data["recommended_signal"] = "flag" if has_hits else "clear"
    data["status"] = "ok"
    return data
