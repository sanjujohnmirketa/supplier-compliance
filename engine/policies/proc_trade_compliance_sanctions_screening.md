# Meridian Drive Systems — Trade Compliance & Sanctions Screening Procedure

Document type: Internal procedure (Trade / Regulatory domain)
Issuing entity: Meridian Drive Systems Inc. (US automotive OEM — fictional, for demo)
Procedure ID: MDS-PROC-TRADE-002
Version: v1.0
Effective from: 2026-01-01
Grounding source: Themes adapted from US OFAC sanctions programs, the US Export
Administration Regulations (EAR), US Customs (CBP) country-of-origin rules, and EU
consolidated sanctions list practice. Adapted, not reproduced.
Note: Illustrative demo baselines, not legal advice. [Unverified] applicability of any
export control or sanctions regime to a specific transaction must be confirmed per case.

---

## 1. Purpose & Scope

1.1 This procedure governs the trade-compliance screening performed on every supplier,
its listed directors, and its beneficial owners before the supplier may receive a
production purchase order, and on a recurring basis after approval.

1.2 It applies to all suppliers regardless of commodity, including services suppliers,
because sanctions and denied-party exposure is independent of what is supplied.

---

## 2. Sanctions & Watchlist Screening

2.1 Lists screened
Each supplier legal entity, its directors, and beneficial owners with 25% or greater
ownership are screened against, at minimum: the OFAC Specially Designated Nationals
(SDN) list, the OFAC consolidated non-SDN lists, the US BIS Entity List and Denied
Persons List, and the EU consolidated sanctions list.

2.2 Match handling
A confirmed exact match to a sanctioned party blocks onboarding immediately and is
escalated. A near-match, fuzzy name match, or politically exposed person (PEP) hit is
routed to the governance gate for human disambiguation before any approval. No
supplier with an unresolved near-match may be advanced to Active status.

2.3 Beneficial ownership
Suppliers must disclose beneficial owners holding 25% or greater interest. Where
ownership is opaque or routed through shell structures, enhanced due diligence is
required and the supplier is raised to HIGH risk tier.

---

## 3. Export Control & Country of Origin

3.1 Country-of-origin declaration
Suppliers must provide a country-of-origin declaration for each supplied part. The
declared origin is used for customs, trade-agreement eligibility, and sanctions-nexus
assessment.

3.2 Export classification
For controlled items, suppliers must provide the applicable export-control
classification (for US-origin items, the ECCN under the EAR; for defense articles, the
USML category). Items lacking a required classification are routed to the gate.

3.3 Embargoed jurisdictions
Suppliers located in, or sourcing material from, comprehensively embargoed
jurisdictions are blocked from onboarding. Partial or sectoral sanctions exposure
raises the supplier to HIGH tier and requires legal review.

---

## 4. Recurring Re-Screening

4.1 Approved suppliers are re-screened against all lists in Section 2 on a recurring
schedule and whenever a watchlist is updated. A change in screening result (a new hit
on a previously clear supplier) triggers immediate re-evaluation and may suspend
purchase-order eligibility pending review.

---

## 5. Audit Trail

5.1 Every screening run records the lists and list-versions checked, the result, and
any human disambiguation decision with its reason, written to the append-only audit
trail with a timestamp and the actor identity.

End of procedure.
