# Presentation Script — Supplier Compliance on Salesforce Data Cloud

**Diagram:** "Supplier compliance — Salesforce Data Cloud pipeline"
*CRM & external feeds → ingest → raw → canonical → identity resolution → insights → write-back*
**Audience:** VP / exec stakeholders. **Goal:** they leave believing this strengthens our
Salesforce-centric position and unlocks the multi-tier visibility no competitor offers.

---

## PART 1 — The high-level story (the 60-second version)

> *Say this while the full diagram is on screen.*

"What you're looking at is how supplier compliance data flows through **one Salesforce
estate** — no external database, no separate system to license or secure.

On the **left**, Salesforce CRM stays our **system of record** — the supplier Account,
the documents, the AI assessments, the invitations. That's where the work happens.

Everything to the **right** is **Salesforce Data Cloud**. Its job is to take that
CRM data — *and* the Tier-2 and Tier-3 supplier feeds we can't license into CRM — and run
them through a five-step pipeline: **ingest, land it raw, shape it into a canonical model,
resolve identity into one golden supplier, then compute the compliance and risk scores.**

The payoff is the **orange line at the top** — those scores get **written straight back to
the CRM Account**. So a procurement manager working inside Salesforce sees not just *'is
this supplier compliant?'* but *'is its entire supply chain compliant?'* — the
**cascading risk across every tier** — without ever leaving the platform.

That's the whole thesis in one picture: **the supply-chain risk that's invisible to Ariba
and Coupa becomes a field on the Account, computed in our own platform, ready for
Agentforce.**"

**Three things to land before going deeper:**
1. **One platform.** CRM is the system of record; Data Cloud is the intelligence layer. No external portal DB to run or secure.
2. **Identity resolution is the unlock.** It stitches CRM suppliers and external Tier-2/3 suppliers into one golden record — *that's* what makes cross-tier roll-up possible.
3. **The write-back is the product.** Insights don't sit in Data Cloud; they land on the Account where procurement and the analyst already work.

---

## PART 2 — The granular walkthrough (how I foresee the implementation)

> *Walk the diagram left-to-right. Each stage: what it is, how we build it, and why it
> matters to the functional vision.*

### Stage 0 · Salesforce CRM — system of record  *(the blue zone)*
**What:** the Account (T1→T2→T3 via `ParentId` cascade), `Compliance_Assessment__c`
(one per required document, with the AI verdict), `Compliance_Document__c` +
`Document_Extraction__c`, and `Supplier_Invitation__c` (the sub-supplier invite).
**How:** this is what we've **already built** — the agentic engine scopes, screens,
assesses, and writes verdicts to these records. Nothing here changes.
**Why it matters:** the transactional onboarding — intake, checklist, upload, AI review,
decision — *stays in Salesforce*, where the human work and the audit trail live. Data
Cloud never owns the workflow; it observes it.

### Stage 1 · Data Streams — ingest  *(DS_CRM_*, DS_EXTERNAL_TIER23)*
**What:** the pipelines that pull data in — three from CRM (Account, Assessment,
Document) and one from **external Tier-2/3 feeds** (Ingestion API or SFTP).
**How:** Salesforce-managed connectors for CRM (incremental refresh); an Ingestion API or
SFTP stream for the sub-suppliers that don't have a Salesforce license.
**Why it matters:** this is the moment **Tier-2/3 enter the picture**. The suppliers
that are invisible today — because no tool reaches past Tier-1 — get a front door here,
*without* paying for a Salesforce seat per supplier.

### Stage 2 · Data Lake Objects — raw  *(DLO_*)*
**What:** the raw landing zone — each stream lands as-ingested into a DLO.
**How:** automatic; the DLO captures the initial state, untouched.
**Why it matters:** one honest line for the exec — *"this is just the raw landing zone;
nothing is interpreted yet."* It's the foundation the canonical model is built on, and the
audit-grade record of exactly what we received.

### Stage 3 · Data Model Objects — canonical  *(DMO_SUPPLIER, DMO_COMPLIANCE, DMO_DOCUMENT)*
**What:** the **business-ready, standardized** model — raw DLOs mapped into clean
canonical objects: a Supplier, a Compliance Status, a Document.
**How:** field-level mappings from DLO → DMO; each DMO carries a required primary key. The
CRM Account *and* the external supplier feed **both map into the same `DMO_SUPPLIER`** —
that's the convergence point.
**Why it matters:** this is where *"a CRM Tier-1"* and *"an external Tier-3"* stop being
two different shapes and become **the same kind of thing** — a Supplier. Without this,
there's no common model to roll risk across.

### Stage 4 · Identity Resolution — the golden, cross-source tier tree  *(IR_RULESET → UNIFIED_SUPPLIER)*
**What:** the rules that match and merge supplier records across sources into **one
Unified Supplier** — the golden record.
**How:** match on **name + tax id + country** (exact + fuzzy), reconcile by source
priority / recency. The Unified Supplier carries the **parent link**, so the cascade is
preserved *across* CRM and external sources — the **cross-source tier tree**.
**Why it matters:** **this is the keystone.** In the old design we leaned on a foreign
key. Here, identity resolution *is* the link — it's what lets a Tier-3 supplier sitting in
an external feed connect to its Tier-1 parent sitting in CRM. **No identity resolution, no
multi-tier roll-up.** Say this one slowly.

### Stage 5 · Calculated Insights — the scores  *(CI_COMPLIANCE_SCORE, CI_CASCADING_RISK)*
**What:** two computed scores per Unified Supplier — its **own** compliance score, and the
**cascading risk** = *worst-of-subtree* across all its descendants.
**How:** Calculated Insights over the unified hierarchy. Own-score is straightforward;
the cascading "worst-of-subtree" is the multi-tier roll-up — *(flag honestly: if a
Calculated Insight can't express full descendant traversal, we keep the roll-up as Apex in
CRM and use Data Cloud for unification + own-score — same result, different engine.)*
**Why it matters:** **this is the differentiator made into a number.** "Own = Compliant,
cascading = High — because a Tier-3 supplier three levels down let its insurance lapse."
That sentence is the entire product vision.

### The write-back — insight → Account  *(the orange line)*
**What:** a **Data Action** pushes both scores back onto the CRM **Account**
(`Cascading_Risk_Tier__c`, `Cascading_Risk_Source__c`).
**How:** Data Action / Flow on insight change, writing to the Account the procurement team
already works in.
**Why it matters:** the loop closes **inside Salesforce**. The analyst and procurement
manager see cascading risk *as a field on the record*, drill into the offending tier, and
the same unified profile **grounds Agentforce** — so the co-pilot reasons over the whole
supply chain, not one supplier.

---

## PART 3 — How this ties to the functional vision  *(the closing)*

> *Bring it back up to altitude to close.*

"So follow the thread end to end:

- A supplier **self-registers** or gets invited → an **Account** is created in CRM.
- The **agentic engine** scopes, screens, and assesses its documents → verdicts land on
  CRM records.
- A **Tier-1 invites its Tier-2s, who invite their Tier-3s** → those sub-suppliers feed in
  through the external stream.
- **Data Cloud unifies** all of them into one golden supplier tree, and **computes the
  cascading risk** across every tier.
- That risk **writes back to the Account** — so the buyer sees, in real time, that a
  spotless Tier-1 is sitting on a non-compliant Tier-3.

That last sentence is the whole point. **Ariba and Coupa stop at Tier-1. We propagate risk
across the entire chain — and we do it on one Salesforce platform, with the same data that
grounds our AI co-pilot.** That's reactive compliance turning into *predictive risk
intelligence* — exactly the vision, now with the data architecture to deliver it."

---

## Appendix — anticipated questions (have these ready)

| If they ask… | Answer in one line |
|---|---|
| *Why not keep an external portal DB?* | One platform = less to secure/license; and the unified profile grounds Agentforce natively. |
| *Where do Tier-2/3 portal logins live?* | Not in Data Cloud (it's not an auth store) — Experience Cloud / Salesforce Identity, or a thin auth service. The one piece outside this picture. |
| *Can the roll-up really run in Data Cloud?* | Own-score yes; full descendant "worst-of-subtree" needs validation — fallback is Apex roll-up in CRM. Same output, decision pending a spike. |
| *What does it cost?* | Data Cloud is consumption-priced (ingest + identity + insights). We model volume before committing — covered in the pgvector-vs-Data-Cloud evaluation. |
| *How fresh is the buyer's dashboard?* | Near-real-time via the Data Action write-back; pair with event-driven Apex if we need instant. |
