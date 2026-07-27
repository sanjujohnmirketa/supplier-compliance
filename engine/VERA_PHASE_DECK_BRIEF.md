# VERA — 3-Page Slide Deck Brief (for Claude design → presentation)

**Instruction to the design model:** Render this as a polished 3-slide deck (16:9).
Audience: product/exec stakeholders evaluating Phase-1 → Phase-2 investment. Tone:
confident, enterprise, "AI that is sophisticated *and* deterministic." Use a clean,
modern palette (deep blue + warm amber accents, white space). One concept per slide.
Each slide's title, subtitle, body blocks, and a visual suggestion are given below.

---

## SLIDE 1 — What VERA Is (the vision)

**Title:** VERA — Vendor Evaluation & Risk Agent
**Subtitle:** A policy-grounded AI compliance engine for supplier onboarding — sophisticated reasoning, deterministic outcomes, a human signs every decision.

**Body — three pillars (icon + one line each):**
- **Adaptable** — provider-agnostic AI engine (OpenAI / Azure / Anthropic / Ollama / vLLM), on-prem capable, no vendor lock-in.
- **Deterministic & Governed** — critical compliance gates are rule-based (expiry, coverage, identity), not model-guessed; every verdict cites the policy clause; PII-tokenized + injection-scanned.
- **Two owners, one pipeline** — Procurement gathers & screens evidence → hands off → Analyst assesses & recommends → Approver signs off.

**Visual suggestion:** A left-to-right pipeline ribbon:
`Intake → Documents & Screening → ▸ Handoff ▸ → Risk Analysis → Decision & Route → Approver`
with a small "✦ AI" tag under the first four stages and a "● Human decides" tag under the last two.

**Footer strip:** "The AI scopes, validates, screens, scores, and drafts. It never decides."

---

## SLIDE 2 — What's Covered (Phase 1 — shipped & live)

**Title:** Phase 1 — Delivered
**Subtitle:** A working two-persona console on Salesforce, wired to a live AI compliance engine. Deployed and demo-ready.

**Body — two columns:**

**Left column — "The experience" (Procurement + Analyst consoles):**
- AI-scoped **document checklist** at intake — policy-grounded, per-item clause justification, AI-set human-oversight level.
- **Documents & Screening** — bulk upload, AI matches each file to the checklist & validates it; merged 2-column view (required document ↔ uploaded file) with **per-document AI verdict, confidence %, and expandable clause-by-clause reasoning**.
- **Rejected documents** promotable into the checklist ("Add to checklist").
- **Screening** — Sanctions, Financials, Adverse Media.
- **Deterministic dashboard** — Risk score (0–100), onboarding progress, score trend — reproducible, no LLM.
- **Action-driving co-pilot** — greeting + persona-aware "do this next" suggestions, grounded in the case.
- Analyst **risk analysis → decision & route** with accountability trail.

**Right column — "The engine" (live, free/open feeds):**
- `/scope` — RAG over policy corpus (pgvector + local embeddings) → domains + checklist.
- `/assess` — LLM extracts, **hard-coded gates decide** (expiry / coverage / identifier).
- `/verify` — **GLEIF** identity · **OpenSanctions** sanctions/PEP · **GDELT** adverse media (all free, keyless/community).
- `/copilot` — grounded Q&A with citations.
- **Continuous evaluation** — golden regression suite locks the deterministic guarantees.

**Visual suggestion:** Two-column card layout; a small green "✓ live" pill on each engine feed (GLEIF, OpenSanctions, GDELT). A subtle "Salesforce LWC ⇄ Named Credential ⇄ FastAPI engine" connector line across the top.

---

## SLIDE 3 — What's Next (Phase 2 — the complexity that scales it)

**Title:** Phase 2 — Enterprise Depth
**Subtitle:** Connect to the systems procurement already lives in, deepen the AI, widen the risk lens.

**Body — three workstreams (each a card with a header + 2–3 bullets):**

**1. External-portal adapters (integration)**
- Connectors to **SAP Ariba / Coupa** (and similar) — pull requisitions, push onboarding outcomes.
- "Ready for Purchase" handoff flows into PR→PO execution, closing the procure-to-pay loop.
- Bi-directional sync so VERA is a step *inside* the existing buying workflow, not a separate tool.

**2. Fine-tuning the AI engine (intelligence)**
- Domain fine-tuning / adapters on the compliance corpus for sharper extraction & verdicts.
- **Hedging / evasive-language detection** at an interactive supplier "gate" (RFI attestations).
- Adverse-media **false-positive clearance** — one high-confidence narrative, not raw hits.
- Learning loop: analyst overrides become calibration examples.

**3. Macro & wider-risk feeds (coverage)**
- **World Bank** governance indicators in `/scope` → an Environmental/Macro-Risk summary at intake that **influences the risk tier & checklist** (geography-aware reasoning).
- **ACLED** (regional instability), **NIST NVD / Shodan** (cyber posture) — free/open APIs.
- Continuous post-onboarding re-screening.

**Visual suggestion:** Three vertical cards. Card 1 shows logos/wordmarks for SAP Ariba & Coupa with a ⇄ arrow to a "VERA" chip. Card 2 a brain/gear "✦" motif. Card 3 a globe motif with feed names. A thin timeline arrow under all three labeled "Phase 2".

**Footer strip:** "Phase 1 proved the engine. Phase 2 embeds it in the enterprise."

---

### Notes for the design model
- Keep each slide to ONE idea; don't crowd. Prefer short bullets (≤ 8 words where possible).
- Use the same three-pillar / three-card rhythm across slides for visual cohesion.
- "Deterministic" and "a human decides" are the trust themes — keep them visible on slides 1 and 2.
- Brand name is **VERA (Vendor Evaluation & Risk Agent)**. Product domain: supplier compliance automation on Salesforce + a provider-agnostic AI engine.
