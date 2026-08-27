# Solution Design — Requirement-Driven Supplier Sourcing (replaces "New Supplier" intake)

**Status:** draft for review — assessed against the current implementation
(`VendorPortalController.cls`, `scProcurementConsole`), not a literal transcription
of the request. User-confirmed decisions captured inline.

**Trigger:** user observed that changing Material Type on an existing supplier's
record doesn't regenerate the checklist, and used that as the entry point into a
larger point: checklist inputs should be driven by a procurement **need**
(Industry → Engagement Type → Material/Service Category, in that weighted order),
not typed ad hoc onto a generic intake form. Broader gaps raised: no existing-
supplier search/match, no Contact object anywhere in the flow, no create-new-vs-
reuse branching, no way to scope a portal request to a specific sourcing need.

---

## 0. What already exists (verified) vs. what's genuinely new

| Piece | Status |
|---|---|
| Single "New Supplier" intake form (Name/Country/Industry/Engagement/Spend/Email) | ✅ exists — `scProcurementConsole` P1 screen, `VendorPortalController.generateChecklist` |
| Material Type / Service Category inputs on that form | ✅ exists (this session) — additive to `ScopeRequest`, feeds `/scope`'s `material_domains()` |
| Weighted domain-selection order (Industry → Engagement → Material) | ✅ **already the actual precedence in `/scope`** — `industry_domains()` sets the guaranteed base, `engagement_domains()` adds/removes on top, `material_domains()` is unioned last. No engine change needed — this was already correct; the bug is that Azure hasn't been redeployed with it (separate, already-flagged issue). |
| Existing-supplier dedup | ⚠️ **exists but weak** — exact `Name + Email` match only ([VendorPortalController.cls:153-161](../supplierCompliance/force-app/main/default/classes/VendorPortalController.cls#L153-L161)), no capability-based search |
| Contact object anywhere in supplier onboarding | ❌ **confirmed absent** — grep across `VendorPortalController.cls` shows zero references to `Contact`; only `Account` is created/updated |
| A "what does this supplier supply" field | ❌ **confirmed absent** — no field like this exists on `Account` today |
| A distinct "sourcing need / requirement" record, separate from the Account | ❌ **confirmed absent** — today's form conflates "why we're engaging a supplier" with "the supplier record itself" |
| Portal link scoped to a specific need | ❌ **absent** — `generateSupplierPortalUrl(accId)` is Account-scoped only, not need-scoped |

---

## 1. Where this is NOT a literal transcription of the request (and why)

1. **The new "form" is a genuinely new object, `Procurement_Requirement__c`** — not a reordering of the existing intake form's fields. This was an explicit choice (over "just reorder the existing form") because collapsing "what we need to buy" and "who the supplier is" into one record is exactly the design flaw being fixed; keeping them one object would just move the problem, not solve it. This matches how mature procurement/SRM platforms (SAP Ariba, Coupa) separate sourcing events from supplier master data.
2. **Supplier matching uses a new structured field (`Account.Supplies_Categories__c`), not inference from assessment history.** Inferring capability from `Compliance_Assessment__c`/`Industry` history was considered and rejected (by the user) — it only works for suppliers already deep in the system and is fuzzier than an explicit field Procurement sets once at onboarding.
3. **Contact is added as a CRM record only — not a real Experience Cloud login.** The user explicitly chose to keep the existing stable-token portal URL scheme rather than move to Contact-based Experience Cloud authentication. This avoids reworking the entire portal auth model (`generateSupplierPortalUrl`, `resolveSupplierToken`) as a side effect of adding a Contact — Contact here answers "who do we email," not "who logs in."
4. **This REPLACES the New Supplier screen, per explicit user decision** — not an additive second path. The user's own reasoning (echoed back for confirmation, not assumed): procurement doesn't onboard a supplier without a reason, so requirement-first should be the only path.

---

## 2. New objects/fields

### `Procurement_Requirement__c` (new)
| Field | Purpose |
|---|---|
| `Name` (auto-number, e.g. `REQ-{0000}`) | |
| `Material_Type__c` (picklist — same values as the existing engine-side `MATERIAL_TYPE_DOMAINS` keys) | drives `/scope` |
| `Service_Category__c` (picklist — same values as `SERVICE_CATEGORY_DOMAINS` keys) | drives `/scope` |
| `Requesting_Industry__c` (picklist — same values as today's `INDUSTRIES` const) | drives `/scope` (industry weight) |
| `Quantity__c` (Number) | procurement detail, not sent to `/scope` |
| `Specification__c` (Long Text Area) | procurement detail |
| `Needed_By_Date__c` (Date) | procurement detail |
| `Status__c` (picklist: Sourcing / Supplier Selected / Fulfilled / Cancelled) | |
| `Selected_Supplier__c` (Lookup to Account) | populated once a candidate is chosen (existing or new) |
| `Engagement_Type__c` (picklist — reuses today's `ENGAGEMENT_TYPES`) | still supplier-relationship-shaped, kept here since it's set at requirement-creation time, before a specific Account exists |

### `Account.Supplies_Categories__c` (new — multi-select picklist)
Same value domain as `Procurement_Requirement__c.Material_Type__c` + `Service_Category__c` combined. Set once per supplier (at onboarding, editable later). This is the field the requirement-matching search filters against.

### Contact (standard object, newly wired into this flow)
No new fields — just newly created/looked-up alongside the Account in both branches below. `AccountId` links it to the supplier Account (standard Salesforce relationship, already exists).

---

## 3. The flow

```
Procurement Manager
  └─▶ Create Procurement_Requirement__c
        (Material_Type, Service_Category, Requesting_Industry, Engagement_Type,
         Quantity, Spec, Needed_By_Date)
        Status = 'Sourcing'
        │
        ▼
  Search existing suppliers
        WHERE Account.Supplies_Categories__c INCLUDES :materialType (or serviceCategory)
        │
        ├─▶ MATCH FOUND (Branch A)
        │     └─▶ Procurement selects an existing Account
        │           └─▶ reuse its existing Contact (or add one if none exists)
        │                 └─▶ generate portal link SCOPED TO THIS REQUIREMENT
        │                       (not just the Account — see §4)
        │                       └─▶ send email; Procurement_Requirement__c.Selected_Supplier__c set;
        │                           Status → 'Supplier Selected'
        │
        └─▶ NO MATCH (Branch B)
              └─▶ Procurement creates a new Account (name, country — minimal)
                    └─▶ creates a new Contact (name, email, phone) linked to that Account
                          └─▶ /scope called with Requirement's Material_Type/Service_Category/
                              Requesting_Industry/Engagement_Type — SAME call shape as today,
                              just sourced from the Requirement instead of a manually-retyped form
                                └─▶ checklist generated, portal link sent (as Branch A)
                                    Account.Supplies_Categories__c is set from this
                                    Requirement's material (so it's matchable next time)
```

**What does NOT change:** `/scope`'s retrieval logic, the deterministic domain rules, the checklist-generation Apex path (`ScopeService.getScope`), the portal token scheme, the document-upload/assessment pipeline. This is entirely a **front-door redesign** — how a Requirement/Account/Contact/checklist-generation call get initiated — not a change to how compliance evaluation itself works.

---

## 4. The "scoped portal link" question — flagged, not yet resolved

Today, `generateSupplierPortalUrl(accId)` and `resolveSupplierToken(token)` are Account-scoped: one stable link per Account, reused across requests. If one Account can now have multiple `Procurement_Requirement__c` records against it (e.g. tyres this quarter, brake components next quarter), the portal link needs to carry **which requirement** the supplier is responding to — otherwise the checklist the supplier sees on the portal side won't match the one Procurement generated for that specific need.

This needs a decision before build: does the portal URL become `.../portal?token=X&requirementId=Y`, or does each Requirement get its own token? This is a real design fork with implications for `VendorPortalController.resolveSupplierToken` and the portal LWC — flagging it explicitly rather than picking one silently.

## 5. Open decisions

1. **§4 above** — how the portal link carries requirement context.
2. **Multi-select picklist governor limits** — `Supplies_Categories__c` as a multi-select picklist has a practical value-count ceiling (~500 in Salesforce, but UI/UX degrades much earlier); if the material/service taxonomy grows large, a junction object (`Account` ↔ `Category__c`) may be needed instead. Fine to start with a multi-select picklist given today's small taxonomy (5 material types, 4 service categories).
3. **What happens to Accounts created under the OLD flow** (no `Supplies_Categories__c` set) — they simply won't surface in future requirement-matching searches until someone backfills the field. Worth a one-time backfill pass, not blocking for new-flow rollout.
4. **Does replacing the New Supplier screen affect the Analyst Console or Screening Queue**, which currently query `Account` directly (`getScreeningQueue`, etc.)? Preliminary read: no — those query `Account` records regardless of how they were created, so existing downstream screens are unaffected by the front-door change.

---

## 6. Build sequencing

1. New fields/object first (`Procurement_Requirement__c`, `Account.Supplies_Categories__c`) — no behavior change yet, safe to deploy alone.
2. New Apex (`ProcurementRequirementController` or extend `VendorPortalController`): create-requirement, search-matching-suppliers, create-new-account-and-contact, update-existing-and-attach-contact.
3. New/modified LWC screen replacing `scProcurementConsole`'s P1 — requirement form → search results → branch UI.
4. §4's portal-scoping decision, then wire the send-link step.
5. One-time backfill consideration for existing Accounts (item 3 in §5) — separate, optional, non-blocking follow-up.
