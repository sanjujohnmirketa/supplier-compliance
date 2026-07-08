"""
prompts.py — load agent SOP prompts from prompts/*.md.

Separation of concerns (production best practice): agent instructions live as
git-tracked Markdown SOPs in prompts/, independent of the Python logic, so they
can be reviewed, versioned, and A/B-tested without touching code. Cached on first
load; a process restart picks up edits (the deploy unit).
"""
import os
import functools

_DIR = os.path.join(os.path.dirname(__file__), "prompts")


@functools.lru_cache(maxsize=None)
def load(name: str) -> str:
    """Return the SOP text for prompts/<name>.md."""
    path = os.path.join(_DIR, name + ".md")
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()
