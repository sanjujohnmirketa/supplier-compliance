---
document_id: STD-HEALTHIT-001
category: cyber
source_regulation: SOC 2 (AICPA Trust Services Criteria); HITRUST CSF; ONC Health IT Certification / Information Blocking Rule (45 CFR Part 171)
issuing_body: AICPA / HITRUST Alliance / ONC
jurisdiction: United States — industry framework (SOC 2/HITRUST are third-party attestation, not federal statute) plus federal (ONC/HHS)
applies_to: Health IT, digital-health platform, and data-integration vendors that process, store, or transmit health data beyond a basic Business Associate relationship
effective_date: 2026-08-13
last_reviewed: 2026-08-13
review_cycle: Annual, or upon regulatory change
---

# Supplier Standard: Health IT / Digital Health Security & Data Governance

## Purpose and Scope

This standard defines the security-attestation, subprocessor-transparency, and
interoperability requirements for a health IT or digital-health vendor — a platform,
navigation service, or data-integration company — beyond the baseline HIPAA Business
Associate Agreement. A signed BAA alone is necessary but not sufficient for a vendor at
this evidentiary tier; this standard is applied IN ADDITION TO the BAA requirement, not
in place of it.

## Requirements

1. **SOC 2 Type II Report.** The vendor must provide a current SOC 2 Type II report
   covering the Trust Services Criteria (security, availability, and — where the vendor
   processes health data — confidentiality/privacy), reflecting operating effectiveness
   over an observation period, not a point-in-time (Type I) attestation.
   *Source: AICPA Trust Services Criteria*

2. **HITRUST CSF Certification (Where Applicable).** For vendors handling a high volume
   of PHI, a current HITRUST CSF certification is the stronger evidentiary bar; where
   the vendor holds SOC 2 only, a bridge letter covering any gap since the last report
   period should be requested.
   *Source: HITRUST Alliance*

3. **Subprocessor Disclosure.** The vendor must disclose its full list of subprocessors
   that touch customer/member data, and confirm each subprocessor is bound by
   equivalent data-protection terms.
   *Source: Standard data processing addendum practice*

4. **Penetration Testing Evidence.** A recent (within 12 months) third-party penetration
   test report or summary should be on file, with material findings remediated or
   tracked to closure.
   *Source: SOC 2 Trust Services Criteria — CC7 (System Operations)*

5. **Breach Notification Commitment.** In addition to the BAA's HIPAA-required
   notification terms, the vendor's own incident-response commitment (notification
   timeline, point of contact) should be documented.
   *Source: 45 CFR 164.410 (baseline); vendor-specific terms layer on top*

6. **Interoperability / Information Blocking.** Where the vendor exchanges clinical data,
   it should support standard interoperability (HL7 FHIR) and not engage in practices
   that constitute information blocking under the ONC rule.
   *Source: 45 CFR Part 171 (ONC Information Blocking Rule)*

## Renewal and Monitoring Reference

| Item | Typical Cycle |
|---|---|
| SOC 2 Type II report | Annual (12-month observation period) |
| HITRUST CSF certification | 2-year cycle with interim assessments |
| Subprocessor list | Reviewed at onboarding and upon material change |

## Severity if Non-Compliant

**High.** Absence of a current SOC 2/HITRUST report or an undisclosed subprocessor
handling PHI is a material gap, though distinct from a missing BAA (Critical, see
STD-HIPAA-BAA-001) — this standard is the deeper evidentiary layer, not the baseline
gate.
