# Solution Design — Lead-Driven Supplier Sourcing & Platform Consolidation

**Status:** draft for review — the user explicitly asked to review this process before
anything is built, given Lead conversion is irreversible. Nothing in this doc has been
implemented. Supersedes and folds in `solution-design-requirement-driven-sourcing.md`
(the Account-first version of this design, superseded by the Lead-first decision below).

**Grounding:** validated against Coupa and SAP Ariba's actual documented new-supplier
flows (both use a two-stage "Request → approved → Supplier record created" model,
independently converging on the same shape as Salesforce's native Lead→Account/Contact
conversion), against Salesforce's own documented platform constraints (Experience
Cloud licensing, sharing model, Lead conversion, mass email limits), and against
Coupa/SAP Ariba's documented ongoing/periodic supplier compliance monitoring practice
(§9 — evidence here is mixed between the two vendors and explicitly flagged as such).

---

## 0. What already exists (verified) vs. what's newly scoped here

| Piece | Status |
|---|---|
| Policy Document upload (Policy_Document__c, scPolicyUpload, /policy/ingest) | ✅ built and deployed this session |
| Material Type / Service Category checklist inputs | ✅ built and deployed this session (Azure redeploy still pending — separate, already-flagged item) |
| Audit logging (`Audit_Log__c`, `AuditLogService`) | ✅ existing, used throughout — `logDocumentReceived`, `logAssessmentChange`, `logAIExtraction` |
| Multi-tier risk propagation (Req 2) | ✅ **already built by a colleague** — `MultiTierRollupService`/`Queueable`/`Batch`, `Cascading_Risk_Tier__c` (worst-case propagation) + `Cascading_Risk_Score__c` (weighted-average blend, `Own×0.7 + Sub-Supplier×0.3`, relationship-type multipliers via `Risk_Rollup_Setting__mdt`), `Supplier_Risk_Change__e` platform event + trigger, `scSupplierRiskDashboard`. Matches the earlier solution-design formula exactly. |
| Expiry monitoring / renewal (Req 1) | ❌ still just designed (`docs/solution-design-expiry-monitoring-and-risk-propagation.md`), not built |
| A "New Supplier" single-form intake screen | ✅ exists (`scProcurementConsole` P1) — **this is what the new flow below replaces** |
| Existing-supplier search/match by capability | ❌ absent — no structured "what can this supplier provide" field anywhere |
| Any Lead-object usage anywhere in this codebase | ❌ absent — confirmed via grep, zero references |
| Any Contact-object usage in supplier onboarding | ❌ absent — only Account is touched today |
| A distinct "sourcing need" record, separate from Account | ❌ absent |
| Dynamic/admin-configurable document checklists per category | ❌ absent — today's checklist logic is code-defined (`INDUSTRY_DOMAINS`, `MATERIAL_TYPE_DOMAINS` dicts in `app.py`) |

---

## 1. The core architectural decision: Lead-first, validated against real platforms

**Decision:** new candidate suppliers are modeled as standard Salesforce **Lead** records. This was explicitly chosen by the user over a custom "Prospective Supplier" object, on the basis that standard Salesforce reporting, list views, and bulk-email tooling work natively on Lead — accepting that Lead carries some sales-shaped baggage (Lead Status values, conversion mapping) that gets repurposed here.

**Validation against real procurement platforms** (this was researched, not assumed):
- **Coupa**: uses a distinct, lightweight **Supplier Request** object (statuses: New → Draft → Pending Approval → Applied) that exists *before* any real Supplier master record. Per Coupa documentation: *"when a supplier request is approved, the supplier is created in your site's supplier database."* Portal linking (Coupa Supplier Portal: Invited → Linked) happens after that.
- **SAP Ariba SLP**: identical shape — an internal or external **Supplier Request** is submitted and approved; only on approval is *"the supplier... created in your site's supplier database."* Registration/qualification (the compliance-heavy work) starts only after that.
- **Verdict**: both reference platforms use a genuine **two-stage model** — a minimal pre-record candidate stage, then a real Supplier record created only on approval. This is architecturally identical to Salesforce's native Lead → Account/Contact conversion. Lead-first is not a CRM concept awkwardly repurposed — it's the same shape both platforms independently use, just under Salesforce's native naming.

**The one hard platform constraint this decision must respect:** Salesforce Experience Cloud documentation is explicit — *"All users who log into an Experience Cloud site must have a record in Salesforce... created either as a person account or as a contact."* A raw Lead **cannot** log into the supplier portal. There is no supported workaround (a Lead can be added to a Sharing Set's eligible-object list only via Salesforce Support intervention, and even then this does not grant portal login capability). **Conversion to Account + Contact must happen before any portal access is granted.**

---

## 2. The conversion trigger — mapped to Coupa/Ariba's "request approved" moment

Both Coupa and Ariba trigger real-Supplier-record creation at "request approved." The Salesforce-native equivalent decided here: **conversion happens automatically, silently, the moment a Procurement Manager generates a document checklist for a Lead** — that action is the PM's real-world equivalent of "approving" this candidate as worth pursuing.

```
Lead created (candidate supplier — name, company, email; minimal data, no vetting yet)
  ↓
Procurement Manager reviews the Lead, decides to pursue it
  ↓
PM fills in the Procurement Requirement (material, quantity, spec, needed-by date)
  and clicks "Generate Checklist"
  ↓  ← Coupa "request approved" / Ariba "request approved" equivalent
Apex: Database.LeadConvert (custom field mapping + Procurement_Requirement__c linkage,
      since Salesforce's declarative Lead-field-mapping only covers Account/Contact/
      Opportunity — the custom object link requires this to run in Apex, invoked via
      an Invocable Apex action from Flow, per documented, supported pattern)
  ↓
Account + Contact created
  ↓
/scope called (materialType/serviceCategory/industry from the Requirement — same
  ScopeService/VendorPortalController path that exists today, just sourced from the
  Requirement instead of a manually re-typed field)
  ↓
Contact-based Experience Cloud access provisioned (Sharing Set, see §4)
  ↓
Portal-setup + checklist email sent — SAME transaction, no separate manual step
```

**User's explicit decision, recorded verbatim for traceability:** silent/automatic conversion was chosen over a confirmation-step UI, on the basis that it matches Coupa/Ariba's flow exactly and Coupa/Ariba's "approval" *is* the conversion trigger, not a separate gate. **The user asked to review this full process before build starts, given conversion is irreversible — this document is that review artifact.**

---

## 3. Existing-supplier path (Branch A) vs. new-Lead path (Branch B)

Reconciling this session's earlier `Procurement_Requirement__c` design (written before the Lead-vs-Account decision was finalized) with the Lead-first decision:

```
Procurement Manager creates Procurement_Requirement__c
  (Material_Type, Service_Category, Requesting_Industry, Engagement_Type,
   Quantity, Spec, Needed_By_Date; Status = 'Sourcing')
        │
        ▼
  Search existing suppliers
    WHERE Account.Supplies_Categories__c INCLUDES :materialType (or serviceCategory)
        │
        ├─▶ Branch A — MATCH FOUND (existing Account already onboarded)
        │     └─▶ PM selects the Account, reuses its existing Contact
        │           └─▶ /scope re-run with this Requirement's inputs
        │                 └─▶ portal link sent, scoped to THIS Requirement (§5 —
        │                     still an open decision, unchanged from the prior draft)
        │
        └─▶ Branch B — NO MATCH (need a new candidate supplier)
              └─▶ Lead created (minimal: company name, contact name, email, country)
                    linked to the Procurement_Requirement__c
                    └─▶ PM reviews the Lead, clicks "Generate Checklist"
                          └─▶ [§2's silent conversion sequence runs]
                                └─▶ Account.Supplies_Categories__c set from this
                                    Requirement's material (so it's matchable next time)
```

**What does NOT change from the prior draft:** `/scope`'s retrieval logic, the deterministic domain rules, the document-assessment pipeline, the portal token scheme's underlying mechanics. This is still entirely a front-door/data-model redesign, not a change to compliance evaluation itself.

---

## 4. Licensing and sharing model for the portal (researched, not assumed)

**License tier:** Salesforce Experience Cloud's current license model has three types — **Member** (named-user annual seat), **Login** (a monthly pool counted per unique login per rolling 24h, not per user record), and **External Apps** (newer, transaction-based). For suppliers who log in occasionally to check status or upload a document, **Login-based licensing is the realistic fit** — cost tracks unique daily logins, not headcount, and Salesforce documentation notes orgs can typically create far more user records than purchased logins.

**Guest User (no license) — deliberately NOT recommended for this platform.** A public, unauthenticated Experience Cloud page is real and license-free, but Salesforce's own documentation treats it as a high-risk surface: guest access forces Private OWD behavior, permits **read-only** access only via dedicated Guest User Sharing Rules, and Salesforce's own help text warns that a guest sharing rule "allows immediate and unlimited access to all records matching the rule's criteria to anyone." Since suppliers need to view their own risk score and compliance status (not just submit a one-way upload), Guest User's read-only, unauthenticated model doesn't fit — a real Login-licensed Contact-based user does.

**Sharing model:** Once a Lead converts to Account + Contact, the standard, Salesforce-documented pattern is **Organization-Wide Default = Private** on the relevant objects, plus a **Sharing Set** granting the portal Contact access to records matching their own Account/Contact lookup (their own Compliance_Document__c, Compliance_Assessment__c rows, etc.) — this is exactly the mechanism Experience Cloud is built around for "users see only their own related records." No new sharing pattern needs inventing; this reuses the same primitive any Salesforce portal uses.

---

## 5. Portal link scoping — still an open decision (carried over, unresolved)

If one Account can now have multiple `Procurement_Requirement__c` records against it over time (tyres this quarter, brake components next), the portal link/session needs to carry **which requirement** the supplier is responding to, so the checklist they see matches the one generated for that specific need. Two options, not yet decided:
- Append `requirementId` as a parameter on the existing Account-scoped portal URL, or
- Introduce a dedicated `Supplier_Invitation__c` object (Requirement lookup + Account lookup + Contact lookup + token + status) — this was suggested during the earlier market-research discussion as the cleaner fix, modeled on the same "was this specific supplier invited to respond to this specific requirement" concept the Coupa/Ariba research surfaces implicitly (their "Invited → Linked" CSP status is exactly this — an invitation record distinct from both the request and the supplier master).

**Recommendation, given the Coupa/Ariba research:** the `Supplier_Invitation__c` object is now better-grounded than when first suggested — it directly mirrors Coupa's own "Invited → Linked" concept as a first-class thing, not an ad-hoc URL parameter. Still flagging as open rather than deciding silently.

---

## 6. Dynamic/configurable checklist forms (researched)

**Finding:** no native Salesforce product does true admin-authored conditional forms. Salesforce's own "Dynamic Forms" feature is about record *page layout* (per-object field visibility on the record detail page), not a per-picklist-value questionnaire engine — a common point of confusion given the name.

**Real, standard pattern**: a Custom Metadata Type (e.g., `Checklist_Config__mdt`) storing which fields/documents are required, keyed by Material Type/Service Category, paired with a generic LWC that renders from it. This is a direct generalization of what already exists in `app.py`'s `MATERIAL_TYPE_DOMAINS`/`SERVICE_CATEGORY_DOMAINS` dicts (currently code-defined) into an admin-configurable layer — same underlying concept, moved from Python dicts to Salesforce CMDT so a Procurement admin can add a new material category without a code deploy.

**Buy-vs-build alternative, real and available**: FormAssembly, Conga, and GetFeedback/Medallia are genuine AppExchange products offering true drag-and-drop conditional form builders, if building the CMDT+LWC pattern in-house isn't wanted.

---

## 7. Bulk email to Leads (researched)

Native Salesforce Mass Email / List Email is genuinely sufficient at this platform's likely scale: **5,000 external emails/day** org-wide pool (shared across Mass Email, Apex `Messaging.MassEmailMessage`, Flow email actions), List Email capped at **500 recipients per "Select All" send** in Lightning. This comfortably covers "send checklist + portal setup link to N candidate Leads for a new sourcing need" at any realistic weekly volume. Marketing Cloud/Account Engagement (Pardot) would only become necessary past that ceiling or for multi-step nurture sequences — not needed for this platform's scope.

---

## 8. Lead conversion field mapping — confirmed supported

Setup → Object Manager → Lead → Fields → **Map Lead Fields** is real, declarative, and supports mapping custom Lead fields to custom Account/Contact/Opportunity fields (same data type, sufficient length). This covers standard Account/Contact population. The **Procurement_Requirement__c linkage is NOT covered by declarative mapping** (it only knows Account/Contact/Opportunity) — this is why §2 specifies `Database.LeadConvert`/`LeadConvertResult` in Apex, invoked via an Invocable Apex action from Flow (Flow cannot call LeadConvert directly) — a documented, commonly-used extension pattern, not a workaround.

---

## 9. Daily AI compliance re-check for the existing supplier base (new — researched against Coupa/Ariba)

**This is distinct from Req 1's expiry monitoring**, already designed in
`docs/solution-design-expiry-monitoring-and-risk-propagation.md`. Worth being precise
about the difference, since they sound similar:

- **Req 1 (existing design, not yet built)**: purely **date-driven**. A nightly batch
  compares `Compliance_Document__c.Expiry_Date__c` to today and fires threshold alerts
  (60/30/7 days). It never re-invokes the AI engine and never re-examines a document that
  hasn't hit a date threshold — a currently-valid-looking document is never re-scrutinized.
- **What's being added here**: a periodic (e.g. daily) **re-run of actual compliance
  assessment logic** across the existing, already-onboarded supplier base — catching
  things a date-only scan can't: a policy corpus update that changes what's required, a
  sanctions-list change, or simply re-validating that a previously "Compliant" document
  still holds up against current rules. This is closer to "periodically re-ask the AI
  engine `/assess` or `/scope`-equivalent questions about suppliers we already approved"
  than "watch a date field."

### 9.1 What Coupa and SAP Ariba actually do — researched, evidence is mixed (flagged honestly)

**Confirmed, documented:**
- **SAP Ariba** has the clearest, most explicit match to what's being asked for here:
  **Supplier Qualification/Requalification projects**, where "qualification project team
  members receive a notification on the date specified as the end of the requalification
  period" — a genuine, documented, date-driven periodic re-check cycle, separate from
  simple document-expiry watching. SAP Ariba Supplier Risk also documents a 4-step
  workflow (onboard → identify → mitigate → **monitor**), including a "periodic review
  and monitoring option for Engagements... scheduled... by risk tier."
- **Coupa's own positioning is explicitly the opposite of periodic batch re-checks** —
  Coupa's marketing and product docs frame their differentiator as moving customers
  **"from one-time or annual risk reviews to continuous monitoring"** of supplier risk,
  fed by real-time third-party signals (see below), not an internal scheduled batch job
  re-running Coupa's own checks on a timer.
- **Confirmed, real third-party continuous-risk integrations** (not internal batch jobs —
  external signal providers Coupa/Ariba plug into): **BitSight, RiskRecon** (cybersecurity/
  InfoSec continuous monitoring), **EcoVadis** (ESG/sustainability ratings, syncs into a
  supplier "health score"), **Dun & Bradstreet, RapidRatings** (financial health signals).
  These push risk-relevant events to the platform as they happen, rather than the
  platform polling on a schedule.
- **When an issue is found**: documented behavior is a **human-gated hold**, not automatic
  suspension — Coupa's Risk & Performance docs describe letting risk/procurement teams
  **"put high-risk suppliers on hold,"** which can then block requisitions/invoices/
  payments. I found no documented case of Coupa auto-suspending a supplier purely on an
  automated trigger with no human step — this matches this platform's own existing
  "flag, never auto-clear, human decides" design principle already in place elsewhere.

**NOT confirmed — explicitly flagged as inferred/thin evidence, not to be presented as
fact:**
- Whether Coupa runs an internal scheduled batch job that re-checks *document* expiration
  specifically (as opposed to relying on external continuous-risk feeds) — Compass
  documentation doesn't state this mechanism outright.
- Whether Coupa sends an automated "your document expired, please re-upload" email
  specifically for compliance docs — real notification infrastructure exists in the CSP
  (Account Settings → Notification Preferences), and buyers can push "Information
  Requests" for suppliers to update profile data, but no doc confirms an automated
  expiry-triggered re-upload email verbatim.

**Verdict for this design**: SAP Ariba's periodic requalification-by-risk-tier is the
better-documented, closer analog to "daily AI compliance status batch." Coupa's better-
documented pattern is continuous **external** signal monitoring (not an internal
scheduled re-check), which is a different architecture — this platform doesn't currently
have third-party risk-feed integrations (BitSight/EcoVadis-equivalent), so a Coupa-style
"continuous external signal" approach isn't available to mirror directly; a scheduled
internal batch (closer to Ariba's requalification model) is the realistic near-term fit
given what this platform already has (the engine's own `/assess`/`/scope` logic).

### 9.2 Proposed shape (extends Req 1's architecture, does not duplicate it)

```
Nightly/Daily Scheduled Apex (Schedulable) — separate job from ExpiryMonitorScheduler
  └─▶ ComplianceRevalidationBatch (Database.Batchable<SObject>)
        scope: Accounts where RecordType = 'Supplier' AND Onboarding_Status__c = 'Active'
        (bounded batches, same bulk-safety shape as ExpiryMonitorBatch)
        │
        └─▶ per supplier: re-run /scope (NOT /assess — see note below) with the
              supplier's current profile (industry, material type, engagement type)
              │
              ├─ same checklist/domains as before → no action, Last_Compliance_Check__c
              │    stamped, nothing else changes (this is the common case, cheap)
              │
              └─ checklist/domains CHANGED (e.g. a new Policy_Document__c was ingested
                   that now requires an additional document for this supplier's profile)
                     └─▶ create new Compliance_Assessment__c row(s) for the NEW
                         requirement(s), Status__c = 'Pending', flagged
                         Source__c = 'Revalidation' (distinguishes from initial-onboarding
                         Pending rows in reporting)
                           └─▶ notify Owning_Procurement_User__c (reuses Req 1's
                               notification infrastructure — same Custom Notification
                               Type, no new mechanism)
                                 └─▶ supplier-facing: existing portal checklist UI
                                     already renders any 'Pending' row as needing a
                                     document — the SAME "Upload Renewal" action from
                                     Req 1 §2.3 handles re-submission; no new portal UI
```

**Why `/scope`, not `/assess`, for the daily batch:** `/scope` is retrieval + deterministic
rules only — no LLM call, cheap, safe to run across the entire supplier base daily.
`/assess` (the LLM-driven document verdict) should NOT be re-run in bulk on a schedule —
it's the expensive, LLM-metered path, and re-running it on already-`Compliant` documents
that haven't changed would be pure waste with no new information gained. The daily batch's
job is narrower and cheaper: **"has what's REQUIRED of this supplier changed"** (a
`/scope` question), not **"re-judge documents that haven't changed"** (an `/assess`
question). A document only gets re-`/assess`ed when the supplier actually uploads
something new — same as today.

**Human-in-the-loop, matching Coupa's documented pattern and this platform's existing
principle:** a revalidation finding **never auto-changes** `Onboarding_Status__c` or puts
a supplier "on hold" automatically — it creates a `Pending` assessment row for a human to
act on, exactly like Req 1's alerts. This mirrors Coupa's documented "flag → human decides
to hold" behavior, not an automatic-suspension model (which isn't confirmed as real Coupa
behavior anyway).

### 9.3 Relationship to Req 1 — same Schedulable pattern, different trigger condition

Both `ExpiryMonitorScheduler` (Req 1) and this new `ComplianceRevalidationScheduler` are
nightly `Schedulable` → `Database.Batchable` pairs, following the identical
governor-limit-safe shape — they can run as two independent scheduled jobs (different
cron times to avoid resource contention) without needing to be unified into one job.
Req 1 asks "has a date passed"; this asks "has what's required changed." They can share
the same `Owning_Procurement_User__c`/notification infrastructure without any code
duplication.

---

## 10. Open decisions requiring explicit sign-off before build

1. **§5** — how the portal link/session carries which Requirement it's scoped to (URL parameter vs. `Supplier_Invitation__c` object).
2. **New fields needed on Lead** to carry Material Type/Service Category/Requesting Industry *before* conversion (so the checklist can be generated pre-conversion, since `/scope` needs these inputs and conversion itself happens as a side effect of checklist generation, not before it) — exact field list not yet drafted.
3. **`Account.Supplies_Categories__c` value governance** — multi-select picklist is fine at today's small taxonomy (5 material types, 4 service categories) per the earlier draft; flag if the taxonomy is expected to grow substantially, since multi-select picklists degrade in UX (though not hard governor limits) well before Salesforce's ~500-value technical ceiling.
4. **CMDT-driven checklist config (§6)** — build now as part of this work, or treat as a separate, later phase? Today's code-defined dicts in `app.py` work fine; the CMDT generalization is a UX/maintainability improvement, not a blocker for the Lead-first flow itself.
5. **Whether the colleague's Multi-Tier Risk Propagation work needs any integration point here** — preliminary read: no, it operates on `Account.ParentId` hierarchy and Account-level risk fields, orthogonal to how a new Lead/Account gets created in the first place. Worth the colleague's own confirmation, not assumed.
6. **§9 — daily revalidation cadence and scope**: nightly is proposed by default (matches Req 1's cadence), but should be confirmed — a very large supplier base may warrant a longer interval (e.g. weekly) purely for cost/load reasons, since this is a real question of "how often does what's required actually change" versus "how often can we afford to check."
7. **§9 — whether "revalidation-sourced" Pending assessments should be visually distinguished** from initial-onboarding Pending assessments in the Procurement/Analyst UI (the `Source__c = 'Revalidation'` field is proposed for this; needs a corresponding UI treatment decision, not just a data-model one).

---

## 11. What this document deliberately does NOT decide

Per the user's explicit request to review the process before anything is built: this document lays out the shape and its grounding, but does not authorize implementation. Next step is the user's review, then resolution of §10's open items, then a build-sequencing pass (in the style of the earlier Policy Upload / Req 1+2 docs) before any code is written.
