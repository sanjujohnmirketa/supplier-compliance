# Solution Design — Content-Based Document Matching & Reinforcement Learning Feedback Loop

**Status:** DEFERRED per explicit user instruction ("add this to the RL design to be
implemented later... start with the other changes"). Not scheduled for the current
build pass. This document exists so the idea isn't lost and the next session can pick
it up with full context, grounded against what was actually built today rather than
re-derived from scratch.

---

## 0. Context — what today's fix already covers, and what it deliberately doesn't

Today's build (same session) fixed the **filename-matching** half of the checklist-doc
"Unmatched" problem:
- Token-overlap fuzzy matching (handles real filenames like
  `CMRT_ConflictMinerals_Nordwind.txt` matching "Conflict Minerals Due Diligence
  (OECD/CMRT)" via shared significant tokens, not brittle substring matching)
- A manual **"Connect to existing checklist item"** action, on both
  `scProcurementConsole` (Procurement's console) and `scSupplierPortal` (the supplier's
  own portal) — lets a human correct a mismatch the fuzzy logic didn't catch

**What this does NOT do**: look at the document's actual *content* at all. Matching
today is 100% filename-based (fuzzy or manual) — a file named `random_scan_001.pdf`
that is actually a valid CMRT declaration would still land in Unmatched, requiring a
human to notice and connect it manually. The user explicitly identified this gap:

> "its not just about matching the name of the file but the content inside post the AI
> data extraction and summarization we need to understand if that is the exact file its
> looking for as per the policy and then if it accepts it shows the summary and if it
> rejects it should show the exact set of reasons why it rejected."

## 1. Two distinct rejection concepts — keep these separate (user's own clarification)

The user was explicit that this is NOT the same as a compliance verdict:

1. **Document-type/matching rejection** (this doc's scope) — "is this file even the
   right *kind* of document for a checklist slot." A pre-compliance triage step.
2. **Compliance/risk-score rejection** (already exists, unchanged) — `/assess`'s actual
   judged verdict (Compliant/Non-Compliant/Needs Analyst), which only happens *after*
   a file is correctly matched to a requirement.

Conflating these would be a real design mistake — don't let a future implementer merge
them.

## 2. Content-based matching — the user's decided shape

User's own words, verbatim (this is the design, not paraphrase): *"It is somewhat the
1st option but its not actually a rejection at the compliance level... here we are
rejecting files that arent actually matching the checklist required documents and for
that the fuzzy file name logic plus the content also helps. If these criterias dont
meet you move the files to the rejected section but then should also provide a button
to move the file to the accepted section and ask for which checklist document the user
wants to connect the file to or as an extra file with additional comments."*

Decided shape (from the AskUserQuestion the user answered "1st option" to): the
**user/system still targets ONE specific requirement per upload** — either via the
existing fuzzy-filename pre-match, or (new) the supplier/Procurement explicitly picks
which requirement they're satisfying. The engine's job is to **verify or reject that
specific pairing using content**, not blindly classify a document against all N open
requirements with no hint. This was an explicit choice over "engine tries the file
against ALL open requirements automatically" — rejected as more engine work per upload
and higher risk of ambiguous matches between similar-sounding requirements.

### 2.1 Proposed architecture

```
Upload (fuzzy-filename-matched OR manually connected to a specific requirement)
  → NEW lightweight engine check, BEFORE /assess's full compliance judgment:
      "Does this document's extracted content plausibly belong to the
       document TYPE this requirement expects?" (e.g. does the text look like
       a CMRT/conflict-minerals declaration, not an unrelated financial statement)
      │
      ├─ Plausible match → proceed to /assess as today (compliance verdict,
      │    Compliant/Non-Compliant/Needs Analyst) — NO CHANGE to this path
      │
      └─ Implausible → do NOT run full /assess. Instead:
            → move to a "content-mismatch" state (distinct from Unmatched-
              by-filename, though may reuse the same UI section)
            → SPECIFIC reason surfaced: e.g. "This document appears to be an
              insurance certificate, not a Conflict Minerals declaration —
              expected content about smelters/CID numbers/DRC sourcing."
            → same recovery options as today: user can override anyway
              ("move to accepted, connect to a different checklist item, or
              file as an extra document with additional comments" — user's
              own phrase) — a human override always wins over the engine's
              content check, consistent with this platform's HITL principle
```

### 2.2 Where this lives — reuse, not a new pipeline

- **No new extraction step needed**: `/assess` already extracts document text before
  judging compliance (see `document_intelligence` extraction in `app.py`/`fewshot.py`).
  The content-plausibility check should run on that SAME extracted text, as a cheap
  pre-check before the expensive/consequential full compliance judgment — not a
  separate document-parsing pass.
- **Likely a new, narrow LLM call (or even a deterministic keyword/domain check first)**:
  "does this text's content match domain X" is a much narrower, cheaper question than
  full compliance judgment — could plausibly be resolved by the SAME domain-keyword
  scoring already used for policy corpus classification (`guess_domain` in `common.py`)
  applied to the uploaded document's extracted text, rather than a new LLM prompt.
  Worth prototyping the deterministic approach FIRST before assuming an LLM call is
  required — consistent with this platform's "math decides, LLM narrates" principle
  established earlier in the project.

## 3. Reinforcement learning feedback loop — the user's decided shape

User's own words: *"Now if the file uploaded was in relation to a checklist but the AI
rejected it it should be trigggering a reinforced learning."* Follow-up decision: build
the FULL feedback loop now-as-a-design (not deferred further) — including wiring
corrections into something that changes future model behavior, not just logging them.

### 3.1 What already exists — `fewshot.py` + `fewshot/*.jsonl`

This mechanism is NOT new — it already exists, already documented as "the learning
loop" in its own header, and is ALREADY used for `document_intelligence` prompts:

```python
# fewshot.py — verbatim, already in the codebase
"""
fewshot.py — few-shot example injection (the learning loop).

Curated input→ideal-output examples calibrate the document agent. They are
sourced from analyst OVERRIDES (the feedback captured by the co-pilot) plus
golden cases, stored as JSONL so they are git-tracked and grow over time WITHOUT
code changes...
"""
```

`fewshot.block(name, limit=3)` reads `fewshot/<name>.jsonl`, returns a
"REFERENCE EXAMPLES (calibration only...)" block injected into the relevant prompt.
Currently only `fewshot/document_intelligence.jsonl` exists.

**The gap**: nothing currently WRITES to these files automatically from a human
correction. The docstring's claim ("sourced from analyst overrides") describes the
INTENDED source, but no code path today captures a correction event and appends it.
This is the actual, concrete gap to close — not inventing a new mechanism.

### 3.2 Proposed flow

```
Human corrects an AI content-match rejection (via the "Connect to checklist item"
override, or a NEW explicit "the AI was wrong" confirmation step) on either
scProcurementConsole or scSupplierPortal
  │
  ▼
NEW Apex: logs the correction as a structured record — needs a NEW object
(e.g. Match_Correction__c: Original_AI_Verdict__c, Original_Reason__c,
Corrected_Requirement__c, Document_Excerpt__c or a reference to the
ContentDocument, Corrected_By__c, Corrected_Date__c) — richer than a plain
Audit_Log__c entry because this needs to be QUERIED and TRANSFORMED into
fewshot examples later, not just read as a human-readable trail
  │
  ▼
NEW engine-side batch/script (run periodically, or on-demand from an admin
action — NOT on every single correction in real-time, since few-shot examples
should be curated/reviewed, not blindly auto-appended): reads new
Match_Correction__c rows, transforms each into a
{"input": "...", "output": {...}} JSONL line in the appropriate
fewshot/<name>.jsonl file, following the EXACT shape fewshot.block() already
expects
  │
  ▼
Next /assess or content-match call for a SIMILAR document benefits immediately
— no retraining, no fine-tuning job, just richer in-context examples, which is
exactly this platform's existing "few-shot calibration" pattern, now finally
fed by real corrections instead of only hand-curated golden cases
```

### 3.3 Why NOT fully-automatic real-time appending (a recommendation, flag for user sign-off later)

Auto-appending every single human correction directly into the live few-shot file
the moment it happens is a real risk: a single bad/inconsistent correction (e.g. a
rushed Procurement Manager clicking "connect anyway" on a genuinely wrong match)
would immediately start poisoning future model behavior with no review step. The
existing `document_intelligence.jsonl` was presumably hand-curated. Recommend an
admin-reviewed batch/promotion step between "correction happened" and "now it's a
few-shot example" — but this is a recommendation to REVISIT with the user when this
work is actually picked up, not a decision made on their behalf here.

## 4. Open questions to resolve before implementation (do not assume answers)

1. Does the content-plausibility check run as a deterministic keyword/domain-match
   (cheap, consistent with "math decides") or does it need an LLM call? Recommend
   prototyping deterministic first (§2.2).
2. What object model for `Match_Correction__c` — confirm field list, whether it needs
   its own object or can extend `Audit_Log__c` with additional structured fields.
3. Batch/admin-reviewed promotion into `fewshot/*.jsonl` (§3.3) — confirm the
   reviewed-promotion approach vs. fully automatic, since the user asked for "the full
   feedback loop" but a review gate is a material design choice not yet confirmed with
   them.
4. Where does a NEW `fewshot/<name>.jsonl` file get created vs. appending to
   `document_intelligence.jsonl` — is document-type-matching a distinct prompt/few-shot
   context from compliance judgment, or the same one?
5. Retention/size limits on `fewshot/*.jsonl` — `fewshot.block()` already limits to the
   most recent 3 examples per call, but the underlying file could grow unbounded; worth
   a policy (e.g. keep last N, or curate down periodically) once real corrections start
   accumulating.

## 5. Explicitly NOT in scope for this doc

- Any change to `/assess`'s actual compliance judgment logic — unaffected.
- Any change to the deterministic domain/checklist-generation rules in `/scope` —
  unaffected.
- Fine-tuning, embeddings retraining, or any ML pipeline beyond few-shot prompt
  injection — out of scope entirely; this is a prompt-calibration mechanism, not a
  model-training one.
