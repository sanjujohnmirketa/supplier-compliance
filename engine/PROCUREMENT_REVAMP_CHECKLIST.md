# Procurement Screen — Revamp Checklist

Derived from demo feedback. Each item notes the **screen**, the **exact code site** in
`scProcurementConsole` (or Apex/engine), and whether it's **frontend / backend / engine**.
Grouped by theme; ordered roughly by dependency.

Legend: `FE` = LWC · `BE` = Apex · `ENG` = Python engine · `?` = needs a decision from you.

---

## A. Intake (P1) — smarter AI checklist

> Today: `generateChecklist` → `ScopeService./scope` does RAG over the policy corpus and
> maps matched *domains* → one fixed document each (`DOMAIN_TO_DOCUMENT`). Baseline domains
> (finance, general) are always added, so different industries reorder a largely overlapping
> doc set. No requirement-understanding, no web research, no dynamic intake fields.

- [ ] **A1 · `?` design** — Define the two-stage intake AI explicitly:
      (1) **Requirement interpretation** — what each intake field implies for compliance;
      (2) **Checklist intelligence** — decide the required document set from (1) + policy.
      Decide where each stage runs (engine vs Apex) and what it returns. *(BE/ENG, design first)*
- [ ] **A2 · ENG** — Add a web-research step to `/scope` (or a new `/enrich`): given
      industry + country + engagement + spend, look up sector/jurisdiction obligations to
      *refine* the checklist beyond the static corpus. Demo-scoped (cache/allowlist).
- [ ] **A3 · FE + BE** — When the AI determines **more fields are needed** to refine the
      checklist, surface them dynamically on P1 (e.g. "handles personal data?", "exports to
      sanctioned regions?"). Needs: engine returns `additionalFields[]`; LWC renders them and
      feeds answers back into a re-scope. *(new contract)*
- [ ] **A4 · FE** — Show *why* each document is required (the `justification`/`clauseId` is
      already returned per item but not displayed in the checklist list). Builds trust in the
      AI's choice. *(P1, render `checklistItems[].justification`)*
- [ ] **A5 · verify** — Confirm "same docs across industries" is expected vs a corpus gap:
      run the two test-data sets, diff the domain→doc mapping, decide if corpus needs entries.

---

## B. Documents & screening (P3) — upload / checklist / rejected

> Today (`_loadSnapshot`, lines ~594–614): checkbox `ticked = uploaded && !rejected`, so an
> uploaded-but-unvalidated doc shows **"Needs attention"**. Three separate components:
> Required checklist · ⚠ Rejected documents · Documents.

- [ ] **B1 · FE** — **Tick the checkbox on upload regardless of validation.** Change the
      tick rule from `uploaded && !rejected` to `uploaded === true` (matched to a checklist
      item). Status text: `Uploaded` once a file is linked, not "Needs attention". *(line ~599–607)*
- [ ] **B2 · FE** — **Merge "Required document checklist" + "Documents" into one component.**
      One row per checklist item: **checkbox on the left**, document label, and on upload show
      **inline Preview + Remove** on the same row. *(reuse `handlePreviewDoc` / `handleRemoveDoc`)*
- [ ] **B3 · FE** — **Rejected Documents** becomes its own simple list: files uploaded that
      **don't match any checklist item**, each with a **one-line summary** and an **"Add to
      checklist"** action so the doc is considered in the forward flow. *(new: promote a
      rejected/unmatched doc into `checklistDocs`)*
- [ ] **B4 · BE** — Support B3's "Add to checklist": persist a user-added requirement so the
      promoted document is carried into assessment + handoff (not dropped as unmatched). *(BE)*
- [ ] **B5 · FE** — In the **Documents tab AI Summaries, show ONLY checklist-document
      summaries — not screening rows.** Getter `docOnlyAssessments` already exists (line ~681);
      ensure the template renders it instead of `pastAssessments`. *(P3 Documents tab)*
- [ ] **B6 · FE** — Chunk/show wrong documents at upload time: when a file doesn't match,
      route it to the Rejected list immediately with its summary (don't leave it ambiguous).

---

## C. Co-pilot (P3/P4)

> Today: floating FAB + `askCopilot` (grounded over persisted assessments + screening). No
> opening message, no suggested actions. Heavy "extract all fields" question → **504 timeout**.

- [ ] **C1 · FE** — **Opening greeting.** Seed `copilotMessages` with a persona-aware hello
      on open (draft: *"Hi — I'm your compliance co-pilot for {supplier}. I can summarise a
      document, explain a finding, or check what's still missing. What do you need?"*). *(toggleCopilot / connectedCallback)*
- [ ] **C2 · FE** — **Suggested action chips** based on screen + persona (Procurement):
      e.g. "What documents are still missing?", "Summarise the latest upload", "Is this ready
      to hand to an analyst?". Clicking sends the prompt. *(P3/P4, new `suggestedActions` getter)*
- [ ] **C3 · ENG/BE** — **Fix the 504 on field-extraction questions.** The "pull all
      key-value fields from document X" query exceeds the timeout. Options: stream/async the
      heavy answer, pre-extract fields at assess-time and answer from stored data, or raise the
      callout timeout + tighten the prompt. *(investigate `/copilot` + `CopilotService` timeout)*
- [ ] **C4 · ?** — Decide co-pilot scope on P4 (submission summary) vs P3 — currently shows on
      both (`showCopilotFab`). Confirm intended.

---

## D. Submission summary (P4) — dashboard + confidence

> Today: `submissionRows` = doc-only assessments with **hard-coded `confidence: '—'`**
> (line ~688). No dashboard header.

- [ ] **D1 · FE** — **Add the dashboard header** (matches the screenshot): **Risk score ring**
      (NN/100 + band), **Onboarding progress** (`X of Y mandatory docs compliant`, %, status),
      **Score trend** (last N evaluations bars). *(new P4 header section)*
- [ ] **D2 · BE + `?`** — **Deterministic, application-based Risk Score (0–100).** Define the
      formula (e.g. weighted: mandatory-doc compliance %, screening signal, expiry/coverage
      gate failures, tier). Must be reproducible and explainable — **no LLM for the number.**
      *(decide weights with you, then compute in Apex/snapshot)*
- [ ] **D3 · BE + FE** — **Populate per-document confidence.** The engine `/assess` already
      returns a `confidence`; persist it on `Compliance_Assessment__c` and surface it in
      `AssessmentSummary` → `submissionRows[].confidence`. Replace the `'—'` placeholder. *(BE+FE)*
- [ ] **D4 · FE** — **Clean up the AI summaries.** `_parseSummary` already splits
      headline/facts/concerns/checks — ensure each summary renders structured + readable, with
      a plain-language explanation of the verdict (the COI example: expired + under-limit). *(P4)*
- [ ] **D5 · FE** — Per-document **confidence column** in the submission table (the column
      exists but is empty — wire it to D3). *(same as D3 on the table)*

---

## E. Supplier queue (P2) — junior feedback

> Today: `_inBucket` (lines ~456–465) buckets by status/aiStatus/routing.

- [ ] **E1 · FE + BE** — **Duration column**: time since initial screening → now, per supplier.
      Needs a screening-start timestamp from the backend (or derive from created/`ageLabel`). *(BE field + FE column)*
- [ ] **E2 · FE** — **Fix bucket mislabeling**: a **Draft** supplier currently can show under
      **In Review** (the In-review default bucket isn't excluding drafts cleanly). Audit
      `_inBucket` so each status lands in exactly one tab. *(line ~456–465)*
- [ ] **E3 · BE + FE** — **Supplier-level confidence score** column in the queue (aggregate of
      per-document confidence from D3). *(BE aggregate + FE column)*

---

## Cross-cutting decisions needed from you (`?`)
1. **Intake AI scope (A1–A3):** how far for the demo — full web-research + dynamic fields, or
   a lighter "explain + refine" pass?
2. **Risk Score formula (D2):** what weights? (mandatory-doc compliance, screening signal,
   gate failures, tier — propose and I'll encode.)
3. **Confidence source (D3/E3):** persist the engine's `/assess` confidence as the single
   source of truth, then aggregate up — confirm.
4. **Co-pilot 504 (C3):** preferred fix — async/stream, pre-extract at assess-time, or raise
   timeout? (Pre-extract is most demo-stable.)

---

### Suggested sequencing
1. **Quick correctness wins (FE-only):** B1, B2, B5, E2, C1, C2, A4.
2. **Confidence pipeline:** D3 → D5 → E3 (one backend thread lights up three UI gaps).
3. **Risk score + dashboard:** D2 → D1 → D4.
4. **Rejected-doc promotion:** B3 → B4 → B6.
5. **Co-pilot stability:** C3.
6. **Intake intelligence (largest):** A1 → A2 → A3.
