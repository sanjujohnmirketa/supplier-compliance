# AI Solution Deployment Standards

**Version:** 1.0  
**Status:** Draft for Review  
**Maintained by:** Platform / DevOps Team  
**Last Updated:** 2026-07

---

## 1. Introduction & Principles

This document defines the **unified deployment standards** for all AI-powered solutions. It covers infrastructure provisioning, service configuration, deployment pipelines, scaling, security, and operations — regardless of the cloud provider or solution type.

### Core Principles

| Principle | What It Means |
|---|---|
| **Infrastructure as Code** | All infrastructure is defined in Terraform — no click-ops in the console |
| **GitOps** | Git is the single source of truth for both infrastructure and application state |
| **Least Privilege** | Every service gets only the permissions it needs — no standing admin access |
| **No Static Credentials** | All service authentication uses Managed Identity or Workload Identity |
| **Immutable Deployments** | Never patch running containers — replace with a new image |
| **Cloud-Portable Design** | Core abstractions (containers, queues, blobs) use provider-agnostic patterns; Terraform modules are provider-specific but share a common interface |
| **Cost Visibility** | Every resource is tagged for cost attribution before it is created |

---

## 2. Deployment Target Decision Framework

### 2.1 Decision Matrix

Use this matrix to select the right compute target. Choose the **first row whose criteria match your solution**.

| Compute Target | Choose When | Don't Use When |
|---|---|---|
| **AKS (Azure Kubernetes Service)** | Production AI services needing HA, autoscaling, GPU workloads, or service mesh; multi-tenant SaaS platforms | Simple single-tenant solution with < 3 services |
| **Azure Container Apps** | Containerized microservices with event-driven scaling, no cluster management overhead; good default for new services | You need GPU, custom networking, or existing AKS investment |
| **Azure Container Instances (ACI)** | Ephemeral batch jobs, one-off model runs, CI/CD sidecar tasks | Long-running APIs, anything needing HA or autoscaling |
| **Azure App Service** | Long-running web APIs (non-GPU) reusing existing App Service Plan; cost-sensitive small services | Isolation from other tenants is required; GPU needed |
| **Azure Function Apps** | Event-triggered, short-duration AI tasks (< 10 min); webhook handlers; lightweight orchestration | Long LLM chains, streaming responses, stateful workflows |
| **Virtual Machine (VM)** | Legacy dependencies that can't containerize; GPU with specific driver requirements | All new solutions (containers preferred) |

### 2.2 Quick Decision Tree

```
Does the solution need GPU?
├── Yes → AKS (GPU node pool) or VM (legacy only)
└── No
    └── Is it event-triggered or very short-lived?
        ├── Yes → Function App or ACI (ephemeral)
        └── No (long-running API/service)
            └── Does it need HA + autoscaling?
                ├── Yes → AKS or Container Apps
                └── No → App Service (cost-sensitive) or Container Apps (new)
```

### 2.3 Azure → AWS → GCP Equivalents

| Category | Azure | AWS | GCP |
|---|---|---|---|
| **Container orchestration** | AKS | EKS | GKE |
| **Serverless containers** | Container Apps | App Runner / Fargate | Cloud Run |
| **Ephemeral containers** | ACI | ECS (Fargate, on-demand) | Cloud Run Jobs |
| **PaaS web hosting** | App Service | Elastic Beanstalk | App Engine |
| **Serverless functions** | Function Apps | Lambda | Cloud Functions |
| **Managed PostgreSQL** | Azure Database for PostgreSQL Flexible | RDS (PostgreSQL) | Cloud SQL (PostgreSQL) |
| **Managed Redis** | Azure Cache for Redis | ElastiCache (Redis) | Memorystore (Redis) |
| **Object storage** | Azure Blob Storage | S3 | GCS |
| **Message queue** | Azure Service Bus | SQS / SNS | Pub/Sub |
| **Secret management** | Azure Key Vault | Secrets Manager | Secret Manager |
| **Container registry** | Azure Container Registry (ACR) | ECR | Artifact Registry |
| **DNS** | Azure DNS | Route 53 | Cloud DNS |
| **CDN** | Azure Front Door / CDN | CloudFront | Cloud CDN |
| **Monitoring** | Azure Monitor + App Insights | CloudWatch | Cloud Monitoring |
| **Identity** | Managed Identity | IAM Roles (EC2/ECS) | Workload Identity |

---

## 3. Infrastructure-as-Code: Terraform Standards

### 3.1 Repository Structure

All Terraform code lives in a dedicated `infra/` directory within each solution repo, or in a shared `platform-infra` repo for shared services.

```
infra/
├── modules/                     # Reusable modules (never called directly)
│   ├── aks-cluster/             # AKS cluster module
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── README.md
│   ├── postgres-flexible/       # PostgreSQL Flexible Server module
│   ├── redis-cache/             # Azure Cache for Redis module
│   ├── key-vault/               # Key Vault module
│   ├── container-registry/      # ACR module
│   └── service-bus/             # Service Bus module
│
├── environments/                # Environment-specific configurations
│   ├── dev/
│   │   ├── main.tf              # Calls modules with dev-sized SKUs
│   │   ├── terraform.tfvars     # Dev variable values (committed)
│   │   └── backend.tf           # Remote state config for dev
│   ├── staging/
│   └── production/
│
└── global/                      # Shared resources (ACR, Key Vault root, DNS)
    ├── main.tf
    └── backend.tf
```

**Rules:**
- **Modules** define the *what* — reusable, parameterized, no hard-coded values
- **Environments** define the *how much* — SKU sizes, counts, environment-specific config
- Never put resource definitions directly in `environments/` — always call a module

### 3.2 Remote State Management

**Every environment must use remote state with locking.**

```hcl
# environments/production/backend.tf
terraform {
  backend "azurerm" {
    resource_group_name  = "platform-terraform-state"
    storage_account_name = "tfstatemirketa"
    container_name       = "tfstate"
    key                  = "supplier-compliance/production.tfstate"
    # State locking is automatic via Azure Blob lease
  }
}
```

| Cloud | State Backend | Locking Mechanism |
|---|---|---|
| Azure | Azure Blob Storage | Blob lease (built-in) |
| AWS | S3 + DynamoDB table | DynamoDB conditional write |
| GCP | GCS bucket | GCS object lock |

**Required state configuration:**
- State stored in a **dedicated storage account** — not shared with app data
- State access requires separate RBAC role (not inherited from app permissions)
- State files **never** committed to Git (add `*.tfstate` to `.gitignore`)

### 3.3 Variable Hierarchy

Variables flow from most-general to most-specific:

```
globals.tfvars              (org-wide: region, naming prefix, tags)
    ↓
environments/{env}/terraform.tfvars   (env-specific: SKUs, counts, flags)
    ↓
-var flags in CI/CD pipeline          (secrets injected at runtime — not committed)
```

**Example variable file structure:**

```hcl
# environments/production/terraform.tfvars

# ── Identity ─────────────────────────────────────────
environment         = "production"
location            = "eastus2"
resource_group_name = "supplier-compliance-prod"

# ── Tags (MANDATORY on all resources) ────────────────
tags = {
  solution    = "supplier-compliance"
  environment = "production"
  team        = "ai-platform"
  cost_center = "ai-products"
  managed_by  = "terraform"
}

# ── Sizing ────────────────────────────────────────────
postgres_sku            = "Standard_D2s_v3"
postgres_storage_gb     = 128
redis_sku               = "Standard"
redis_capacity          = 1
aks_system_node_count   = 3
aks_worker_node_count   = 2
aks_worker_node_vm_size = "Standard_D4s_v3"
```

### 3.4 Naming Conventions

```
{solution}-{resource-type}-{environment}[-{suffix}]

Examples:
  supplier-compliance-aks-prod
  supplier-compliance-postgres-prod
  supplier-compliance-redis-dev
  supplier-compliance-kv-prod          (Key Vault — max 24 chars)
  supplier-compliance-acr              (Container Registry — shared, no env suffix)
```

| Rule | Detail |
|---|---|
| Lowercase + hyphens only | No underscores, no uppercase |
| Max 63 chars | Most Azure resources enforce this |
| Abbreviations allowed | `kv` = Key Vault, `acr` = Container Registry, `pg` = PostgreSQL |
| Globally unique resources | Append 4-char random suffix for Storage Accounts, ACR, Key Vaults |

### 3.5 Provider Pinning & Drift Detection

```hcl
# Always pin providers — never use floating versions
terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"    # allows patch/minor updates, blocks major
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}
```

**Drift detection:** Run `terraform plan` in CI on a schedule (daily) against production. Alert if drift is detected (plan is non-empty).

---

## 4. Service Catalogue

Standard supporting services for AI solutions. Use these — don't invent alternatives without platform team approval.

### 4.1 PostgreSQL (Primary Datastore + Vector Store)

**Azure:** PostgreSQL Flexible Server  
**AWS:** RDS PostgreSQL  
**GCP:** Cloud SQL PostgreSQL

```hcl
# Minimum production configuration
module "postgres" {
  source              = "../../modules/postgres-flexible"
  name                = "${var.solution}-pg-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = var.postgres_sku          # "Standard_D2s_v3" minimum for prod
  storage_mb          = var.postgres_storage_gb * 1024
  postgres_version    = "16"
  extensions          = ["vector", "uuid-ossp"]   # pgvector always enabled for AI
  high_availability   = var.environment == "production"
  geo_redundant_backup = var.environment == "production"
  backup_retention_days = 14
  tags                = var.tags
}
```

**Rules:**
- SSL required on all connections (`sslmode=require`)
- Public access disabled — access only via private endpoint or VNet integration
- `pgvector` extension enabled by default on all AI solution DBs
- Separate DB per solution — never share a Postgres server across solutions
- Connection pooling via PgBouncer sidecar on AKS, or use Azure's built-in connection pooling

### 4.2 Redis (Cache, Rate Limiting, Job Queues)

**Azure:** Azure Cache for Redis  
**AWS:** ElastiCache (Redis)  
**GCP:** Memorystore (Redis)

```hcl
module "redis" {
  source              = "../../modules/redis-cache"
  name                = "${var.solution}-redis-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = var.redis_sku      # "Basic" (dev) | "Standard" (prod) | "Premium" (HA)
  capacity            = var.redis_capacity # 1 = 1GB
  tls_only            = true
  tags                = var.tags
}
```

Redis key namespace conventions:
```
{solution}:{purpose}:{key}

Examples:
  supplier-compliance:rate-limit:tenant_abc:2026-07-15
  supplier-compliance:job:status:job_abc123
  supplier-compliance:cache:embedding:sha256:abc...
  supplier-compliance:quota:user_xyz:2026-07-15
```

### 4.3 Temporal (Workflow Orchestration)

Use for Pattern 4 workloads (see Development Standards, Section 4.4).

**Deployment options (in preference order):**

1. **Temporal Cloud** (SaaS) — preferred for new solutions; no infra to manage
2. **Self-hosted on AKS** — use the official Temporal Helm chart; requires Postgres backend

```yaml
# Temporal namespace configuration (one namespace per solution)
temporal:
  namespace: supplier-compliance-prod
  retention: 30d      # workflow history retention
  archival:
    enabled: true
    destination: azure-blob  # archive old histories to blob storage
```

### 4.4 Message Queue (Azure Service Bus / SQS / Pub-Sub)

Use for decoupled event-driven messaging between services (not job queuing — use Redis/BullMQ for that).

```hcl
module "service_bus" {
  source              = "../../modules/service-bus"
  name                = "${var.solution}-sb-${var.environment}"
  resource_group_name = var.resource_group_name
  sku                 = "Standard"     # "Premium" for VNet integration + sessions
  
  queues = [
    { name = "document-intake",  max_delivery_count = 10, lock_duration = "PT5M" },
    { name = "document-intake-dlq" }   # Dead-letter queue
  ]
  
  topics = [
    { name = "assessment-completed" }  # Pub/sub for downstream subscribers
  ]
  tags = var.tags
}
```

### 4.5 Object Storage (Azure Blob / S3 / GCS)

```hcl
# Storage account per solution + environment
module "storage" {
  source                   = "../../modules/storage-account"
  name                     = "sc${var.environment}${random_id.suffix.hex}" # max 24 chars
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  replication_type         = var.environment == "production" ? "GRS" : "LRS"
  public_blob_access       = false         # always disabled
  https_only               = true
  min_tls_version          = "TLS1_2"
  
  containers = [
    { name = "documents",   access = "private" },
    { name = "embeddings",  access = "private" },
    { name = "exports",     access = "private" },
    { name = "tf-state",    access = "private" }  # if hosting Terraform state here
  ]
  tags = var.tags
}
```

### 4.6 Container Registry (ACR)

**One shared ACR per organization** (not per solution). All AI solution images are pushed here.

```
Registry: {org}registry.azurecr.io
Image naming: {org}registry.azurecr.io/{solution-name}/{service-name}:{tag}

Tag convention:
  :latest              ← never use in production (floating)
  :sha-{7-char-git-sha} ← immutable, used for deployment
  :v1.2.3              ← semver release tag, also immutable
  :v1.2.3-sha-abc1234  ← preferred: semver + sha for traceability
```

**Required ACR configuration:**
- Admin user disabled — access via Managed Identity only
- Vulnerability scanning enabled (Defender for Containers or Trivy in CI)
- Geo-replication enabled if serving multiple regions
- Retention policy: delete untagged images older than 30 days

### 4.7 Secret Management (Key Vault / Secrets Manager)

**One Key Vault per environment per solution** (never share Key Vaults across solutions).

```hcl
module "key_vault" {
  source              = "../../modules/key-vault"
  name                = "sc-kv-${var.environment}-${random_id.suffix.hex}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "standard"
  
  # Purge protection MUST be enabled — prevents accidental permanent deletion
  purge_protection_enabled   = true
  soft_delete_retention_days = 90
  
  # Access via RBAC, not access policies (modern approach)
  enable_rbac_authorization = true
  
  # Public access OFF — only via private endpoint
  public_network_access_enabled = false
  tags                          = var.tags
}
```

**Secret naming convention:**
```
{SERVICE}-{SECRET-PURPOSE}

Examples:
  database-url
  llm-openai-api-key
  llm-anthropic-api-key
  redis-connection-string
  inbound-api-key
```

**Injecting secrets into containers (AKS):**
```yaml
# Use CSI Secret Store driver — mounts Key Vault secrets as env vars or files
# Never use static Kubernetes Secrets backed by plaintext values
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: supplier-compliance-secrets
spec:
  provider: azure
  parameters:
    keyvaultName: "sc-kv-production-abc1"
    tenantId: "${AZURE_TENANT_ID}"
    objects: |
      array:
        - objectName: database-url
          objectType: secret
        - objectName: llm-openai-api-key
          objectType: secret
```

---

## 5. Deployment Pipeline (GitOps)

### 5.1 Build → Scan → Push → Deploy Flow

```
[Developer pushes to main / creates release tag]
         │
         ▼
┌─────────────────────────────────────────────────────┐
│                  CI Pipeline (GitHub Actions / ADO)  │
│                                                      │
│  1. Build Docker image                              │
│     docker build -t {registry}/{image}:{sha}        │
│                                                      │
│  2. Vulnerability scan (Trivy / Grype)             │
│     BLOCK on CRITICAL CVEs                          │
│                                                      │
│  3. Push to ACR                                     │
│     Tag: sha-{7-char-git-sha}                       │
│     Tag: v{semver} (on release tags only)           │
│                                                      │
│  4. Update GitOps manifest                          │
│     Bump image tag in infra/k8s/staging/deployment  │
│     Open automated PR or commit directly to GitOps  │
└─────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│            GitOps Controller (ArgoCD / Flux)         │
│                                                      │
│  5. Detects manifest change in Git                  │
│  6. Deploys to Staging automatically                │
│  7. Runs smoke tests against staging                │
│  8. Production deploy: MANUAL GATE (approval)       │
│  9. Deploys to Production                           │
└─────────────────────────────────────────────────────┘
```

### 5.2 Kubernetes Manifest Structure (GitOps Repo)

```
gitops-repo/
├── apps/
│   └── supplier-compliance/
│       ├── base/                    # Common manifests (kustomize base)
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   ├── hpa.yaml
│       │   ├── keda-scaledobject.yaml
│       │   └── kustomization.yaml
│       ├── staging/
│       │   ├── kustomization.yaml   # Overlays: image tag, replica count, env vars
│       │   └── patch-replicas.yaml
│       └── production/
│           ├── kustomization.yaml
│           └── patch-replicas.yaml
│
└── infrastructure/                  # ArgoCD App-of-Apps or Flux Kustomizations
    ├── argocd-apps/
    └── flux-kustomizations/
```

### 5.3 Deployment Strategies

| Strategy | When to Use | How to Implement on AKS |
|---|---|---|
| **Rolling Update** | Default for stateless AI APIs | Kubernetes default deployment strategy |
| **Blue/Green** | Zero-downtime releases of AI services with breaking changes | Two deployments behind one Service; switch via label selector |
| **Canary** | Gradual rollout of new AI model versions; monitor quality metrics before full release | Flagger + KEDA; route 5% → 20% → 50% → 100% traffic |
| **Recreate** | Stateful single-instance services (e.g., Temporal worker) | `strategy: Recreate` in Deployment spec |

**Default for AI APIs: Blue/Green** — because AI behavior changes can be subtle and hard to catch with infrastructure metrics alone. Keep the old version live for 30 minutes after switching, then decommission.

### 5.4 Rollback Strategy

**Application rollback** (bad AI model behavior or bug):
```bash
# ArgoCD: rollback to previous revision
argocd app rollback supplier-compliance --revision 42

# kubectl: manual rollback to previous Deployment revision
kubectl rollout undo deployment/supplier-compliance-engine -n supplier-compliance
```

**Infrastructure rollback** (Terraform):
```bash
# Pull previous state version from Blob Storage versioning
# Apply the previous version's tfvars
terraform apply -var-file=environments/production/terraform.tfvars \
  -target=module.aks_cluster  # scope to affected module only
```

**AI model rollback** (bad model behavior after version bump):
1. Update `LLM_MODEL` env var in Key Vault to previous pinned version
2. Trigger a rolling restart of pods: `kubectl rollout restart deployment/supplier-compliance-engine`
3. Verify via eval metrics that quality has recovered before investigating root cause

---

## 6. Networking & Security

### 6.1 VNet Design for AI Services

All production AI services must be deployed within a Virtual Network (VNet / VPC). No public-IP-only deployments.

```
VNet: 10.0.0.0/16
├── Subnet: aks-nodes          10.0.1.0/24    (AKS node pool)
├── Subnet: aks-pods           10.0.2.0/22    (AKS pod CIDR — must be large)
├── Subnet: private-endpoints  10.0.8.0/27    (all private endpoints land here)
│     ├── PostgreSQL private endpoint
│     ├── Redis private endpoint
│     ├── Key Vault private endpoint
│     ├── Storage Account private endpoint
│     └── Service Bus private endpoint
└── Subnet: management         10.0.9.0/28    (jump box / Bastion)
```

### 6.2 Private Endpoints

Every data service (PostgreSQL, Redis, Storage, Key Vault, Service Bus) must have a **private endpoint**. Public network access must be **disabled**.

```hcl
# Example: PostgreSQL private endpoint
resource "azurerm_private_endpoint" "postgres" {
  name                = "${var.solution}-pe-postgres-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = module.vnet.private_endpoints_subnet_id

  private_service_connection {
    name                           = "postgres-connection"
    private_connection_resource_id = module.postgres.id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }
}
```

### 6.3 WAF Rules for Public AI APIs

All externally-exposed AI APIs must sit behind an Application Gateway or Azure Front Door with WAF enabled.

**Mandatory WAF rules:**
- OWASP Core Rule Set 3.2 (or OWASP CRS 4.x)
- Custom rules for AI-specific abuse:
  - Rate limit: max 100 requests/minute per IP
  - Block oversized payloads: max 1MB request body (adjust per endpoint)
  - Block known prompt injection patterns (custom rule)

```hcl
# Custom WAF rule — block large payloads to AI endpoints
policy_settings {
  enabled                     = true
  mode                        = "Prevention"
  request_body_check          = true
  max_request_body_size_in_kb = 1024   # 1MB
}
```

### 6.4 Network Security Group (NSG) Rules

Minimum NSG rules for AKS node subnet:

| Direction | Priority | Protocol | Source | Destination | Port | Action | Purpose |
|---|---|---|---|---|---|---|---|
| Inbound | 100 | TCP | AppGW Subnet | AKS | 8000-8999 | Allow | App traffic |
| Inbound | 200 | TCP | Management | AKS | 22, 443 | Allow | Admin |
| Inbound | 65000 | Any | Any | Any | Any | Deny | Block all else |
| Outbound | 100 | TCP | AKS | Private Endpoints | 5432, 6379, 443 | Allow | Data services |
| Outbound | 200 | TCP | AKS | Internet | 443 | Allow | LLM provider APIs |
| Outbound | 65000 | Any | Any | Any | Any | Deny | Block all else |

---

## 7. Identity & Access

### 7.1 Managed Identity (No Static Credentials)

**Rule: Never use service principal client secrets or storage account keys in production.**

Every Azure workload must authenticate via **Managed Identity**:

```hcl
# AKS user-assigned managed identity
resource "azurerm_user_assigned_identity" "aks_workload" {
  name                = "${var.solution}-identity-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
}

# Grant identity access to Key Vault (read secrets)
resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = module.key_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.aks_workload.principal_id
}

# Grant identity access to ACR (pull images)
resource "azurerm_role_assignment" "acr_pull" {
  scope                = module.container_registry.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aks_workload.principal_id
}
```

### 7.2 RBAC Per Environment

| Role | Dev | Staging | Production |
|---|---|---|---|
| Developer | Read + Deploy | Read | Read-only (no deploy) |
| Tech Lead | Full | Full | Read + Deploy (with approval) |
| Platform Team | Full | Full | Full |
| CI/CD Service Principal | Deploy-only | Deploy-only | Deploy-only |
| On-call Engineer | Read | Read | Read + Restart pods |

Production changes require **two-person approval** via Git PR — no direct console changes.

### 7.3 Workload Identity for Kubernetes (AKS)

For AKS workloads, use **Azure Workload Identity** (OIDC federation — replaces AAD Pod Identity):

```yaml
# Kubernetes ServiceAccount with Workload Identity annotation
apiVersion: v1
kind: ServiceAccount
metadata:
  name: supplier-compliance-sa
  namespace: supplier-compliance
  annotations:
    azure.workload.identity/client-id: "${MANAGED_IDENTITY_CLIENT_ID}"

---
# Deployment using the ServiceAccount
spec:
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: supplier-compliance-sa
```

---

## 8. Scaling Strategy

### 8.1 API Layer: Horizontal Pod Autoscaler (HPA)

For synchronous REST / streaming API pods:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: supplier-compliance-api-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: supplier-compliance-api
  minReplicas: 2       # always >= 2 for HA
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60    # scale up when avg CPU > 60%
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 70
```

### 8.2 Queue Workers: KEDA (Event-Driven Autoscaling)

For async job workers, scale on **queue depth** — not CPU. A worker can be idle (low CPU) while the queue backs up.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: document-processor-scaledobject
spec:
  scaleTargetRef:
    name: document-processor-worker
  minReplicaCount: 0       # scale to zero when queue is empty (cost saving)
  maxReplicaCount: 10
  triggers:
    - type: azure-servicebus
      metadata:
        queueName: document-intake
        namespace: supplier-compliance-sb-prod
        messageCount: "5"  # 1 worker per 5 queued messages
      authenticationRef:
        name: keda-azure-servicebus-auth
```

**KEDA is the standard for all queue-driven AI workers.** Never use HPA for workers.

### 8.3 GPU Autoscaling (AKS)

For GPU-based inference workloads:

```hcl
# GPU node pool — scales to zero when idle
resource "azurerm_kubernetes_cluster_node_pool" "gpu" {
  name                  = "gpu"
  kubernetes_cluster_id = module.aks_cluster.id
  vm_size               = "Standard_NC4as_T4_v3"  # T4 GPU
  min_count             = 0
  max_count             = 5
  enable_auto_scaling   = true
  node_taints           = ["nvidia.com/gpu=present:NoSchedule"]
  node_labels = {
    "accelerator" = "nvidia-t4"
  }
}
```

Pods requesting GPU must declare tolerations and resource limits:
```yaml
tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
resources:
  limits:
    nvidia.com/gpu: 1
```

---

## 9. Monitoring & Alerting in Production

### 9.1 Required Dashboards

Every production AI solution must have a live dashboard covering:

| Panel | Metric | Alert Threshold |
|---|---|---|
| API p95 Latency | `http.server.latency p95` | > SLA target for workload type |
| API Error Rate | `http.server.error.rate` | > 1% over 5 min |
| LLM Call Latency p95 | `ai.llm.latency p95` | > 5s |
| LLM Error Rate | `ai.llm.errors / ai.llm.requests` | > 5% over 5 min |
| Token Usage/Hour | `ai.llm.tokens.total rate(1h)` | > 80% of quota |
| Queue Depth | `ai.job.queue.depth` | > 100 unprocessed |
| Dead Letter Count | DLQ message count | > 0 (any DLQ message = alert) |
| DB Connections | Postgres active connections | > 80% of max |
| Pod Restart Rate | Kubernetes pod restarts | > 3 in 15 min |

**Tooling:** Azure Monitor + Application Insights (Azure). Prometheus + Grafana (self-hosted on AKS). All emit via OpenTelemetry.

### 9.2 Alerting Rules

Alerts route to Teams/Slack channel first, PagerDuty for P1:

| Severity | Condition | Response Time | Channel |
|---|---|---|---|
| P1 (Critical) | Service completely down, all LLM calls failing | 15 min | PagerDuty + Teams |
| P2 (High) | Error rate > 5%, p95 > 2x SLA target | 1 hour | Teams |
| P3 (Medium) | DLQ messages, quota > 80%, pod restarts | 4 hours | Teams |
| P4 (Low) | Cost budget > 90%, disk > 70% | Next business day | Email |

### 9.3 On-Call Runbook Template

Each AI solution must have a runbook at `docs/runbook.md` covering:

```markdown
# Runbook: {Solution Name}

## Service Overview
Brief description, key endpoints, dependencies.

## Alert: LLM_UNAVAILABLE
**Symptoms:** 503 errors on AI endpoints, circuit breaker OPEN
**Immediate action:**
1. Check LLM provider status page
2. Verify API key not expired: `az keyvault secret show --name llm-openai-api-key`
3. Manually switch provider: update `LLM_PROVIDER` in Key Vault, restart pods
**Escalation:** If not resolved in 30 min, page Tech Lead

## Alert: HIGH_QUEUE_DEPTH
**Symptoms:** KEDA not scaling workers fast enough
**Immediate action:**
1. Check worker pod logs: `kubectl logs -l app=document-processor -n supplier-compliance`
2. Manually scale workers: `kubectl scale deployment document-processor --replicas=N`
3. Check DLQ for poison messages

## Rollback Procedure
See Section 5.4 of Deployment Standards.
```

---

## 10. Cost Management

### 10.1 Mandatory Tagging Strategy

**Every Azure resource must have all of these tags.** Terraform modules enforce this via `variable "tags"` with validation.

```hcl
tags = {
  solution    = "supplier-compliance"    # which AI product
  environment = "production"             # dev | staging | production
  team        = "ai-platform"            # owning team
  cost_center = "ai-products"            # for billing allocation
  managed_by  = "terraform"              # terraform | manual (flag manual resources)
}
```

Azure Policy will be used to enforce that untagged resources cannot be created in production resource groups.

### 10.2 Reserved vs. Spot/Preemptible

| Workload | Compute Strategy | Rationale |
|---|---|---|
| API pods (min replica) | Reserved instances (1-year) | Always-on, predictable |
| API pods (burst replicas) | On-demand | Pay only when needed |
| Queue workers (KEDA) | Spot VMs / Azure Spot Nodes | Can tolerate eviction; KEDA re-schedules |
| GPU inference (batch) | Spot VMs | Up to 90% savings; eviction-tolerant batch jobs |
| Databases | Reserved (1-year) | Always-on, significant savings |

### 10.3 Budget Alerts

```hcl
resource "azurerm_consumption_budget_resource_group" "solution_budget" {
  name              = "${var.solution}-budget-${var.environment}"
  resource_group_id = azurerm_resource_group.main.id
  amount            = var.monthly_budget_usd
  time_grain        = "Monthly"

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    contact_emails = var.budget_alert_emails
    contact_roles  = ["Owner"]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    contact_emails = var.budget_alert_emails
    contact_roles  = ["Owner", "Contributor"]
  }
}
```

---

## 11. Disaster Recovery

### 11.1 Backup Schedule

| Service | Backup Method | Frequency | Retention |
|---|---|---|---|
| PostgreSQL | Azure automated backup | Daily (continuous WAL) | 14 days |
| Redis | Azure Redis persistence (RDB snapshot) | Every 60 min | 7 days |
| Blob Storage | Soft delete + point-in-time restore | Continuous | 30 days |
| AKS cluster config | Terraform state (remote) | On every apply | Indefinite (versioned) |
| Key Vault secrets | Soft delete + purge protection | Continuous | 90 days |
| AI model weights / embeddings | Blob storage (GRS replication) | On change | 5 versions |

### 11.2 RTO / RPO Targets

| Environment | RTO | RPO | Strategy |
|---|---|---|---|
| Development | 4 hours | 24 hours | Restore from backup |
| Staging | 2 hours | 4 hours | Restore from backup |
| Production | 30 minutes | 1 hour | Hot standby + failover |

**Production DR approach:**
- **Database:** PostgreSQL geo-redundant backup → restore to replica in secondary region
- **AKS:** Terraform can recreate the cluster in < 20 minutes; stateless services recover immediately
- **Storage:** GRS (Geo-Redundant Storage) for Azure Blob — secondary region read access
- **DNS failover:** Azure Traffic Manager or Front Door for automatic failover routing

### 11.3 DR Drill Schedule

- **Quarterly:** Restore PostgreSQL backup to staging and verify data integrity
- **Semi-annual:** Full DR drill — simulate region outage, measure actual RTO vs. target

---

## 12. Solution Onboarding Checklist

When deploying a **new AI solution** to production for the first time, verify all items are complete:

### Infrastructure
```
☐ Terraform module exists for all required services (not console-created)
☐ Remote Terraform state configured with locking
☐ All resources tagged with mandatory tags
☐ Private endpoints enabled on all data services
☐ Public network access disabled on databases, storage, Key Vault
☐ Managed Identity configured — no static credentials in use
☐ RBAC roles assigned per environment (Section 7.2)
☐ Budget alert configured
☐ VNet integration verified (nslookup resolves private endpoints)
```

### Deployment Pipeline
```
☐ GitOps repo has manifests for staging and production
☐ Image tag is SHA-pinned (not :latest) in production manifests
☐ Container image vulnerability scan passing (no CRITICAL CVEs)
☐ Production deploy requires manual approval gate
☐ Rollback procedure documented in runbook
```

### Scaling & Reliability
```
☐ HPA configured for API pods (min 2 replicas)
☐ KEDA configured for queue workers (min 0)
☐ Pod disruption budget set (minAvailable: 1 for APIs)
☐ Liveness and readiness probes configured
☐ Resource requests and limits set on all containers
```

### Security
```
☐ WAF enabled on all public endpoints
☐ NSG rules reviewed and locked down
☐ Secrets injected via CSI driver from Key Vault
☐ TLS enabled on all endpoints
☐ API authentication tested end-to-end
```

### Monitoring
```
☐ Dashboard created covering all required panels (Section 9.1)
☐ Alerts configured with correct routing (Teams + PagerDuty)
☐ Runbook written and reviewed
☐ On-call rotation assigned
```

### Compliance (for regulated solutions)
```
☐ Audit log table created and immutable constraints verified
☐ PII scrubbing verified in log pipeline
☐ Data residency requirements met (region confirmed)
☐ Backup schedule verified and first backup confirmed
☐ DR drill scheduled
```

---

## Appendix A: Terraform Module Interface Standard

Every module must expose this standard variable set (in addition to module-specific variables):

```hcl
# Standard variables required on every module
variable "name"                { type = string }
variable "resource_group_name" { type = string }
variable "location"            { type = string }
variable "environment"         { type = string; validation { condition = contains(["dev","staging","production"], var.environment) } }
variable "tags"                { type = map(string) }

# Standard outputs required on every module
output "id"   { value = azurerm_*.main.id }
output "name" { value = azurerm_*.main.name }
```

---

## Appendix B: Cloud Provider Quick Reference

| Operation | Azure CLI | AWS CLI | gcloud |
|---|---|---|---|
| Login | `az login` | `aws configure` | `gcloud auth login` |
| Set subscription/account | `az account set --subscription` | `aws configure --profile` | `gcloud config set project` |
| List AKS/EKS/GKE clusters | `az aks list` | `aws eks list-clusters` | `gcloud container clusters list` |
| Get kubeconfig | `az aks get-credentials` | `aws eks update-kubeconfig` | `gcloud container clusters get-credentials` |
| Push to registry | `az acr login && docker push` | `aws ecr get-login-password \| docker login` | `gcloud auth configure-docker` |
| View Key Vault secrets | `az keyvault secret list` | `aws secretsmanager list-secrets` | `gcloud secrets list` |

---

*This document should be reviewed and updated every 6 months or when a new cloud service or deployment pattern is adopted. Suggest changes via PR.*
