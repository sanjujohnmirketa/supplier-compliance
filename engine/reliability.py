"""
reliability.py — small, dependency-free resilience helpers.

with_retry() retries a callable on TRANSIENT errors (timeouts, connection drops,
429/5xx) with bounded exponential backoff. Non-transient errors (4xx, bad input,
auth) fail immediately — retrying them is pointless.

Used for the fast external registry calls (GLEIF, OpenSanctions). The LLM is
deliberately NOT retried here: it is slow and the upstream caller (Salesforce
Apex) has a hard timeout, so it uses a per-call timeout + graceful degradation
to the human gate instead.
"""
import time

_TRANSIENT_HINTS = (
    "timeout", "timed out", "connection", "connectionerror", "temporarily",
    "rate limit", "ratelimit", "429", "500", "502", "503", "504",
    "max retries", "reset by peer", "broken pipe",
)


def is_transient(exc: Exception) -> bool:
    s = str(exc).lower()
    return any(h in s for h in _TRANSIENT_HINTS)


def with_retry(fn, *, attempts: int = 3, base_delay: float = 0.6, max_delay: float = 4.0):
    """Call fn() with bounded exponential backoff on transient errors."""
    last = None
    for i in range(attempts):
        try:
            return fn()
        except Exception as e:           # noqa: BLE001 — we re-raise below
            last = e
            if i == attempts - 1 or not is_transient(e):
                raise
            time.sleep(min(max_delay, base_delay * (2 ** i)))
    raise last
