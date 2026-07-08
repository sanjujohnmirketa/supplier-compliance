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

    # provider-specific — only the ACTIVE provider's settings are needed
    OPENAI_API_KEY: str    = os.getenv("OPENAI_API_KEY", "")
    OPENAI_BASE_URL: str   = os.getenv("OPENAI_BASE_URL", "")     # Azure / proxy / compatible
    ANTHROPIC_API_KEY: str = os.getenv("ANTHROPIC_API_KEY", "")
    OLLAMA_BASE_URL: str   = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434/v1")
    LOCAL_BASE_URL: str    = os.getenv("LOCAL_BASE_URL", "")      # vLLM / LM Studio (OpenAI-compatible)

    # ── Screening (optional; demo fallback when unset) ───────────────────────
    OPENSANCTIONS_API_KEY: str = os.getenv("OPENSANCTIONS_API_KEY", "")

    @classmethod
    def llm_configured(cls) -> bool:
        """True when the active provider has what it needs to make a call."""
        p = cls.LLM_PROVIDER
        if p == "openai":            return bool(cls.OPENAI_API_KEY)
        if p == "azure":             return bool(cls.OPENAI_API_KEY and cls.OPENAI_BASE_URL)
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
