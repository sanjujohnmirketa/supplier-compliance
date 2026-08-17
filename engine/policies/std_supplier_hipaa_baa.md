---
document_id: STD-HIPAA-BAA-001
category: cyber
source_regulation: HIPAA Privacy Rule and Security Rule, 45 CFR Parts 160 and 164
issuing_body: U.S. Department of Health and Human Services (HHS)
jurisdiction: United States — Federal
applies_to: Any vendor that creates, receives, maintains, or transmits protected health information (PHI) on behalf of a customer, including labs, pharmacies, and IT/data vendors
effective_date: 2026-08-11
last_reviewed: 2026-08-11
review_cycle: Annual, or upon regulatory change
---

# Supplier Standard: HIPAA Business Associate Agreement (BAA)

## Purpose and Scope

This standard defines the data protection agreement and safeguard requirements for any
vendor whose services involve access to protected health information (PHI), regardless of
vendor category. It applies in addition to any industry-specific standard (for example,
STD-CLIA-001) that governs the vendor's core service.

## Requirements

1. **Business Associate Agreement Required.** A signed Business Associate Agreement (BAA)
   must be in place with any vendor that creates, receives, maintains, or transmits PHI,
   before that access begins.
   *Source: 45 CFR 164.502(e), 164.504(e)*

2. **Permitted Uses and Disclosures.** The BAA must limit the vendor's use and disclosure
   of PHI to what is expressly permitted by the agreement and required by law.
   *Source: 45 CFR 164.504(e)(2)*

3. **Safeguards Requirement.** The vendor must implement administrative, physical, and
   technical safeguards that reasonably and appropriately protect the confidentiality,
   integrity, and availability of electronic PHI.
   *Source: 45 CFR 164.308, 164.310, 164.312 (Security Rule)*

4. **Breach Notification.** The vendor must report any use or disclosure not permitted by
   the agreement, including breaches of unsecured PHI, without unreasonable delay and no
   later than 60 days after discovery (many BAAs contractually shorten this to 30 days for
   internal notice).
   *Source: 45 CFR 164.410*

5. **Subcontractor Flow-Down.** If the vendor uses subcontractors that create, receive,
   maintain, or transmit PHI on its behalf, the vendor must ensure those subcontractors
   agree, in writing, to the same restrictions and conditions the vendor itself is bound
   by.
   *Source: 45 CFR 164.504(e)(2)(ii)(D)*

6. **Security Risk Assessment Evidence.** Vendors handling electronic PHI should be able
   to demonstrate a current security risk assessment and remediation plan, commonly
   evidenced through a SOC 2 or HITRUST report.
   *Source: 45 CFR 164.308(a)(1)*

7. **Return or Destruction of PHI on Termination.** Upon termination of the relationship,
   the vendor must return or destroy all PHI in its possession, or, if that is not
   feasible, extend the agreement's protections to the retained PHI indefinitely.
   *Source: 45 CFR 164.504(e)(2)(ii)(I)*

## Renewal and Monitoring Reference

| Item | Typical Cycle |
|---|---|
| BAA validity | Term of the underlying service contract |
| Security risk assessment / SOC 2 or HITRUST report | Annual refresh |

## Severity if Non-Compliant

**Critical.** Any vendor with PHI access and no signed BAA on file should block approval
regardless of that vendor's standing on other industry-specific standards.
