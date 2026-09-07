# Solution Design — Expiry Monitoring & Renewal (Req 1) + Multi-Tier Risk Propagation (Req 2)

**Status:** draft for review — assessed against real enterprise workflow, not a literal
transcription of the requirements. Verified against the org's actual metadata
(retrieved fresh before this design), not assumed.
**Phase context:** all prior work onboarded *new* supplier requestors. This phase adds a
**scheduled, always-running compliance monitor** over *existing* suppliers.

---

## 0. What already exists (verified) vs. what's genuinely new

| Piece | Status |
|---|---|
| `Compliance_Document__c.Expiry_Date__c`, `.Status__c` | ✅ exists — the scheduler has a field to scan |
| `Account.Risk_Score__c`, `.Risk_Tier__c`, `.Tier`, `.ParentId` | ✅ exists — the hierarchy + own-score foundation |
| `SubSupplierController.cls` — builds `ParentId`-based child lists, reads `Supplier_Tier__c` | ✅ exists — reusable traversal foundation |
| A scheduler, batch job, or any Apex Scheduled class | ❌ none exist — **new** |
| Any notification/alert infrastructure (email templates, Salesforce Notifications) | ❌ none exist — **new** |
| A second Platform Event (only `Document_Uploaded__e` exists) | ❌ **new**, modeled on the existing one |
| Relationship-weight field (Sole Source / Preferred / Secondary) | ❌ **new** — not modeled anywhere today |
| Cascading-risk fields (`Cascading_Risk_Tier__c` etc.) | ❌ **new** — but **already designed** in `docs/multi-tier-risk-rollup.md` this session — Req 2 is the formalized version of that design with a specific formula. We reconcile, not re-invent. |
| Purchase Order / Contract data linked to suppliers | ❌ **confirmed absent** in this org (checked Opportunity, custom objects, standard Order/Contract — none exist) | **new, minimal, explicitly scoped** — see §3.6 |

---

## 1. Where I pushed back on the literal requirement (and why)

1. **Req 1 "no manual intervention for high-confidence renewals"** — kept per your
   decision: **human-in-the-loop stays universal.** A renewal upload *automatically*
   triggers the same AI ingestion/evaluation pipeline (that part is genuinely automatic —
   no one has to manually re-run anything), but the resulting verdict is still subject to
   the same deterministic gates and lands as a reviewable state, consistent with every
   other assessment in this platform. We do NOT introduce a silent, fully-autonomous
   compliance-clearing path — that would be a new, unreviewed trust posture inconsistent
   with the rest of the system's design (flag-can-never-auto-clear, HITL gates on the
   agent, etc.).
2. **Req 1 "PO risk flag"** — genuinely absent from the org; scoped in explicitly as a
   **minimal** new object (§3.6), not assumed to exist.
3. **Req 2 "Platform Event... not a batch job"** — kept as real-time, but designed with an
   **idempotency/debounce guard** so a supplier flapping between statuses doesn't trigger
   redundant full-hierarchy recalculations in a tight loop (a real operational risk the
   literal requirement doesn't address).
4. **Req 2 relationship weight** — modeled as a field on the **child Account** (not a
   separate junction object), consistent with the org's existing single-parent
   `ParentId` model. Documented as a known limitation: if a supplier ever serves multiple
   parents with different relationship types, this model can't express that (matches the
   design decision already recorded in `multi-tier-data-model.md`: *"single parent only —
   a supplier serving multiple buyers registers as separate Accounts."*).

---

## 2. Req 1 — Expiry Monitoring, Tiered Alerts & Renewal

### 2.1 Architecture shape

```
Nightly Scheduled Apex (Schedulable)
  └─▶ Batch Apex (Queueable/Database.Batchable) — scans ALL active Compliance_Document__c
        └─▶ per document: compare Expiry_Date__c to today
              ├─ crosses 60d threshold  → Expiry_Alert_60d_Sent__c flag + email (informational)
              ├─ crosses 30d threshold  → status → At Risk + email (urgent) + Salesforce Notification → Procurement Manager
              ├─ crosses 7d threshold   → Compliance Manager Notification + CC email (critical) + supplier status update
              └─ past expiry, no renewal → Purchase_Order__c risk flag (informational only, NO PO suspension)
  └─▶ (separate, event-driven) renewal upload → existing /assess pipeline → verdict
        └─ if Compliant → clear ALL open alerts for that document + confirmation email
```

### 2.2 Backend engine changes — none required for the monitoring/alerting itself

This is a deliberate, important finding: **the scheduler, thresholds, alerts, and status
changes are pure Salesforce logic** — they operate on data (`Expiry_Date__c`,
`Status__c`) already computed and stored by the engine from a *previous* assessment. The
engine does not need to run anything nightly.

**The only engine touchpoint:** when a supplier uploads a renewal document, that's the
**exact same `/assess` call** that already exists (Document Upload → `DocAssessQueueable`
→ `/assess`). No new engine endpoint. The only engine-side consideration:

- **`/assess`'s existing structured summary + deterministic gates already produce
  everything needed to auto-clear an alert correctly** — `Status__c = 'Compliant'` and
  `Expiry_Date__c` in the future is suf­ficient to detect "this alert is resolved." No
  engine change needed here either.

### 2.3 Salesforce changes — new components

**New fields:**

| Object | Field | Type | Purpose |
|---|---|---|---|
| `Compliance_Document__c` | `Expiry_Alert_60d_Sent__c` | Checkbox | idempotency — never send the same tier twice |
| `Compliance_Document__c` | `Expiry_Alert_30d_Sent__c` | Checkbox | " |
| `Compliance_Document__c` | `Expiry_Alert_7d_Sent__c` | Checkbox | " |
| `Compliance_Document__c` | `Expiry_Alert_Cleared_Date__c` | DateTime | when a renewal cleared the alert (audit) |
| `Account` | `Owning_Procurement_User__c` | Lookup(User) | who gets the 30d Salesforce Notification |
| `Account` | `Compliance_Manager__c` | Lookup(User) | who gets the 7d critical notification |

**New Custom Metadata Type — `Expiry_Alert_Threshold__mdt`** (matches the existing
`Compliance_Requirement__mdt` pattern — configurable, not hardcoded):
`Threshold_Days__c` (60/30/7), `Alert_Tier__c` (Informational/Urgent/Critical),
`Email_Template_Name__c`, `Status_Change_To__c` (optional — e.g. 30d → "At Risk").

**New Apex:**
- `ExpiryMonitorScheduler` (Schedulable) — nightly cron (e.g. `0 0 2 * * ?`, 2 AM), kicks
  off the batch.
- `ExpiryMonitorBatch` (`Database.Batchable<SObject>`) — query scope: all
  `Compliance_Document__c` with `Expiry_Date__c != null AND Status__c != 'Expired-Handled'`
  (bounded, bulk-safe — this is the right shape for "scan every document" at scale,
  not a single monolithic SOQL in a Schedulable, which would hit governor limits on a
  large supplier base).
- `ExpiryAlertService` — the actual threshold logic + email dispatch + Notification
  dispatch, called from the batch's `execute()`. Reads `Expiry_Alert_Threshold__mdt` for
  configurable thresholds (not hardcoded 60/30/7 — matches the requirement's "configurable
  thresholds" ask and the platform's existing CMDT convention).
- Reuses **Salesforce Custom Notification Types** for the in-app notifications (native
  feature — no custom object needed for "Salesforce notification").

**Renewal workflow (Experience Cloud / scSupplierPortal):**
- The portal's checklist rendering already knows each `Compliance_Document__c`'s status
  (per the checklist-tick work from earlier this session). Add: when a document's status
  is `At Risk` or has an open alert, render an **"Upload Renewal"** action directly on
  that checklist row — no new navigation, reusing the existing upload component
  (`scProcurementDocumentUploader` / `uploadFilesFlow`).
- On successful re-assessment → `Compliant`: `ExpiryAlertService.clearAlerts()` resets
  the three checkbox flags, stamps `Expiry_Alert_Cleared_Date__c`, and sends the
  confirmation email to supplier + Procurement Manager.

### 2.4 Purchase Order risk flag — minimal, explicit scope (per your decision)

Given no PO data exists today, this phase adds the **minimum viable object** to satisfy
the acceptance criterion honestly, not a full procurement module:

**New object `Purchase_Order__c`** (Master-Detail or Lookup → Account):
`PO_Number__c` (Text), `Supplier__c` (Lookup→Account), `Status__c` (Active/Closed),
`Estimated_Value__c` (Currency, optional). **Deliberately minimal** — this is a
compliance-risk-visibility record, not a procurement system; if a real Procurement/ERP
integration exists later, this object becomes a sync target, not a system of record.

**Logic:** when a document reaches expiry with no successful renewal,
`ExpiryAlertService` queries `Purchase_Order__c WHERE Supplier__c = :account AND
Status__c = 'Active'` and raises an **informational flag** (a new
`PO_Risk_Flag__c` field or a row in `Audit_Log__c` + a Notification to the Procurement
Lead) — explicitly **no automatic suspension of anything**, matching the requirement's
own "alert only" language.

---

## 3. Req 2 — Multi-Tier Risk Propagation

### 3.1 This is largely already designed — reconciling, not rebuilding

The core mechanics — worst-case-style propagation up `ParentId`, a distinct
`Cascading_Risk_Tier__c` field, bottom-up recompute order, a "blame pointer" back to the
originating supplier — were already designed in `docs/multi-tier-risk-rollup.md`
this session. **Req 2 supplies the missing piece that design left open: the actual
weighted formula** (`Own×0.7 + Sub-Supplier×0.3`, tier-averaged, relationship-weighted).
This section updates that design with the formula, rather than starting over.

### 3.2 Backend engine changes — none required

Like Req 1, this is pure Salesforce-side logic operating on already-computed
`Risk_Score__c` values. The engine's job (assessing documents, screening, computing a
supplier's *own* risk) is unchanged. The propagation math runs entirely in Apex over
existing Account data.

### 3.3 New field — relationship weight

| Object | Field | Type | Purpose |
|---|---|---|---|
| `Account` (child) | `Relationship_Type__c` | Picklist: Sole Source / Preferred / Secondary | drives the weight in the formula |
| `Account` | `Cascading_Risk_Tier__c` | Picklist | worst-case-propagated tier (already designed) |
| `Account` | `Cascading_Risk_Source__c` | Text | blame pointer (already designed) |
| `Account` | `Propagated_Score__c` | Number | the formula's numeric output, distinct from `Risk_Score__c` (own) |
| `Account` | `Cascading_Risk_Last_Computed__c` | DateTime | already designed |

**New Custom Metadata Type — `Risk_Propagation_Config__mdt`**: `Own_Weight__c` (0.7),
`Sub_Supplier_Weight__c` (0.3), `Sole_Source_Weight__c` (1.5), `Preferred_Weight__c`
(1.0), `Secondary_Weight__c` (0.8), `Cascading_Risk_Threshold__c` — **all configurable
per the requirement's own explicit instruction ("store as system settings, not hardcoded
values"), matching the platform's established CMDT pattern.**

### 3.4 New Platform Event — `Supplier_Status_Changed__e`

Modeled directly on the existing `Document_Uploaded__e` pattern already proven in this
org.

**Fields:** `AccountId__c`, `Old_Status__c`, `New_Status__c` (Non-Compliant/At
Risk/Expired/Compliant), `Triggered_From__c`.

**Publisher:** wherever `Account.Compliance_Status_Rollup__c` (or `Risk_Tier__c`)
actually changes today — the existing assessment-write path (`DocAssessQueueable`,
`ExpiryAlertService` from Req 1, screening persistence) publishes this event on a
genuine status transition (not on every save — only when the value actually changes,
to avoid noise).

### 3.5 Traversal + calculation engine

**`RiskPropagationTrigger`** (Platform Event trigger, `after insert` on
`Supplier_Status_Changed__e`) → enqueues **`RiskPropagationQueueable`**.

**`RiskPropagationQueueable`** (implements the formula from your spec exactly):
1. Load the originating Account + walk `ParentId` up to Tier 1 (bounded — max 3 hops:
   T3→T2→T1, matching the platform's actual tier depth; the code should not assume
   unlimited depth even though `ParentId` technically supports 10 levels).
2. **Bottom-up order, exactly as specified:** if the change originated at T3, recompute
   its T2 parent FIRST, then that T2's T1 parent — never compute a parent before its own
   children are settled.
3. Per parent: gather all children at that tier, compute
   `contribution = child.Propagated_Score__c(or Risk_Score__c if T3) × relationshipWeight`,
   **average** across multiple children (per the spec), then
   `new_score = own×Own_Weight + blended_contribution×Sub_Supplier_Weight`, **capped at
   100**.
4. If `new_score` crosses `Cascading_Risk_Threshold__c` AND it's driven by propagation
   (not the parent's own compliance) → set `Cascading_Risk_Tier__c` = "Cascading Risk –
   Sub-Supplier Non-Compliance" (kept **distinct** from `Risk_Tier__c`, per the
   requirement) and set `Cascading_Risk_Source__c` to the originating supplier's name +
   id (traceability, per the requirement).
5. **Idempotency/debounce guard** (the piece I added beyond the literal spec): skip
   recomputation if `Cascading_Risk_Last_Computed__c` is within N seconds AND the inputs
   haven't actually changed — prevents a rapid status-flap from cascading redundant
   recalculations up the same chain repeatedly.
6. Writes trigger `Audit_Log__c` rows (existing object) for every propagated change —
   full traceability of *why* a Tier 1 supplier's score moved.

### 3.6 Governor-limit / bulk safety note

A single Platform Event → Queueable → (potentially) another Queueable chain (T3 triggers
T2 recompute, which itself may need to trigger T1 recompute) must respect Salesforce's
Queueable chaining depth. Given the tier depth is bounded at 3, this is safe, but the
design explicitly **walks and computes in one Queueable job per event**, not a
Queueable-calls-Queueable chain per tier, to stay well inside limits.

---

## 4. Open decisions before implementation

1. **Confirm `Owning_Procurement_User__c` / `Compliance_Manager__c` population** — how
   are these assigned per supplier today? (Manually on intake? Derived from
   `OwnerId`?) Needed before the notification routing can be built.
2. **Email templates** — need the actual copy for the 60d/30d/7d/confirmation emails
   (Lightning Email Templates, referenced by `Expiry_Alert_Threshold__mdt`).
3. **`Purchase_Order__c` minimal object** — confirm this lightweight, compliance-only
   object (not a real procurement system integration) is acceptable scope for this
   phase, per your decision above.
4. **Cascading Risk threshold default** — the requirement doesn't specify a number;
   propose starting at the same tier boundaries as `Risk_Tier__c` (e.g. score ≥ 60 →
   flagged) and tune with real data.

---

## 5. Build sequencing (both requirements, ordered)

```
Req 1: fields (2.3) → Expiry_Alert_Threshold__mdt → ExpiryAlertService → 
       ExpiryMonitorBatch → ExpiryMonitorScheduler → portal "Upload Renewal" action →
       Purchase_Order__c (minimal) + PO risk flag

Req 2: Relationship_Type__c + cascading fields (3.3) → Risk_Propagation_Config__mdt →
       Supplier_Status_Changed__e → RiskPropagationQueueable (with debounce guard) →
       wire the publish call into existing status-change points (DocAssessQueueable,
       ExpiryAlertService, screening persistence)
```

Req 1 and Req 2 can be built in parallel — they share no code, only the general pattern
(CMDT-driven config, Platform-Event-driven async processing) already established in this
platform.
