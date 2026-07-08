# Meridian Drive Systems — Supplier General Onboarding & Fallback Procedure

Document type: Internal procedure (General domain)
Issuing entity: Meridian Drive Systems Inc. (US automotive OEM — fictional, for demo)
Procedure ID: MDS-PROC-GEN-001
Version: v1.0
Effective from: 2026-01-01
Grounding source: General supplier-management practice — self-assessment questionnaires,
business-continuity planning (ISO 22301 themes), and standard commercial general-liability
insurance requirements. Adapted, not reproduced.
Note: Illustrative demo baselines, not legal advice.

---

## 1. Purpose & Core Logic

1.1 This procedure is the catch-all governance baseline for general supplier profiling. When
a supplier's commodity and engagement do not trigger any commodity-specific or regulatory
standard, this procedure applies so that no supplier is onboarded without a documented
baseline. It governs commodity-hardware, administrative, and low-risk service suppliers.

---

## 2. Supplier Self-Assessment Questionnaire

2.1 Every supplier with no domain-specific standard in scope must complete the Supplier
Self-Assessment Questionnaire (SAQ) to full completion of all mandatory fields. The SAQ
captures operational scale, primary sites, workforce size, business-continuity posture, and
executive points of contact. An incomplete SAQ blocks advancement past the governance gate.

---

## 3. Business Continuity & Disaster Recovery

3.1 Suppliers with a high operational footprint, or where Meridian is single-sourced on the
supplied item, must submit a documented, executive-approved business-continuity and
disaster-recovery plan. The plan must evidence a continuity test or simulation performed
within the previous twelve months.

---

## 4. Insurance

4.1 Suppliers performing on-site services or delivering physical product must provide a
current Certificate of Insurance evidencing Commercial General Liability cover of at least
2,000,000 USD, naming Meridian Drive Systems as an additional insured. The certificate
expiry date is tracked automatically, and a renewal reminder is raised thirty days before
lapse. A lapsed certificate is treated as a non-compliance pending renewal.

---

## 5. Fallback Routing Logic

5.1 When the onboarding engine evaluates a supplier and matches zero domain-specific
standards, orchestration defaults the routing path to this procedure, generates the SAQ,
requires the baseline Certificate of Insurance, and records a fallback justification token at
the governance gate (GENERAL_FALLBACK_APPLIED) so the reason for the reduced baseline is
explicit and reconstructable.

---

## 6. Record & Provenance

6.1 The completed SAQ, the continuity-plan submission and last test date, the insurance
certificate and its expiry, and the fallback justification token are written to the
append-only event record with a timestamp, the actor, and a pointer to the source evidence.

End of procedure.
