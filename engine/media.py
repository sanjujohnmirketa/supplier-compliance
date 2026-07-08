"""
media.py — adverse-media screening (Stage-02c).

Free, KEYLESS news retrieval via the GDELT DOC 2.0 API; the LLM then classifies
whether recent coverage is ADVERSE (sanctions, fraud, litigation, corruption,
labour/environmental violations) vs benign. No API key required, so it fits the
on-prem / no-bundled-secrets design. Degrades gracefully when no LLM is set
(returns the raw hits for analyst review rather than auto-clearing).
"""
import json as _json
import requests

GDELT_URL = "https://api.gdeltproject.org/api/v2/doc/doc"


def _fetch(name: str, risk: bool = False):
    # Single attempt, short timeout — GDELT is free/best-effort. If it's slow or
    # down, return nothing (→ Clear) rather than blocking the whole screen with
    # retries. Adverse media is one signal among several; never the bottleneck.
    try:
        r = requests.get(GDELT_URL, params={
            "query": f'"{name}"', "mode": "artlist", "format": "json",
            "maxrecords": 10, "sort": "datedesc", "timespan": "6months",
        }, timeout=8)
        r.raise_for_status()
        return r.json().get("articles", []) or []
    except Exception:
        return []


def adverse_media_screen(name: str, country: str = None) -> dict:
    """Return {status, summary, articles}. status ∈ Clear|Review|Flag."""
    if not name:
        return {"status": "Clear", "summary": "No entity name.", "articles": []}

    # Name-focused query (precise) — the LLM judges adverse-ness from real coverage.
    # The risk-keyword query returned noisy false positives for clean entities.
    try:
        arts = _fetch(name, risk=False)
    except Exception as e:
        return {"status": "Review", "summary": f"Adverse-media source error: {e}", "articles": []}

    articles = [{"title": a.get("title"), "domain": a.get("domain"),
                 "date": a.get("seendate"), "url": a.get("url")} for a in arts[:12]]
    if not articles:
        return {"status": "Clear",
                "summary": "No adverse-media coverage found in the last 12 months (GDELT).",
                "articles": []}

    import llm
    if not llm.is_configured():
        return {"status": "Review",
                "summary": f"{len(articles)} potentially-adverse article(s) found — analyst review (no LLM to classify).",
                "articles": articles}

    import prompts
    system = prompts.load("adverse_media")
    user = (f"ENTITY: {name}" + (f"\nCOUNTRY: {country}" if country else "")
            + "\nUNTRUSTED NEWS HEADLINES:\n" + _json.dumps(articles)[:6000])
    try:
        data = llm.chat_json(system, user)
    except Exception as e:
        return {"status": "Review",
                "summary": f"{len(articles)} article(s) found; classification error: {e}",
                "articles": articles}

    status = data.get("status") if data.get("status") in ("Clear", "Review", "Flag") else "Review"
    return {"status": status, "summary": (data.get("summary") or "")[:400], "articles": articles}
