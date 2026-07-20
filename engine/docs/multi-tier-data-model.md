# Logical Data Model — Multi-Tier Supplier Onboarding

**Scope:** T1 → T2 → T3 supplier cascade, sub-supplier invitations, document
intelligence, compliance scoring, cross-system sync.
**Architecture:** Hybrid split — **Salesforce = system of record for identity +
compliance**; **AI Portal (Postgres) = credentials, invitation tokens, raw docs, AI
extractions, audit**, synced to SF via REST. T1 = Experience Cloud; T2/T3 = AI Portal.
**Status:** logical model (not physical DDL). Grounded in what is ALREADY built.

> Legend per entity: **[SF]** lives in Salesforce · **[PORTAL]** lives in the AI
> Portal Postgres DB · **[SYNC]** the bridge. ✅ = already implemented · ➕ = gap to add.

---

## 0. Assessment — model vs. what we've already built

The Salesforce identity + compliance layer is **~70% built**. The model formalizes it,
renames to a consistent vocabulary, and names the true gaps.

| Logical entity | Already in our org | Action |
|---|---|---|
| Supplier (Account + ParentId cascade) | ✅ `Account.ParentId`, `Tier`, `Risk_Tier__c`, `Risk_Score__c`, `Onboarding_Status__c`, `Compliance_Status_Rollup__c`, `Compliance_Case_Id__c`, `HITL_Threshold__c` | formalize |
| ComplianceRequirement (per-doc checklist row) | ✅ `Compliance_Assessment__c` (per requirement, with verdict/severity/analyst fields) | keep |
| Document | ✅ `Compliance_Document__c` (Issuer, Expiry, Confidence, Tier, Upload_Channel) | keep |
| AIExtraction | ✅ `Document_Extraction__c` | keep |
| ComplianceStatus (per-supplier rollup) | ⚠️ partial — `Account.Compliance_Status_Rollup__c` + `Risk_Score__c` exist; no dedicated rollup object | derive / extend |
| AuditEvent | ✅ `Audit_Log__c` + `Document_Uploaded__e` (platform event) | keep |
| **Invitation (sub-supplier token lifecycle)** | ❌ **missing** | ➕ **add** |
| **Account.Invited_By_Account__c** | ❌ **missing** | ➕ **add** |
| **PortalUser (T2/T3 credentials)** | ❌ N/A in SF (correct) | ➕ Portal DB |

**Key reconciliation:** our `Compliance_Assessment__c` is **per-requirement** (one row per
required doc, with the AI verdict). The SupplierIQ doc's `compliance_status` is
**per-supplier** (one rollup row). These are **complementary**: assessments are the
line-items; the supplier rollup is their aggregate. The model keeps both (rollup =
derived from assessments).

---

## 1. Entities & attributes (logical)

### 1.1 Supplier  **[SF]**  ✅  (Salesforce `Account`)
The system-of-record for company identity at every tier. Multi-tier via self-referencing parent.

| Logical attribute | Our SF field | Notes |
|---|---|---|
| supplier_id (PK) | `Id` (18-char) | **golden id** — the cross-system FK everywhere in the Portal |
| name | `Name` | legal entity name |
| tier | `Tier` / RecordType | Tier 1 / 2 / 3 (RecordType drives layout + reporting) |
| **parent_supplier_id** | `ParentId` | **the cascade**: T2.Parent→T1, T3.Parent→T2 |
| **invited_by_supplier_id** ➕ | `Invited_By_Account__c` (add) | who sent the invite (may differ from parent in edge cases; usually = parent) |
| country | `Country_of_Origin__c` / `BillingCountry` | |
| industry / category | `Industry` / `Supplier_Category__c` | |
| onboarding_status | `Onboarding_Status__c` | Invited / Registered / Screening / In Review / Active / … |
| risk_tier | `Risk_Tier__c` | AI-assessed Low/Med/High/Critical |
| compliance_score | `Risk_Score__c` + `Compliance_Status_Rollup__c` | 0–100 rollup |
| oversight_level (HITL) | `HITL_Threshold__c` | the supervision dial |
| case_id | `Compliance_Case_Id__c` | links to the engine's durable agent case |
| contact_email | `Supplier_Contact_Email__c` | |
| onboarding_started / completed | `Onboarding_Started_Date__c` / `Onboarding_Completed_Date__c` | |

Relationships: `Supplier 1—* Supplier` (parent/child, ≤10 levels — platform limit, T1→T2→T3
is 3). `Supplier 1—* ComplianceRequirement`, `1—* Document`, `1—1 ComplianceStatus`.

### 1.2 Invitation  **[PORTAL]** ➕  (sub-supplier token lifecycle)
First-class entity for the cascade: a T1 invites a T2, a T2 invites a T3. **Token hash only**
(never the plain token). On acceptance → creates the Supplier Account + PortalUser.

| Attribute | Type | Notes |
|---|---|---|
| invite_id (PK) | UUID | |
| inviter_supplier_id (FK→SF) | sf_account_id | the T1/T2 who sent it |
| invitee_email / company / contact | text | pre-fills the registration form |
| intended_tier | enum (tier_2 / tier_3) | which onboarding flow |
| required_docs | json | e.g. ["COI","BIZ_LICENSE","QUALITY_CERT"] |
| token_hash | sha-256 | plain token only in the email URL |
| expires_at | timestamptz | 7/14/30 days |
| status | enum | pending / accepted / expired / revoked |
| resulting_supplier_id (FK→SF) | sf_account_id | set once the Account is created |
| sent_at / accepted_at | timestamptz | |

Relationships: `Supplier(inviter) 1—* Invitation`; `Invitation 1—1 Supplier(resulting)`.
**SF mirror (optional):** `Account.Invite_Token_Status__c` reflects status for buying-org reporting.

### 1.3 ComplianceRequirement  **[SF]**  ✅  (`Compliance_Assessment__c`)
One row per required document for a supplier (the checklist line-item + the AI verdict).

| Logical attribute | Our SF field |
|---|---|
| requirement_id (PK) | `Id` |
| supplier_id (FK) | `Supplier__c` |
| requirement_key / label | `Requirement_Key__c` / `Requirement_Label__c` |
| status (verdict) | `Status__c` (Compliant / Non-Compliant / Needs Analyst / Pending) |
| severity | `Severity__c` |
| ai_confidence | `AI_Confidence__c` |
| reason / summary | `Reason_Detail__c` (structured headline+facts) |
| valid_until | `Valid_Until__c` |
| document_id (FK) | `Compliance_Document__c` (the uploaded doc that satisfies it) |
| analyst_comment / validated | `Analyst_Comment__c` / `Analyst_Validated__c` |

### 1.4 Document  **[SF metadata]** ✅ + **[PORTAL]** raw file
Metadata in SF; the raw file in object storage (S3/Blob) or SF Files.

| Logical attribute | Our SF field (`Compliance_Document__c`) |
|---|---|
| document_id (PK) | `Id` |
| supplier_id (FK) | `Account__c` |
| doc_type | `Document_Type__c` |
| status | `Status__c` (pending_ai → ai_extracted → pending_review → approved/rejected/expired) |
| issuer / number | `Issuer__c` / `Document_Number__c` |
| issue / expiry date | `Issue_Date__c` / `Expiry_Date__c` |
| confidence | `Confidence_Score__c` |
| tier / region | `Supplier_Tier__c` / `Strategic_Region__c` |
| upload_channel | `Upload_Channel__c` (portal / experience-cloud / email) |
| file ref | `Source_File__c` (SF) — or `file_url` (S3, Portal) |

### 1.5 AIExtraction  **[SF]** ✅ (`Document_Extraction__c`)  /  **[PORTAL]** `ai_extractions`
Structured AI output per document version.

| Attribute | Notes |
|---|---|
| extraction_id (PK) | |
| document_id (FK) | |
| extracted_fields (json) | issuer, coverage, expiry, policy#, … (our engine already returns this) |
| confidence_score | <0.70 → human review |
| validation_result (json) | per-field pass/fail (our clause_checks) |
| model_version | e.g. gpt-4o |

### 1.6 ComplianceStatus (per-supplier rollup)  **[SYNC]** ⚠️
**Derived** from ComplianceRequirement rows. Today partly on the Account
(`Compliance_Status_Rollup__c`, `Risk_Score__c`); in the hybrid split the Portal owns the
authoritative rollup and **syncs it to SF**.

| Attribute | Notes |
|---|---|
| supplier_id (PK/unique FK) | one row per supplier |
| overall_score | (docs_approved / docs_required) × 100 |
| docs_required / approved | |
| docs_expiring_30d / 90d / expired | drives alerts |
| sf_sync_status / synced_at | pending / synced / error |

### 1.7 AuditEvent  **[SF]** ✅ (`Audit_Log__c`) + **[PORTAL]** `event_log`
Append-only. SF holds buying-org-visible events; Portal holds the full T2/T3 trail.
Event types: supplier_invited, invite_accepted, document_uploaded,
ai_extraction_completed, document_approved/rejected, compliance_score_updated,
sf_sync_success/error, expiry_alert_30d/90d, sub_supplier_invited.

### 1.8 PortalUser (credentials)  **[PORTAL]** ➕  (`supplier_portal_users`)
T2/T3 login/creds — **never in Salesforce**. bcrypt(12) password, hashed tokens,
MFA secret AES-encrypted, lockout policy. Holds `sf_account_id` as the bridge.

---

## 2. Relationships (ER summary)

```
[SF] Supplier(T1) ──ParentId──▶ Supplier(T2) ──ParentId──▶ Supplier(T3)   (≤10 levels)
        │ 1                          │                          │
        │ *                          ▼                          ▼
        ├─▶ ComplianceRequirement(*)  [SF]  ── 1:1 ──▶ Document(*) [SF meta + PORTAL file]
        │                                                   │ 1
        │                                                   ▼ *
        │                                              AIExtraction [SF/PORTAL]
        ├─▶ ComplianceStatus (1:1, derived)  [SYNC]
        └─▶ AuditEvent(*)  [SF + PORTAL]

[PORTAL] Invitation(*)  inviter_supplier_id ─▶ Supplier   ·  resulting ─▶ Supplier(new)
[PORTAL] PortalUser(1:1 with Supplier, T2/T3 only)  ── sf_account_id ──▶ Supplier
                         ▲
                         └──────── sf_account_id is the GOLDEN cross-system FK ────────┘
```

---

## 3. Cross-system sync (Portal → SF)

| Portal source | SF target | Trigger |
|---|---|---|
| compliance_status.overall_score | `Account.Risk_Score__c` / rollup | doc approved/rejected |
| docs_required / approved | `Account.Docs_Required__c` / `Docs_Approved__c` ➕ | checklist / approval |
| portal_user.status | `Account.Onboarding_Status__c` | account created / suspended |
| invitation.status | `Account.Invite_Token_Status__c` ➕ | invite accepted/expired |
| invitation.accepted_at | `Account.Onboarding_Started_Date__c` | first profile submit |

Mechanism: REST API, OAuth 2.0 **JWT Bearer** (Connected App, private key in secrets
manager — no stored user creds). Idempotent `PATCH …/sobjects/Account/{sf_account_id}`.

---

## 4. Gaps to implement (the actionable list)

1. ➕ `Account.Invited_By_Account__c` (Lookup→Account) — the inviter, distinct from ParentId if needed.
2. ➕ `Account.Invite_Token_Status__c`, `Docs_Required__c`, `Docs_Approved__c` (sync targets).
3. ➕ **Invitation** entity — in the Portal DB (token lifecycle). Optional thin SF mirror object if buying-org wants invite reporting natively.
4. ➕ **PortalUser** + auth tables — Portal DB only (creds never in SF).
5. ⚠️ Decide ComplianceStatus home: keep deriving on the Account vs. a dedicated rollup object/table. (Recommend: Portal owns authoritative rollup; SF fields are the synced projection — consistent with the hybrid split.)

---

## 5. Key design decisions (carried from the SupplierIQ doc, validated against our build)

- **T2/T3 as SF Accounts (not a custom object)** — reuses native ParentId hierarchy,
  reports, Flows. ✅ already our approach (`Account.ParentId` + `Tier`).
- **Single parent only (no junction)** — one inviter per supplier in Phase 1; a supplier
  serving multiple buyers registers as separate Accounts. (Revisit with a junction if
  many-to-many parents become real.)
- **Credentials in Portal, not SF** — SF can't host arbitrary portal-user auth without
  Community licenses; the Portal owns auth, SF owns identity.
- **`sf_account_id` is the golden FK** — stable, unique, available at creation; no separate
  UUID-mapping table.
- **JSONB for extracted_fields** — doc types extract different fields; matches our engine's
  `extracted_fields` shape exactly.
- **Append-only audit** — regulatory (UFLPA/CSDDD); ✅ we have `Audit_Log__c`.
