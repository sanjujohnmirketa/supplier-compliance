# Evaluation — Replace pgvector with Salesforce Data Cloud (Data 360) for Vector Storage

**Question:** Should we replace the engine's pgvector store with Salesforce Data
Cloud's (now **Data 360**) vector database to strengthen Salesforce-centric positioning?

**TL;DR recommendation:** **Do not replace pgvector for the core RAG engine now.**
Adopt a **hybrid posture**: keep pgvector as the engine's retrieval store (it is fast,
free, on-prem-deployable, and already tuned), and position Data 360 vector search as the
**Salesforce-native option for a future fully-in-platform deployment** and for indexing
CRM-resident unstructured data (e.g. document text already synced to Salesforce). Revisit
a full migration only if (a) the product must run with **zero external services** and
(b) Salesforce confirms **bring-your-own-embedding** parity. See the decision gate at the end.

---

## 1. What we have today (the baseline)

| Aspect | Current implementation |
|---|---|
| Store | Postgres + `pgvector` (cosine `<=>`), runs in local Docker / on-prem |
| Embeddings | `all-MiniLM-L6-v2`, **384-dim**, local, no API key, offline |
| Retrieval | **Hybrid**: dense (pgvector) + sparse (`tsvector` BM25-style) fused with **RRF** (k=60), dense relevance floor 0.32 |
| Cost | $0 (open-source, self-hosted) |
| Latency | Single-digit ms vector search; co-located with the engine |
| Coupling | Provider-agnostic; the engine is deployable on-prem / air-gapped |

This is a deliberate design choice tied to a hard product constraint: **"I cannot store
keys in my environment and expect an external user to use it"** — i.e. the engine must be
**self-hostable with no mandatory external dependency**. pgvector satisfies that.

---

## 2. What Salesforce Data 360 vector DB offers

(Verified against Salesforce docs / Salesforce Ben, June 2026 — see Sources.)

- **GA vector database** inside Data 360 (rebranded from Data Cloud, Oct 2025). Backed by
  **Hyper (native) and Milvus** for indexing.
- **Chunk → embed → index** pipeline on unstructured data in DMOs/UDMOs; OOTB + pluggable
  chunking/embedding models. Recommended chunking 400–600 tokens, 50–100 overlap.
- **Hybrid search** (semantic + keyword) is supported natively — good, it matches our RRF intent.
- **Native to the platform**: embeddings + retrieval live next to CRM data; consumable by
  Agentforce / Prompt Builder / Einstein with no egress.
- **Consumption-priced** (credits): hybrid search costs **~2× the credits of vector search**;
  credits ≈ (data volume / 1M) × multiplier; structured Salesforce data ingest is now free,
  but **search/index operations and unstructured pipelines consume credits**.

---

## 3. Side-by-side

| Dimension | pgvector (current) | Data 360 vector DB |
|---|---|---|
| **Salesforce-native positioning** | ❌ external engine | ✅ fully in-platform, Agentforce-ready |
| **Cost model** | $0, fixed (self-host) | Consumption credits; hybrid = 2× vector; scales with volume + query rate |
| **On-prem / air-gapped** | ✅ yes | ❌ no — it is a Salesforce cloud service |
| **Bring-your-own embedding (MiniLM-384)** | ✅ full control | ⚠️ **must confirm** — OOTB + "pluggable" models advertised; 384-dim BYO parity unverified |
| **Hybrid (dense+sparse) search** | ✅ custom RRF, tuned (floor 0.32) | ✅ native hybrid (less tuning control) |
| **Latency** | ✅ ms, co-located with engine | Network hop from engine → Salesforce API; fine for UI, slower for tight agent loops |
| **External app access** | ✅ engine owns it | ⚠️ engine would query Salesforce Connect/Query API (auth + governor/credit considerations) |
| **Tuning control** (k, floor, fusion) | ✅ total | ⚠️ limited to Data 360 config knobs |
| **Ops burden** | Run Postgres | ✅ managed by Salesforce |
| **Vendor lock-in** | low | high |

---

## 4. Analysis against *our* constraints

1. **On-prem / no-external-dependency is a stated product constraint.** Data 360 is a
   cloud service — moving core RAG there **breaks the air-gapped deployment story**. This
   is the single biggest blocker.
2. **Embedding parity is the technical crux.** Our retrieval is tuned around MiniLM-384 +
   RRF + a 0.32 floor. If Data 360 cannot index **our** 384-dim vectors (BYO embedding),
   we would be forced onto its embedding model → re-tuning, re-validation of the eval gate
   (currently 8/8), and a different relevance profile. **Confirm BYO-embedding before
   considering migration.**
3. **Cost flips from fixed to consumption.** pgvector is $0. Data 360 charges per
   index/search; **hybrid (which we rely on) is 2× vector**. For a high-query agent loop
   (per-document assess, co-pilot, re-synthesis) this is a recurring, volume-scaling cost.
   Recall the earlier Fly/MPG decision was reverted partly on a **$38/mo** line — a
   consumption vector bill warrants the same scrutiny.
4. **Latency.** Today retrieval is co-located with the engine (ms). Routing every
   `retrieve()` through the Salesforce API adds a network hop and governor/credit surface
   to the agent's hot path.
5. **Positioning upside is real but partial.** "Salesforce-centric" is a genuine GTM win —
   but it is achievable **without** ripping out pgvector by using Data 360 vector search
   for **CRM-resident unstructured data** (document text already synced to Salesforce) and
   surfacing it to Agentforce, while the engine keeps its own tuned store for policy RAG.

---

## 5. Recommendation — hybrid, staged

**Now (keep):** pgvector remains the engine's retrieval store for policy RAG and document
clauses. It is free, on-prem-capable, tuned, and passing the eval gate. No migration.

**Position (parallel):** Present Data 360 vector search as the **Salesforce-native
deployment option** — for customers who want everything in-platform and Agentforce
integration, and for indexing **document text that already lives in Salesforce**. This
captures the Salesforce-centric narrative without sacrificing the on-prem story.

**Later (decision gate):** Migrate the core store to Data 360 **only if ALL hold**:
- [ ] Product no longer needs an on-prem / air-gapped deployment, AND
- [ ] Salesforce confirms **BYO 384-dim embedding** (or we accept re-tuning to its model)
      and we **re-run the eval harness to ≥ the current 8/8**, AND
- [ ] Modeled **consumption cost** at expected query volume is acceptable vs. $0 today, AND
- [ ] Measured **retrieval latency** via the API is acceptable on the agent hot path.

---

## 6. Open items to confirm with Salesforce
- BYO embedding model + **384-dim** support (or required dimension/model).
- External (non-SF) app retrieval pattern + auth + whether it consumes credits per query.
- Credit cost of our actual query mix (assess + co-pilot + re-synthesis) at target volume.
- Index/chunk count limits relative to our policy corpus + per-supplier document volume.

---

## Sources
- [Salesforce — Vector Search (help.salesforce.com)](https://help.salesforce.com/s/articleView?id=data.c360_a_search_index_vector_index.htm&language=en_US&type=5)
- [Salesforce — Data Cloud Vector Database GA announcement](https://www.salesforce.com/news/stories/data-cloud-vector-database-availability/)
- [Salesforce Ben — Data 360 Vector Database Deep Dive](https://www.salesforceben.com/data-360-formerly-data-cloud-deep-dive-your-guide-to-the-vector-database/)
- [Salesforce — Create a Vector Search Index (Advanced Setup)](https://help.salesforce.com/s/articleView?id=data.c360_a_search_index_create_vector_index_config.htm&language=en_US&type=5)
- [Salesforce Data 360 Credit Optimization Guide (Mar 2026)](https://www.jitendrazaa.com/blog/salesforce/salesforce-data-360-credit-optimization-guide-march-2026/)
- [Salesforce — Data Cloud Pricing Updates](https://www.salesforce.com/blog/data-cloud-pricing-updates/)
