# ════════════════════════════════════════════════════════════════════════════
# Supplier Compliance Engine — portable container image.
# Models (spaCy + sentence-transformers) are baked in so the image runs
# air-gapped / on-prem with no download at runtime. Provider keys are supplied
# at run time via env (nothing is bundled).
# ════════════════════════════════════════════════════════════════════════════
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/app/.cache/huggingface

# Baked models are cached under $HF_HOME (inside /app, owned by appuser below) so
# the non-root runtime user finds them at startup with no re-download.

# Minimal build deps (most wheels are prebuilt: psycopg2-binary, torch, spaCy)
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python deps first (layer cache)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Bake governance + embedding models into the image (no runtime download)
RUN python -m spacy download en_core_web_sm \
 && python -c "from sentence_transformers import SentenceTransformer; \
SentenceTransformer('sentence-transformers/all-MiniLM-L6-v2')"

# Application code
COPY . .

# Force offline mode NOW (after the model download above) — newer transformers/
# sentence-transformers versions probe the Hub (e.g. for an adapter config) even
# when the model is already cached, which breaks air-gapped/no-egress deployments.
ENV HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1

# Run as a non-root user (Azure Container Apps / any hardened runtime)
RUN useradd --create-home --shell /bin/bash appuser \
 && chown -R appuser:appuser /app
USER appuser

EXPOSE 8000

# Liveness/readiness for orchestrators (Docker/K8s) hit /ready
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://localhost:8000/ready || exit 1

# Production: no --reload. Scale by running more replicas behind a load balancer.
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
