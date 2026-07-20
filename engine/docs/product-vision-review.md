# Product Vision & Prototype Review — assessed against real scenarios

**Purpose:** Pressure-test the AI Supplier Compliance vision + prototypes before the
data model and Phase-1 build. Covers (1) vision critique, (2) the Phase-1 architecture
decision, (3) scenario-by-scenario viability. Tone: balanced — strengths first, then
risks with mitigations. Grounded in what we've actually built (the FastAPI agentic
engine + Salesforce consoles), not theory.
**Date:** June 2026 · **Status:** working review for team alignment.

---

## 1. Executive read

The vision is **strong on market thesis and economics, and we've already built the hard
technical core** — but it carries **one unresolved architecture contradiction** and
**three real-world operating risks** that should be settled before the data model.

- **Keep & lead with:** multi-tier visibility (real regulatory demand), the Tier-2/3
  license-cost optimization (the sharpest, most defensible idea), and the responsible-AI
  HITL design we've already implemented (a credibility asset).
- **Resolve first:** all-in-Salesforce vs. external T2/T3 portal — these two can't both
  be Phase 1, and everything downstream depends on the answer.
- **Pre-empt:** Tier-1 cooperation, multi-buyer supplier identity, and "TBD" timelines.

What we've **already proven in code** de-risks a lot of the vision: agentic
scope→screen→assess→synthesize→route with human gates, structured field-grounded
extraction, screening with a flag-can-never-auto-clear safety rule. The vision should
claim these as *built*, not aspirational.

---

## 2. What holds up well (strengths)

1. **Multi-tier visibility is a real, defensible differentiator.** Ariba/Coupa being
   Tier-1-centric and AI-light is accurate; EU CSDDD, UFLPA, and modern-slavery due
   diligence create genuine demand for Tier-2/3 propagation. This is a market gap, not a
   manufactured one.

2. **The license-cost insight is the standout idea.** "500 T2/T3 × $25/mo Experience
   Cloud ≈ $150K/yr → use a free email-invite portal for T2/T3." A concrete decision with
   a number behind it. It's what makes multi-tier economically viable rather than a slide.

3. **The responsible-AI core is already built — and better than the deck claims.** Our
   engine deliberately abstains ("Needs Analyst"), never auto-clears a flag, and gates on
   human oversight. That's exactly what a compliance buyer's risk team will demand. The
   prototype's "98.2% → auto-submit" *undersells* this by making it look naive.

4. **The prototypes are coherent and demo-ready.** The 10-screen invite flow and the
   role-switcher portal are internally consistent and tell the cascade story clearly.

5. **The phased roadmap is sound in shape.** Each phase delivers standalone value; the
   "no rip-and-replace" connector strategy (Phase 3) is the right enterprise wedge.

---

## 3. The architecture decision (resolve before the data model)

**There is a direct contradiction between two stated directions:**

| | Direction A — all-in-Salesforce | Direction B — hybrid external portal |
|---|---|---|
| Source | Your latest stated shift | The prototypes + product-vision docs |
| Intake | Public SF site; supplier self-registers → Account | External AI Portal; Account via REST |
| Staff | Veera app *inside* Salesforce | Buying Org in CRM, T1 in Experience Cloud |
| T2/T3 | (implied) in Salesforce too | **External portal, no SF license** |
| Credentials | Salesforce-managed | External Postgres (bcrypt), never in SF |

**Why it must be settled now:** the data model, the licensing economics, and the sync
architecture are *completely different* under A vs. B. Building the data model before
deciding is building on sand.

**Recommendation: a deliberate split, not a binary.**

- **Buying Org + Tier 1 → Salesforce** (CRM + the internal Veera app for procurement/
  analyst; Experience Cloud or a public intake for T1 self-registration). This is where
  the contractual relationship, the money, and the single-pane-of-glass live. It's also
  what we've *already built*.
- **Tier 2 / Tier 3 → lightweight external portal** (email-invite, no SF license), syncing
  compliance status back to SF. This is the *only* way the unit economics work at T2/T3
  scale — and the vision's own best idea.

So Direction A is right for the **buyer + T1 surface**, and Direction B is right for the
**T2/T3 surface**. They are not competing — they apply to different actors. The mistake
is treating "all in Salesforce" as covering T2/T3 (license blow-up) or treating "external
portal" as covering the buyer/T1 (loses the native CRM value). **Decision to ratify:**
*SF for buyer + T1; external portal for T2/T3; `sf_account_id` as the bridge.*

(One caveat to confirm: if the demo / Phase-1 scope is **single-tier only** for now, then
build the SF surface first and defer the external T2/T3 portal — the model should be
tier-ready but you don't pay for the portal until multi-tier is funded.)

---

## 4. Scenario viability (vision vs. operating reality)

### Scenario 1 — "A non-compliant Tier-2 is invisible until it's a crisis" (the core thesis)
**Strength:** the regulatory driver is real. **Risk:** the mechanic assumes *Tier-1
invites and polices its own sub-suppliers* into the buyer's system — unpaid work that
exposes their supply base. Tier-1s often guard their sub-supplier list as commercially
sensitive. **The whole cascade depends on Tier-1 cooperation the vision assumes but
doesn't justify.** This is the #1 thesis risk.
**Mitigations to add to the vision:** (a) the buyer *mandates* sub-tier disclosure as a
contractual onboarding condition (compliance leverage, not goodwill); (b) make T1's life
easier, not harder — pre-filled invites, AI doing the document work, a clean dashboard —
so cascading is low-effort; (c) position sub-tier visibility as *protecting* the T1 too
(shared audit readiness), not just serving the buyer.

### Scenario 2 — One company is Tier-2 to three different buyers
**Risk:** the data-model doc's own decision ("register as separate Accounts per buyer")
means the same supplier gets 3 logins, uploads the *same COI* 3×, maintains 3 scores.
**Supplier adoption dies here**, contradicting the "lightweight UX for adoption" goal.
**Mitigation:** design the supplier portal **supplier-centric** — one supplier identity,
"upload once, share with many buyers" (consent-based document sharing). Salesforce stays
buyer-centric (separate Account per relationship), but the *portal* unifies the supplier's
experience. Flag this explicitly as a Phase-2 identity decision; Phase-1 single-parent is
fine, but don't let the data model harden a supplier-hostile pattern.

### Scenario 3 — ">90% AI confidence makes automation viable"
**Reality from our own build:** screening false-positives flooded *every* supplier until
we added name-match thresholds; a flag must never auto-clear; "Needs Analyst" is a
frequent, correct outcome. The prototype's "98.2% → auto-submit" oversells what our engine
*deliberately won't do*. **This is actually a credibility win** — we built the responsible
version. **Mitigation:** reframe the vision so HITL + abstention are *headline features*
("AI that knows when to ask a human"), not a footnote. Use a realistic confidence
distribution in demos, not a single 98% hero number.

### Scenario 4 — Supplier offboarding / relationship ends
Not addressed anywhere. Suppliers churn, contracts end, entities get acquired. **Add:**
deactivation states, data retention vs. deletion (regulatory — audit log is append-only),
and what happens to a T2's own T3s when the T2 leaves.

### Scenario 5 — Document rejection & re-submission loop
The happy path is well-prototyped; the unhappy path (reject → reason → supplier fixes →
re-uploads → re-review, possibly several rounds) is where real onboarding time is spent.
The "50–70% faster onboarding" KPI lives or dies on this loop. **Add** explicit
re-submission cycle modeling + SLA tracking on it.

---

## 5. Vision-document quality notes (smaller, fixable)

- **All timelines are "TBD" and budgets "to be confirmed."** Fine for a vision; risky if
  presented as a plan. Add at least relative sequencing/quarters before VP review.
- **Phase 4 (predictive) needs "6+ months historical data"** you won't have at launch —
  so the headline "predictive risk intelligence" is 18+ months out. Lead the *near-term*
  story with what's real now: automated onboarding + multi-tier visibility + responsible
  AI. Keep prediction as the north star, not the Phase-1 promise.
- **The "Unified Risk Score"** blends compliance-health (Ph1), cascading-risk (Ph2), and
  predictive (Ph4) — three things from three phases. Make clear which components light up
  when, so it doesn't imply Day-1 prediction.
- **"Zero manual data entry"** is too absolute given HITL review and re-submission loops.
  "Minimal manual entry; human review only on low-confidence" is both true and stronger.

---

## 6. Prioritized recommendations

**P0 — settle before the data model**
1. Ratify the architecture split: **SF (buyer + T1) + external portal (T2/T3)**, or
   explicitly scope Phase 1 to single-tier-in-SF and defer the portal.
2. Decide Phase-1 tier scope: single-tier-now-tier-ready vs. full multi-tier now.

**P1 — strengthen the vision before VP review**
3. Add the **Tier-1 cooperation mechanism** (contractual mandate + low-effort cascade) —
   close the #1 thesis hole.
4. Reframe **HITL/abstention as a headline feature**; align prototype confidence with
   our real engine behavior.
5. Add **relative timelines**; separate "built today" from "Phase 4 aspiration."

**P2 — model these explicitly (feeds the data model)**
6. Multi-buyer supplier identity (supplier-centric portal, upload-once-share-many).
7. Offboarding / deactivation + retention.
8. Rejection → re-submission loop + SLA.

---

## 7. Bottom line

The thesis is sound, the economics idea is genuinely sharp, and **the hardest technical
piece — the responsible agentic AI engine — is already built and arguably ahead of the
deck.** The vision is *stronger than it presents itself* on AI maturity, and *weaker than
it presents itself* on two operating assumptions (Tier-1 cooperation, multi-buyer
identity) and one unresolved architecture choice. Fix those three, lead with what's real,
and this is a defensible Phase-1 story. **Then** the data model has firm ground.
