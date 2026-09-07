# Demo Narration Script — Supplier Compliance Platform

**Audience:** mixed (exec + technical reviewers). **Format:** spoken talk track — read
this live as you click through the demo. Each step: **what you just did** → **why it
matters** → **the tech underneath**. Cache and PII are woven in where they actually
happen, not bolted on as a separate slide.

---

## Opening (30 seconds, before you touch anything)

"What I'm going to show you is a supplier compliance platform that's **Salesforce-native
on the front end** and **AI-native on the back end** — a FastAPI engine that does the
retrieval, reasoning, and screening, callable from Salesforce over a single secured
endpoint. I'll walk the exact flow a procurement manager uses: generate a checklist,
upload a document, watch the AI assess it, then ask the co-pilot a question about it. At
each step I'll tell you what's happening, why we built it that way, and where we're
taking it next."

---

## Step 1 — Generate the checklist

**[Click: fill in supplier details, click "Generate checklist"]**

"I've entered a supplier — industry, country, engagement type, spend. I click Generate,
and in under a second we get back a risk tier and a document checklist, each item tied to
a specific policy clause.

**Why this matters:** this replaces what used to be a manual, tribal-knowledge exercise —
someone reading through regulations and deciding what to ask a supplier for. We wanted
that decision to be **explainable and consistent**, not a black box.

**The tech underneath — Retrieval-Augmented Generation (RAG):**
- Our policy and regulatory documents are chunked and embedded into **384-dimension
  vectors** using `all-MiniLM-L6-v2` — that runs **locally**, no external API call, no
  per-embedding cost, and it works fully air-gapped if a client needs on-prem.
- Those vectors live in **Postgres with the pgvector extension** — one table,
  `policy_chunk`, holding the clause text, its domain, and its embedding.
- When you clicked Generate, we didn't just do a vector similarity search. We run
  **hybrid retrieval** — dense (vector/semantic) search fused with sparse (keyword/BM25)
  search using **Reciprocal Rank Fusion**. That matters because semantic search alone
  can miss an exact regulatory term, and keyword search alone misses paraphrasing. Fusing
  both gives us the best of each.
- Here's the part I want to highlight: **the risk tier and the checklist are not decided
  by the LLM.** They come from **deterministic Python rules** — spend thresholds,
  commodity/country risk signals, industry-to-domain mappings. The LLM's job is only to
  **narrate why**, grounded in the clauses we retrieved, and cite them. Math decides,
  the model explains. That's a deliberate architecture choice, and it's why the same
  supplier profile gives you the same checklist every time — which is the property you
  need for something that has to survive an audit.

**Where we're improving:** today the mapping of policy → checklist domain has some rules
hardcoded in the engine. We're moving that into a **Salesforce-native rule table** so a
compliance officer can update requirements by uploading a new policy document — no
engineering change needed. I'll come back to that."

---

## Step 2 — Upload a document

**[Click: upload a Certificate of Insurance / other doc]**

"Now I upload a document against one of the checklist items.

**Why this matters:** manually reading every certificate, cross-checking it against a
requirement, and tracking expiry dates is the single slowest part of supplier
onboarding. We wanted the AI to do the first pass and hand a human only the judgment
calls, not the busywork.

**The tech underneath:**
- The file goes into Salesforce Files, gets linked to the supplier record, and an Apex
  Queueable fires a callout to our engine's `/assess` endpoint.
- **Before the document text ever reaches a model, it goes through governance.** This is
  the PII tokenizer I want to call out specifically: names, tax IDs, bank and account
  numbers in the document are detected and **tokenized** — replaced with placeholders —
  using Microsoft's **Presidio** library, before the text is sent to the LLM. The model
  reasons over the document's structure and content without ever seeing the raw PII. In
  parallel, we run a **prompt-injection scan** — because a document is untrusted input,
  and if someone embedded text trying to manipulate the model, we want to catch that,
  not obey it.
- The engine then retrieves the specific policy clauses relevant to *this* document type
  (same hybrid RAG as step 1, just scoped differently), and asks the model to extract
  structured fields — issuer, coverage amount, expiry date — and judge compliance against
  the clauses, with citations.
- Then — and this is important — we run **deterministic gates** on top of what the model
  extracted: is the expiry date in the past? Is the coverage amount above the required
  minimum? A hard rule always overrides an LLM 'Compliant' verdict. If the model says
  compliant but the certificate expired yesterday, the rule wins.
- If anything is ambiguous, the provider is unavailable, or a document tries to inject
  instructions, the system **degrades safely to 'Needs Analyst'** rather than guessing.
  It never silently reports a failure as a pass.

**Where we're improving:** we're extending the extraction schema so every document type
returns a richer, more structured summary — not just a verdict, but a headline, key
facts, and pass/fail checks a human can scan in two seconds instead of reading a
paragraph."

---

## Step 3 — The AI assessment result

**[Point at the assessment card / summary]**

"Here's what came back: a verdict, a confidence score, and a **structured summary** —
not a wall of text. Headline, key facts extracted from the document, and a line-by-line
check against the specific requirement.

**Why it's built this way:** early on, this was just a paragraph of LLM prose. It wasn't
scannable, and it didn't show *what was checked*. We restructured it so a human reviewer
gets the same information but formatted for a two-second scan, with the deterministic
checks visible, not hidden inside prose."

---

## Step 4 — Ask the co-pilot

**[Click: open the co-pilot, ask a question about the supplier]**

"Now I ask the co-pilot a question — say, 'what's blocking approval for this supplier?'

**Why this matters:** an analyst or procurement manager shouldn't have to click through
every document and every screening result to answer a simple question. The co-pilot
answers it directly, grounded in what's actually on the record for this supplier.

**The tech underneath:**
- The co-pilot is **role-aware** — it knows whether it's talking to a procurement manager
  or an analyst, and gives a next step appropriate to that role. A procurement manager
  gets told to confirm the spend tier or chase a document; an analyst gets told to
  validate a document or resolve a screening flag. Same case, same underlying data,
  different, appropriate answer.
- It's **grounded** — the answer is built from the supplier's actual assessment records
  and screening results, retrieved and passed to the model as context, with the same
  governance (PII tokenization, injection scanning) applied.
- **And here's the cache layer:** identical questions on an unchanged case are served
  from a short-lived in-memory cache instead of calling the LLM again. We measured this —
  a repeat question went from about **4 seconds to about half a second**. That's not just
  a nice-to-have: every cached hit is a cost we don't pay and a network round-trip we
  don't wait on. The cache key includes the case's current state, so the moment anything
  actually changes on that supplier, the cache naturally misses and you get a fresh,
  correct answer — it never serves you stale information.

**Where we're improving:** we're moving from a single free-text question box to a set of
**role-specific suggested prompts** — so instead of typing a question, an analyst can
click 'what's blocking this?' and get a consistent, well-formatted answer every time. That
also makes the cache more effective, since common questions repeat more often."

---

## Weaving in what's *already happened* by this point — screening & the agent (optional, if time allows)

"One thing I haven't shown explicitly but has been running underneath: this whole flow —
scope, screen, assess documents, synthesize a risk score, route to an approver — is driven
by an **agentic supervisor**, not a chain of button clicks. It advances the case through
these steps on its own, and pauses at exactly two points for a human: once when
procurement confirms the AI's scoping, and once when an analyst signs off before final
routing. And there's a hard safety rule baked into that: **a flagged supplier — a
sanctions hit, a failing document — can never auto-clear**, even if the oversight setting
is 'automatic.' The agent can move fast on clean cases, but a real risk always stops for a
human."

---

## Best practices to call out explicitly (thread these through, don't save for one slide)

- **Determinism where it matters, generation where it doesn't** — risk scoring and
  compliance gates are rule-based and reproducible; the LLM narrates and drafts, it never
  makes the final call alone.
- **Governance is not optional, it's in the critical path** — PII tokenization and
  injection scanning run on *every* call over untrusted content, not as an afterthought.
- **Fail-safe, not fail-open** — every degradation path (no LLM configured, provider
  error, low confidence, injection detected) routes to a human, never to a silent pass.
- **Provider-agnostic by design** — the LLM layer supports OpenAI, Azure OpenAI,
  Anthropic, or a fully local model (Ollama) with no code change — this is what makes an
  on-prem, air-gapped deployment possible for a security-conscious client.
- **Cache with correctness, not just speed** — the co-pilot cache key is tied to case
  state, so speed never costs you a stale answer.

---

## Closing — "the one thing that really shines"

"If I had to point at one thing: it's that **the agent knows when *not* to decide.**
Anyone can build an AI that gives you an answer. The harder, more valuable thing we built
is a system that gives you a **fast, confident answer when the data supports it, and
explicitly stops and asks a human when it doesn't** — a flagged sanctions match, an
expired certificate, a low-confidence extraction — every single time, without exception.
That's the difference between a demo and something a compliance team can actually trust
their name to."
