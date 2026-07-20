# New Data Model — ER Diagram (Mermaid)

Target data model after the architecture shift: **public self-service intake +
internal Veera app + multi-tier (T1 in Salesforce, T2/T3 via external portal)**.

> Paste either ```mermaid``` block into draw.io (Arrange → Insert → Advanced → Mermaid)
> or any Mermaid renderer.

**Legend:** `[SF]` Salesforce object · `[PORTAL]` external Postgres (T2/T3) · `[RAG]`
engine pgvector · `★` = new/changed for the shift.

---

## 1. Full ER diagram (all systems)

```mermaid
erDiagram
    ACCOUNT ||--o{ ACCOUNT : "ParentId (T1-T2-T3 cascade) ★"
    ACCOUNT ||--o{ COMPLIANCE_ASSESSMENT : "has (master-detail)"
    ACCOUNT ||--o{ COMPLIANCE_DOCUMENT : "owns (master-detail)"
    ACCOUNT ||--o| SUPPLIER_PROFILE : "sourcing attrs (lookup)"
    ACCOUNT ||--o{ SUPPLIER_INVITATION : "invites (T1 invites) ★"
    ACCOUNT ||--o{ AUDIT_LOG : "trail (polymorphic)"
    COMPLIANCE_DOCUMENT ||--o{ DOCUMENT_EXTRACTION : "extracted (master-detail)"
    COMPLIANCE_ASSESSMENT }o--|| COMPLIANCE_DOCUMENT : "satisfied by (lookup)"
    SUPPLIER_INVITATION ||--o| ACCOUNT : "creates resulting account ★"

    PORTAL_USER ||--o| ACCOUNT : "sf_account_id bridge ★"
    PORTAL_INVITATION ||--o| PORTAL_USER : "accept creates ★"
    PORTAL_DOCUMENT }o--|| ACCOUNT : "sf_account_id ★"
    PORTAL_DOCUMENT ||--o{ PORTAL_AI_EXTRACTION : "extracted ★"
    PORTAL_COMPLIANCE_STATUS ||--o| ACCOUNT : "syncs to (REST) ★"
    PORTAL_EVENT_LOG }o--|| ACCOUNT : "sf_account_id ★"

    POLICY_CHUNK }o--o{ COMPLIANCE_ASSESSMENT : "grounds verdict (RAG, no FK)"

    ACCOUNT {
        id Id PK "18-char golden id"
        string Name
        picklist Tier "T1 / T2 / T3"
        lookup ParentId "self - cascade ★"
        lookup Invited_By_Account__c "★"
        recordtype RecordTypeId "Tier_1/2/3_Supplier ★"
        picklist Risk_Tier__c
        number Risk_Score__c
        text Risk_Domains__c
        picklist Onboarding_Status__c "Invited/Registered/Self-Registered ★"
        picklist HITL_Threshold__c "oversight dial"
        text Compliance_Case_Id__c "engine case link"
        picklist Engagement_Type__c
        currency Annual_Spend_Est__c
        email Supplier_Contact_Email__c
        checkbox Self_Registered__c "public intake ★"
        picklist Invite_Token_Status__c "★"
        number Docs_Required__c "sync target ★"
        number Docs_Approved__c "sync target ★"
        text Portal_User_Id__c "T2/T3 bridge ★"
    }
    COMPLIANCE_ASSESSMENT {
        id Id PK
        masterdetail Supplier__c FK "Account"
        text Requirement_Key__c UK "unique"
        string Requirement_Label__c
        picklist Status__c "Compliant/Non-Compliant/Needs Analyst/Pending"
        picklist Severity__c
        longtext Reason_Detail__c "structured AI summary"
        number AI_Confidence__c
        date Valid_Until__c
        lookup Compliance_Document__c FK "satisfying doc"
        text Analyst_Comment__c
        checkbox Analyst_Validated__c
    }
    COMPLIANCE_DOCUMENT {
        id Id PK
        masterdetail Account__c FK "Account"
        picklist Document_Type__c
        picklist Status__c "pending_ai..approved/rejected/expired"
        string Issuer__c
        date Issue_Date__c
        date Expiry_Date__c
        number Confidence_Score__c
        picklist Upload_Channel__c "portal/experience-cloud/email"
        text Source_File__c
    }
    DOCUMENT_EXTRACTION {
        id Id PK
        masterdetail Compliance_Document__c FK
        longtext Extracted_Fields__c "JSON"
        number Overall_Confidence__c
        checkbox Below_Threshold__c "HITL flag"
        string Model_Version__c
    }
    SUPPLIER_PROFILE {
        id Id PK
        lookup Account__c FK
        picklist Commodity_Category__c
        picklist Supplier_Tier__c
        picklist Strategic_Region__c
        picklist Criticality__c
    }
    SUPPLIER_INVITATION {
        id Id PK "★ new object"
        lookup Inviter_Account__c FK
        email Invitee_Email__c
        string Invitee_Company__c
        picklist Intended_Tier__c "tier_2/tier_3"
        text Required_Docs__c "JSON"
        text Token_Hash__c "sha-256, hash only"
        picklist Token_Status__c "Pending/Accepted/Expired/Revoked"
        datetime Expires_At__c
        lookup Resulting_Account__c FK
    }
    AUDIT_LOG {
        id Id PK
        picklist Event_Type__c
        text New_Value__c
        text Original_Value__c
        picklist Actor_Type__c "system/portal_user/sf_user"
        datetime Event_DateTime__c
        string Related_Object__c "polymorphic"
        string Related_Record_Id__c
    }
    PORTAL_USER {
        uuid user_id PK "★ Portal DB"
        varchar sf_account_id FK "golden bridge"
        varchar email UK
        varchar password_hash "bcrypt(12), never in SF"
        enum status "active/suspended/.."
        boolean mfa_enabled
    }
    PORTAL_INVITATION {
        uuid invite_id PK "★ Portal DB"
        varchar inviter_sf_account_id FK
        varchar invitee_email
        enum intended_tier "tier_2/tier_3"
        varchar token_hash "sha-256, hash only"
        timestamptz token_expires_at
        jsonb required_docs
        enum status "pending/accepted/expired/revoked"
        varchar resulting_sf_account_id FK
    }
    PORTAL_DOCUMENT {
        uuid document_id PK "★ Portal DB"
        varchar sf_account_id FK
        enum doc_type
        varchar file_url "S3 / blob"
        varchar file_hash "sha-256"
        enum status
        date expiry_date
    }
    PORTAL_AI_EXTRACTION {
        uuid extraction_id PK "★ Portal DB"
        uuid document_id FK
        jsonb extracted_fields
        decimal confidence_score
        jsonb validation_result
        varchar model_version
    }
    PORTAL_COMPLIANCE_STATUS {
        uuid status_id PK "★ Portal DB"
        varchar sf_account_id FK "unique - one per supplier"
        smallint overall_score
        smallint docs_required
        smallint docs_approved
        smallint docs_expiring_30d
        enum sf_sync_status "pending/synced/error"
    }
    PORTAL_EVENT_LOG {
        uuid event_id PK "★ Portal DB"
        varchar sf_account_id FK
        varchar event_type
        enum actor_type
        jsonb payload
        timestamptz created_at
    }
    POLICY_CHUNK {
        int id PK "★ pgvector"
        string source
        string version
        string clause_id
        string domain
        text text
        vector embedding "384-dim MiniLM"
    }
```

---

## 2. Salesforce-only view (the buyer + Tier 1 surface)

A simpler diagram if you only need the in-SF model (drop the external portal + RAG).

```mermaid
erDiagram
    ACCOUNT ||--o{ ACCOUNT : "ParentId cascade ★"
    ACCOUNT ||--o{ COMPLIANCE_ASSESSMENT : "has"
    ACCOUNT ||--o{ COMPLIANCE_DOCUMENT : "owns"
    ACCOUNT ||--o| SUPPLIER_PROFILE : "sourcing"
    ACCOUNT ||--o{ SUPPLIER_INVITATION : "invites ★"
    ACCOUNT ||--o{ AUDIT_LOG : "trail"
    COMPLIANCE_DOCUMENT ||--o{ DOCUMENT_EXTRACTION : "extracted"
    COMPLIANCE_ASSESSMENT }o--|| COMPLIANCE_DOCUMENT : "satisfied by"
    SUPPLIER_INVITATION ||--o| ACCOUNT : "creates account ★"

    ACCOUNT {
        id Id PK
        string Name
        picklist Tier
        lookup ParentId "cascade ★"
        lookup Invited_By_Account__c "★"
        number Risk_Score__c
        picklist Onboarding_Status__c
        checkbox Self_Registered__c "★"
        text Compliance_Case_Id__c
    }
    COMPLIANCE_ASSESSMENT {
        text Requirement_Key__c UK
        picklist Status__c
        longtext Reason_Detail__c "structured summary"
        lookup Compliance_Document__c FK
    }
    COMPLIANCE_DOCUMENT {
        picklist Document_Type__c
        picklist Status__c
        date Expiry_Date__c
        picklist Upload_Channel__c
    }
    DOCUMENT_EXTRACTION {
        longtext Extracted_Fields__c "JSON"
        number Overall_Confidence__c
    }
    SUPPLIER_INVITATION {
        lookup Inviter_Account__c FK "★"
        email Invitee_Email__c
        picklist Intended_Tier__c
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
```

---

## Notes
- **`★`** marks what's new/changed for the architecture shift. Everything unmarked
  already exists in the org today.
- **`sf_account_id`** (the Account 18-char Id) is the golden cross-system FK — every
  Portal table carries it; the Portal never mints its own supplier identity.
- Master-detail vs lookup is annotated on the SF relationships (matches the verified org
  metadata). Portal relationships are FK-by-`sf_account_id`.
- `POLICY_CHUNK` has no real FK to assessments — it grounds verdicts via RAG retrieval at
  runtime; the dashed conceptual link is shown for completeness.
