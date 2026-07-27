# Current Data Model + Architecture-Shift Deltas

**Part A** — the data model **as it exists today** (verified against org metadata, not
approximated). **Part B** — the changes/additions the architecture shift (public
self-service intake + internal Veera app + multi-tier) introduces.

Verified June 2026 from `force-app/main/default/objects/*`.

---

## PART A — Current model (as-built, verified)

### A.1 Relationship topology (verified types)

```
Account (RecordType: Supplier)        ◀─ ParentId (self) ── multi-tier cascade (field exists, unused today)
  │
  ├──(Master-Detail)──▶ Compliance_Assessment__c   [Supplier__c]   one per required document
  │                          │
  │                          └──(Lookup)──▶ Compliance_Document__c  [the doc that satisfies it]
  │
  ├──(Master-Detail)──▶ Compliance_Document__c      [Account__c]    an uploaded document
  │                          │
  │                          └──(Master-Detail)──▶ Document_Extraction__c  [Compliance_Document__c]
  │
  └──(Lookup)──────────▶ Supplier_Profile__c        [Account__c]    sourcing attrs (tier/region/criticality)

Audit_Log__c   — standalone, polymorphic via Related_Object__c / Related_Record_Id__c (append-only)

Metadata (config, not data):
  Compliance_Domain__mdt · Compliance_Requirement__mdt · Compliance_Verification_Source__mdt

policy_chunk (Postgres / pgvector)  — the RAG corpus, OUTSIDE Salesforce
```

Cascade note: deleting a supplier Account cascade-deletes its Assessments, Documents, and
(via Document) Extractions — they are Master-Detail children.

### A.2 Account (Supplier RecordType) — *the supplier case*

| Field | Type | Purpose |
|---|---|---|
| `Name` | Text | legal entity name |
| `Tier` | (text/picklist) | supplier tier — **present, multi-tier ready** |
| `ParentId` | Lookup(Account) | **self-referencing — the cascade hook (exists, unused today)** |
| `Risk_Tier__c` | picklist | AI risk tier (Low/Med/High/Critical) |
| `Risk_Score__c` | number | 0–100 weighted score |
| `Risk_Domains__c` | text | scoped domains (comma list) |
| `Risk_Last_Computed__c` | datetime | last scoring run |
| `Onboarding_Status__c` | picklist | Invited / Screening / In Review / … |
| `Onboarding_Started_Date__c` / `Onboarding_Completed_Date__c` | date | lifecycle dates |
| `HITL_Threshold__c` | picklist/text | AI-set oversight level (the supervision dial) |
| `Compliance_Case_Id__c` | Text(64) | **links to the engine's durable LangGraph case** |
| `Compliance_Status_Rollup__c` | text/formula | supplier-level rollup |
| `Engagement_Type__c` | picklist | direct/indirect, tier of engagement |
| `Annual_Spend_Est__c` | currency/number | spend (risk input) |
| `Supplier_Contact_Email__c` | email | supplier contact |
| `Requested_By__c` | text/lookup | procurement requestor |
| `Country_of_Origin__c` | text | HQ / origin |
| `Industry` / `Industry__c` | picklist | sector (risk input) |
| `Vendor_Type__c`, `ERP_Vendor_ID__c`, `DUNS_Number__c`, `Tax_ID_EIN__c` | — | vendor master attrs |
| `Active_Supplier__c` | checkbox | active flag |

### A.3 Compliance_Assessment__c — *one per required document (verdict + grounded reasoning)*
**Master-Detail → Account.** This is the per-requirement checklist row.

| Field | Type | Purpose |
|---|---|---|
| `Supplier__c` | **Master-Detail(Account)** | parent supplier |
| `Requirement_Key__c` | Text, **UNIQUE** | stable per-supplier requirement id (the unique-collision field) |
| `Requirement_Label__c` | text | human label (e.g. "Certificate of Insurance") |
| `Status__c` | picklist | Compliant / Non-Compliant / Needs Analyst / Pending |
| `Severity__c` | picklist | Critical / High / Medium / Low |
| `Reason_Detail__c` | long text | **structured AI summary** (headline + facts + clause checks) |
| `Reason_Code__c` | picklist | coded reason |
| `AI_Confidence__c` | number | extraction/judgment confidence |
| `Valid_Until__c` | date | key expiry (from extraction) |
| `Compliance_Document__c` | **Lookup(Document)** | the uploaded doc satisfying this requirement |
| `Analyst_Comment__c` / `Analyst_Validated__c` | text / checkbox | HITL validation |
| `Evaluated_By__c` / `Evaluator_User__c` / `Evaluation_DateTime__c` | — | who/when |

### A.4 Compliance_Document__c — *an uploaded document*
**Master-Detail → Account.**

| Field | Type | Purpose |
|---|---|---|
| `Account__c` | **Master-Detail(Account)** | owning supplier |
| `Document_Type__c` | picklist | COI / ISO / W-9 / … |
| `Status__c` | picklist | pending_ai → ai_extracted → pending_review → approved/rejected/expired |
| `Issuer__c` / `Document_Number__c` | text | extracted identity |
| `Issue_Date__c` / `Expiry_Date__c` | date | extracted dates (drive alerts) |
| `Confidence_Score__c` | number | extraction confidence |
| `Supplier_Tier__c` / `Strategic_Region__c` / `Criticality__c` / `Direct_or_Indirect__c` | — | classification |
| `Upload_Channel__c` | picklist | **portal / experience-cloud / email** (channel matters post-shift) |
| `Source_File__c` | text/url | ContentVersion / file ref |
| `Latest_Extraction__c` | lookup | newest extraction |
| `Uploaded_By_User__c` / `Uploaded_By_Contact__c` | — | uploader |

### A.5 Document_Extraction__c — *AI extraction result*
**Master-Detail → Compliance_Document__c.**

| Field | Type | Purpose |
|---|---|---|
| `Compliance_Document__c` | **Master-Detail(Document)** | the document |
| `Extracted_Fields__c` | long text (JSON) | structured fields (issuer, coverage, expiry, …) |
| `Overall_Confidence__c` / `Below_Threshold__c` | number / checkbox | confidence + HITL flag |
| `Model_Name__c` / `Model_Version__c` | text | reproducibility |
| `Raw_Response__c` | long text | raw model output (audit) |
| `Extraction_DateTime__c` / `Processing_Duration_ms__c` | — | when / perf |

### A.6 Supplier_Profile__c — *sourcing attributes* (Lookup → Account)
`Commodity_Category__c`, `Supplier_Tier__c`, `Strategic_Region__c`, `Criticality__c`,
`Direct_or_Indirect__c`, `Source_System__c`.

### A.7 Audit_Log__c — *append-only activity/decision trail* (standalone, polymorphic)
`Event_Type__c`, `New_Value__c`, `Original_Value__c`, `Actor_Type__c`, `Actor_User__c`,
`Event_DateTime__c`, `Reason__c`, `Source_System__c`, `AI_Model_Name__c` /
`AI_Model_Version__c` / `AI_Confidence__c`, `Related_Object__c` / `Related_Record_Id__c`
(polymorphic link to any record).

### A.8 Config metadata (CMDT)
- `Compliance_Domain__mdt` — domain catalogue.
- `Compliance_Requirement__mdt` — requirement → doc-type mapping.
- `Compliance_Verification_Source__mdt` — registry/screening source config.

### A.9 RAG corpus — `policy_chunk` (Postgres/pgvector, outside Salesforce)
`source, version, clause_id, domain, text, embedding(384)` — MiniLM-384, hybrid
dense+sparse(BM25)+RRF retrieval. The engine owns this; SF never stores embeddings.

---

## PART B — Architecture-shift deltas

The shift = **public self-service intake** (supplier fills the public site → Account
created in SF) + **internal Veera app** for procurement/analyst + **multi-tier** (T1 in
SF / Experience Cloud, T2/T3 via lightweight external portal) syncing back via REST.
Below: what changes / gets added. (✅ already there · ➕ add · ✏️ change · ⚙ config)

### B.1 Account (Supplier) — additions for self-service + multi-tier

| Change | Field | Why |
|---|---|---|
| ✅ | `ParentId` | already present — **activate** it as the T1→T2→T3 cascade |
| ✅ | `Tier`, `Compliance_Case_Id__c`, `Upload_Channel__c`(on Doc) | already present |
| ➕ | `Invited_By_Account__c` (Lookup→Account) | who sent the sub-supplier invite (may differ from ParentId) |
| ➕ | `Invite_Token_Status__c` (picklist: Pending/Accepted/Expired/Revoked) | sync target from Portal invitation status |
| ➕ | `Docs_Required__c` / `Docs_Approved__c` (number) | sync targets for the rollup score |
| ➕ | `Portal_User_Id__c` (Text 36) | bridge to external Portal `supplier_portal_users.user_id` (T2/T3) |
| ➕ | `Self_Registered__c` (checkbox) | true when created via the public intake site (not procurement-keyed) |
| ✏️ | `Onboarding_Status__c` | add values: **Invited**, **Registered** (self-service), **Self-Registered** |
| ⚙ | **RecordTypes** | add `Tier_1_Supplier` / `Tier_2_Supplier` / `Tier_3_Supplier` (currently only `Supplier`) for layout + reporting per tier |

### B.2 Public self-service intake — who creates the Account, how

- **New flow:** the public site (guest user / Experience Cloud public page) lets a supplier
  fill intake → **Save creates the Account** (RecordType per tier, `Self_Registered__c=true`,
  `Onboarding_Status__c='Self-Registered'`). Then procurement picks it up in Veera.
- **Security:** guest-user create must go through a **controlled Apex/Flow with sharing
  rules** (never direct guest CRUD on Account). Validate + dedup by name+email on save
  (we already dedup on submit — reuse it).
- **Data impact:** intake fields the supplier provides map to existing Account fields
  (`Name`, `Country_of_Origin__c`, `Industry`, `Engagement_Type__c`, `Annual_Spend_Est__c`,
  `Supplier_Contact_Email__c`). **No new fields needed for the buyer-tier intake** — it's
  the same form, new surface.

### B.3 New entity — Invitation (sub-supplier token lifecycle)

The multi-tier cascade needs a first-class invitation record. **Two homes, by tier:**
- **Buyer-side / T1 invites** (inside SF): a thin **`Supplier_Invitation__c`** object ➕
  — `Inviter_Account__c`(Lookup), `Invitee_Email__c`, `Invitee_Company__c`,
  `Intended_Tier__c`, `Required_Docs__c`(JSON/multiselect), `Token_Status__c`,
  `Expires_At__c`, `Resulting_Account__c`(Lookup). Token **hash** only.
- **T2/T3 invites** (external Portal DB): `invitations` table (UUID, `token_hash`,
  `inviter_sf_account_id`, …) — never stores the plain token; on accept → creates the SF
  Account via REST + the Portal `supplier_portal_users` row.

### B.4 External Portal DB (T2/T3 only — outside Salesforce) ➕

Net-new, lives in Postgres alongside the engine (or its own DB):
`supplier_portal_users` (bcrypt creds — **never in SF**), `invitations`, `documents`
(raw file in S3 + status), `ai_extractions`, `compliance_status` (rollup → syncs to SF),
`event_log`. Bridge = `sf_account_id` (the Account 18-char Id) on every table.

### B.5 Sync surface (Portal → Salesforce)

| Portal source | SF target | Trigger |
|---|---|---|
| compliance_status.overall_score | `Account.Risk_Score__c` / rollup | doc approved/rejected |
| docs_required / approved | `Account.Docs_Required__c` / `Docs_Approved__c` ➕ | checklist / approval |
| portal_user.status | `Account.Onboarding_Status__c` | account created/suspended |
| invitation.status | `Account.Invite_Token_Status__c` ➕ | invite accepted/expired |
| event_log (key events) | `Audit_Log__c` | each significant event |

Mechanism: REST, OAuth 2.0 **JWT Bearer** (Connected App, key in secrets manager),
idempotent `PATCH …/Account/{sf_account_id}`.

### B.6 What does NOT change

- `Compliance_Assessment__c`, `Compliance_Document__c`, `Document_Extraction__c`,
  `Audit_Log__c`, the CMDT config, and `policy_chunk` — **unchanged**. The per-requirement
  assessment + structured-summary model we built carries straight over.
- The engine (`/scope`, `/assess`, `/verify`, `/cases`) is unchanged; it just gets driven
  from the Veera app (internal) instead of the portal.

---

## Summary of deltas (the build list)

| # | Change | Where |
|---|---|---|
| 1 | Activate `Account.ParentId` as the tier cascade | SF config |
| 2 | Add Tier RecordTypes (T1/T2/T3) | SF config |
| 3 | Add `Invited_By_Account__c`, `Invite_Token_Status__c`, `Docs_Required__c`, `Docs_Approved__c`, `Portal_User_Id__c`, `Self_Registered__c` | SF Account fields |
| 4 | Add `Onboarding_Status__c` values (Invited/Registered/Self-Registered) | SF picklist |
| 5 | Public intake → controlled Apex/Flow creates Account (guest-safe + dedup) | SF + site |
| 6 | `Supplier_Invitation__c` (T1 invites, in SF) | SF new object |
| 7 | External Portal DB (T2/T3 creds + workflow) + REST sync | Engine/Postgres |
| 8 | No change to Assessment/Document/Extraction/Audit/policy_chunk | — |
