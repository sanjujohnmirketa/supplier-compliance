/**
 * ComplianceEvaluatorService
 * ═══════════════════════════════════════════════════════════════════════════
 * Apex Action for the Compliance Evaluator Agentforce topic.
 *
 * ROLE
 * ────
 * Decides whether a supplier meets each of their compliance requirements,
 * based on the documents they have uploaded and the CMT rules. Goes beyond
 * deterministic rule matching — uses an LLM to:
 *   - Cross-reference documents (does the COI list this supplier as insured?)
 *   - Detect mismatches the rule engine cannot catch via picklist matching
 *   - Generate plain-English remediation guidance
 *   - Handle edge cases (renewal in progress, scope mismatch, etc.)
 *
 * The deterministic rule engine seeded Compliance_Assessment__c records
 * (one per applicable requirement, Status=Pending). This service evaluates
 * each Pending assessment using the validated documents available.
 *
 * INVOCATION
 * ──────────
 * 1. From the Agentforce agent topic — when a compliance analyst asks
 *    "Why is supplier Acme non-compliant?" or "Evaluate Acme's compliance"
 * 2. From ComplianceEvaluationQueueable — called automatically after all
 *    documents for a supplier have been validated
 *
 * OUTPUT
 * ──────
 * Updates Compliance_Assessment__c.Status__c + Reason_Detail__c + Reason_Code__c
 * Returns a structured summary the agent can read back to the analyst.
 */
public with sharing class ComplianceEvaluatorService {

    // ── Configuration ────────────────────────────────────────────────────────
    @TestVisible private static final String  AI_ENDPOINT = 'callout:Azure_OpenAI_GPT4o';
    @TestVisible private static final Integer AI_MAX_TOKENS = 3000;
    @TestVisible private static final Integer CALLOUT_TIMEOUT_MS = 90000;

    // Reason codes — must match picklist values exactly
    private static final String CODE_MISSING  = 'Missing Document';
    private static final String CODE_EXPIRED  = 'Expired';
    private static final String CODE_NOT_MET  = 'Rule Not Met';
    private static final String CODE_OTHER    = 'Other';

    // ═════════════════════════════════════════════════════════════════════════
    // Input wrapper
    // ═════════════════════════════════════════════════════════════════════════
    public class EvaluateRequest {
        @InvocableVariable(
            label='Supplier Id or Name'
            description='Either a Salesforce Account ID (e.g. 001fn00000RlkvuAAB) OR a supplier name (e.g. "Acme Manufacturing", "vv"). If a name is provided and matches exactly one supplier, the action proceeds. If multiple suppliers match the name, the action returns an Ambiguity Message asking the user to clarify. Use this instead of asking the user for an ID when they have given you a name.'
            required=true
        )
        public String supplierId;

        @InvocableVariable(
            label='Specific Requirement Key'
            description='Optional. If provided, evaluates only this one requirement instead of all of them. Use the DeveloperName of the Compliance_Requirement__mdt record (e.g. RULE_A_001).'
        )
        public String requirementKey;

        @InvocableVariable(
            label='Persist Results'
            description='Whether to update the Compliance_Assessment__c records with the evaluation results. Set to false for a dry-run analysis without changing data.'
        )
        public Boolean persistResults = true;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Output wrapper
    // ═════════════════════════════════════════════════════════════════════════
    public class EvaluateResponse {
        @InvocableVariable(
            label='Supplier Name'
            description='The name of the supplier that was evaluated.'
        )
        public String supplierName;

        @InvocableVariable(
            label='Overall Status'
            description='The supplier\'s overall compliance status: Compliant, Non-Compliant, or Pending. Compliant means every mandatory requirement is met. Non-Compliant means at least one critical requirement has failed. Pending means some requirements are still awaiting documents or review.'
        )
        public String overallStatus;

        @InvocableVariable(
            label='Total Requirements'
            description='Total number of compliance requirements that apply to this supplier.'
        )
        public Integer totalRequirements;

        @InvocableVariable(
            label='Requirements Met'
            description='Number of requirements where the supplier provided valid evidence.'
        )
        public Integer requirementsMet;

        @InvocableVariable(
            label='Requirements Failed'
            description='Number of requirements that are Non-Compliant — missing, expired, or invalid evidence.'
        )
        public Integer requirementsFailed;

        @InvocableVariable(
            label='Summary'
            description='Plain-English summary of the supplier\'s compliance state, suitable for reading to a compliance analyst or sending to the supplier.'
        )
        public String summary;

        @InvocableVariable(
            label='Remediation Steps'
            description='Specific actions the supplier must take to become compliant. Empty if already Compliant.'
        )
        public String remediationSteps;

        @InvocableVariable(
            label='Critical Failures'
            description='List of requirement labels that are critical and currently failing. These block supplier approval.'
        )
        public String criticalFailures;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // @InvocableMethod — entry point for both the agent and the Queueable
    // ═════════════════════════════════════════════════════════════════════════
    @InvocableMethod(
        label='Evaluate Supplier Compliance'
        description='Evaluates whether a supplier meets each of their compliance requirements based on validated documents. Updates Compliance_Assessment__c statuses and generates remediation guidance. Use this when an analyst asks about a supplier\'s compliance state or wants to know why a supplier is non-compliant.'
        category='Compliance'
        callout=true
    )
    public static List<EvaluateResponse> evaluateCompliance(List<EvaluateRequest> requests) {
        List<EvaluateResponse> results = new List<EvaluateResponse>();
        for (EvaluateRequest req : requests) {
            results.add(evaluateOne(req));
        }
        return results;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Single-supplier evaluation
    // ═════════════════════════════════════════════════════════════════════════
    private static EvaluateResponse evaluateOne(EvaluateRequest req) {
        EvaluateResponse resp = new EvaluateResponse();

        try {
            // ── 0. Resolve the supplierId field — accepts either a Salesforce ID
            //     OR a supplier name. If the input is a name and matches multiple
            //     suppliers, fail loudly with the disambiguation list so the agent
            //     can ask the user to clarify rather than picking arbitrarily.
            String resolvedId = resolveSupplierIdOrName(req.supplierId);
            if (resolvedId == null) {
                // resolveSupplierIdOrName threw an ambiguity — read the cached message
                resp.summary = lastResolutionMessage;
                resp.overallStatus = 'Pending';
                resp.supplierName = req.supplierId;
                return resp;
            }
            req.supplierId = resolvedId;

            // ── 1. Load supplier + all related data ────────────────────────
            Account supplier = loadSupplier(req.supplierId);
            if (supplier == null) {
                resp.summary = 'Supplier not found: ' + req.supplierId;
                resp.overallStatus = 'Pending';
                return resp;
            }
            resp.supplierName = supplier.Name;

            // Filter to specific requirement if requested
            List<Compliance_Assessment__c> assessments = loadAssessments(
                req.supplierId, req.requirementKey);
            if (assessments.isEmpty()) {
                resp.summary = 'No compliance requirements have been generated for this supplier yet.';
                resp.overallStatus = 'Pending';
                return resp;
            }

            // Load all related documents in one SOQL
            Map<Id, Compliance_Document__c> docsByAssessment = loadRelatedDocuments(assessments);

            // ── 2. Build evaluation prompt ─────────────────────────────────
            String prompt = buildEvaluationPrompt(supplier, assessments, docsByAssessment);

            // ── 3. Call LLM for reasoning ──────────────────────────────────
            EvaluationLLMResult llmResult = callEvaluatorLLM(prompt);

            // ── 4. Apply results to assessments + compute summary ──────────
            List<Compliance_Assessment__c> toUpdate = new List<Compliance_Assessment__c>();
            Integer metCount = 0, failedCount = 0, pendingCount = 0;
            List<String> criticalFails = new List<String>();

            for (Compliance_Assessment__c assessment : assessments) {
                AssessmentDecision decision = llmResult.decisions.get(assessment.Requirement_Key__c);
                if (decision == null) {
                    // LLM didn't return a decision for this — keep as-is
                    pendingCount++;
                    continue;
                }

                if (decision.status == 'Compliant') metCount++;
                else if (decision.status == 'Non-Compliant') {
                    failedCount++;
                    if (assessment.Severity__c == 'Critical') {
                        criticalFails.add(assessment.Requirement_Label__c);
                    }
                } else pendingCount++;

                if (req.persistResults == null || req.persistResults) {
                    toUpdate.add(new Compliance_Assessment__c(
                        Id                     = assessment.Id,
                        Status__c              = decision.status,
                        Reason_Code__c         = decision.reasonCode,
                        Reason_Detail__c       = decision.reasonDetail.left(4000),
                        Evaluation_DateTime__c = DateTime.now(),
                        Evaluated_By__c        = 'Auto'
                    ));
                }
            }

            // ── 5. Persist assessment updates ──────────────────────────────
            if (!toUpdate.isEmpty()) {
                update Security.stripInaccessible(AccessType.UPDATABLE, toUpdate).getRecords();
            }

            // ── 6. Compute and persist Account rollup ──────────────────────
            String rollupStatus;
            if (failedCount > 0 && !criticalFails.isEmpty()) {
                rollupStatus = 'Non-Compliant';
            } else if (pendingCount > 0) {
                rollupStatus = 'Pending';
            } else {
                rollupStatus = 'Compliant';
            }

            if (req.persistResults == null || req.persistResults) {
                update Security.stripInaccessible(AccessType.UPDATABLE, new List<Account>{
                    new Account(
                        Id = supplier.Id,
                        Compliance_Status_Rollup__c = rollupStatus
                    )
                }).getRecords();
            }

            // ── 7. Build agent-facing response ─────────────────────────────
            resp.overallStatus       = rollupStatus;
            resp.totalRequirements   = assessments.size();
            resp.requirementsMet     = metCount;
            resp.requirementsFailed  = failedCount;
            resp.summary             = llmResult.summary;
            resp.remediationSteps    = llmResult.remediation;
            resp.criticalFailures    = String.join(criticalFails, '; ');

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                '[ComplianceEvaluatorService] ' + e.getMessage()
                + '\n' + e.getStackTraceString());
            resp.summary = 'Evaluation could not complete: ' + e.getMessage();
            resp.overallStatus = 'Pending';
        }

        return resp;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Prompt construction
    // ═════════════════════════════════════════════════════════════════════════
    @TestVisible
    private static String buildEvaluationPrompt(
        Account supplier,
        List<Compliance_Assessment__c> assessments,
        Map<Id, Compliance_Document__c> docsByAssessment
    ) {
        // Build a structured summary of each requirement and its document state
        List<Map<String, Object>> requirementData = new List<Map<String, Object>>();
        for (Compliance_Assessment__c a : assessments) {
            Compliance_Document__c doc = docsByAssessment.get(a.Id);
            Compliance_Requirement__mdt rule = lookupRule(a.Requirement_Key__c);

            Map<String, Object> entry = new Map<String, Object>{
                'requirement_key'   => a.Requirement_Key__c,
                'requirement_label' => a.Requirement_Label__c,
                'severity'          => a.Severity__c,
                'current_status'    => a.Status__c,
                'document_provided' => doc != null
            };
            if (rule != null) {
                entry.put('source_regulation', rule.Source_Regulation__c);
                entry.put('document_type_expected', rule.Document_Type__c);
            }
            if (doc != null) {
                entry.put('document_status', doc.Status__c);
                entry.put('document_expiry', doc.Expiry_Date__c != null
                    ? String.valueOf(doc.Expiry_Date__c) : null);
                entry.put('document_confidence', doc.Confidence_Score__c);
                entry.put('document_issuer', doc.Issuer__c);
            }
            requirementData.add(entry);
        }

        return String.join(new List<String>{
            'You are a compliance evaluator for US manufacturing supplier relationships.',
            '',
            'TASK',
            'Determine whether each compliance requirement below is met for this supplier.',
            'For each requirement, return a status (Compliant / Non-Compliant / Pending),',
            'a reason code, and a specific remediation message.',
            '',
            'SUPPLIER',
            'Name: ' + supplier.Name,
            'Industry: ' + (supplier.Industry__c != null ? supplier.Industry__c : 'unknown'),
            'Country: ' + (supplier.BillingCountry != null ? supplier.BillingCountry : 'unknown'),
            '',
            'REQUIREMENTS TO EVALUATE',
            JSON.serializePretty(requirementData),
            '',
            'EVALUATION RULES',
            '  - Compliant: document_provided=true AND document_status="Validated" '
                + 'AND document_expiry is in the future (or null for non-expiring docs)',
            '  - Non-Compliant + reason "Missing Document": document_provided=false',
            '  - Non-Compliant + reason "Expired": document_expiry is in the past',
            '  - Non-Compliant + reason "Rule Not Met": document exists and validated but '
                + 'fails the requirement (e.g. insufficient coverage on a COI)',
            '  - Pending: document_status="Pending" (awaiting validation)',
            '',
            'OUTPUT — return ONLY this JSON structure with no markdown:',
            '{',
            '  "decisions": {',
            '    "requirement_key": {',
            '      "status": "Compliant" | "Non-Compliant" | "Pending",',
            '      "reason_code": "Missing Document" | "Expired" | "Rule Not Met" | "Other",',
            '      "reason_detail": "specific 1-2 sentence explanation for this requirement"',
            '    }',
            '  },',
            '  "summary": "2-3 sentences summarising the supplier\'s overall compliance state",',
            '  "remediation": "Numbered list of specific actions the supplier must take. '
                + 'For each: which document to upload or what to fix. Cite the source regulation if known."',
            '}',
            '',
            'BE SPECIFIC in remediation. Bad: "Upload missing documents."',
            'Good: "Upload your IATF 16949 certificate from an IATF-recognised certification body, '
                + 'showing certification of your facility for the scope of automotive part manufacturing. '
                + 'Required by IATF Rules for Achieving and Maintaining IATF Recognition."'
        }, '\n');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // LLM callout
    // ═════════════════════════════════════════════════════════════════════════
    @TestVisible
    private static EvaluationLLMResult callEvaluatorLLM(String prompt) {
        Map<String, Object> body = new Map<String, Object>{
            'max_tokens'  => AI_MAX_TOKENS,
            'temperature' => 0.0,
            'messages'    => new List<Object>{
                new Map<String, Object>{
                    'role'    => 'system',
                    'content' => 'You are a compliance evaluation agent. Return only valid JSON.'
                },
                new Map<String, Object>{
                    'role'    => 'user',
                    'content' => prompt
                }
            }
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(AI_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(CALLOUT_TIMEOUT_MS);
        req.setBody(JSON.serialize(body));

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new EvaluatorException('LLM HTTP ' + res.getStatusCode()
                + ': ' + res.getBody().left(500));
        }

        Map<String, Object> parsed =
            (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> choices = (List<Object>) parsed.get('choices');
        Map<String, Object> message = (Map<String, Object>) ((Map<String, Object>) choices[0]).get('message');
        String content = (String) message.get('content');

        String cleaned = content.replaceAll('```json', '').replaceAll('```', '').trim();
        Map<String, Object> verdictJson = (Map<String, Object>) JSON.deserializeUntyped(cleaned);

        EvaluationLLMResult result = new EvaluationLLMResult();
        result.summary     = toStringValue(verdictJson.get('summary'));
        result.remediation = toStringValue(verdictJson.get('remediation'));
        result.decisions   = new Map<String, AssessmentDecision>();

        Map<String, Object> decisionsJson = (Map<String, Object>) verdictJson.get('decisions');
        if (decisionsJson != null) {
            for (String key : decisionsJson.keySet()) {
                Map<String, Object> d = (Map<String, Object>) decisionsJson.get(key);
                AssessmentDecision dec = new AssessmentDecision();
                dec.status       = (String) d.get('status');
                dec.reasonCode   = normaliseReasonCode((String) d.get('reason_code'));
                dec.reasonDetail = (String) d.get('reason_detail');
                result.decisions.put(key, dec);
            }
        }
        return result;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═════════════════════════════════════════════════════════════════════════
    private static String normaliseReasonCode(String raw) {
        if (String.isBlank(raw)) return CODE_OTHER;
        // Map LLM variations back to picklist values
        String lower = raw.toLowerCase();
        if (lower.contains('missing'))    return CODE_MISSING;
        if (lower.contains('expir'))      return CODE_EXPIRED;
        if (lower.contains('not met') || lower.contains('rule')) return CODE_NOT_MET;
        return CODE_OTHER;
    }

    private static Account loadSupplier(Id supplierId) {
        if (supplierId == null) return null;
        List<Account> accts = [
            SELECT Id, Name, Industry__c, BillingCountry, Country_of_Origin__c,
                   Compliance_Status_Rollup__c
            FROM   Account
            WHERE  Id = :supplierId
            WITH   USER_MODE
            LIMIT  1
        ];
        return accts.isEmpty() ? null : accts[0];
    }

    private static List<Compliance_Assessment__c> loadAssessments(
        Id supplierId, String specificRequirementKey
    ) {
        if (String.isNotBlank(specificRequirementKey)) {
            return [
                SELECT Id, Requirement_Key__c, Requirement_Label__c, Status__c,
                       Severity__c, Compliance_Document__c, Reason_Code__c
                FROM   Compliance_Assessment__c
                WHERE  Supplier__c       = :supplierId
                AND    Requirement_Key__c = :specificRequirementKey
                WITH   USER_MODE
                LIMIT  50
            ];
        }
        return [
            SELECT Id, Requirement_Key__c, Requirement_Label__c, Status__c,
                   Severity__c, Compliance_Document__c, Reason_Code__c
            FROM   Compliance_Assessment__c
            WHERE  Supplier__c = :supplierId
            WITH   USER_MODE
            ORDER  BY Severity__c ASC, Requirement_Label__c ASC
            LIMIT  200
        ];
    }

    private static Map<Id, Compliance_Document__c> loadRelatedDocuments(
        List<Compliance_Assessment__c> assessments
    ) {
        Set<Id> docIds = new Set<Id>();
        for (Compliance_Assessment__c a : assessments) {
            if (a.Compliance_Document__c != null) docIds.add(a.Compliance_Document__c);
        }
        if (docIds.isEmpty()) return new Map<Id, Compliance_Document__c>();

        Map<Id, Compliance_Document__c> byDocId = new Map<Id, Compliance_Document__c>([
            SELECT Id, Document_Type__c, Status__c, Expiry_Date__c, Issue_Date__c,
                   Issuer__c, Confidence_Score__c
            FROM   Compliance_Document__c
            WHERE  Id IN :docIds
            WITH   USER_MODE
        ]);

        Map<Id, Compliance_Document__c> byAssessmentId = new Map<Id, Compliance_Document__c>();
        for (Compliance_Assessment__c a : assessments) {
            if (a.Compliance_Document__c != null) {
                byAssessmentId.put(a.Id, byDocId.get(a.Compliance_Document__c));
            }
        }
        return byAssessmentId;
    }

    private static Compliance_Requirement__mdt lookupRule(String key) {
        if (String.isBlank(key)) return null;
        try { return Compliance_Requirement__mdt.getInstance(key); }
        catch (Exception e) { return null; }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Internal types
    // ═════════════════════════════════════════════════════════════════════════
    @TestVisible
    private class AssessmentDecision {
        public String status;
        public String reasonCode;
        public String reasonDetail;
    }

    @TestVisible
    private class EvaluationLLMResult {
        public Map<String, AssessmentDecision> decisions;
        public String summary;
        public String remediation;
    }

    // Safely converts a JSON value that may be either a String or a List<Object>
    // to a String. The LLM sometimes returns remediation/summary as an array
    // of strings rather than a single string.
    private static String toStringValue(Object val) {
        if (val == null) return null;
        if (val instanceof String) return (String) val;
        if (val instanceof List<Object>) {
            List<String> parts = new List<String>();
            for (Object item : (List<Object>) val) {
                if (item != null) parts.add(String.valueOf(item));
            }
            return String.join(parts, '\n');
        }
        return String.valueOf(val);
    }

    public class EvaluatorException extends Exception {}

    // ═════════════════════════════════════════════════════════════════════════
    // Supplier ID resolution — accepts either ID or name
    // ═════════════════════════════════════════════════════════════════════════
    // Cached message from the last resolveSupplierIdOrName() call.
    // Set when the name is ambiguous so evaluateOne() can surface the
    // disambiguation prompt to the agent.
    @TestVisible
    private static String lastResolutionMessage = '';

    /**
     * Accepts a Salesforce 15/18-char Account ID or a supplier name.
     * Returns a definite Account.Id when the input is unambiguous.
     * Returns null when the name matches zero or multiple suppliers —
     * in that case lastResolutionMessage is populated with text the agent
     * can read back to the user to ask for clarification.
     */
    @TestVisible
    private static String resolveSupplierIdOrName(String input) {
        lastResolutionMessage = '';
        if (String.isBlank(input)) {
            lastResolutionMessage = 'No supplier name or ID was provided.';
            return null;
        }

        String trimmed = input.trim();

        // First — check if it's already a 15- or 18-char Salesforce ID
        if (trimmed.length() == 15 || trimmed.length() == 18) {
            try {
                Id candidate = Id.valueOf(trimmed);
                if (candidate.getSObjectType() == Account.SObjectType) {
                    return trimmed;
                }
            } catch (Exception e) {
                // Not a valid ID — fall through to name lookup
            }
        }

        // Treat as a name lookup
        Id supplierRtId = getSupplierRecordTypeIdSafe();
        List<Account> matches;
        if (supplierRtId != null) {
            matches = [
                SELECT Id, Name, BillingCity, BillingState, Industry__c
                FROM   Account
                WHERE  Name LIKE :('%' + trimmed + '%')
                AND    RecordTypeId = :supplierRtId
                WITH   USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT  10
            ];
        } else {
            matches = [
                SELECT Id, Name, BillingCity, BillingState, Industry__c
                FROM   Account
                WHERE  Name LIKE :('%' + trimmed + '%')
                WITH   USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT  10
            ];
        }

        if (matches.isEmpty()) {
            lastResolutionMessage = 'No supplier found matching "' + trimmed
                + '". Ask the user to verify the supplier name.';
            return null;
        }
        if (matches.size() == 1) {
            return (String) matches[0].Id;
        }

        // Multiple matches — build a numbered list for the agent
        List<String> lines = new List<String>();
        for (Integer i = 0; i < matches.size(); i++) {
            Account a = matches[i];
            lines.add((i + 1) + '. ' + a.Name
                + (a.BillingCity != null ? ' (' + a.BillingCity + ')' : '')
                + (a.Industry__c != null ? ' — ' + a.Industry__c : ''));
        }
        lastResolutionMessage = 'Found ' + matches.size() + ' suppliers matching "'
            + trimmed + '". Please clarify which one:\n'
            + String.join(lines, '\n');
        return null;
    }

    private static Id getSupplierRecordTypeIdSafe() {
        try {
            Map<String, Schema.RecordTypeInfo> rtMap =
                Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
            return rtMap.containsKey('Supplier')
                ? rtMap.get('Supplier').getRecordTypeId()
                : null;
        } catch (Exception e) {
            return null;
        }
    }
}