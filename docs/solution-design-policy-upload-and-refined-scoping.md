# Solution Design — Internal Policy Upload + Re-Scope Fan-Out (Feedback 1) & Finer-Grained Checklist Inputs (Feedback 2)

**Status:** draft for review — assessed against the current implementation (verified by
reading `ingest_policies.py`, `common.py`, `app.py`, `VendorPortalController.cls`), not a
literal transcription of the feedback.

---

## 0. What already exists (verified) vs. what's genuinely new

| Piece | Status |
|---|---|
| Policy corpus storage — `policy_chunk` table (Postgres/pgvector) | ✅ exists — stays exactly as-is, no schema change |
| Chunking/embedding pipeline (`chunk_text`, `embed_texts`, `guess_domain` in `common.py`) | ✅ exists — reused as-is by the new endpoint |
| Hybrid retrieval (`/scope`'s `retrieve()` — dense + sparse + RRF) | ✅ exists — unchanged; doesn't know or care where a chunk came from |
| Deterministic domain→document + industry→domain rules (`DOMAIN_TO_DOCUMENT`, `INDUSTRY_DOMAINS`) | ✅ exists — reused for the fan-out join key |
| Any UI/Apex path for a human to upload a policy document | ❌ none — today ingestion is a **manual script run against an SFTP folder only the developer can reach** — **new** |
| Any Salesforce-visible record of what's in the corpus | ❌ none — **new** (`Policy_Document__c`) |
| Any endpoint that accepts a policy document over HTTP | ❌ none — `ingest_policies.py` only reads from SFTP — **new** (`/policy/ingest`) |
| Any batch/re-evaluation mechanism for existing suppliers | ❌ none — **new** (`RescopeBatch`) |
| Structured material/service-type input on checklist generation | ❌ none — today it's one blended free-text `commodity` string (`VendorPortalController.buildScopeContext`) — **new fields + a second matching table** |

---

## 1. Where this is NOT a literal transcription of the feedback (and why)

1. **"Vectorization... stored in Salesforce"** — the user confirmed (after being asked) that
   the *file + status* should live in Salesforce, but the **vectors stay in Postgres**,
   exactly where they are today. Moving embeddings into Salesforce would mean replacing a
   working hybrid-search engine (dense+sparse+RRF) with a Salesforce-native equivalent —
   a much larger, riskier re-architecture with no stated benefit. Salesforce becomes the
   **upload/visibility/governance layer**, not the vector store. This mirrors the exact
   division of labor the platform already uses for supplier documents (`Compliance_Document__c`
   is the Salesforce record; the actual assessment/extraction logic runs in the engine).
2. **"Re-scope existing suppliers"** — the user explicitly chose this (harder) option over
   "going forward only." Because of that, this design is **not purely additive** — new
   ingestion has to identify and fan out to affected suppliers. To keep this from silently
   overriding a Procurement Manager's prior review, re-scope results land in a
   **Pending Review** state rather than auto-updating the checklist — consistent with the
   "human-in-the-loop always" decision already made for Req 1's renewal flow.
3. **Feedback 2's "few more input options"** — rather than replacing `buildScopeContext`'s
   blended string, this adds explicit structured fields **alongside** it. The existing
   Industry + Engagement Type + Annual Spend blend stays (other logic may depend on it);
   new Material Type / Service Category fields sharpen the same query rather than replacing
   working inputs.

---

## 2. Feedback 1 — Internal Policy Upload, Vectorization, and Re-Scope Fan-Out

### 2.1 Architecture shape

```
Procurement Manager (internal, non-portal)
  └─▶ scPolicyUpload LWC — upload file, optional domain override
        └─▶ creates Policy_Document__c (Status__c = 'Uploaded') + ContentVersion
              └─▶ Policy_Document_Uploaded__e (Platform Event, modeled on Document_Uploaded__e)
                    └─▶ PolicyIngestQueueable
                          ├─▶ POST /policy/ingest (engine) — parse → chunk → embed → upsert policy_chunk
                          │     returns {domain, chunkCount, version}
                          ├─▶ update Policy_Document__c: Status__c='Ingested', Chunk_Count__c, Corpus_Version__c
                          └─▶ resolve affected industries (INDUSTRY_DOMAINS reverse lookup on returned domain)
                                └─▶ SELECT Account WHERE Industry IN :affectedIndustries AND already-scoped
                                      └─▶ Database.executeBatch(RescopeBatch, 50)
                                            └─▶ per Account: re-run existing ScopeCalloutQueueable → ScopeService.getScope()
                                                  └─▶ new items land as Checklist_Item__c (or equivalent) with
                                                      Review_Status__c = 'Pending Review' — NOT auto-applied
                                                      └─▶ notify Owning_Procurement_User__c (Custom Notification,
                                                          same pattern as existing doc-assessment notifications)
```

### 2.2 New Salesforce components

**Object: `Policy_Document__c`** (internal-only — permission set excludes portal profiles)
| Field | Purpose |
|---|---|
| `Name` | file/document name |
| `Domain__c` (picklist: conflict/trade/finance/quality/material/cyber/auto-detect) | manual override; blank = engine's `guess_domain` decides |
| `Status__c` (Uploaded / Processing / Ingested / Failed) | upload lifecycle |
| `Chunk_Count__c` (Number) | returned by `/policy/ingest`, shown to the Procurement Manager as ingestion confirmation |
| `Corpus_Version__c` (Text) | same versioning scheme `ingest_policies.py` already uses (ingest-date based) |
| `Affected_Supplier_Count__c` (Number) | filled in after fan-out — how many suppliers got a pending re-scope |
| `Ingested_Date__c` (DateTime) | |

**LWC `scPolicyUpload`** — reuses the existing `lightning-file-upload` + `ContentVersion` pattern already used in `scProcurementDocumentUploader`; new record creation only, no new upload mechanism to invent.

**New Platform Event `Policy_Document_Uploaded__e`** — `Policy_Document_Id__c`, `Domain_Override__c` — directly modeled on the existing `Document_Uploaded__e`, same async decoupling rationale (upload response shouldn't block on a potentially-slow embed+ingest call).

**New Apex:**
- `PolicyIngestQueueable` — the callout + status update + fan-out trigger
- `RescopeBatch implements Database.Batchable<Id>` — iterates affected Accounts in chunks of 50 (governor-limit-safe callout batching, same pattern precedent as the Req 1/2 batch designs), re-invokes the **existing** scope-generation path per account — no new checklist-generation logic, just re-triggering it
- New field(s) on whatever object holds checklist items today — `Review_Status__c` (Pending Review / Confirmed / Dismissed) — so a re-scope's new items are visibly distinct from the Procurement Manager's already-confirmed checklist

### 2.3 New engine component

**`POST /policy/ingest`** — accepts `{documentBase64, fileName, domainHint}`, returns `{domain, chunkCount, version}`. Internally this is almost entirely `ingest_policies.py`'s existing functions (`parse_file`, `chunk_text`, `guess_domain`, `embed_texts`, the `UPSERT_SQL` upsert) — the only new code is the FastAPI route handler and base64 decode. This becomes the real ingestion path going forward; the manual SFTP script (`ingest_policies.py`) can stay as a bulk/offline tool but stops being the only way in.

**No change to `/scope`, `retrieve()`, or the deterministic rule tables** — new policy chunks are just more rows in `policy_chunk`; retrieval logic is unaware of and unaffected by their source.

### 2.4 Fan-out join key — how "affected suppliers" is determined

`INDUSTRY_DOMAINS` (in `app.py`) already maps industries → their guaranteed domains (e.g. `"electronics": ["material", "cyber", "conflict", "quality"]`). A newly-ingested policy's resolved `domain` is reverse-looked-up against this table to get the set of industries it's relevant to, which becomes the `Account.Industry IN (...)` filter for the batch. This reuses an existing table rather than inventing a new mapping.

### 2.5 Open decision carried forward

Same as Req 1's open item: population of `Owning_Procurement_User__c` (who gets notified when a re-scope produces pending items) — this design assumes that field/lookup exists or is added as part of Req 1; if Req 1 hasn't shipped yet, this notification step has no target and would need a fallback (e.g. notify a queue/public group).

---

## 3. Feedback 2 — Finer-Grained Checklist Inputs (Material Type / Service Category)

### 3.1 The gap, precisely

`VendorPortalController.buildScopeContext(industry, engagementType, annualSpend)` ([VendorPortalController.cls:220](../supplierCompliance/force-app/main/default/classes/VendorPortalController.cls#L220)) blends three signals into one free-text string that becomes `ScopeRequest.commodity` — the single field driving both the RAG embedding query and the `INDUSTRY_DOMAINS` substring match. There's no separate, structured "what raw material" or "what service" input anywhere in the UI or Apex today.

### 3.2 Proposed addition (additive, not a replacement)

- New optional UI inputs on checklist generation: **Material Type** (picklist: e.g. conflict-mineral-bearing metals, chemicals, electronics components, packaging, none/not-applicable) and **Service Category** (picklist: e.g. logistics, IT/software, professional services, manufacturing-subcontract)
- `ScopeService.ScopeRequest` gains two new optional fields: `materialType`, `serviceCategory`
- `buildScopeContext` keeps its existing blend AND appends these new values when present — sharpens the same query string, doesn't replace working inputs
- Engine-side: a second, more specific keyword table (parallel structure to `INDUSTRY_DOMAINS`) keyed on `materialType`/`serviceCategory` values, unioned with the existing industry-based domain guarantee — e.g. `materialType: "conflict-mineral-bearing metals"` guarantees the `conflict` domain regardless of what industry substring matching alone would catch, tightening precision for suppliers whose industry text is generic but whose actual material is sensitive

### 3.3 Why this is low-risk

Both new fields are optional and additive — a supplier scoped without them behaves exactly as today. This is a precision improvement for users willing to provide more detail, not a breaking change to the existing flow.

---

## 4. Build sequencing

Feedback 1 and Feedback 2 don't share code but do share one dependency: Feedback 1's re-scope fan-out re-invokes the same `/scope` call path that Feedback 2 sharpens — so shipping Feedback 2 first means Feedback 1's re-scopes are already more precise from day one. Feedback 1 does not need to wait on Feedback 2, but sequencing Feedback 2 first is slightly higher-leverage.

Feedback 1 has an internal dependency order of its own: `Policy_Document__c` + upload LWC → `/policy/ingest` engine endpoint → `PolicyIngestQueueable` → `RescopeBatch` + `Review_Status__c` — each step is independently testable before the next is built.
