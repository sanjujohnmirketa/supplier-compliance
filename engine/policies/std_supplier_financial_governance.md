# Meridian Drive Systems — Financial Health & Identity Governance Standard

Document type: Supplier-facing standard (Finance domain)
Issuing entity: Meridian Drive Systems Inc. (US automotive OEM — fictional, for demo)
Standard ID: MDS-STD-FIN-006
Version: v1.0
Effective from: 2026-01-01
Grounding source: Themes adapted from US IRS tax-identity practice (W-8/W-9, FATCA),
the GLEIF Legal Entity Identifier system, RapidRatings Financial Health Rating (FHR)
methodology, and standard anti-fraud banking-verification controls. Adapted, not reproduced.
Note: Illustrative demo baselines, not legal advice. Thresholds below are demo values and
must be confirmed per program.

---

## 1. Purpose & Scope

1.1 This standard defines the financial viability, tax identity, corporate-identity, and
anti-fraud verification a supplier must satisfy before any purchase agreement is executed.
It applies to every supplier legal entity regardless of commodity, because financial
distress and identity fraud are independent of what is supplied. No purchase order may be
issued to a supplier that has not cleared the baseline financial and identity checks in
Sections 2 through 5.

---

## 2. Financial Statements & Solvency

2.1 Suppliers with anticipated annual spend above 250,000 USD must provide their most
recent two fiscal years of financial statements — balance sheet, income statement, and
cash-flow statement — examined or signed by an independent Certified Public Accountant
(CPA). Statements are reviewed for revenue trend, debt-to-equity ratio, current ratio, and
operating cash flow as indicators of short-term solvency.

2.2 Where audited statements are unavailable for a private supplier, a credit report from a
recognized business credit agency, including payment history and any liens or judgments, is
required as a substitute and is recorded with a reason at the governance gate.

---

## 3. Financial Health Rating

3.1 Critical and high-spend tier suppliers are subject to a Financial Health Rating (FHR),
pulled programmatically from a financial-risk provider (for example RapidRatings) during
onboarding. The FHR and the supplier's probability-of-default signal establish the credit
and risk threshold for the relationship.

3.2 An FHR of 52 or above clears the financial gate. A supplier scoring between 40 and 51
is conditionally acceptable only with a documented mitigation — payment escrow, split-
payment terms, or shortened payment cycles — logged at the governance gate. An FHR below 40
is treated as a financial non-compliance and blocks advancement pending Chief Financial
Officer review.

---

## 4. Tax Identity

4.1 Domestic US suppliers must provide a current IRS Form W-9 establishing taxpayer
identification. Foreign suppliers must provide the applicable Form W-8 (W-8BEN, W-8BEN-E, or
W-8ECI) to establish tax-treaty benefits and FATCA status. The legal name on the tax form
must match the legal entity name on the supplier master.

4.2 Tax identity evidence is refreshed every three-year cycle, or immediately upon a change
of legal name, ownership, or country of incorporation.

---

## 5. Corporate Identity & Beneficial Ownership

5.1 Every supplier legal entity must hold an active Legal Entity Identifier (LEI). The LEI
is verified through the GLEIF public directory; a registration status of "ISSUED" is
required. An LEI that is "LAPSED", expired, or that returns a corporate address or legal
name inconsistent with the supplier master is a hard onboarding block pending human
reconciliation.

5.2 Suppliers must disclose beneficial owners holding 25 percent or greater interest, and
verified banking / ACH remittance details. Banking changes are confirmed through an
out-of-band callback to a known contact before any payment is released, as an anti-fraud
control. Opaque ownership or unverifiable banking details raise the supplier to HIGH risk
tier and route to the gate.

---

## 6. Validity & Re-Evaluation

6.1 Financial statements and FHR scores are refreshed at least annually and immediately on a
material adverse credit event. A lapse in LEI status, a failed banking verification, or an
FHR drop below threshold triggers re-evaluation and may suspend purchase-order eligibility
pending review.

---

## 7. Audit Trail

7.1 The financial statements reviewed, the FHR score and threshold decision, the tax-form
type, the GLEIF LEI status, and any mitigation or CFO exception are written to the
append-only audit trail with a timestamp, the actor, and a pointer to the source evidence.

End of standard.
