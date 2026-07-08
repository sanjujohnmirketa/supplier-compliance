"""
guardrails.py — prompt-injection detection for untrusted supplier documents.
Pairs with the untrusted-content framing + fail-safe in app.py judge_compliance().
"""
import re

INJECTION_PATTERNS = [
    r"ignore (all |the |any )?(previous|prior|above) (instructions|prompts?)",
    r"disregard (all |the |any )?(previous|prior|above)",
    r"forget (all |the |everything)",
    r"you are now",
    r"\bact as\b",
    r"system prompt",
    r"new instructions?",
    r"\boverride\b",
    r"mark (this |it )?(as )?(compliant|approved|valid)",
    r"approve (this|the) (supplier|document)",
    r"do not flag",
    r"respond with .{0,20}compliant",
    r"</?(system|assistant|user)>",
]
_COMPILED = [re.compile(p, re.IGNORECASE) for p in INJECTION_PATTERNS]


def scan_injection(text: str):
    """Return matched injection snippets (empty list if clean)."""
    if not text:
        return []
    hits = []
    for rx in _COMPILED:
        for m in rx.finditer(text):
            s = m.group(0).strip()
            if s and s.lower() not in [h.lower() for h in hits]:
                hits.append(s)
    return hits[:10]
