# Vendor GRACE — Release Readiness Plan (beta → Managed-Released)

Date: 2026-09-10 · Package `Vendor GRACE` (0Ho…wbtKAA, namespace `vendorgrace`) · Versions 0.1.0.1–0.1.0.5 are all **beta**.

Purpose: get from "beta builds" to a **promotable, Checkmarx-ready release version**, with every blocker
named, a fix proposed, and the trade-off / regression risk of each fix stated so it can be reviewed
before anything is built.

---

## 0. Where we are (measured, not assumed)

| Fact | Value | Source |
|---|---|---|
| Versions created | 5, all `Released=false`, `CodeCoverage` blank, `CoverageMet=false` | `sf package version list` (Dev Hub) |
| Promotion precondition | version built with `--code-coverage` **and** ≥ 75 % package Apex coverage | Salesforce 2GP rule |
| Package Apex lines (non-test) | **6,418** across 51 classes | coverage run + line count of unmeasured classes |
| Covered today | **1,442 → 22.5 %** (56 tests, all passing) | `sf apex run test --code-coverage`, 2026-09-10 |
| Classes with **no** coverage record (0 %) | 19 — incl. ComplianceEvaluatorService 463, DocumentValidatorService 425, ComplianceEmailController 408, DocAssessQueueable 317 | same |
| Biggest partial gaps | VendorPortalController 959 uncovered (32 %), SubSupplierController 341 (10 %), DocumentProcessingController 248 (15 %), PolicyDocumentController 172 (6 %) | same |
| `global` Apex (permanent API on release) | 5 classes — all Salesforce community-login scaffolding | grep |
| Beta installed elsewhere | not in myDevOrg / agentforceDevOrg / intelogikDevOrg — **other orgs unknown** | `sf package installed list` |

Coverage is the gate. Everything else is about **what gets locked forever** the moment we promote.

---

## 1. Release sequence

1. **Decide package scope** (§2 — the irreversible part; do this first because it changes the coverage denominator).
2. **Raise package coverage to ≥ 75 %** (§3 — the work).
3. **Rehearse the build**: fresh scratch org from `config/project-scratch-def.json`, push `force-app`, run all tests. This is exactly what `package version create --code-coverage` does internally, and it surfaces environment dependencies (features, guest users, Content Deliveries) *before* a 30-minute build fails.
4. **Build**: `sf package version create --package "Vendor GRACE" --code-coverage --installation-key-bypass --wait 60`. Confirm `Code Coverage Met = true` in `sf package version report`.
5. **Promote**: `sf package version promote --package "Vendor GRACE@1.0.0-N"` — irreversible; only after §2 decisions are final.
6. **Install the released version in a clean org** (not the packaging org), run the Post-Install Guide end-to-end, smoke-test the three personas + guest portal.
7. **Checkmarx** on the released 04t (user runs it). Map findings to the false-positive tables.
8. **Housekeeping after promote**: set `ancestorVersion: HIGHEST`, bump `versionNumber` for the next line; uninstall any beta from orgs that will take the release (beta → release upgrade is not allowed).

---

## 2. Blockers & decisions — package scope (irreversible on release)

Legend: **Fix** = what I propose · **Impact** = effect on our org / architecture · **Risk** = regression exposure.

### B1 — Community/site scaffolding ships in the package, incl. 5 `global` classes
26 classes (`Communities*`, `Site*`, `Lightning*`, `ChangePassword`, `ForgotPassword`, `MyProfilePage`, `MicrobatchSelfReg`), 22 VF pages, 4 VF components, 3 Aura login bundles, `SiteSamples` static resource. Salesforce generated these when the Experience sites were created; subscribers get their own copy generated when *they* create a site. Releasing them locks 5 `global` classes as a permanent API and ships the 2 remaining `VfCsrf` findings.
- **Fix:** move them to `force-app-parked/` (they stay deployed in our org; the sites' `indexPage`/`authorizationRequiredPage` keep working). Keep `AuditReportPDF` page + controller (ours).
- **Impact:** package −~330 non-test lines, −5 global classes, −2 VfCsrf. No change to the working org.
- **Risk:** none at runtime. Coverage ratio unchanged (they were ~75 % covered themselves).

### B2 — Agentforce is in the org but not in the package (decision needed)
`Compliance_Agent` + 5 GenAI function definitions (`Validate_Document`, `Evaluate_Compliance`, `Find_Supplier` ×2, `Find_Documents`) exist only in the org. The four invocable services they call (**1,167 lines, 0 % covered**) *are* in the package but nothing shipped can reach them.
- **Option A — ship Agentforce in 1.0:** add `GenAiPlannerBundle` / `GenAiPlugin` / `GenAiFunction` metadata to the package; keep the 4 services and write callout-mocked tests for them (+~900 lines of tests). Build scratch org needs Einstein/Agentforce features enabled in `project-scratch-def.json`; Agentforce packaging has its own validation quirks (first time we'd exercise it).
- **Option B — defer Agentforce to 1.1:** move the 4 services to `force-app-parked/` for 1.0 (org keeps them; agent keeps working). Denominator −1,167 lines. Ship the agent as a 1.1 feature once the core is released.
- **Recommendation:** **B**, unless Agentforce is part of the 1.0 listing pitch. It removes a quarter of the coverage gap and the riskiest packaging unknown from the critical path. Nothing is lost — parked code re-enters the package in a later version with no lock-in penalty.

### B3 — Dead / sample content that would be locked forever
| Item | Evidence | Fix | Risk |
|---|---|---|---|
| `AgentCaseService` (131 lines) | zero references anywhere (no Apex, LWC, flow, REST annotation) | park | none |
| `VendorPortalController.addRequirementFromDocument` / `…ByToken`, `routeDecision`; `DocumentProcessingController.addDocumentToComplianceByToken`; `PolicyDocumentController.startIngestion` | `@AuraEnabled` but no LWC/Aura/flow references them | verify each, delete (or park) | low — verify `CopilotService` isn't orphaned by `routeDecision` |
| `sfdc_default_ReportExport_Protection_Flow` | Salesforce default, Draft, TransactionSecurity | remove from package | none |
| Account web link `Billing` → `genwatt.com` | Developer Edition sample data | delete | none |
| **8 custom fields referenced by nothing shipped**: Account `Compliance_Case_Id__c`, `Own_Compliance_Score__c`, `SLAExpirationDate__c`, `SLASerialNumber__c`, `Total_amount__c`; Compliance_Document__c `Document_Number__c`, `Uploaded_By_User__c`; Document_Extraction__c `Processing_Duration_ms__c` | grep across Apex/LWC/flows/layouts/list views | **decision:** drop from package before release (fields shipped in a release can never be removed) | low — check none holds data you care about; `SLA*` are DE sample fields |

### B4 — Package asserts org-wide defaults for standard objects
`Account.object-meta.xml` carries `sharingModel Private` + `externalSharingModel Private`; `Case`/`Opportunity` stub files exist only to satisfy the packaging validator. A managed package cannot set a subscriber's OWD; at best it's ignored, at worst it blocks install in an org whose Account OWD differs.
- **Fix:** remove the `sharingModel`/`externalSharingModel` tags from the Account file, delete the Case/Opportunity stubs. Add "Set Account OWD to Private" to the Post-Install Guide (it already implies it; make it a numbered step).
- **Impact:** our org's OWD is untouched (removing the tag from source doesn't reset the org).
- **Risk:** the validator may raise a *different* complaint at build — caught in step 3 rehearsal, not at promote.

### B5 — `Procurement Manager` profile in the package
Contains only 198 `userPermissions` — no object, field, tab, class or app settings. Packaged profiles are a weak, half-honored vehicle; the 5 permission sets already carry everything (132 field perms, tabs, CMT access).
- **Fix:** remove from package. **Impact/Risk:** none — the guide's persona setup is permission-set based.

### B6 — Named Credential endpoints are ours
`Local_Compliance_Service` → a dev-tunnel URL; `Azure_OpenAI_GPT4o` / `AzureDocIntelCredentials` → our Azure resources (resource names are visible to every subscriber).
- **Fix:** keep as-is (subscribers edit the URL post-install; guide §1.2 already covers it). Optional hardening: a pre-build swap to placeholder URLs — adds a build step and breaks the dev org if forgotten. **Recommendation:** keep, document; revisit before public listing.

### B7 — Version numbering & ancestry
`0.1.0.NEXT` / "ver 0.1". Only one release per `major.minor.patch`.
- **Fix:** `versionNumber: 1.0.0.NEXT`, `versionName: "1.0"`, a real `versionDescription`. After promote: `ancestorVersion: HIGHEST`, next line `1.1.0.NEXT`. **Risk:** none.

### B8 — Beta installs
A beta cannot be upgraded to the release; it must be uninstalled first. None found in the three reachable orgs — **confirm any customer/demo org that has 0.1.0.x installed.**

---

## 3. The blocker — coverage 22.5 % → ≥ 75 %

### 3.1 Denominator after §2 (assuming B1, B2-Option B, B3)
| | Lines | Covered |
|---|---|---|
| Today | 6,418 | 1,442 (22.5 %) |
| − scaffolding (B1) | −330 | −250 |
| − Agentforce services (B2-B) | −1,167 | 0 |
| − dead code (B3) | −~280 | 0 |
| **Target base** | **~4,640** | **~1,190 (25.6 %)** |
| **Needed for 75 %** | | **~3,480 → +2,290 new covered lines** |

### 3.2 Where the lines come from (priority = uncovered lines, all live code)
| Class | Uncovered | Target | What the tests need |
|---|---|---|---|
| VendorPortalController | 959 | ~80 % (+680) | token-verified guest paths + internal paths; ContentVersion docs; assessments; `HttpCalloutMock` for engine calls |
| SubSupplierController | 341 | ~85 % (+280) | parent/child accounts, invite flow (User insert → `runAs` + mixed-DML care), email mock |
| DocAssessQueueable + DocAssessService | 384 | ~80 % (+300) | callout mock returning engine assess JSON; `Test.startTest/stopTest` to run the queueable |
| ComplianceEmailController | 408 | ~75 % (+300) | `Messaging` under test (no send), templates |
| PolicyDocumentController + PolicyIngestQueueable + PolicyIngestService | 437 | ~80 % (+340) | ContentVersion policy upload, callout mock |
| DocumentProcessingController | 248 | ~80 % (+200) | file save/link/remove, both token and internal entry |
| AuditReportController + PDF + AuditLogService | 257 | ~85 % (+200) | audit rows, VF page controller instantiation |
| ComplianceChecklistController | 112 | ~90 % (+100) | invocable with bulk inputs (uses packaged CMT records ✓) |
| IntelligenceDashboardController | 107 | ~85 % (+90) | seeded assessments/docs |
| ComplianceExpiryBatch, SupplierProfileTriggerHandler, ScreeningQueueable, ScopeService, MaterialType/ComplianceDomain controllers, CopilotService | ~270 | (+200) | batch execute, trigger insert, callout mock |
| **Total achievable** | | **≈ +2,700 → ~84 %** | headroom above the gate |

### 3.3 Test infrastructure (once, shared)
- `TestDataFactory` — supplier Account (Supplier record type, portal token, material/service scope), Compliance_Document__c + ContentVersion, Compliance_Assessment__c rows, sub-supplier hierarchy, Audit_Log__c.
- `EngineCalloutMock implements HttpCalloutMock` — canned JSON per engine route (screen, assess, policy ingest, LLM) keyed on the request path; error variant for failure branches.
- Rules: no `SeeAllData`; nothing that needs the Supplier Portal guest user (or guard with early return, as `CrudEnforcementTest` does); nothing that needs org data except the packaged custom-metadata records.

### 3.4 Trade-offs / impact
- **Architecture:** none — tests only. No production refactors; where a method is untestable as written I'll add a `@TestVisible` seam, not restructure.
- **Regression risk:** none from the tests themselves; **expect the tests to surface real bugs** in the 0 %-covered paths (that is the point) — each becomes a small, reviewed fix.
- **Effort:** ~2,500–3,500 lines of test Apex; realistically 2–3 working sessions, VendorPortalController first.
- **Alternative rejected:** reducing the denominator further by parking live-but-uncovered code (e.g. ComplianceEmailController). It's reachable from the dashboard, so parking it would remove a shipped feature.

---

## 4. Build-time blockers to expect (caught by the step-3 rehearsal)
| Risk | Why | Mitigation |
|---|---|---|
| Test needs a feature the build scratch org lacks (Content Deliveries for `ContentDistribution`, Platform Events, Sites) | `--code-coverage` runs every test in a fresh scratch org from `project-scratch-def.json` | rehearse in a scratch org from the same def; add features to the def |
| A test hits the network | callouts fail under test without a mock | `EngineCalloutMock` everywhere; `Test.setMock` in each callout test |
| Guest-user tests | no Experience site in the build org | already guarded (`if (guests.isEmpty()) return;`) — keep the pattern |
| B4 validator reaction | removing OWD tags may re-trigger a sharing-model check | fix at rehearsal, before promote |
| Agentforce metadata (only if B2-Option A) | first-time packaging of GenAi* types | separate spike before committing to it |

---

## 5. Decisions needed from you before I start
1. **B2 — Agentforce in 1.0 (Option A) or 1.1 (Option B, recommended)?**
2. **B3 — OK to drop the 8 unreferenced fields, the 5 unreferenced methods, `AgentCaseService`, the sample flow and web link from the package?**
3. **B1 / B4 / B5 — OK to park the site scaffolding, remove the OWD assertions, and drop the profile?**
4. **B8 — any org outside the three I can see where a 0.1.0.x beta is installed?**
5. **Version line — go to `1.0.0` for the first release?**

Once these are answered I'll execute §2 (scope, ~1 session), then §3 (coverage), then the rehearsal build — and stop for review before `promote`.
