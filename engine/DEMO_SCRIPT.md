# Mirketa Supplier Compliance Automation — Demo Script

---

## PART 1 — The Workflow & The Screens

Hello everyone, and welcome to the demo for the **Mirketa Supplier Compliance Automation** platform — an AI compliance team that onboards your suppliers for you.

Onboarding a new supplier today means a procurement analyst manually figuring out *which* compliance documents a supplier even needs, chasing those documents down, reading every certificate line by line, checking the company against sanctions and registries, scoring the risk, and routing it to the right approver. It's slow, it's inconsistent from analyst to analyst, and it's exactly the kind of work that gets rushed under deadline pressure.

So we built a platform that does the heavy lifting and keeps a human in control of every real decision. It's **procurement-initiated** — your team starts the request — and from there a **club of specialized AI agents** scopes the risk, verifies the documents, screens the entity, scores the supplier, and routes it for sign-off. Every step is **grounded in your own policies and real authoritative registries**, never invented, and a person always makes the final call.

We designed the experience around four principles:
- **Deterministic where it matters** — the AI reads a document, but hard rules decide whether a certificate is expired or under-limit. The model never gets to "creatively" pass a non-compliant document.
- **Grounded and explainable** — every verdict cites the exact policy clause and shows its confidence.
- **A human gate on every decision** — the AI recommends; the analyst and the approver decide.
- **It gets smarter over time** — every analyst override becomes a precedent the system learns from.

Now let's walk through it.

### The Screening Queue
This is the command center. At a glance, your team sees every supplier in flight, with live KPIs across the top — total suppliers, how many the AI **auto-cleared**, how many need an analyst, how many are onboarded, and the **average time-to-onboard**. Each row carries the supplier's **risk tier**, a **risk score**, an **AI status** pill, and who requested it. There's also a dedicated **"Awaiting your review"** section at the top — these are the cases that have been routed to *you* as an approver. We'll come back to that.

### Intake — generating the checklist
Let's start a new supplier. The analyst enters the basics — the legal entity name, country, industry, engagement type, and annual spend — and clicks **Generate Checklist**.

In a moment, the AI scopes the supplier. It identifies the **risk and compliance domains** that actually apply — here we see Finance, Material, Quality, and Conflict Minerals light up — and it generates the exact list of **required documents**, each one grounded in a specific clause from your company's policy corpus. It also sets a **human-review threshold**, derived from the detected risk tier: higher-risk suppliers automatically get a tighter threshold so more of them route to a human. Notice this is read-only and AI-set — the analyst isn't guessing at it.

From here the analyst sends the document request to the supplier with a single click.

### Due Diligence — the AI risk summary
Once documents come in, this is where the work happens. As each document is uploaded, the AI assesses it **in the background** — the analyst can keep uploading the rest without waiting.

On the right, the **AI Risk Summary** comes to life. At the top is a live **risk score** that *adjusts as documents are assessed and screening runs* — upload a non-compliant certificate and the score climbs. Below that, every document gets its own **verdict and confidence level**: Compliant, Non-Compliant, or Needs Analyst, each with the AI's grounded reasoning and the policy clauses it relied on.

Take this Conflict Minerals declaration — the AI marks it **Non-Compliant at 90% confidence**, and explains exactly why: it's missing the five-step OECD due-diligence statement for cobalt, and the clause checks show which requirement passed and which failed. That's not the model's opinion alone — the **expiry, coverage, and identifier checks are decided by deterministic rules**, so an expired or under-limit document can never slip through.

Below the documents we have **Screening signals** — the platform independently verifies the entity against four authoritative sources: **GLEIF** for legal-entity identity, **OpenSanctions** for sanctions and PEP exposure, the **RMI** conflict-minerals gate, and **GDELT** for adverse media in the news. Each returns a clear status, and the overall signal rolls up to clear, review, or flag.

And if the analyst needs more, they can **ask the co-pilot** right here — "What's the biggest compliance risk for this supplier?" or "How do I verify this certificate?" The co-pilot answers grounded in this exact case — its documents, its screening, and your policies — and cites where the answer comes from.

When the analyst is ready, they can **Accept the AI summary** or **Override** it with a note — and that note feeds back into the system to make it sharper next time.

### The Decision — approve or route
This is the deciding screen. The AI presents its **recommended tier**, the **required mitigations** — derived from the actual findings, and editable — and the **routing**. The analyst confirms.

Now the decision is clear and consequential: for a low-risk supplier, the button reads **"Approve & onboard"** and the supplier is onboarded immediately. For anything higher, it reads **"Route to the Senior Compliance Approver"** — and the case is assigned, with a fully summarized packet, to that approver. Either way, the analyst is taken straight back to the queue.

### The Approver's review
Now let's switch hats. As the approver, I open the queue and there's my **"Awaiting your review"** section. I click the supplier, and I land on the same rich **dashboard** — the risk score, every document verdict, the screening signals, the flagged findings — and the **same co-pilot**, so I can interrogate the case myself before I sign off.

When I'm satisfied, I make the final Phase-1 call: **"Ready for Purchase"** — which marks the supplier *Reviewed* and ready to move into procurement — or **"Failed."** That decision closes the loop, and procurement can take the approved supplier into the purchasing phase.

That's the full journey: a supplier goes from a name in a form to a fully screened, document-verified, risk-scored, human-approved, purchase-ready vendor — with the AI doing the legwork and a person owning every decision.

---

## PART 2 — Technical Implementation, Security & Governance

Now let's look under the hood, because the architecture is what makes this trustworthy enough to put in front of compliance.

### Architecture: an engine and a club of agents
The product is two pieces. The first is a **provider-agnostic compliance engine** — a Python FastAPI service — and the second is the Salesforce console your team works in. Salesforce talks to the engine over a secured callout; nothing about the intelligence is locked into Salesforce, which means the same engine can be deployed on-premise or air-gapped for clients who require it.

Inside the engine is a **club of specialized agents**, orchestrated with **LangGraph**. Rather than one giant prompt trying to do everything, each agent has a narrow job and a tightly scoped instruction set: an **intake/scope** agent, a **screening** agent, a **document-intelligence** agent, a **risk-synthesis** agent, and a **routing** agent. They share a single state "blackboard," so every agent sees what the others produced, and the whole case is checkpointed — which means a case can pause at the **human gate** and resume byte-for-byte intact when the analyst returns.

### The RAG knowledge base
The checklist and every document verdict are grounded in your own policies. We use **pgvector** on Postgres for vector search, with **local sentence-transformer embeddings** — the MiniLM model runs on the box, so your policy corpus never leaves your environment and needs no external embedding API. When we scope a supplier or judge a document, we retrieve the most relevant policy clauses and the model reasons strictly over those — and cites them.

### Document Intelligence — extract, then verify
This is the core of the "deterministic where it matters" principle. The document agent does two things: it **extracts** structured fields from the certificate — issuer, identifier, issue and expiry dates, coverage amounts — and it **judges** the document against the retrieved clauses. But the model only *extracts*. The critical gates — is the certificate **expired**, is the coverage **below the minimum**, is the tax identifier **present** — are decided by **hard-coded Python rules**. So even if a document tries to talk the model into a pass, an expired or under-limit certificate is force-failed every time.

### Registry & screening — authoritative sources
For independent verification we wired in four sources, deliberately mixing live APIs with honest manual fallbacks:
- **GLEIF** — the Global LEI Index, free and keyless — confirms the legal entity exists and is active.
- **OpenSanctions** — OFAC, EU, UK consolidated lists plus PEP screening.
- **RMI** conflict-minerals — no public API, so it's routed to a human with the exact lookup instructions, rather than faking a result.
- **GDELT** — a free, keyless global news index — pulls recent coverage and an LLM classifies whether it's genuinely *adverse* media.
Where a registry has no API, the platform **auto-routes to the human gate** rather than guessing — and a screening sub-agent does **entity disambiguation** to suppress false-positive sanctions matches.

### Provider-agnostic AI
The engine talks to LLMs through a single abstraction. You can run **OpenAI, Azure OpenAI, Anthropic, or a fully local model** like Ollama or vLLM by changing one line of configuration — no agent code changes. That's what lets a regulated client run this entirely on-prem with a local model and **zero external API calls**. We currently run GPT-4o for its speed-to-quality balance, but switching providers is a config change, not a rewrite.

### Security & governance
Every single LLM call that touches untrusted supplier content is **governed the same way**:
- **PII tokenization** — we run Microsoft Presidio to detect and tokenize personal data before it ever reaches the model.
- **Prompt-injection scanning** — supplier documents are scanned and wrapped in untrusted-content framing, and a document that attempts to manipulate the model can **never auto-pass** — it's forced to the human gate.
- **Schema validation** — every model response is parsed against a strict schema, never free text.
- And critically, **we ship no bundled secrets**. Each deployment supplies its own keys in its own environment, or runs a local model that needs none. The Salesforce-to-engine connection is authenticated with a bearer token held in a Named Credential and a secured tunnel, with the anti-phishing handshake built into every callout.

### Reliability
Compliance can't fail silently. Transient errors are retried, but any real failure — an unconfigured model, an unreachable service — **degrades gracefully to "Needs Analyst."** The system would rather hand a case to a human than return a confident wrong answer.

### Continuous evaluation & the learning loop
This is what makes it sharpen over time. We maintain a **golden regression set** and an evaluation harness — every time we change a prompt or the code, we run it and confirm the deterministic guarantees still hold. And the prompts themselves are externalized as **version-controlled SOP files**, separate from the code, so they can be reviewed and tuned independently. Finally, when an analyst **overrides** a verdict or **rates** a solution, that becomes a **few-shot example** that calibrates the agent — so the next similar case gets the better answer first.

### In summary
What you've seen is a system that is **adaptable** — any LLM, on-prem or cloud; **reliable** — it degrades to a human, never to a wrong answer; **secure and governed** — PII-tokenized, injection-resistant, no bundled secrets; and **self-improving** — grounded in your policies and learning from your analysts.

Thank you so much for watching this demonstration of the Mirketa Supplier Compliance Automation platform.
