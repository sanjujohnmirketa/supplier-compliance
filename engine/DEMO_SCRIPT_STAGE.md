# Supplier Compliance Automation — Recording Script (with Stage Directions)

> **Legend:** 🎬 = camera/screen to be on · 👉 = where to point/hover · 🖱️ = click · ⌨️ = type · ⏳ = wait/pause · 🗣️ = narration (read aloud)

---

## PART 1 — Workflow & Screens

### ▶ Intro (no screen needed, or title slide)
🎬 *Title card or your face-cam.*
🗣️ "Hello everyone, and welcome to the demo for the **Mirketa Supplier Compliance Automation** platform — an AI compliance team that onboards your suppliers for you."

🗣️ "Onboarding a supplier today means an analyst manually figuring out which documents are needed, chasing them down, reading every certificate, screening the entity, scoring the risk, and routing for sign-off. It's slow and inconsistent."

🗣️ "So we built a platform that does the heavy lifting and keeps a human in control of every real decision. It's procurement-initiated, and a club of specialized AI agents scopes the risk, verifies documents, screens the entity, scores the supplier, and routes it for approval — all grounded in your own policies and real registries."

🗣️ "We designed it around four principles: **deterministic where it matters**, **grounded and explainable**, a **human gate on every decision**, and it **gets smarter over time**."

🗣️ "Now let's walk through it."

---

### ▶ Screen 1 — The Screening Queue
🎬 *Open the console on the **Screening Queue** screen.*
👉 *Hover across the KPI strip at the top.*
🗣️ "This is the command center. At a glance your team sees every supplier in flight, with live KPIs — total suppliers, how many the AI **auto-cleared**, how many need an analyst, how many are onboarded, and the **average time-to-onboard**."

👉 *Point to one queue row — the tier badge, the risk score, the AI-status pill.*
🗣️ "Each row carries the supplier's risk tier, a risk score, an AI-status pill, and who requested it."

👉 *Point to the yellow **"Awaiting your review"** section at the top.*
🗣️ "And there's a dedicated 'Awaiting your review' section — cases routed to you as an approver. We'll come back to that."

---

### ▶ Screen 2 — Intake (Generate Checklist)
🖱️ *Click into the **Intake** screen.*
⌨️ *Type the supplier fields:* legal name (`Nordwind Präzisionsguss GmbH`), country (`Germany`), industry (`Manufacturing`), engagement type (`Direct Material – Production (Tier 1)`), annual spend (`2,400,000`), email.
🗣️ "Let's start a new supplier. The analyst enters the basics — legal name, country, industry, engagement type, and annual spend."

🖱️ *Click **Generate Checklist**.* ⏳ *Wait ~1–2 s.*
👉 *Point to the risk/scope domains lighting up (Finance, Material, Quality, Conflict).*
🗣️ "In a moment, the AI scopes the supplier. It identifies the risk and compliance domains that actually apply — Finance, Material, Quality, Conflict Minerals — and generates the exact list of required documents, each grounded in a specific policy clause."

👉 *Point to the **Human-review threshold** chip (✦ AI-set) and read its one-line explanation.*
🗣️ "It also sets a human-review threshold, derived from the detected risk tier — higher-risk suppliers get a tighter threshold so more of them route to a human. It's read-only and AI-set."

🖱️ *(Optional) hover the **Request to supplier** button.*
🗣️ "From here the analyst requests the documents with a single click."

---

### ▶ Screen 3 — Due Diligence (the AI Risk Summary)
🖱️ *Open a supplier → **Due Diligence**.* 🖱️ *Upload a document (drag or click Upload).*
👉 *Point to "AI is reviewing in the background" / the next upload slot.*
🗣️ "As each document is uploaded, the AI assesses it in the background — the analyst keeps uploading the rest without waiting."

👉 *Point to the **score-hero** (big number + tier badge + bar) on the right panel.* ⏳ *Let it tick up after an assessment lands.*
🗣️ "On the right, the AI Risk Summary comes to life. At the top is a **live risk score** that adjusts as documents are assessed and screening runs — upload a non-compliant certificate and the score climbs."

👉 *Point to a **Document assessment** row — verdict + confidence %.* 🖱️ *Click to expand the reasoning.*
🗣️ "Every document gets its own verdict and confidence level. Take this Conflict Minerals declaration — Non-Compliant at 90% confidence — and the AI explains exactly why: it's missing the five-step OECD due-diligence statement for cobalt."

👉 *Point to the **clause checks** (PASS / FAIL chips) and the expiry/registry chips.*
🗣️ "And these clause checks — expiry, coverage, identifier — are decided by deterministic rules, so an expired or under-limit document can never slip through."

🖱️ *Click across the screening tabs: **Sanctions → Financials → Conflict → Media**.* ⏳ *Let results load.*
🗣️ "The platform independently verifies the entity against four authoritative sources — GLEIF for identity, OpenSanctions for sanctions and PEP, the RMI conflict-minerals gate, and GDELT for adverse media — each returning a clear status."

🖱️ *Click the **Ask the co-pilot** box → type* `What's the biggest compliance risk for this supplier?` *→ Send.* ⏳ *Wait for the grounded answer.*
🗣️ "And if the analyst needs more, they can ask the co-pilot right here — grounded in this exact case, its documents, screening, and your policies — and it cites where the answer comes from."

🖱️ *Hover the **Accept AI summary** / **Override** buttons.*
🗣️ "When ready, the analyst can Accept the AI summary, or Override it with a note — which feeds back to make the system sharper next time."

---

### ▶ Screen 4 — The Decision (Approve or Route)
🖱️ *Navigate to the **Decision** screen.*
👉 *Point to the **AI-recommended tier** card (✦ AI recommended), the **Required mitigations** tags, and the **Routing** options.*
🗣️ "This is the deciding screen. The AI presents its recommended tier, the required mitigations — derived from the actual findings and editable — and the routing."

🖱️ *(Optional) type a mitigation in the **Add** box → +add. Click a routing option.*
🗣️ "The analyst can add mitigations and confirm the routing."

👉 *Point to the dynamic primary button.*
🗣️ "Now the decision is clear: for a low-risk supplier it reads 'Approve & onboard.' For anything higher, 'Route to the Senior Compliance Approver' — and the case is assigned to that approver."
🖱️ *Click **Route to Sr. Compliance Approver →**.* ⏳ *Watch the redirect.*
🗣️ "Either way, the analyst is taken straight back to the queue."

---

### ▶ Screen 5 — The Approver's Review
🎬 *Back on the **Screening Queue**.* 👉 *Point to the **"Awaiting your review"** section now showing the routed supplier.*
🗣️ "Now let's switch hats. As the approver, I open the queue and there's my 'Awaiting your review' section."

🖱️ *Click the supplier in that section.* ⏳ *Lands on the dashboard.*
👉 *Sweep across the score, the document verdicts, the screening signals, the co-pilot.*
🗣️ "I land on the same rich dashboard — the risk score, every document verdict, the screening signals, the flagged findings — and the same co-pilot, so I can interrogate the case myself before I sign off."

🖱️ *Go to the Decision screen → point to the **✓ Ready for Purchase** and **✕ Failed** buttons.* 🖱️ *Click **Ready for Purchase →**.*
🗣️ "When I'm satisfied, I make the final Phase-1 call: Ready for Purchase — which marks the supplier Reviewed and ready to move into procurement — or Failed. That closes the loop."

🗣️ "And that's the full journey: from a name in a form to a fully screened, document-verified, risk-scored, human-approved, purchase-ready vendor — with the AI doing the legwork and a person owning every decision."

---

## PART 2 — Technical Implementation, Security & Governance

> 🎬 *For Part 2 you can stay on a relevant screen, switch to an architecture diagram/slide, or go face-cam. Suggested visuals noted per beat.*

### ▶ Architecture
🎬 *Architecture diagram slide (engine ↔ Salesforce ↔ agents).*
🗣️ "The product is two pieces: a provider-agnostic Python compliance engine, and the Salesforce console your team works in. Nothing about the intelligence is locked into Salesforce — the same engine can run on-premise or air-gapped."

🗣️ "Inside the engine is a club of specialized agents orchestrated with LangGraph — intake, screening, document-intelligence, risk-synthesis, and routing. They share one state blackboard, and the whole case is checkpointed, so it can pause at the human gate and resume intact."

### ▶ RAG knowledge base
🎬 *Diagram: pgvector + local embeddings.*
🗣️ "The checklist and every verdict are grounded in your own policies, using pgvector and local sentence-transformer embeddings — so your policy corpus never leaves your environment and needs no external embedding API."

### ▶ Document Intelligence — extract, then verify
🎬 *Show a finding with PASS/FAIL clause chips.*
🗣️ "The document agent does two things: it extracts structured fields — issuer, dates, coverage — and it judges the document against the clauses. But the model only extracts. The critical gates — expired, under-limit, missing identifier — are decided by hard-coded rules. So a non-compliant certificate is force-failed every time."

### ▶ Registry & screening
🎬 *Show the four screening tabs.*
🗣️ "For verification we wired in four sources, mixing live APIs with honest manual fallbacks: GLEIF — free and keyless — for identity; OpenSanctions for sanctions and PEP; RMI conflict-minerals, which has no public API so it routes to a human; and GDELT — a free news index — for adverse media. Where a registry has no API, we route to the human gate rather than guess. A sub-agent also disambiguates entities to suppress false-positive sanctions hits."

### ▶ Provider-agnostic AI
🎬 *Config snippet or slide.*
🗣️ "The engine talks to LLMs through one abstraction. You can run OpenAI, Azure, Anthropic, or a fully local model like Ollama or vLLM by changing one line of config — no agent code changes. That's what lets a regulated client run this entirely on-prem with zero external calls."

### ▶ Security & governance
🎬 *Governance slide.*
🗣️ "Every LLM call over untrusted supplier content is governed the same way: PII is tokenized with Microsoft Presidio before it reaches the model; documents are scanned for prompt injection and a document that tries to manipulate the model can never auto-pass; and every response is validated against a strict schema. And we ship no bundled secrets — each deployment supplies its own keys, or runs a local model that needs none. The Salesforce-to-engine connection is authenticated with a bearer token in a Named Credential over a secured tunnel."

### ▶ Reliability
🗣️ "Compliance can't fail silently. Transient errors are retried, but any real failure degrades gracefully to 'Needs Analyst' — the system would rather hand a case to a human than return a confident wrong answer."

### ▶ Continuous evaluation & learning
🎬 *Show eval output / golden set, or a slide.*
🗣️ "We maintain a golden regression set and an evaluation harness — every code or prompt change is re-validated. The prompts themselves are version-controlled SOP files, separate from the code. And when an analyst overrides or rates a solution, that becomes a few-shot example that calibrates the agent — so the next similar case gets the better answer first."

### ▶ Close
🎬 *Title card or face-cam.*
🗣️ "So what you've seen is a system that's adaptable — any LLM, on-prem or cloud; reliable — it degrades to a human, never to a wrong answer; secure and governed; and self-improving. Thank you so much for watching this demonstration of the Mirketa Supplier Compliance Automation platform."
