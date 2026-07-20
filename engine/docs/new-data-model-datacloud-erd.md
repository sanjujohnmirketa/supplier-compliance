# New Data Model — Salesforce Data Cloud (Data 360) Implementation

Target data model after the architecture shift, with the **external Postgres portal
replaced by Salesforce Data Cloud (Data 360)** — keeping the platform Salesforce-centric.

> Paste any ```mermaid``` block into draw.io (Arrange → Insert → Advanced → Mermaid).

**Legend:** `[CRM]` Salesforce CRM object · `[DC-DLO]` Data Cloud Data Lake Object (raw
ingest) · `[DC-DMO]` Data Cloud Data Model Object (mapped, business-ready) · `[DC-IR]`
Identity Resolution · `[RAG]` engine pgvector · `★` = new for the shift.

---

## 0. What changes vs. the Postgres version (read this first)

Data Cloud is **not** a transactional app database — so it is not a 1:1 swap for the
Postgres portal. The differences shape the whole model:

| Concern | Postgres portal (old) | Data Cloud (Data 360) |
|---|---|---|
| Raw ingest | tables you write directly | **Data Stream → DLO** (ingested/federated) |
| Business model | tables + FKs | **DMO** (mapped from DLOs); related by **mappings + Identity Resolution**, not FKs |
| Cross-system key | `sf_account_id` FK column | **Identity Resolution** unifies → Unified Individual / Unified Account; CRM `Account.Id` is the match key |
| **Credentials / auth / tokens** | `supplier_portal_users` (bcrypt) | ❌ **DOES NOT belong in Data Cloud** — auth lives in Experience Cloud / Salesforce Identity (or a thin auth service). Data Cloud is analytical/unified-profile, not an OLTP auth store |
| OLTP writes (invite accept, status flip) | direct DB writes | happen in **CRM** (Apex/Flow); Data Cloud **ingests** the result for unification/analytics/segmentation |
| What it's FOR | run the portal | **unify + score + segment + activate** supplier/document/compliance data across tiers, feed Agentforce/Einstein, push insights back to CRM |

**Net:** transactional supplier onboarding stays in **CRM** (Accounts, the Veera app,
invitations, the agent case). **Data Cloud sits alongside** as the unification + analytics
+ activation layer — ingesting CRM data and any external/Tier-2-3 feeds, resolving
identity across them, computing compliance/risk insights, and writing those insights back
to the CRM Account (Calculated Insights / Data Actions).

---

## 1. Full model — CRM (system of record) + Data Cloud (unify/insight/activate)

```mermaid
erDiagram
    ACCOUNT ||--o{ ACCOUNT : "ParentId cascade ★"
    ACCOUNT ||--o{ COMPLIANCE_ASSESSMENT : "has (master-detail)"
    ACCOUNT ||--o{ COMPLIANCE_DOCUMENT : "owns (master-detail)"
    ACCOUNT ||--o| SUPPLIER_PROFILE : "sourcing (lookup)"
    ACCOUNT ||--o{ SUPPLIER_INVITATION : "invites ★"
    ACCOUNT ||--o{ AUDIT_LOG : "trail (polymorphic)"
    COMPLIANCE_DOCUMENT ||--o{ DOCUMENT_EXTRACTION : "extracted (master-detail)"
    COMPLIANCE_ASSESSMENT }o--|| COMPLIANCE_DOCUMENT : "satisfied by (lookup)"
    SUPPLIER_INVITATION ||--o| ACCOUNT : "creates account ★"

    DS_CRM_ACCOUNT ||--|| DLO_ACCOUNT : "ingests"
    DS_CRM_ASSESSMENT ||--|| DLO_ASSESSMENT : "ingests"
    DS_CRM_DOCUMENT ||--|| DLO_DOCUMENT : "ingests"
    DS_EXTERNAL_TIER23 ||--|| DLO_EXTERNAL_SUPPLIER : "ingests T2/T3 ★"

    DLO_ACCOUNT ||--|| DMO_SUPPLIER : "mapped to"
    DLO_EXTERNAL_SUPPLIER ||--|| DMO_SUPPLIER : "mapped to"
    DLO_ASSESSMENT ||--|| DMO_COMPLIANCE : "mapped to"
    DLO_DOCUMENT ||--|| DMO_DOCUMENT : "mapped to"

    DMO_SUPPLIER ||--o{ IR_RULESET : "unified by"
    DMO_SUPPLIER ||--|| UNIFIED_SUPPLIER : "resolves to ★"
    UNIFIED_SUPPLIER ||--o{ DMO_COMPLIANCE : "relates (mapping)"
    UNIFIED_SUPPLIER ||--o{ DMO_DOCUMENT : "relates (mapping)"
    UNIFIED_SUPPLIER ||--o{ DMO_SUPPLIER : "self - tier cascade ★"

    UNIFIED_SUPPLIER ||--o| CI_COMPLIANCE_SCORE : "computes ★"
    UNIFIED_SUPPLIER ||--o| CI_CASCADING_RISK : "computes (multi-tier) ★"
    CI_COMPLIANCE_SCORE ||--o| ACCOUNT : "writes back (Data Action) ★"
    CI_CASCADING_RISK ||--o| ACCOUNT : "writes back (Data Action) ★"

    ACCOUNT {
        id Id PK "golden id + IR match key"
        string Name
        picklist Tier
        lookup ParentId "cascade ★"
        lookup Invited_By_Account__c "★"
        number Risk_Score__c "own"
        picklist Risk_Tier__c "own"
        picklist Cascading_Risk_Tier__c "from Data Cloud CI ★"
        text Cascading_Risk_Source__c "★"
        picklist Onboarding_Status__c
        checkbox Self_Registered__c "★"
        text Compliance_Case_Id__c
    }
    COMPLIANCE_ASSESSMENT {
        masterdetail Supplier__c FK
        text Requirement_Key__c UK
        picklist Status__c
        longtext Reason_Detail__c "structured summary"
        lookup Compliance_Document__c FK
    }
    COMPLIANCE_DOCUMENT {
        masterdetail Account__c FK
        picklist Document_Type__c
        picklist Status__c
        date Expiry_Date__c
        picklist Upload_Channel__c
    }
    DOCUMENT_EXTRACTION {
        masterdetail Compliance_Document__c FK
        longtext Extracted_Fields__c "JSON"
        number Overall_Confidence__c
    }
    SUPPLIER_INVITATION {
        lookup Inviter_Account__c FK "★"
        email Invitee_Email__c
        picklist Intended_Tier__c
        text Token_Hash__c "hash only"
        lookup Resulting_Account__c FK
    }
    SUPPLIER_PROFILE {
        picklist Supplier_Tier__c
        picklist Strategic_Region__c
    }
    AUDIT_LOG {
        picklist Event_Type__c
        datetime Event_DateTime__c
    }
    DS_CRM_ACCOUNT {
        string connector "Salesforce CRM ★"
        string object_filter "RecordType=Supplier"
        string refresh "incremental"
    }
    DS_CRM_ASSESSMENT {
        string connector "Salesforce CRM ★"
        string refresh "incremental"
    }
    DS_CRM_DOCUMENT {
        string connector "Salesforce CRM ★"
    }
    DS_EXTERNAL_TIER23 {
        string connector "Ingestion API / SFTP ★"
        string desc "T2/T3 supplier + compliance feed"
    }
    DLO_ACCOUNT {
        string source_dlo "Account__dll ★"
        string raw "as-ingested CRM Account"
    }
    DLO_EXTERNAL_SUPPLIER {
        string source_dlo "ExtSupplier__dll ★"
        string raw "as-ingested T2/T3"
    }
    DLO_ASSESSMENT {
        string source_dlo "Assessment__dll ★"
    }
    DLO_DOCUMENT {
        string source_dlo "Document__dll ★"
    }
    DMO_SUPPLIER {
        string dmo "Supplier (custom DMO) ★"
        string pk "SupplierId__c (required) ★"
        string name
        string tier
        string parent_supplier_id "cascade"
        string source_account_id "CRM Account.Id"
    }
    DMO_COMPLIANCE {
        string dmo "Compliance Status (DMO) ★"
        string pk "ComplianceId__c ★"
        string supplier_ref "→ Supplier"
        number overall_score
        number docs_required
        number docs_approved
        string status
    }
    DMO_DOCUMENT {
        string dmo "Document (DMO) ★"
        string pk "DocumentId__c ★"
        string supplier_ref
        string doc_type
        date expiry_date
        string status
    }
    IR_RULESET {
        string ruleset "Supplier Identity Resolution ★"
        string match "name + tax id + country (fuzzy + exact)"
        string reconcile "most-recent / source-priority"
    }
    UNIFIED_SUPPLIER {
        string unified_id PK "Unified Supplier (IR output) ★"
        string golden_name
        string tier
        string parent_unified_id "cascade across CRM+external ★"
    }
    CI_COMPLIANCE_SCORE {
        string insight "Calculated Insight ★"
        string grain "per Unified Supplier"
        number own_compliance_score
        number docs_approved_ratio
    }
    CI_CASCADING_RISK {
        string insight "Calculated Insight (multi-tier) ★"
        string grain "per Unified Supplier subtree"
        string cascading_risk_tier "worst-of self+descendants"
        string cascading_risk_source "blame pointer"
    }
    POLICY_CHUNK {
        int id PK "★ pgvector (engine)"
        string clause_id
        string domain
        vector embedding "384-dim"
    }
```

---

## 2. Data Cloud layer only (the four Data 360 concerns, isolated)

Salesforce best practice = separate **ingestion → modeling → identity → activation**.
This diagram shows just that pipeline.

```mermaid
erDiagram
    DS_CRM ||--|| DLO_CRM : "1. ingest (Data Stream)"
    DS_EXTERNAL ||--|| DLO_EXTERNAL : "1. ingest T2/T3 ★"
    DLO_CRM ||--|| DMO_SUPPLIER : "2. map (modeling)"
    DLO_EXTERNAL ||--|| DMO_SUPPLIER : "2. map (modeling)"
    DMO_SUPPLIER ||--|| IR : "3. identity resolution"
    IR ||--|| UNIFIED_SUPPLIER : "3. unify"
    UNIFIED_SUPPLIER ||--o{ CI : "4a. calculated insights"
    CI ||--o| DATA_ACTION : "4b. activation"
    DATA_ACTION ||--o| CRM_ACCOUNT : "write insight back ★"
    UNIFIED_SUPPLIER ||--o{ AGENTFORCE : "4c. grounding / segments ★"

    DS_CRM {
        string type "Salesforce connector"
    }
    DS_EXTERNAL {
        string type "Ingestion API / SFTP (T2-T3)"
    }
    DLO_CRM {
        string layer "Data Lake Object (raw)"
    }
    DLO_EXTERNAL {
        string layer "Data Lake Object (raw)"
    }
    DMO_SUPPLIER {
        string layer "Data Model Object (mapped)"
        string pk "required PK"
    }
    IR {
        string layer "match + reconcile rules"
    }
    UNIFIED_SUPPLIER {
        string layer "golden unified record"
    }
    CI {
        string layer "compliance + cascading-risk scores"
    }
    DATA_ACTION {
        string layer "Data Action / Flow"
    }
    CRM_ACCOUNT {
        string target "Account.Cascading_Risk_Tier__c"
    }
    AGENTFORCE {
        string target "grounded co-pilot / segments"
    }
```

---

## 3. How each tier and the roll-up live in Data Cloud

- **CRM stays system of record** for Accounts (all tiers), the agent case, invitations,
  and the per-requirement `Compliance_Assessment__c`. Transactional onboarding is CRM.
- **Data Streams** ingest CRM (Account/Assessment/Document) **and** any external Tier-2/3
  feed (Ingestion API or SFTP) into **DLOs**.
- **DMOs** (`Supplier`, `Compliance Status`, `Document`) are the mapped, business-ready
  model. Each needs a **required primary key**. Tier cascade is `parent_supplier_id` on
  the Supplier DMO.
- **Identity Resolution** unifies CRM + external supplier records into a **Unified
  Supplier** (golden record) — this is what replaces the `sf_account_id` FK: matching, not
  a foreign key. Match on name + tax id + country.
- **Calculated Insights** compute, per Unified Supplier: `own_compliance_score` and the
  **multi-tier `cascading_risk_tier`** (worst-of self + descendants — the roll-up now runs
  *in Data Cloud* over the unified hierarchy, instead of Apex walking ParentId).
- **Activation / Data Actions** write the insights **back to the CRM Account**
  (`Cascading_Risk_Tier__c`, `Cascading_Risk_Source__c`) so procurement/analyst see them in
  the Veera app — and ground **Agentforce/Einstein** co-pilots on the unified profile.

---

## 4. Where the OLD portal tables go (explicit mapping)

| Old Postgres table | Data Cloud / Salesforce home |
|---|---|
| `supplier_portal_users` (creds) | ❌ **NOT Data Cloud.** Experience Cloud / Salesforce Identity (or a thin auth microservice). Auth is not a Data Cloud concern. |
| `invitations` (token lifecycle) | **CRM** `Supplier_Invitation__c` (transactional). Optionally ingested to Data Cloud for analytics. |
| `documents` (metadata) | **CRM** `Compliance_Document__c` → ingested to `DMO_DOCUMENT`. Raw files in Salesforce Files / object storage. |
| `ai_extractions` | **CRM** `Document_Extraction__c` → optionally ingested. |
| `compliance_status` (rollup) | **Data Cloud `CI_COMPLIANCE_SCORE` + `CI_CASCADING_RISK`** (Calculated Insights) → written back to CRM Account. |
| `event_log` | **CRM** `Audit_Log__c` (append-only); ingest to Data Cloud for cross-tier audit analytics. |

---

## 5. Build implications (Data Cloud path)

1. **No external app DB to run** — fewer moving parts; everything in the Salesforce estate.
2. **Auth must be solved separately** — Data Cloud can't host portal logins. Decide:
   Experience Cloud external users vs. a thin auth service. (This is the one thing the
   Postgres model gave you "for free" that Data Cloud does not.)
3. **The roll-up moves from Apex → Calculated Insights** over the Unified Supplier
   hierarchy — but cross-tier CI over a self-referencing hierarchy needs validation (CI
   joins are not arbitrary graph traversal). **Confirm**: can a Calculated Insight express
   "worst tier across all descendants"? If not, keep the **Apex ParentId roll-up in CRM**
   and use Data Cloud only for unification + own-score insights. (Recommended fallback.)
4. **Latency / freshness** — Data Cloud ingest + CI is near-real-time, not transactional.
   For the buyer's live dashboard, the write-back cadence matters; pair with the
   event-driven Apex roll-up for instant CRM updates if needed.
5. **Cost** — Data Cloud is consumption-credit priced (ingest, CI, identity resolution all
   consume). Model expected volume before committing (see the Data-Cloud-vs-pgvector eval).

---

## Sources
- [Model Data in Data 360 — DMO & Mapping Guide](https://developer.salesforce.com/docs/data/data-cloud-dmo-mapping/guide/c360dm-model-data.html)
- [Object Model in Data 360 (DLO/DMO)](https://developer.salesforce.com/docs/data/data-cloud-dev/guide/dc-object-model.html)
- [Data Lake Objects in Data 360](https://help.salesforce.com/apex/HTViewHelpDoc?id=sf.c360_a_data_lake_objects.htm)
- [Data Mapping in Data Cloud — foundation for IR & activation](https://medium.com/@tumuvenkateswarareddy193/data-mapping-in-salesforce-data-cloud-data-360-the-foundation-for-segmentation-identity-f2cfcddb1cd0)
