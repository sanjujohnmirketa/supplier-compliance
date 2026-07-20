# VERA — Phase-1 Delivery Plan (the AI showcase)

**Purpose:** Phase 1 is a *confidence-builder for Phase 2.* It is **not** a feature dump.
The bar for every item: *does it make VERA's intelligence visible AND keep the outcome
deterministic/explainable?* If an item adds an endpoint but not visible intelligence, it
waits.

We fuse two inputs: the existing [PROCUREMENT_REVAMP_CHECKLIST.md](PROCUREMENT_REVAMP_CHECKLIST.md)
(demo-feedback fixes) and the new comparative research (Procurement-Tactics "gate" framework,
macro-risk, hedging detection, free data feeds).

---

## The three "AI moments" Phase-1 must land

A demo audience remembers *moments*, not feature lists. Phase 1 delivers **three**, each
mapped to an existing endpoint so we extend, not rebuild:

```
  MOMENT 1                     MOMENT 2                      MOMENT 3
  "It understands us"          "It catches what humans miss"  "It's deterministic"
  ───────────────────          ─────────────────────────────  ──────────────────────
  Intake → macro-risk +        Interactive Gate → hedging      Risk score + confidence
  smart checklist              language detection              that always adds up
  (/scope upgrade)             (/assess gate-text — NEW)       (deterministic, app-logic)
```

| Moment | Why it sells Phase 2 | Endpoint | Cost |
|--------|----------------------|----------|------|
| **1. Comprehension** | Shows VERA reads the *business context* (country+industry+geo), not just files | `POST /scope` upgrade → `macro_environmental_risks[]` | M |
| **2. Judgment** | Shows VERA catches *soft* risk (evasive supplier language) a checklist never could — the "wow" | `POST /assess/gate-text` (NEW) + `veraSupplierGate` LWC | M |
| **3. Trust** | Shows every number is reproducible & explainable — the deterministic promise | Apex/snapshot risk score + persisted `/assess` confidence | S–M |

Everything else in Phase 1 is **supporting hygiene** so these three moments land on a clean screen.

---

## Phase-1 SCOPE — what we build

### Track A — Moment 1: Comprehension (intake intelligence)
- [ ] **A-1 · ENG** Upgrade `POST /scope` to also return `macro_environmental_risks[]` —
      country-level signals from a **free feed: World Bank Governance Indicators API**
      (unauthenticated) → political stability / regulatory quality / control-of-corruption.
      *(Deterministic: same country → same indices, cached.)*
- [ ] **A-2 · FE (P1)** Render an **"Environmental Risk Summary"** card next to the checklist:
      the macro signals + a one-line "why this matters for this supplier." *(checklist already
      returns `justification`/`clauseId` — show those too, per checklist item A4.)*
- [ ] **A-3 · BE+FE** When macro-risk is elevated, `/scope` injects **extra tracking
      questions** that flow into Moment 2's gate (e.g. proximity-to-sanctioned-border →
      transshipment attestation). *(This is the bridge from Moment 1 → 2.)*
- [ ] **A-4 · data** `Account.Macro_Risk_Context__c` (Long Text) to store the summary.

### Track B — Moment 2: Judgment (the interactive gate + hedging detection) — THE HIGHLIGHT
- [ ] **B-1 · ENG** New `POST /assess/gate-text` — structured-output hedging detector
      (`is_fully_compliant`, `hedging_index`, `detected_hedging_phrases[]`, `analyst_risk_note`,
      `cited_policy_alignment`). Runs through existing `governance.py` (PII + injection) and
      `llm.py` (provider-agnostic). *(temperature 0 → deterministic.)*
- [ ] **B-2 · ENG/eval** Add the **gate hedging golden suite** to `eval_harness.py` (3
      scenarios: absolute-pass, commercial-viability-fail, future-promise-fail) so the
      determinism is *provable* on stage. Keeps the existing 8/8 green.
- [ ] **B-3 · BE** `VendorPortalController.verifySupplierGateAnswers(accountId, responseText,
      policyClause)` → callout to `/assess/gate-text`, persist result, audit-log it.
- [ ] **B-4 · FE** New `veraSupplierGate` LWC — dynamic questions (seeded from A-3),
      "Evaluate Gate with VERA," **live red/green feedback per answer**, and a **locked
      "Proceed" barrier** until all answers clear. Insert as **Step 2 between P1 and P3.**
- [ ] **B-5 · data** `Compliance_Document__c.Attestation_Text__c` (Long Text) +
      `Compliance_Assessment__c.Hedge_Detected__c` (Checkbox) to store the gate outcome.

### Track C — Moment 3: Trust (deterministic score + confidence) — from the checklist
- [ ] **C-1 · BE** **Deterministic Risk Score (0–100)** — pure app-logic, no LLM. Proposed
      weighting (confirm): mandatory-doc compliance %, screening signal, deterministic-gate
      failures (expiry/coverage), tier, **+ hedging index from Moment 2**. Reproducible &
      explainable. *(checklist D2)*
- [ ] **C-2 · BE+FE** **Persist + surface per-document confidence** from `/assess` (today
      hard-coded `'—'`). Replace placeholder; aggregate to a **supplier-level confidence**.
      *(checklist D3/D5/E3)*
- [ ] **C-3 · FE (P4)** **Submission-summary dashboard header**: Risk-score ring +
      Onboarding-progress + Score-trend — matching the screenshot. *(checklist D1)*

### Track D — Supporting hygiene (so the moments land clean) — FE-mostly
- [ ] **D-1 · FE** Checkbox ticks **on upload** (not only on validation); status reads
      "Uploaded." *(checklist B1)*
- [ ] **D-2 · FE** Merge **Required checklist + Documents** into one row (checkbox left,
      preview/remove right); **Rejected Documents** = unmatched uploads + one-line summary +
      "Add to checklist." *(checklist B2/B3/B6)*
- [ ] **D-3 · FE** Documents-tab AI summaries show **checklist docs only**, not screening rows.
      *(checklist B5)*
- [ ] **D-4 · FE** Queue fixes: Draft no longer shows under In Review; **duration** column.
      *(checklist E1/E2)*
- [ ] **D-5 · FE** Co-pilot **greeting + persona suggested-action chips**. *(checklist C1/C2)*
- [ ] **D-6 · ENG/BE** Adverse-media **false-positive clearance** via existing LLM
      disambiguation on `/verify` — present ONE high-confidence narrative, not raw hits.
      *(research Part 2.4; reuses what we have — high value, low cost)*

---

## Phase-1 OUT (explicitly deferred to Phase 2 — say no on purpose)
- `POST /triage` — unstructured 50-page RFI ingestion → compliance matrix. *(big, not a
  moment for a first demo; gate-text proves the capability at lower cost.)*
- Full supplier **self-service portal** for the gate (Phase 1 = internal procurement runs the
  gate on the supplier's behalf / pasted responses).
- **ACLED / Shodan / NIST NVD / CISA** feeds — World Bank alone carries Moment 1; the rest are
  Phase-2 depth.
- Dynamic-intake-fields full loop (`additionalFields[]` round-trip) beyond the gate questions.
- Co-pilot 504 deep fix (async/stream) — Phase-1 mitigation only: pre-extract fields at
  assess-time so the heavy question is answered from stored data. *(checklist C3, lighter cut)*

---

## Free data feeds locked for Phase 1
| Risk | Feed | Auth | Used in |
|------|------|------|---------|
| Macro/geopolitical | **World Bank Indicators API** | none | Moment 1 (`/scope`) |
| Identity/registry | **GLEIF** (already wired) | none | existing `/verify` |
| Sanctions/PEP | **OpenSanctions** (already wired) | key/demo fallback | existing `/verify` |
| Adverse media | **GDELT** (already wired) | none | `/verify` + D-6 dedup |

---

## Decisions needed before build (4)
1. **Risk-score weights (C-1):** approve a starting formula? *(I'll propose concrete weights.)*
2. **Gate placement (B-4):** Step-2 sub-screen between P1→P3, or a modal on P3? *(sub-screen
   reads as a real "gate"; recommend that.)*
3. **Gate input source (B-4):** procurement pastes the supplier's RFI/email answers in Phase 1
   (no external portal), confirm.
4. **Co-pilot 504 (deferred):** accept the lighter "pre-extract at assess-time" mitigation for
   Phase 1?

---

## Build order (delivers a demo-able slice early)
1. **Hygiene first (D-1…D-5):** clean screen in days, FE-only. Audience sees polish.
2. **Moment 3 (C-1…C-3):** deterministic score + confidence + dashboard — the "trust" backbone.
3. **Moment 1 (A-1…A-4):** macro-risk in intake — World Bank feed + Environmental Risk card.
4. **Moment 2 (B-1…B-5):** the gate + hedging detector — the headline, last so it lands on a
   finished stage, with eval proving determinism.
5. **D-6** adverse-media dedup as a closing "and it cuts the noise too."
```
```
