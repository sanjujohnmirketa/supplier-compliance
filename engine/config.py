"""
config.py — central, typed configuration for the compliance engine.

Every secret / URL is read from the environment (or .env) HERE — nothing is
hardcoded or bundled, and each deployment supplies its own values. An on-prem
deployment can run with NO external API key by pointing LLM_PROVIDER at a local
model (embeddings are already local).

Required settings missing → fail fast at import with a clear message.
"""
import os
from dotenv import load_dotenv

load_dotenv()


def _req(name: str) -> str:
    v = os.getenv(name)
    if not v:
        raise RuntimeError(
            f"Missing required configuration '{name}'. Set it in the deployment "
            f"environment or .env (see .env.example)."
        )
    return v


class Settings:
    # ── Core (always required) ───────────────────────────────────────────────
    INBOUND_TOKEN: str = _req("INBOUND_TOKEN")   # bearer token callers must present
    DB_URL: str        = _req("DB_URL")          # pgvector Postgres connection

    # ── Embeddings (local by default — on-prem / air-gapped friendly) ────────
    EMBED_BACKEND: str = os.getenv("EMBED_BACKEND", "local")

    # ── Policy corpus version (stamped on every citation for provenance) ─────
    CORPUS_VERSION: str = os.getenv("CORPUS_VERSION", "unversioned")

    # ── LLM provider (swappable per deployment, no agent changes) ────────────
    #   openai | azure | ollama | vllm | local | anthropic
    LLM_PROVIDER: str    = os.getenv("LLM_PROVIDER", "openai").lower()
    LLM_MODEL: str       = os.getenv("LLM_MODEL", os.getenv("OPENAI_MODEL", "gpt-4o-mini"))
    LLM_TEMPERATURE: float = float(os.getenv("LLM_TEMPERATURE", "0"))
    LLM_TIMEOUT: int     = int(os.getenv("LLM_TIMEOUT", "60"))

    # Fast-path override (chat_json(fast=True), narrow low-stakes tasks) — can
    # point at a DIFFERENT provider than the main model, not just a different
    # model name, so a deployment can trial a model that only exists on one
    # provider (e.g. an Azure-only test deployment) without touching the main
    # reasoning path. Empty LLM_PROVIDER_FAST means "same provider as main."
    LLM_MODEL_FAST: str     = os.getenv("LLM_MODEL_FAST", "")
    LLM_PROVIDER_FAST: str  = os.getenv("LLM_PROVIDER_FAST", "").lower()

    # provider-specific — only the ACTIVE provider's settings are needed
    OPENAI_API_KEY: str    = os.getenv("OPENAI_API_KEY", "")
    OPENAI_BASE_URL: str   = os.getenv("OPENAI_BASE_URL", "")     # non-Azure OpenAI-compatible proxy only — see AZURE_ENDPOINT for real Azure OpenAI
    ANTHROPIC_API_KEY: str = os.getenv("ANTHROPIC_API_KEY", "")
    OLLAMA_BASE_URL: str   = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434/v1")
    LOCAL_BASE_URL: str    = os.getenv("LOCAL_BASE_URL", "")      # vLLM / LM Studio (OpenAI-compatible)

    # Real Azure OpenAI (LLM_PROVIDER=azure) — Azure's wire format differs from
    # plain OpenAI (api-version query param, azure_endpoint + deployment name
    # instead of a bare base_url), so it needs the AzureOpenAI SDK client, not
    # a base_url override on the plain OpenAI client. AZURE_API_KEY falls back
    # to OPENAI_API_KEY so a deployment can reuse one key var if it wants.
    AZURE_ENDPOINT: str    = os.getenv("AZURE_ENDPOINT", "")      # e.g. https://<resource>.cognitiveservices.azure.com/
    AZURE_API_KEY: str     = os.getenv("AZURE_API_KEY", "") or os.getenv("OPENAI_API_KEY", "")
    AZURE_API_VERSION: str = os.getenv("AZURE_API_VERSION", "2024-10-21")

    # ── Screening (optional; demo fallback when unset) ───────────────────────
    OPENSANCTIONS_API_KEY: str = os.getenv("OPENSANCTIONS_API_KEY", "")

    @classmethod
    def llm_configured(cls, provider: str = None) -> bool:
        """True when the given provider (default: the main LLM_PROVIDER) has
        what it needs to make a call. Pass provider= to check a different one
        (e.g. the fast-path provider, which can differ from the main one)."""
        p = provider or cls.LLM_PROVIDER
        if p == "openai":            return bool(cls.OPENAI_API_KEY)
        if p == "azure":             return bool(cls.AZURE_API_KEY and cls.AZURE_ENDPOINT)
        if p == "anthropic":         return bool(cls.ANTHROPIC_API_KEY)
        if p in ("ollama", "vllm", "local"):
            return True              # local model — no external key required
        return False

    @classmethod
    def summary(cls) -> dict:
        return {
            "llm_provider": cls.LLM_PROVIDER,
            "llm_model": cls.LLM_MODEL,
            "llm_configured": cls.llm_configured(),
            "embed_backend": cls.EMBED_BACKEND,
            "corpus_version": cls.CORPUS_VERSION,
            "sanctions": "live" if cls.OPENSANCTIONS_API_KEY else "demo",
        }


settings = Settings()
