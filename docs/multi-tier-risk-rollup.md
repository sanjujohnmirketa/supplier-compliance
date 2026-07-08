# Multi-Tier Risk Roll-Up — design, object roles, and field-population timeline

**Question answered:** how does a Tier-2/3 supplier's compliance/risk roll up to its
Tier-1 (and to the buyer/procurement requester), how does each object/field participate,
and **at what instant in the functional flow** each field is populated.

**Decisions locked:**
- **Roll-up semantics = worst-case propagation** — a parent's *effective* risk is the
  worst of (its own risk, any child's effective risk). One Non-Compliant T3 makes the
  whole chain High. Audit-defensible; matches the "one bad sub-supplier = crisis" thesis.
- **Recompute = event-driven + nightly safety net** — propagate up the chain immediately
  on a child status change; a nightly job catches expiries + missed events.

---

## 0. The decisive constraint (why this needs code, not config)

Salesforce **native Roll-Up Summary fields require Master-Detail**. The tier cascade is
`Account.ParentId` — a **lookup hierarchy**, not master-detail. So **tier roll-up cannot
use native RUS.** It must be **Apex (or Flow) that walks ParentId** and recomputes. This
is the core engineering fact the design is built around.

(Within a *single* supplier, `Compliance_Assessment__c` IS master-detail to Account — so
that level's rollup is cheap. The cross-tier roll-up is the part that needs code.)

---

## 1. Two scores, kept distinct (so the buyer sees the truth)

Worst-case propagation is most useful when the buyer can see **both** "is this supplier
itself OK?" and "is its supply chain OK?". So each Account carries:

| Field | Meaning | Source |
|---|---|---|
| `Risk_Score__c` / `Risk_Tier__c` | the supplier's **OWN** compliance (its docs, screening) | computed from *its own* assessments (existing) |
| `Cascading_Risk_Tier__c` ★ | **worst** tier across its whole sub-tree (self + all descendants) | the roll-up (new) |
| `Cascading_Risk_Source__c` ★ | which descendant drove it (e.g. "SteelMax Inc (T3) — Non-Compliant: insurance expired") | the roll-up (new) |
| `Sub_Tier_Supplier_Count__c` ★ | # of descendants | the roll-up (new) |
| `Compliance_Status_Rollup__c` | own-level status label (Compliant/Pending/Non-Compliant) | existing per-supplier rollup |

So a T1 row reads: *own = Compliant, cascading = High (SteelMax T3 non-compliant).* That
distinction is the product's differentiator made concrete.

---

## 2. Object roles in the roll-up

| Object | Role in the multi-tier roll-up |
|---|---|
| **Account** (per tier) | The node. Holds own-risk + the rolled-up cascading-risk fields. `ParentId` is the edge that the roll-up walks upward. |
| **Compliance_Assessment__c** | The leaf evidence. A supplier's OWN `Risk_Tier__c` is derived from its assessment rows. A change here is the **trigger origin** for a roll-up. |
| **Compliance_Document__c / Document_Extraction__c** | Feed the assessment verdict (and expiry dates that the nightly job watches). |
| **Supplier_Invitation__c** ★ / Portal `invitations` | Establish the parent/child edge at creation (sets `ParentId` + `Invited_By_Account__c`). The roll-up has nothing to walk until this runs. |
| **Audit_Log__c** | Records every roll-up recompute (`Event_Type__c = compliance_score_updated`) + what propagated, for the immutable trail. |
| **Portal `compliance_status`** (T2/T3) | The authoritative own-score for external suppliers; **syncs to the T2/T3 Account**, which then triggers the in-SF roll-up up to T1. |

---

## 3. The worst-case roll-up algorithm (logical)

```
effective_tier(account) =
    max_severity(
        own_tier(account),                      # from its own assessments
        [ effective_tier(child) for child in children(account) ]   # recurse down
    )

# implemented bottom-up: when a leaf changes, walk UP via ParentId,
# recomputing each ancestor's effective_tier until it stops changing.
```

- `own_tier` = the supplier's `Risk_Tier__c` (already computed from its assessments /
  screening by the engine today).
- Severity order: `Critical > High > Medium > Low > (None)`.
- `Cascading_Risk_Source__c` = the descendant whose `own_tier` equals the propagated max
  (the "blame" pointer), so the buyer can drill straight to the cause.
- **Short-circuit:** stop walking up when an ancestor's effective tier doesn't change —
  avoids needless writes up a deep chain.

---

## 4. Functional flow — what populates which field, at what instant

The whole point of your question: **field population mapped to flow moments.** Read
top-to-bottom = chronological.

| # | Flow moment | Actor / trigger | Fields populated | Object |
|---|---|---|---|---|
| 1 | **Public self-service intake — supplier saves details** | Supplier (guest) | `Name`, `Country_of_Origin__c`, `Industry`, `Engagement_Type__c`, `Annual_Spend_Est__c`, `Supplier_Contact_Email__c`, `Self_Registered__c=true`, `Onboarding_Status__c='Self-Registered'`, RecordType (tier) | Account |
| 2 | **Sub-supplier invited** (T1 invites T2, or T2 invites T3) | Inviter | `ParentId` (→ inviter), `Invited_By_Account__c`, `Tier`, `Invite_Token_Status__c='Pending'` on the *new* Account once accepted | Account + Supplier_Invitation__c / Portal `invitations` |
| 3 | **Procurement opens supplier in Veera → agent scopes** | Procurement (case start) | `Compliance_Case_Id__c`, `Risk_Tier__c` (preliminary), `Risk_Domains__c`, `HITL_Threshold__c`, `Onboarding_Status__c='In Review'` | Account |
| 4 | **Checklist generated** | agent (intake) | one `Compliance_Assessment__c` per required doc: `Requirement_Key__c`, `Requirement_Label__c`, `Status__c='Pending'` | Compliance_Assessment__c |
| 5 | **Document uploaded + AI assessed** | supplier upload → engine `/assess` | `Compliance_Document__c` (type/issuer/expiry/confidence), `Document_Extraction__c` (`Extracted_Fields__c`), then the assessment row: `Status__c`, `Severity__c`, `Reason_Detail__c`, `AI_Confidence__c`, `Valid_Until__c`, `Compliance_Document__c` (lookup) | Document, Extraction, Assessment |
| 6 | **Screening runs** | engine `/verify` | screening assessment rows + flag signal feeding the supplier's own tier | Compliance_Assessment__c |
| 7 | **Own-risk recomputed** | synthesis (engine) | `Risk_Score__c`, `Risk_Tier__c`, `Risk_Last_Computed__c`, `Compliance_Status_Rollup__c` | Account (this supplier) |
| 8 | **★ ROLL-UP fires (event-driven)** | trigger on step 7 change | walk `ParentId` upward; on each ancestor set `Cascading_Risk_Tier__c`, `Cascading_Risk_Source__c`, `Sub_Tier_Supplier_Count__c` | Account (ancestors, up to T1 + buyer view) |
| 9 | **Audit written** | every recompute | `Event_Type__c='compliance_score_updated'`, `New_Value__c` (new cascading tier), `Original_Value__c`, `Related_Record_Id__c` (the child that drove it) | Audit_Log__c |
| 10 | **Analyst decision / handoff** | Gate 2 | `Onboarding_Status__c`, decision recorded; if it changes own_tier → re-fires step 8 | Account |
| 11 | **★ Nightly safety net** | scheduled job | re-scan expiries (`Compliance_Document__c.Expiry_Date__c` past → flips assessment → own_tier → roll-up); reconcile any missed events | all of the above |
| 12 | **T2/T3 external sync** | Portal → SF REST (PATCH) | `Risk_Score__c`, `Docs_Required/Approved__c`, `Onboarding_Status__c`, `Invite_Token_Status__c` on the T2/T3 Account → **which triggers step 8 up to T1** | Account (T2/T3) |

**The key causal chain (your "what rolls up when"):**
`child doc/screening change → child assessment → child own_tier (step 7) → roll-up walks
ParentId (step 8) → T1 Cascading_Risk_Tier__c → visible to buyer/procurement requester`.
For external T2/T3, the same chain, but the child own_tier arrives via REST sync (step 12)
first.

---

## 5. New fields to add (the build list for the roll-up)

| Field | Type | On | Populated at |
|---|---|---|---|
| `Cascading_Risk_Tier__c` ★ | picklist (Low/Med/High/Critical) | Account | step 8 / 11 |
| `Cascading_Risk_Source__c` ★ | text | Account | step 8 / 11 |
| `Sub_Tier_Supplier_Count__c` ★ | number | Account | step 8 / 11 |
| `Cascading_Risk_Last_Computed__c` ★ | datetime | Account | step 8 / 11 |

(Plus the shift fields already listed in the data-model doc: `Invited_By_Account__c`,
`Self_Registered__c`, sync targets.)

---

## 6. Implementation shape (so it's buildable, not just conceptual)

- **`MultiTierRollupService` (Apex)** — given a changed Account id, recompute its own_tier
  (from its assessments), then `while parent != null`: recompute parent's
  `Cascading_Risk_Tier__c` from (parent own + all children effective); stop early if
  unchanged. Bulk-safe (collect ancestor ids, one DML).
- **Trigger** on `Compliance_Assessment__c` (after update/insert) and on `Account`
  (after update of `Risk_Tier__c`) → enqueue the service (Queueable; respects the
  callout-after-DML rule we already hit).
- **Scheduled job** (`MultiTierRollupBatch`, nightly) — find docs expiring/expired +
  Accounts with stale `Cascading_Risk_Last_Computed__c`; recompute their chains.
- **Loop guard** — `ParentId` hierarchy is acyclic by SF rule, but cap recursion depth
  (≤10, the platform max) defensively.
- **Sync hook** — the Portal→SF PATCH that updates a T2/T3 Account's `Risk_Score__c` must
  also enqueue the rollup so external changes propagate to T1.

---

## 7. What the buyer / procurement requester finally sees

On the **Tier-1 Account** (and rolled into the procurement requester's queue):

- **Own status:** Compliant — its own docs are fine.
- **Cascading risk:** **High** — `Cascading_Risk_Source__c` = "SteelMax Inc (T3) ·
  Non-Compliant · insurance expired 2026-03".
- **Drill path:** ParentId hierarchy → expand to the offending T3.
- **Audit:** every propagation logged, timestamped, attributable.

That single "own vs. cascading" split on the T1 record — recomputed the instant a T3
changes — **is the multi-tier differentiator made operational.**
