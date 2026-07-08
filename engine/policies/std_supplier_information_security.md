# Meridian Drive Systems — Supplier Information Security Requirements

Document type: Supplier-facing standard (Cybersecurity domain)
Issuing entity: Meridian Drive Systems Inc. (US automotive OEM — fictional, for demo)
Standard ID: MDS-STD-CYBER-005
Version: v1.0
Effective from: 2026-01-01
Grounding source: Themes adapted from TISAX (ENX Association), SOC 2 (AICPA Trust
Services Criteria), NIST SP 800-171, and CMMC for defense-related work. Adapted, not
reproduced.
Note: Illustrative demo baselines, not legal advice.

---

## 1. Purpose & Scope

1.1 This standard defines the information-security evidence a supplier must provide
based on the type of Meridian data or systems it accesses. It applies to any supplier
that handles Meridian intellectual property, connected-vehicle or telematics data,
prototype/pre-production information, production data, or that connects to Meridian
systems.

1.2 A supplier that handles none of the above (for example, a commodity hardware
supplier exchanging only catalog data) may be exempt from Sections 2 and 3, recorded
with a reason at the governance gate.

---

## 2. Baseline Security Attestation

2.1 In-scope suppliers must provide one of: a current TISAX label at the assessment
level matching the data classification, or a current SOC 2 Type II report covering the
relevant Trust Services Criteria (at minimum Security; Confidentiality where IP is
handled).

2.2 Evidence is validated on substance, not existence: the report date, the assessment
scope, and the assessed locations are checked. A SOC 2 report older than twelve months,
or whose scope excludes the systems handling Meridian data, is treated as insufficient.

---

## 3. Defense-Related Work

3.1 Suppliers in scope of US defense-related programs that handle Controlled
Unclassified Information (CUI) must provide NIST SP 800-171 evidence, or CMMC
certification at the level specified in the purchase agreement. A current System
Security Plan (SSP) and Plan of Action and Milestones (POA&M) are required where full
compliance is not yet met.

---

## 4. Data Handling

4.1 Where Meridian-supplied data is exchanged, the supplier must provide a data-
handling attestation describing how the data is stored, encrypted in transit and at
rest, access-controlled, and deleted at end of contract.

4.2 Suppliers must report a confirmed security breach affecting Meridian data within
the notification window stated in the purchase agreement.

---

## 5. Validity & Re-Evaluation

5.1 TISAX labels and SOC 2 reports must be current as of the evaluation date. A lapse,
a scope change, or a reported breach triggers re-evaluation and may suspend the
supplier's eligibility to receive or hold Meridian data pending review.

---

## 6. Audit Trail

6.1 The attestation type, report date, scope, and any breach notifications are written
to the append-only audit trail with a pointer to the source evidence and the actor
that recorded the assessment.

End of standard.
