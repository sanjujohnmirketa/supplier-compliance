# AI Solution Development Standards

**Version:** 1.0  
**Status:** Draft for Review  
**Maintained by:** Platform / AI Engineering Team  
**Last Updated:** 2026-07

---

## 1. Introduction & Principles

This document defines the **unified development standards** for all AI-powered solutions built by the team. It applies to any service, API, or pipeline that incorporates machine learning models, large language models (LLMs), or AI-driven automation — regardless of the business domain.

### Core Principles

| Principle | What It Means |
|---|---|
| **Predictability** | AI systems must behave consistently. Non-determinism must be bounded and documented. |
| **Observability** | Every AI interaction must be traceable end-to-end — prompt in, response out, cost incurred. |
| **Security by Default** | No plaintext secrets. No unvalidated inputs reaching models. |
| **Cost Awareness** | Token usage and LLM costs are tracked per request, user, and solution — not at month-end. |
| **Separation of Concerns** | Workload type (sync / stream / async) determines architecture, not preference. |
| **Fail Gracefully** | AI failures should degrade to a useful fallback, not hard errors surfaced to users. |

---

## 2. Tech Stack Catalogue

### 2.1 Python Stack (Preferred for AI-heavy backends)

| Layer | Standard Choice | Alternatives Allowed |
|---|---|---|
| **API Framework** | FastAPI | Flask (legacy only) |
| **ASGI Server** | Uvicorn + Gunicorn | — |
| **LLM Orchestration** | LangChain / LlamaIndex | Semantic Kernel, raw SDK |
| **LLM SDKs** | `openai`, `anthropic`, `azure-openai` | Provider-native SDKs |
| **Task Queue** | Celery (simple) / Temporal (complex) | — |
| **Validation** | Pydantic v2 | — |
| **HTTP Client** | `httpx` (async-first) | `requests` for sync-only scripts |
| **Testing** | `pytest` + `pytest-asyncio` | — |

### 2.2 Node.js Stack (Preferred for full-stack or Salesforce-integrated solutions)

| Layer | Standard Choice | Alternatives Allowed |
|---|---|---|
| **API Framework** | Express.js or NestJS | — |
| **LLM SDK** | Vercel AI SDK / `@langchain/core` | OpenAI Node SDK |
| **Task Queue** | BullMQ (Redis-backed) | — |
| **Validation** | Zod | Joi |
| **ORM** | Prisma | TypeORM |
| **Testing** | Jest + Supertest | Vitest |

### 2.3 Full Stack (MEAN / MERN)

Use Node.js/NestJS as the AI backend API layer. The frontend (Angular/React) must **never** call LLM APIs directly — all AI calls must be proxied through the backend.

```
[Browser / React / Angular]
        │  HTTPS
        ▼
[NestJS API Gateway]  ←── auth, rate limit, logging
        │
        ▼
[LLM Provider / Internal AI Service]
```

### 2.4 Databases & Storage

| Purpose | Standard | Notes |
|---|---|---|
| **Relational / primary store** | PostgreSQL 16+ | Use Flexible Server on Azure |
| **Vector store** | pgvector (on Postgres) | Pinecone or Weaviate for dedicated vector at scale |
| **Caching / rate limit store** | Redis (Azure Cache for Redis) | Also used for job queues (BullMQ) |
| **Object / blob storage** | Azure Blob Storage | S3 on AWS, GCS on GCP |
| **Workflow state** | Temporal (PostgreSQL backend) | For complex multi-step AI workflows |
| **Secrets** | Azure Key Vault | AWS Secrets Manager / GCP Secret Manager |

### 2.5 AI/ML Library Reference

| Category | Library | Use Case |
|---|---|---|
| LLM orchestration | LangChain, LlamaIndex | RAG, chains, agents |
| Embeddings | `sentence-transformers`, OpenAI Embeddings API | Vectorization |
| Structured output | Instructor, Marvin, Outlines | Enforce JSON/schema from LLMs |
| Evals | RAGAS, DeepEval, PromptFoo | Automated AI quality testing |
| Guardrails | Guardrails AI, LLM Guard | Input/output safety |
| Observability | OpenTelemetry, Langfuse, LangSmith | Tracing AI pipelines |

---

## 3. Environment Standards

### 3.1 Dependency Management

**Python:**
```bash
# Always pin exact versions in requirements.txt
pip freeze > requirements.txt          # for deployment
pip-compile pyproject.toml             # preferred (pip-tools)
```

- Use `python-dotenv` for local `.env` loading
- Pin Python version in `.python-version` (pyenv) or `pyproject.toml`
- Use virtual environments — never install to system Python

```
project/
├── pyproject.toml        # defines dependencies (pip-tools / poetry)
├── requirements.txt      # pinned lock file (committed)
├── requirements-dev.txt  # dev-only (pytest, ruff, mypy)
└── .python-version       # e.g., 3.11.9
```

**Node.js:**
```bash
# Always commit package-lock.json
npm ci                  # install from lockfile in CI
```

- Pin Node version in `.nvmrc` or `engines` field in `package.json`

### 3.2 Docker Standards

Every AI service must ship as a Docker image. Follow these conventions:

```dockerfile
# ✅ REQUIRED: multi-stage build to minimize image size
FROM python:3.11-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.11-slim AS runtime
WORKDIR /app
COPY --from=builder /usr/local/lib/python3.11 /usr/local/lib/python3.11
COPY --from=builder /usr/local/bin /usr/local/bin
COPY . .

# ✅ REQUIRED: non-root user
RUN adduser --disabled-password --gecos "" appuser
USER appuser

# ✅ REQUIRED: health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:8000/health || exit 1

# ✅ REQUIRED: explicit port declaration
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
```

**Required files in every AI service repo:**

| File | Purpose |
|---|---|
| `Dockerfile` | Production image |
| `docker-compose.yml` | Local dev with all dependencies |
| `.dockerignore` | Exclude `.env`, `__pycache__`, `.git`, test data |
| `.env.example` | Template for all required env vars (no real values) |

### 3.3 Environment Variables & Secret Injection

**Rules:**
1. **Never hardcode secrets** in source code or Dockerfiles
2. **Never commit `.env` files** — only `.env.example` is committed
3. Local dev: use `.env` file loaded by `python-dotenv` / `dotenv` npm package
4. CI/CD: inject via pipeline secret variables
5. Production: inject via Key Vault references or Kubernetes secrets (mounted as env vars)

**`.env.example` structure (mandatory template in every repo):**

```bash
# ── App ─────────────────────────────────────────────
APP_ENV=development           # development | staging | production
APP_PORT=8000
LOG_LEVEL=INFO                # DEBUG | INFO | WARNING | ERROR

# ── LLM Provider (pick ONE) ─────────────────────────
LLM_PROVIDER=openai           # openai | anthropic | azure_openai | ollama
LLM_MODEL=gpt-4o-mini
LLM_TEMPERATURE=0
LLM_TIMEOUT_SECONDS=60
OPENAI_API_KEY=               # required if LLM_PROVIDER=openai
ANTHROPIC_API_KEY=            # required if LLM_PROVIDER=anthropic
AZURE_OPENAI_ENDPOINT=        # required if LLM_PROVIDER=azure_openai
AZURE_OPENAI_API_KEY=

# ── Database ─────────────────────────────────────────
DATABASE_URL=postgresql://user:password@localhost:5432/dbname?sslmode=require

# ── Redis ─────────────────────────────────────────────
REDIS_URL=redis://localhost:6379/0

# ── Auth ──────────────────────────────────────────────
INBOUND_API_KEY=              # API key for inbound requests

# ── Observability ─────────────────────────────────────
OTEL_EXPORTER_OTLP_ENDPOINT= # OpenTelemetry collector endpoint
LANGFUSE_PUBLIC_KEY=          # optional — LLM trace observability
LANGFUSE_SECRET_KEY=
```

### 3.4 Environment Parity (Dev / Staging / Production)

| Rule | Detail |
|---|---|
| Same Docker image across all environments | No env-specific builds |
| Same secrets injection method | Key Vault in all envs (different vaults) |
| Same service dependencies | docker-compose mirrors prod services locally |
| Environment identified by `APP_ENV` only | Code must not branch on env name |
| Staging must mirror production data volume | Use anonymized/synthetic data |

---

## 4. API & Workload Patterns

AI workloads fall into **four patterns**. The workload type determines the architecture — never override this based on preference.

### Choosing the Right Pattern

```
Is the AI response needed synchronously (user is waiting)?
├── Yes
│   └── Will the response take > 3 seconds?
│       ├── No  → Pattern 1: Sync REST API
│       └── Yes → Pattern 2: Streaming API (SSE/WebSocket)
└── No (fire-and-forget or batch)
    └── Is there a defined workflow with steps / retries / compensation?
        ├── No  → Pattern 3: Simple Job Queue (Celery / BullMQ)
        └── Yes → Pattern 4: Workflow Orchestration (Temporal)
```

---

### 4.1 Pattern 1 — Synchronous REST API (Short-Running)

**Use for:** Classification, entity extraction, embeddings, simple chat completions, RAG queries expected to complete within ~3s.

**Requirements:**

- OpenAPI 3.x spec (`openapi.json` or `/docs` via FastAPI) is **mandatory**
- All endpoints versioned under `/v1/`, `/v2/` etc.
- Idempotency key header (`X-Idempotency-Key`) supported on POST endpoints that trigger LLM calls
- Response envelope (consistent structure across all endpoints):

```json
{
  "request_id": "req_01J9K...",
  "data": { /* endpoint-specific payload */ },
  "metadata": {
    "model": "gpt-4o-mini",
    "model_version": "2024-07-18",
    "tokens_used": { "prompt": 512, "completion": 128, "total": 640 },
    "latency_ms": 823,
    "cached": false
  }
}
```

- Error envelope (consistent across all endpoints):

```json
{
  "request_id": "req_01J9K...",
  "error": {
    "code": "LLM_UNAVAILABLE",
    "message": "The AI model is temporarily unavailable.",
    "fallback_used": true,
    "retry_after_seconds": 30
  }
}
```

**Standard endpoints every AI service must expose:**

| Endpoint | Method | Purpose |
|---|---|---|
| `/health` | GET | Liveness check — returns 200 if process is alive |
| `/ready` | GET | Readiness check — returns 200 only if DB, LLM reachable |
| `/v1/...` | * | All business endpoints |

---

### 4.2 Pattern 2 — Streaming API (Real-Time LLM Output)

**Use for:** Chat interfaces, document generation, any use case where the user should see tokens appear progressively.

**Protocol:** Server-Sent Events (SSE) preferred over WebSocket for unidirectional streaming. Use WebSocket only when bidirectional (user can interrupt).

**SSE stream format (standardized):**

```
data: {"type": "start", "request_id": "req_01J9K..."}

data: {"type": "delta", "content": "The "}

data: {"type": "delta", "content": "supplier "}

data: {"type": "delta", "content": "compliance "}

data: {"type": "end", "metadata": {"tokens_used": 340, "latency_ms": 2100}}

data: [DONE]
```

**Requirements:**
- Always include `request_id` in the `start` event so clients can correlate
- The `end` event must include the same `metadata` object as Pattern 1
- On error, emit an `error` event before closing the stream:
  ```
  data: {"type": "error", "code": "LLM_TIMEOUT", "message": "..."}
  ```
- Set appropriate headers: `Content-Type: text/event-stream`, `Cache-Control: no-cache`, `X-Accel-Buffering: no`

---

### 4.3 Pattern 3 — Async Job Queue (Long-Running, Simple)

**Use for:** Document processing, batch embeddings, report generation, PDF extraction — tasks taking seconds to minutes with no complex dependency graph.

**Stack:** Celery (Python) + Redis broker / BullMQ (Node.js) + Redis

**Job lifecycle and API contract:**

```
POST /v1/jobs/process-document
  → Returns immediately: { "job_id": "job_abc123", "status": "queued" }

GET /v1/jobs/job_abc123
  → Returns: { "job_id": "job_abc123", "status": "running|completed|failed", "result": {...}, "progress_pct": 60 }
```

**Requirements:**
- Jobs must have a **dead-letter queue (DLQ)** for failures after max retries
- Jobs must be **idempotent** — same input + same `job_id` must be safe to submit twice
- Job payloads stored in Redis or DB — not just in the queue message (large payloads)
- Retry policy: **3 retries with exponential backoff** (base 2s, max 60s) — see Section 9
- Job status must be queryable for at least **7 days** after completion
- Workers log job start, completion, and failure as structured events (see Section 6)

---

### 4.4 Pattern 4 — Workflow Orchestration (Long-Running, Complex)

**Use for:** Multi-step AI pipelines with retries, compensating transactions, human-in-the-loop steps, or workflows that take hours/days (e.g. supplier onboarding, multi-agent research).

**Stack:** Temporal (preferred) — provides durable execution, replay, and visibility out of the box.

**Workflow structure:**

```python
@workflow.defn
class SupplierComplianceWorkflow:
    @workflow.run
    async def run(self, input: ComplianceInput) -> ComplianceResult:
        # Each activity is independently retried, observable, and auditable
        docs = await workflow.execute_activity(fetch_documents, ...)
        embeddings = await workflow.execute_activity(embed_documents, ...)
        assessment = await workflow.execute_activity(run_llm_assessment, ...)
        
        if assessment.needs_human_review:
            await workflow.wait_for_signal("human_approval")  # pause indefinitely
        
        return await workflow.execute_activity(finalize_result, ...)
```

**Requirements:**
- All Temporal workflows must have a `WorkflowId` that maps back to the business entity
- Activities must be **idempotent**
- Workflows must define `startToCloseTimeout` and `scheduleToCloseTimeout` explicitly
- Human-in-the-loop steps use Temporal Signals — never block with `time.sleep`

---

## 5. Security

### 5.1 Authentication

| Context | Standard |
|---|---|
| External API consumers | API key via `Authorization: Bearer <token>` header |
| Service-to-service (internal) | Managed Identity / mTLS — never shared API keys |
| User-facing (browser) | JWT via established auth provider (Azure AD, Auth0) |
| Webhooks inbound | HMAC signature verification on payload |

**Rules:**
- API keys are minimum 32 bytes of cryptographic randomness (`openssl rand -hex 32`)
- API keys are hashed (bcrypt or SHA-256) before storage — never stored plaintext
- Keys are rotatable without downtime (support multiple active keys per solution)
- All auth failures return `401` (missing/invalid) or `403` (valid but unauthorized) — never `200` with an error body

### 5.2 Input Validation & Prompt Injection Protection

AI services face a unique attack surface: **prompt injection** — where user input manipulates the LLM's system prompt or overrides instructions.

**Required mitigations:**

```python
# ✅ Always validate and sanitize inputs before they touch prompts
class UserInput(BaseModel):
    query: str = Field(..., min_length=1, max_length=4000)
    
    @validator("query")
    def no_injection_patterns(cls, v):
        # Block common injection attempts
        forbidden = ["ignore previous instructions", "system:", "###"]
        if any(p.lower() in v.lower() for p in forbidden):
            raise ValueError("Invalid input detected")
        return v.strip()
```

```python
# ✅ Always separate system prompt from user input — never f-string them together
messages = [
    {"role": "system", "content": SYSTEM_PROMPT},        # static, from config
    {"role": "user",   "content": sanitized_user_input}  # validated user content
]
# ❌ NEVER do this:
prompt = f"{SYSTEM_PROMPT}\n\nUser: {user_input}"  # allows injection
```

**Additional requirements:**
- Validate JSON schema of all inbound request bodies (Pydantic / Zod)
- Enforce maximum token limits on user-supplied content before sending to LLM
- Use output validators for structured LLM responses (Instructor, Outlines)

### 5.3 CORS & Network Exposure

- CORS `allowedOrigins` must be **explicitly configured** — never `*` in production
- Internal AI services that don't serve browsers must disable CORS entirely
- Sensitive AI endpoints (model inference) must never be publicly exposed without auth

---

## 6. Logging, Auditing & Observability

### 6.1 Structured Logging Format

All logs must be **JSON-structured**. No plain-text log lines in production.

**Standard log fields (all logs must include):**

```json
{
  "timestamp": "2026-07-15T06:34:00.123Z",
  "level": "INFO",
  "service": "supplier-compliance-engine",
  "version": "1.2.3",
  "environment": "production",
  "request_id": "req_01J9K...",
  "trace_id": "otel_trace_abc123",
  "message": "LLM assessment completed",
  "duration_ms": 1240
}
```

**Log levels:**

| Level | When to Use |
|---|---|
| `DEBUG` | Detailed internal state (dev/staging only — disabled in prod) |
| `INFO` | Normal operations: request received, job queued, LLM call initiated |
| `WARNING` | Recoverable anomaly: retry attempted, fallback used, rate limit approaching |
| `ERROR` | Failure requiring attention: LLM call failed, DB unreachable, job failed |
| `CRITICAL` | Service-threatening: cannot start, data corruption detected |

### 6.2 LLM Trace Logging (Mandatory for All LLM Calls)

Every call to an LLM must be logged as a structured trace event. This is the primary tool for debugging, cost attribution, and quality audits.

**LLM trace log schema:**

```json
{
  "event": "llm_call",
  "timestamp": "2026-07-15T06:34:00.123Z",
  "request_id": "req_01J9K...",
  "trace_id": "otel_trace_abc123",
  "provider": "openai",
  "model": "gpt-4o-mini",
  "model_version": "2024-07-18",
  "temperature": 0,
  "max_tokens": 1024,
  "prompt_tokens": 512,
  "completion_tokens": 128,
  "total_tokens": 640,
  "latency_ms": 823,
  "cached": false,
  "finish_reason": "stop",
  "solution_id": "supplier-compliance",
  "user_id": "user_xyz",        
  "tenant_id": "tenant_abc",    
  "pii_scrubbed": true,         
  "prompt_hash": "sha256:abc...",
  "cost_usd": 0.000384
}
```

> **Note:** The actual prompt and response text may optionally be stored in a **separate, access-controlled log store** (not the main application log) depending on data sensitivity requirements. Always apply PII scrubbing (Section 6.4) before storing.

### 6.3 Correlation ID Propagation

Every request must carry a `request_id` from entry point through all downstream calls.

**Python (FastAPI):**
```python
from fastapi import Request
import uuid

@app.middleware("http")
async def add_request_id(request: Request, call_next):
    request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
    # Bind to context var so all log calls in this request include it
    request_id_ctx.set(request_id)
    response = await call_next(request)
    response.headers["X-Request-ID"] = request_id
    return response
```

Pass `request_id` and `trace_id` in all downstream HTTP calls as headers:
```
X-Request-ID: req_01J9K...
traceparent: 00-{trace_id}-{span_id}-01   # OpenTelemetry W3C format
```

### 6.4 PII Scrubbing Rules

Before writing any log that may contain user-supplied content:

| Data Type | Rule |
|---|---|
| Email addresses | Replace with `[EMAIL_REDACTED]` |
| Phone numbers | Replace with `[PHONE_REDACTED]` |
| Names (in prompts) | Replace with `[NAME_REDACTED]` if identifiable |
| Credit card / financial data | Replace with `[FINANCIAL_REDACTED]` |
| SSN / National ID | Replace with `[ID_REDACTED]` |
| API keys / tokens in payloads | Replace with `[SECRET_REDACTED]` |

Use a library (e.g. `scrubadub`, `presidio`) rather than manual regex — it's more comprehensive and maintainable.

### 6.5 Audit Trail Requirements

For AI solutions that make or influence decisions (compliance, screening, approvals):

- **Immutable** — audit logs must not be overwriteable (append-only table or WORM storage)
- **What to capture:** actor (user/system), timestamp, action, input, AI decision/output, confidence/score, model version
- **Retention:** minimum 90 days (extend to 1–7 years for regulated industries)
- Audit logs are **separate** from application logs — different table or storage account

```sql
CREATE TABLE audit_log (
    id           BIGSERIAL PRIMARY KEY,
    event_time   TIMESTAMPTZ NOT NULL DEFAULT now(),
    request_id   TEXT NOT NULL,
    actor_id     TEXT NOT NULL,
    actor_type   TEXT NOT NULL,          -- 'user' | 'system' | 'workflow'
    action       TEXT NOT NULL,          -- e.g. 'llm_assessment', 'job_completed'
    entity_type  TEXT,                   -- e.g. 'supplier', 'document'
    entity_id    TEXT,
    model        TEXT,
    model_version TEXT,
    input_hash   TEXT,                   -- SHA-256 of input (not plaintext)
    output_hash  TEXT,
    decision     TEXT,
    confidence   NUMERIC(5,4),
    metadata     JSONB
    -- No UPDATE, no DELETE on this table
);
```

### 6.6 Metrics & Distributed Tracing (OpenTelemetry)

All AI services must instrument with **OpenTelemetry (OTel)**:

| Signal | What to Capture |
|---|---|
| **Traces** | Full request span, LLM call span, DB query spans |
| **Metrics** | Request count, error rate, LLM latency (p50/p95/p99), token usage/hour |
| **Logs** | Forward structured logs to OTel collector |

```python
# Standard metric names (use these across all solutions)
ai.llm.request.count        # counter — total LLM calls
ai.llm.tokens.prompt        # histogram — prompt tokens per call
ai.llm.tokens.completion    # histogram — completion tokens per call  
ai.llm.latency              # histogram — ms from LLM API call to first byte
ai.job.queue.depth          # gauge — pending jobs in queue
ai.job.duration             # histogram — job processing time
http.server.request.count   # counter — inbound HTTP requests
http.server.error.rate      # counter — 4xx/5xx responses
```

---

## 7. Usage Tracking & Cost Attribution

### 7.1 Token Counting Per Request

Every LLM response includes token usage — capture it unconditionally on the `llm_call` log event (Section 6.2) and persist to the usage table:

```sql
CREATE TABLE llm_usage (
    id              BIGSERIAL PRIMARY KEY,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    request_id      TEXT NOT NULL,
    solution_id     TEXT NOT NULL,
    user_id         TEXT,
    tenant_id       TEXT,
    provider        TEXT NOT NULL,
    model           TEXT NOT NULL,
    prompt_tokens   INT NOT NULL,
    completion_tokens INT NOT NULL,
    total_tokens    INT NOT NULL,
    estimated_cost_usd NUMERIC(12,8)
);
```

### 7.2 Per-User / Per-Tenant Quotas

Implement soft and hard quotas using Redis counters:

```python
# Key pattern: quota:{solution_id}:{tenant_id}:{YYYY-MM-DD}
# Value: running token count for the day

async def check_quota(solution_id: str, tenant_id: str, requested_tokens: int):
    key = f"quota:{solution_id}:{tenant_id}:{today()}"
    current = await redis.get(key) or 0
    if int(current) + requested_tokens > DAILY_TOKEN_QUOTA:
        raise QuotaExceededError(quota=DAILY_TOKEN_QUOTA, used=current)
    await redis.incrby(key, requested_tokens)
    await redis.expire(key, 86400 * 2)  # 2-day TTL
```

### 7.3 Cost Attribution

- Every `llm_usage` record must have a `solution_id` (which AI product) and `tenant_id` (which customer)
- Cost per token for each model must be maintained in a config table (update when providers change pricing)
- Weekly cost reports per solution and tenant must be auto-generated

### 7.4 Model Version Tracking

- Always capture `model_version` (the provider's actual model version date, not just the alias)
- Never rely on model aliases (e.g., `gpt-4o`) alone — capture the resolved version from the API response
- Pin `model` in config; alert if the resolved version changes unexpectedly (model drift)

---

## 8. Rate Limits & Performance

### 8.1 Token-Based Rate Limiting

**Standard: rate limit on tokens, not just requests.** A single request can consume thousands of tokens.

```
Per-client limits (enforced by the AI service, using Redis sliding window):
  - 100,000 tokens / minute per tenant
  - 5,000,000 tokens / day per tenant
  
Response when limit hit:
  HTTP 429
  Headers: Retry-After: 30
  Body: { "error": { "code": "RATE_LIMIT_EXCEEDED", "retry_after_seconds": 30 } }
```

Also enforce request-count limits as a secondary protection:
- Max 60 requests/minute per API key (burst protection)

### 8.2 SLA Targets by Workload Type

| Pattern | p50 Target | p95 Target | p99 Target | Max Timeout |
|---|---|---|---|---|
| Sync REST (simple) | < 500ms | < 2s | < 5s | 30s |
| Sync REST (RAG/complex) | < 1s | < 5s | < 10s | 60s |
| Streaming (first token) | < 500ms | < 2s | < 3s | 120s |
| Job queue (simple) | < 30s | < 2min | < 5min | 30min |
| Workflow (complex) | — | — | — | 24h |

These are **alert thresholds** — breach = PagerDuty / Teams alert.

### 8.3 Timeout Hierarchy & Retry Strategy

Always configure a **layered timeout**:

```
Client → AI Service → LLM Provider

Client timeout:       30s (what the caller sets)
Service timeout:      25s (internal — must be less than client timeout)
LLM API timeout:      20s (per LLM call)
DB query timeout:     5s
```

**Retry policy (all outbound calls):**

```python
# Standard retry configuration
RETRY_CONFIG = {
    "max_attempts": 3,
    "initial_delay_s": 1.0,
    "backoff_multiplier": 2.0,     # 1s, 2s, 4s
    "max_delay_s": 60.0,
    "retryable_status_codes": [429, 500, 502, 503, 504],
    "non_retryable_status_codes": [400, 401, 403, 404],
}
```

### 8.4 Circuit Breaker Pattern

Wrap all LLM provider calls with a circuit breaker:

| State | Condition | Behavior |
|---|---|---|
| **Closed** (normal) | Error rate < 50% | Pass requests through |
| **Open** (tripped) | Error rate ≥ 50% in last 60s | Reject immediately with `503`, return fallback |
| **Half-Open** (probing) | After 30s in Open state | Allow 1 probe request; if success → Closed |

Use `tenacity` (Python) or `cockatiel` (Node.js) for retry + circuit breaker.

---

## 9. Error Handling & Resilience

### 9.1 LLM Failure Fallback Modes

Define the fallback mode for each AI endpoint in its configuration. Every endpoint must have a declared fallback:

| Fallback Mode | Description | When to Use |
|---|---|---|
| `DEGRADED_RESPONSE` | Return a human-readable "AI unavailable" message | User-facing chat |
| `QUEUE_FOR_RETRY` | Accept request, add to retry queue | Non-urgent async tasks |
| `ROUTE_TO_HUMAN` | Flag for manual review | High-stakes decisions (compliance, legal) |
| `USE_CACHED` | Return last cached response for same input | Read-heavy, cacheable queries |
| `HARD_FAIL` | Return error — no fallback | Internal APIs where caller handles it |

### 9.2 Human-in-the-Loop Escalation

For AI decisions above a confidence threshold, or on specific failure types:

```python
if assessment.confidence < CONFIDENCE_THRESHOLD or llm_failed:
    await escalate_to_human(
        entity_id=request.entity_id,
        reason="low_confidence" if not llm_failed else "ai_unavailable",
        context=request.dict(),
        urgency="normal"  # or "high" for time-sensitive
    )
```

Human escalation must be audited (Section 6.5) — log the escalation event and the eventual human decision.

### 9.3 Dead-Letter Queues for Jobs

All job queues must have a DLQ configured:
- Jobs failing after max retries move to DLQ automatically
- DLQ messages trigger an alert
- DLQ messages are retained for 7 days for manual inspection and replay
- Provide an admin endpoint to replay DLQ messages: `POST /admin/jobs/dlq/{job_id}/replay`

---

## 10. Testing & Quality

### 10.1 Unit & Integration Tests

- **Minimum coverage: 70%** on business logic (not generated code, not vendor SDKs)
- All LLM calls must be **mocked in unit tests** — never call real providers in unit tests
- Integration tests may call providers using a dedicated test API key with strict quotas
- Test files co-located with source (`tests/` directory at package root)

```bash
# Run unit tests (no external calls)
pytest tests/unit/ -v

# Run integration tests (requires .env with real keys)
pytest tests/integration/ -v --timeout=60
```

### 10.2 AI Evaluations (Evals)

AI quality cannot be measured by traditional pass/fail tests. Use evals:

| Eval Type | Tool | Measures |
|---|---|---|
| **Relevance** | RAGAS, DeepEval | Does the response answer the question? |
| **Groundedness** | RAGAS | Is the response grounded in provided context? |
| **Faithfulness** | RAGAS | No hallucinations beyond context? |
| **Safety** | Guardrails AI, LLM Guard | No harmful/toxic output |
| **Format correctness** | Pydantic, Instructor | Structured output matches schema |
| **Regression** | PromptFoo | Golden dataset — no quality regression vs baseline |

**Evals must run in CI/CD pipeline** on every PR to prompt-related code. A regression (score drop > 10%) blocks merge.

### 10.3 Golden Dataset Management

- Maintain a `tests/evals/golden_dataset.json` file per AI endpoint
- Each entry: `{ "input": {...}, "expected_output": {...}, "acceptable_range": {...} }`
- Reviewed and updated quarterly by the AI team
- Version-controlled — changes require review from at least two engineers

---

## 11. CI/CD Pipeline Standard

Every AI service repo must have a CI pipeline with these gates **in order**:

```
[Push / PR]
    │
    ├── 1. Lint & Format       (ruff/eslint) — fail fast
    ├── 2. Type Check          (mypy/tsc)
    ├── 3. Unit Tests          (pytest/jest) — no external calls
    ├── 4. Security Scan       (bandit/npm audit/trivy on Dockerfile)
    ├── 5. AI Evals            (on PR to main only — may be slow)
    ├── 6. Build Docker Image
    ├── 7. Image Vulnerability Scan (Trivy / Grype)
    │
    [Merge to main]
    │
    ├── 8. Push to Registry    (tag: git-sha + semver)
    └── 9. Deploy to Staging   (auto) → Deploy to Production (manual gate)
```

---

## 12. Versioning & Breaking Change Policy

### API Versioning

- All AI service APIs are versioned: `/v1/`, `/v2/`, etc.
- A new version is required for any **breaking change** (removed field, changed type, changed behavior)
- Old versions supported for minimum **6 months** after new version is stable
- Deprecation communicated via `Deprecation` and `Sunset` response headers

```
Deprecation: Sat, 01 Jan 2027 00:00:00 GMT
Sunset: Sat, 01 Jul 2027 00:00:00 GMT
Link: <https://api.example.com/v2/docs>; rel="successor-version"
```

### Model Version Pinning

- Never use floating model aliases in production (e.g., `gpt-4o` → could change behavior silently)
- Pin to a dated snapshot (e.g., `gpt-4o-2024-11-20`) where the provider supports it
- Any model version change is a **breaking change** and requires an eval regression run before promotion

---

## 13. Responsible AI Checklist

Before launching any AI solution to production, complete this checklist:

```
☐ Prompt injection mitigations are in place (Section 5.2)
☐ LLM output is validated before being used in downstream logic
☐ Hallucination handling is defined — what happens when LLM makes things up?
☐ Confidence thresholds are set — low-confidence AI decisions route to human review
☐ Bias assessment done — has the solution been tested across diverse user inputs?
☐ PII scrubbing is active in all log pipelines (Section 6.4)
☐ Audit trail is enabled for all AI decisions (Section 6.5)
☐ Rate limits protect against abuse (Section 8.1)
☐ Fallback mode is defined and tested for every AI endpoint (Section 9.1)
☐ Users are informed they are interacting with AI (where applicable)
☐ Model version is pinned and tracked (Section 12)
☐ AI evals baseline has been established (Section 10.2)
```

---

## Appendix A: Error Code Reference

| Code | HTTP Status | Meaning |
|---|---|---|
| `LLM_UNAVAILABLE` | 503 | LLM provider unreachable or circuit open |
| `LLM_TIMEOUT` | 504 | LLM call exceeded timeout |
| `RATE_LIMIT_EXCEEDED` | 429 | Token or request quota exceeded |
| `QUOTA_EXCEEDED` | 429 | Tenant daily quota exhausted |
| `INVALID_INPUT` | 400 | Input validation failed |
| `PROMPT_INJECTION_DETECTED` | 400 | Prompt injection pattern detected |
| `AUTH_REQUIRED` | 401 | Missing or invalid auth |
| `FORBIDDEN` | 403 | Valid auth, insufficient permissions |
| `JOB_NOT_FOUND` | 404 | Job ID doesn't exist |
| `JOB_FAILED` | 500 | Job processing failed, check DLQ |
| `INTERNAL_ERROR` | 500 | Unexpected server error |

---

*This document should be reviewed and updated every 6 months. Suggest changes via PR.*
