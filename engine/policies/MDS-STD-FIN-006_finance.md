# Finance Compliance and Financial Risk Management
# Document ID: MDS-STD-FIN-006
# Version: 2026.1
# Status: APPROVED

## 1. Purpose & Scope
This policy defines the mandatory financial verification, tax compliance, and entity vetting required for all suppliers onboarding or maintaining an active status with the enterprise. This closes the Boreal financial risk assessment gap.

## 2. Mandatory Financial Evidence Checklist

| Document / Evidence | Required when | Validity & Verification Rules |
| :--- | :--- | :--- |
| **Audited Financial Statements** | Mandatory for all Tier-1 and critical path suppliers; optional but preferred for commodity hardware vendors. | Must cover the two most recent fiscal years; prepared in accordance with GAAP or IFRS; reviewed for liquidity, debt-to-equity, and operational cash flow health. |
| **RapidRatings Financial Health Score** | Mandatory for all production-part and system-connected suppliers. | Financial Health Rating (FHR) must be updated annually; Core Health Score must meet or exceed the enterprise baseline minimum (>60); scores below baseline trigger an automatic High Risk tier mitigation workflow. |
| **Banking & ACH Verification Form** | Every supplier receiving electronic fund transfers (EFT). | Form must be signed by the supplier's CFO or authorized financial officer; must match bank letters or voided checks; verified via independent bank account ownership validation networks before first payment. |
| **W-8 Series (Foreign) or W-9 (US) Tax Form** | Every supplier (Mandatory prior to any disbursement). | Form must be signed within the current calendar year; Taxpayer Identification Number (TIN) or legal name must successfully clear the IRS TIN Matching System without errors. |
| **GLEIF Legal Entity Identifier (LEI)** | Mandatory for all international suppliers, corporate parents, and Tier-1 vendors. | Entity status must show "ISSUED" and active on the Global Legal Entity Identifier Foundation (GLEIF) index; Level 2 data (relationship data) must be fully mapped to detect ultimate parent structures and shield companies. |

## 3. Exceptions & Gate Waivers
* **Exemptions:** Low-spend, non-critical localized services under $10,000 annual contract value may waive the Audited Financials requirement, provided a logged reason is documented at the gate by the Procurement Lead. No waiver is permitted for Tax (W-8/W-9) or ACH Verification documents.

## 4. Authoritative Verification Sources
* **GLEIF Search Portal** — verify the Legal Entity Identifier (LEI) status is "ISSUED" and active.
* **IRS TIN Matching System** — validate W-8/W-9 TIN + legal name pairing.
* **RapidRatings** — pull the supplier's Financial Health Rating (FHR) directly.
