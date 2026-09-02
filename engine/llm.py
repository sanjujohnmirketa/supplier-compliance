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


def is_configured(fast: bool = False) -> bool:
    return settings.llm_configured(provider=_fast_provider() if fast else None)


def active_model() -> str:
    return settings.LLM_MODEL


def fast_model() -> str:
    """A cheaper/faster model for narrow tasks (classify, disambiguation, short
    structured answers). Defaults to gpt-4o-mini; override via LLM_MODEL_FAST."""
    return settings.LLM_MODEL_FAST or "gpt-4o-mini"


def _fast_provider() -> str:
    """Provider for the fast path — LLM_PROVIDER_FAST overrides the main
    LLM_PROVIDER so a deployment can trial a model that only exists on a
    different provider (e.g. an Azure-only test deployment) without
    switching the main reasoning path off its own provider."""
    return settings.LLM_PROVIDER_FAST or settings.LLM_PROVIDER


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
    provider = _fast_provider() if fast else settings.LLM_PROVIDER
    if not is_configured(fast=fast):
        raise LLMUnavailable(f"LLM provider '{provider}' is not configured")

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
    if provider == "azure":
        # Real Azure OpenAI wire format (api-version query param, azure_endpoint
        # + deployment name) differs from plain OpenAI's — a base_url override
        # on the plain OpenAI client 404s against a real Azure resource
        # (confirmed 2026-09-02 testing elixiraifoundry.cognitiveservices.azure.com).
        # `model` here is the Azure DEPLOYMENT name, not a model family name.
        from openai import AzureOpenAI
        client = AzureOpenAI(
            api_key=settings.AZURE_API_KEY,
            azure_endpoint=settings.AZURE_ENDPOINT,
            api_version=settings.AZURE_API_VERSION,
        )
    else:
        from openai import OpenAI
        if provider == "ollama":
            client = OpenAI(api_key="not-needed", base_url=settings.OLLAMA_BASE_URL)
        elif provider in ("vllm", "local"):
            client = OpenAI(api_key="not-needed",
                            base_url=settings.LOCAL_BASE_URL or settings.OLLAMA_BASE_URL)
        else:  # openai
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
    # Reasoning models (gpt-5 family, o-series) spend an opaque, variable share
    # of the completion budget on invisible reasoning tokens BEFORE any visible
    # answer — confirmed 2026-09-02: a 500-token cap on a small structured-JSON
    # prompt left only ~20 visible tokens (448/500 went to reasoning). They also
    # reject the `max_tokens` param entirely in favor of `max_completion_tokens`,
    # which covers reasoning + visible output combined. So a cap tuned for a
    # non-reasoning model (gpt-4o-mini's 500-token default) can silently starve
    # a reasoning model's visible answer to nothing even though the call
    # "succeeds". REASONING_TOKEN_HEADROOM pads the cap for reasoning models
    # specifically; tune per-model if a specific one needs more/less.
    REASONING_MODEL_PREFIXES = ("gpt-5", "o1", "o3", "o4")
    is_reasoning_model = any(model.lower().startswith(p) for p in REASONING_MODEL_PREFIXES)
    REASONING_TOKEN_HEADROOM = 1500
    if max_tokens:
        effective_cap = max_tokens + REASONING_TOKEN_HEADROOM if is_reasoning_model else max_tokens
        token_param = "max_completion_tokens" if is_reasoning_model else "max_tokens"
        base[token_param] = effective_cap
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
