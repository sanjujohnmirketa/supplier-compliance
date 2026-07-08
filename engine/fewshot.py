"""
fewshot.py — few-shot example injection (the learning loop).

Curated input→ideal-output examples calibrate the document agent. They are
sourced from analyst OVERRIDES (the feedback captured by the co-pilot) plus
golden cases, stored as JSONL so they are git-tracked and grow over time WITHOUT
code changes — exactly the "examples guide behaviour better than description"
production principle. Empty/missing file → no examples (no behaviour change).
"""
import os
import json
import functools

_DIR = os.path.join(os.path.dirname(__file__), "fewshot")


@functools.lru_cache(maxsize=None)
def block(name: str, limit: int = 3) -> str:
    """Return a prompt-ready reference-examples block for fewshot/<name>.jsonl."""
    path = os.path.join(_DIR, name + ".jsonl")
    if not os.path.exists(path):
        return ""
    exs = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()][:limit]
    if not exs:
        return ""
    out = ["\nREFERENCE EXAMPLES (calibration only — still judge the actual document "
           "above on its own merits):"]
    for e in exs:
        out.append("INPUT: " + e.get("input", "")
                   + "\nIDEAL OUTPUT: " + json.dumps(e.get("output", {})))
    return "\n".join(out)
