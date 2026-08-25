# Beacon Health Systems — Financial Health, Tax Identity & Fraud-Waste-Abuse Governance
# Document ID: BHS-STD-FIN-006
# Version: v1.0
# Status: APPROVED

## 1. Purpose & Scope
This policy defines the mandatory financial verification, tax-identity, entity-vetting, and healthcare-specific fraud-waste-abuse (FWA) screening required for all suppliers onboarding or maintaining active status. It applies to every supplier legal entity regardless of commodity — device manufacturer, pharmaceutical distributor, or clinical/IT service provider — because financial distress and program-integrity exposure are independent of what is supplied.

## 2. Mandatory Financial & Program-Integrity Evidence Checklist

| Document / Evidence | Required when | Validity & Verification Rules |
| :--- | :--- | :--- |
| **Audited Financial Statements** | Mandatory for all Tier-1 and clinically-critical suppliers; optional but preferred for low-spend commodity vendors. | Must cover the two most recent fiscal years; prepared under GAAP or IFRS; reviewed for liquidity, debt-to-equity, and operating cash-flow health. |
| **Financial Health Rating (FHR)** | Mandatory for all production-device and system-connected suppliers. | FHR must be refreshed annually; Core Health Score must meet or exceed the enterprise baseline (≥ 55); scores below baseline trigger an automatic High Risk mitigation workflow. |
| **Banking & ACH Verification Form** | Every supplier receiving electronic fund transfers (EFT). | Form signed by the supplier's CFO or authorized financial officer; matched against bank letters or voided checks; verified via out-of-band callback before first payment. |
| **W-8 Series (Foreign) or W-9 (US) Tax Form** | Every supplier (Mandatory prior to any disbursement). | Form signed within the current calendar year; TIN or legal name must clear the IRS TIN Matching System without errors. |
| **GLEIF Legal Entity Identifier (LEI)** | Mandatory for all international suppliers, corporate parents, and Tier-1 vendors. | Entity status must show "ISSUED" and active on the GLEIF index; Level 2 relationship data mapped to detect ultimate parent structures. |
| **Anti-Kickback / Fraud-Waste-Abuse (FWA) Attestation** | Every supplier with any nexus to federal healthcare programs (Medicare, Medicaid, TRICARE). | Signed attestation confirming no financial arrangement violates the Anti-Kickback Statute or the Stark Law; required annually and immediately upon a change of ownership or referral arrangement. |

## 3. Exceptions & Gate Waivers
* **Exemptions:** Low-spend, non-critical localized services under $10,000 annual contract value may waive the Audited Financials requirement, with a logged reason documented at the gate by the Procurement Lead. No waiver is permitted for Tax, ACH Verification, or the FWA Attestation.

## 4. Authoritative Verification Sources
* **GLEIF Search Portal** — verify LEI status is "ISSUED" and active.
* **IRS TIN Matching System** — validate W-8/W-9 TIN + legal-name pairing.
* **RapidRatings** — pull the supplier's Financial Health Rating.
* **HHS-OIG List of Excluded Individuals/Entities (LEIE)** and **GSA SAM.gov Exclusions** — cross-checked at the trade/sanctions gate (see BHS-PROC-TRADE-002), not duplicated here.

Grounding source: Themes adapted from US IRS tax-identity practice, GLEIF LEI system, RapidRatings FHR methodology, and the federal Anti-Kickback Statute / Stark Law. Adapted, not reproduced. Illustrative demo baseline, not legal advice.
