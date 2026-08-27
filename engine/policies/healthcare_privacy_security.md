# Beacon Health Systems — Supplier Data Privacy &amp; Information Security Requirements

Document type: Supplier-facing standard (Cybersecurity / Privacy domain)
Issuing entity: Beacon Health Systems (US healthcare delivery &amp; device network — fictional, for demo)
Standard ID: BHS-STD-CYBER-005
Version: v1.0
Effective from: 2026-01-01
Grounding source: Themes adapted from the HIPAA Privacy Rule and Security Rule (45 CFR
Parts 160 &amp; 164), SOC 2 (AICPA Trust Services Criteria), NIST SP 800-66, and standard
Business Associate Agreement (BAA) practice. Adapted, not reproduced.
Note: Illustrative demo baselines, not legal advice.

---

## 1. Purpose &amp; Scope

1.1 This standard defines the privacy and information-security evidence a supplier
must provide based on whether it creates, receives, maintains, or transmits Protected
Health Information (PHI) on behalf of Beacon Health Systems. It applies to any
supplier meeting the definition of a "business associate" under HIPAA, including
health-IT vendors, billing/claims processors, cloud/data-hosting providers, and
device vendors whose products transmit or store patient data.

1.2 A supplier with no PHI access (for example, a commodity hardware supplier
exchanging only catalog data) may be exempt from Sections 2 and 3, recorded with a
reason at the governance gate.

---

## 2. Business Associate Agreement

2.1 Every in-scope supplier must execute a current Business Associate Agreement (BAA)
before any PHI is created, received, maintained, or transmitted. The BAA must specify
permitted uses and disclosures, required safeguards, breach-notification timelines,
and termination/data-return obligations.

2.2 A BAA that has lapsed, been superseded by a service change not reflected in its
terms, or that is missing required breach-notification language is treated as a
non-compliance pending renewal and blocks advancement past the governance gate.

---

## 3. HIPAA Security Rule Safeguards

3.1 In-scope suppliers must provide evidence of the three safeguard categories
required under the HIPAA Security Rule: administrative (e.g. workforce training,
access management), physical (e.g. facility access controls, device/media controls),
and technical (e.g. access controls, audit controls, encryption in transit and at
rest).

3.2 Suppliers must provide one of: a current HITRUST CSF certification, a SOC 2
Type II report covering the Security and Confidentiality Trust Services Criteria, or
an equivalent independent security assessment less than twelve months old. A report
whose scope excludes the systems handling Beacon PHI is treated as insufficient.

---

## 4. Breach Notification

4.1 Suppliers must report a confirmed or suspected breach of unsecured PHI within the
notification window stated in the BAA (no more than 60 days from discovery, per the
HIPAA Breach Notification Rule, and sooner where the BAA specifies a shorter window).

4.2 The breach report must include the nature of the PHI involved, the individuals
affected (or a good-faith estimate), and the remediation steps taken.

---

## 5. Validity &amp; Re-Evaluation

5.1 BAAs, HITRUST certifications, and SOC 2 reports must be current as of the
evaluation date. A lapse, a scope change, or a reported breach triggers re-evaluation
and may suspend the supplier's eligibility to receive or hold PHI pending review.

---

## 6. Audit Trail

6.1 The BAA execution date, the attestation type and report date, and any breach
notifications are written to the append-only audit trail with a pointer to the source
evidence and the actor that recorded the assessment.

End of standard.
