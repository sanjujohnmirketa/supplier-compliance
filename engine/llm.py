"""
llm.py — provider-agnostic LLM access for the compliance engine.

A single chat_json() interface. Swap providers per deployment via LLM_PROVIDER
(openai | azure | ollama | vllm | local | anthropic) with NO change to the
agents. On-prem deployments point at a local OpenAI-compatible server
(Ollama / vLLM / LM Studio) and need no external key.

Provider SDKs are imported lazily inside each branch, so a deployment only needs
the SDK for the provider it actually uses.
"""
import json
from config import settings


class LLMUnavailable(Exception):
    """Raised when the active provider isn't configured (caller should abstain)."""


def is_configured() -> bool:
    return settings.llm_configured()


def active_model() -> str:
    return settings.LLM_MODEL


def fast_model() -> str:
    """A cheaper/faster model for narrow tasks (classify, disambiguation, short
    structured answers). Defaults to gpt-4o-mini; override via LLM_MODEL_FAST."""
    return getattr(settings, "LLM_MODEL_FAST", "") or "gpt-4o-mini"


def chat_json(system: str, user: str, model: str = None, temperature: float = None,
              max_tokens: int = None, fast: bool = False) -> dict:
    """
    One structured-JSON completion across providers. Returns the parsed dict.
    Raises LLMUnavailable if the active provider is not configured; other
    exceptions propagate so the caller can decide how to degrade.

    LATENCY KNOBS:
      • max_tokens — cap the OUTPUT (where latency lives). Short structured answers
        should pass a small cap (e.g. 500) so the model can't ramble.
      • fast=True  — route to the cheaper/faster model (gpt-4o-mini) for narrow
        tasks; keeps gpt-4o for the heavy reasoning. Big quality/$ win, no API change.
    """
    if not is_configured():
        raise LLMUnavailable(f"LLM provider '{settings.LLM_PROVIDER}' is not configured")

    provider    = settings.LLM_PROVIDER
    model       = model or (fast_model() if fast else settings.LLM_MODEL)
    temperature = settings.LLM_TEMPERATURE if temperature is None else temperature

    if provider == "anthropic":
        from anthropic import Anthropic
        client = Anthropic(api_key=settings.ANTHROPIC_API_KEY)
        msg = client.messages.create(
            model=model,
            max_tokens=max_tokens or 1024,
            temperature=temperature,
            system=system + "\n\nRespond ONLY with a single valid JSON object — no prose.",
            messages=[{"role": "user", "content": user}],
            timeout=settings.LLM_TIMEOUT,
        )
        text = "".join(getattr(b, "text", "") for b in msg.content)
        return _loads(text)

    # ── OpenAI-compatible providers (openai / azure / ollama / vllm / local) ──
    from openai import OpenAI
    if provider == "ollama":
        client = OpenAI(api_key="not-needed", base_url=settings.OLLAMA_BASE_URL)
    elif provider in ("vllm", "local"):
        client = OpenAI(api_key="not-needed",
                        base_url=settings.LOCAL_BASE_URL or settings.OLLAMA_BASE_URL)
    else:  # openai / azure
        kwargs = {}
        if settings.OPENAI_API_KEY:  kwargs["api_key"]  = settings.OPENAI_API_KEY
        # IMPORTANT: pass an explicit base_url. The OpenAI SDK otherwise reads the
        # OPENAI_BASE_URL env var directly, and an EMPTY string there (which
        # docker-compose injects via `${OPENAI_BASE_URL:-}`) overrides the SDK's
        # default and yields a scheme-less URL -> httpx.UnsupportedProtocol ->
        # APIConnectionError. So only honor a non-empty override; otherwise force
        # the public default explicitly.
        base_url = (settings.OPENAI_BASE_URL or "").strip()
        kwargs["base_url"] = base_url or "https://api.openai.com/v1"
        client = OpenAI(**kwargs)

    base = dict(model=model, timeout=settings.LLM_TIMEOUT,
                messages=[{"role": "system", "content": system},
                          {"role": "user", "content": user}])
    if max_tokens:
        base["max_tokens"] = max_tokens   # cap output → faster, can't ramble
    # Try the richest call first, then progressively drop parameters that some
    # models/servers reject — e.g. gpt-5 / o-series only allow the default
    # temperature; some local servers don't support response_format. Errors that
    # are NOT about these parameters are re-raised immediately.
    attempts = [
        {"temperature": temperature, "response_format": {"type": "json_object"}},
        {"response_format": {"type": "json_object"}},   # drop temperature
        {"temperature": temperature},                   # drop json mode
        {},                                             # plain
    ]
    last = None
    for extra in attempts:
        try:
            resp = client.chat.completions.create(**base, **extra)
            return _loads(resp.choices[0].message.content)
        except Exception as e:
            last = e
            m = str(e).lower()
            if not any(k in m for k in ("temperature", "response_format",
                                        "json", "unsupported", "not support")):
                raise
    raise last


def _loads(text: str) -> dict:
    """Tolerant JSON parse — handles code fences / stray prose from local models."""
    text = (text or "").strip()
    if "```" in text and text.count("```") >= 2:
        inner = text.split("```")[1]
        if inner.lstrip().lower().startswith("json"):
            inner = inner.split("\n", 1)[1] if "\n" in inner else inner
        text = inner.strip()
    if not text.startswith("{"):
        i, j = text.find("{"), text.rfind("}")
        if i >= 0 and j > i:
            text = text[i:j + 1]
    return json.loads(text)
