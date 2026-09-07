/**
 * AIExtractionQueueable  (v3 — single-pass extract + validate + evaluate)
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * WHAT CHANGED FROM v2
 * ────────────────────
 * v2 made one LLM call to extract fields. Validation, evaluation, and risk
 * happened in separate services (DocumentValidatorService,
 * ComplianceEvaluatorService) each making their own LLM call. Three LLM
 * round-trips per document upload.
 *
 * v3 does everything in ONE LLM call:
 *   - Field extraction (issuer, expiry, cert number, etc.)
 *   - Document validation (type-match, name-match, dates, accredited issuer,
 *     authenticity concerns)
 *   - Compliance evaluation against the specific rule the doc was uploaded for
 *   - Risk contribution score
 *   - Remediation guidance
 *
 * The full structured response is stored in Document_Extraction__c.Raw_Response__c.
 * The Supplier Risk Dashboard reads that JSON directly via SOQL — no second
 * LLM call ever, no separate validator/evaluator service.
 *
 * SERVICES TO DELETE AFTER DEPLOYING v3
 * ─────────────────────────────────────
 * Once this file is deployed and tested:
 *   1. DocumentValidatorService.cls       — superseded by this prompt
 *   2. ComplianceEvaluatorService.cls     — superseded by this prompt
 *   3. AgentforceComplianceServicesTest.cls — tests for the above
 *
 * The Agentforce agent actions that referenced those services must also be
 * either deleted from Setup OR re-pointed to new lightweight Apex methods
 * that read Document_Extraction__c.Raw_Response__c.
 *
 * COMPLIANCE EVALUATION QUEUEABLE
 * ───────────────────────────────
 * ComplianceEvaluationQueueable used to call ComplianceEvaluatorService.
 * It needs a small rewrite: load the latest Document_Extraction__c per
 * Compliance_Assessment__c, parse the compliance block from Raw_Response__c,
 * and write to Compliance_Assessment__c — pure SOQL + JSON.parse, no LLM.
 * The chain still fires from this class after a successful extraction.
 *
 * RESPONSE STRUCTURE (stored in Raw_Response__c, read by the dashboard)
 * ─────────────────────────────────────────────────────────────────────
 *   {
 *     "extracted_fields": {
 *       "document_type":      { "value": "...", "confidence": 0.0 },
 *       "issuer":             { "value": "...", "confidence": 0.0 },
 *       "issue_date":         { "value": "YYYY-MM-DD", "confidence": 0.0 },
 *       "expiry_date":        { "value": "YYYY-MM-DD", "confidence": 0.0 },
 *       "certificate_number": { "value": "...", "confidence": 0.0 },
 *       "subject_company":    { "value": "...", "confidence": 0.0 },
 *       "scope":              { "value": "...", "confidence": 0.0 }
 *     },
 *     "validation": {
 *       "verdict": "Valid|Invalid|Needs Human Review",
 *       "reasoning": "...",
 *       "issues": ["..."],
 *       "document_type_matches": true,
 *       "company_name_matches": true,
 *       "dates_coherent": true,
 *       "issuer_accredited": true,
 *       "authenticity_concerns": ["..."]
 *     },
 *     "compliance": {
 *       "status": "Compliant|Non-Compliant|Needs Human Review",
 *       "reason_code": "Missing Document|Expired|Rule Not Met|Other",
 *       "reason_detail": "...",
 *       "regulation_citation": "..."
 *     },
 *     "risk_contribution": 0,
 *     "remediation": "...",
 *     "overall_confidence": 0.0
 *   }
 */
public class AIExtractionQueueable implements Queueable, Database.AllowsCallouts {

    // ── Configuration constants ──────────────────────────────────────────────
    @TestVisible private static final String  AI_ENDPOINT             = 'callout:Azure_OpenAI_GPT4o';
    @TestVisible private static final String  AI_MODEL_NAME           = 'gpt-4o-mini';
    @TestVisible private static final Integer AI_MAX_TOKENS           = 4000;
    @TestVisible private static final Decimal AI_CONFIDENCE_THRESHOLD = 0.75;
    @TestVisible private static final Integer MAX_FILE_BYTES          = 10 * 1024 * 1024;
    @TestVisible private static final Integer CALLOUT_TIMEOUT_MS      = 120000;

    @TestVisible private static final Integer MAX_RETRY_ATTEMPTS = 4;

    // ── Payload from the Platform Event ──────────────────────────────────────
    private final String  complianceDocId;
    private final String  contentVersionId;
    private final String  supplierId;
    private final String  documentTypeHint;
    private final Integer retryAttempt;

    public AIExtractionQueueable(
        String complianceDocId,
        String contentVersionId,
        String supplierId,
        String documentTypeHint
    ) {
        this(complianceDocId, contentVersionId, supplierId, documentTypeHint, 0);
    }

    public AIExtractionQueueable(
        String complianceDocId,
        String contentVersionId,
        String supplierId,
        String documentTypeHint,
        Integer retryAttempt
    ) {
        this.complianceDocId  = complianceDocId;
        this.contentVersionId = contentVersionId;
        this.supplierId       = supplierId;
        this.documentTypeHint = documentTypeHint;
        this.retryAttempt     = retryAttempt == null ? 0 : retryAttempt;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // @InvocableMethod — entry point from Document_Upload_Event_Handler flow
    // ═════════════════════════════════════════════════════════════════════════

    public class ExtractionRequest {
        @InvocableVariable(label='Compliance Document Id' required=true)
        public String complianceDocId;
        @InvocableVariable(label='Content Version Id' required=true)
        public String contentVersionId;
        @InvocableVariable(label='Supplier Id')
        public String supplierId;
        @InvocableVariable(label='Document Type Hint')
        public String documentTypeHint;
    }

    @InvocableMethod(
        label       = 'Enqueue AI Extraction Job'
        description = 'Called by Document_Upload_Event_Handler flow. One LLM call returns extraction + validation + compliance evaluation as a single structured JSON.'
        category    = 'Compliance'
    )
    public static void enqueueFromEvent(List<ExtractionRequest> requests) {
        if (requests == null || requests.isEmpty()) return;

        for (ExtractionRequest req : requests) {
            if (String.isBlank(req.complianceDocId) || String.isBlank(req.contentVersionId)) {
                System.debug(LoggingLevel.ERROR,
                    '[AIExtractionQueueable] Missing IDs: docId=' + req.complianceDocId
                    + ' cvId=' + req.contentVersionId);
                continue;
            }
            System.enqueueJob(new AIExtractionQueueable(
                req.complianceDocId,
                req.contentVersionId,
                req.supplierId,
                req.documentTypeHint
            ));
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // execute — runs in its own transaction
    // ═════════════════════════════════════════════════════════════════════════
    public void execute(QueueableContext ctx) {
        System.debug(LoggingLevel.INFO,
            '[AIExtractionQueueable] Starting v3 single-pass extraction. ComplianceDoc='
            + complianceDocId + ' Job=' + ctx.getJobId());

        try {
            // ── 1. Load document + supplier + rule context ─────────────────
            Compliance_Document__c compDoc = loadComplianceDocument();
            if (compDoc == null) {
                System.debug(LoggingLevel.ERROR,
                    'Compliance_Document__c ' + complianceDocId + ' not found');
                return;
            }

            ContentVersion cv = loadContentVersion();
            if (cv == null || cv.VersionData == null) {
                System.debug(LoggingLevel.ERROR,
                    'ContentVersion ' + contentVersionId + ' missing or empty');
                return;
            }

            // Supplier and rule context feed the prompt so the model can do
            // company-name cross-checks and requirement-type validation in
            // one pass. Both can be null safely — prompt uses defaults.
            Account supplier = loadSupplier(compDoc.Account__c);
            Compliance_Requirement__mdt rule = lookupRule(documentTypeHint);

            // ── 2. Validate file size ──────────────────────────────────────
            if (cv.ContentSize > MAX_FILE_BYTES) {
                String msg = 'File too large for AI processing: '
                    + (cv.ContentSize / 1024 / 1024) + 'MB exceeds '
                    + (MAX_FILE_BYTES / 1024 / 1024) + 'MB limit';
                System.debug(LoggingLevel.ERROR, msg);
                recordExtractionFailure(msg);
                return;
            }

            // ── 3. Build the single-pass prompt ────────────────────────────
            String prompt = buildPrompt(cv, compDoc, supplier, rule);

            // ── 4. Send file natively to Azure OpenAI ──────────────────────
            String base64Body = EncodingUtil.base64Encode(cv.VersionData);
            String rawJson    = callAzureOpenAI(base64Body, cv, prompt);

            System.debug(LoggingLevel.INFO,
                '[AIExtractionQueueable] AI response received: '
                + (rawJson != null ? rawJson.length() : 0) + ' chars');

            // ── 5. Extract the top-level fields we need for the Apex write ─
            //     The full JSON also stays in Raw_Response__c for the dashboard.
            ExtractionSummary summary = summarise(rawJson);

            // ── 6. Persist Document_Extraction__c (full JSON in Raw_Response) ─
            Document_Extraction__c extraction = new Document_Extraction__c(
                Compliance_Document__c  = complianceDocId,
                Extraction_DateTime__c  = DateTime.now(),
                Model_Name__c           = AI_MODEL_NAME,
                Overall_Confidence__c   = summary.overallConfidence,
                Below_Threshold__c      = summary.overallConfidence < AI_CONFIDENCE_THRESHOLD,
                Extracted_Fields__c     = summary.cleanJson,
                Raw_Response__c         = rawJson != null ? rawJson.left(131072) : null
            );
            insert extraction;

            // ── 7. Update Compliance_Document__c with verdict-driven status ─
            update new Compliance_Document__c(
                Id                   = complianceDocId,
                Status__c            = resolveDocStatus(summary),
                Confidence_Score__c  = summary.overallConfidence,
                Latest_Extraction__c = extraction.Id,
                Document_Type__c     = compDoc.Document_Type__c
                // String.isNotBlank(summary.detectedDocumentType)
                //                             ? summary.detectedDocumentType
                //                             : compDoc.Document_Type__c
            );

            // ── 8. Chain to evaluation queueable OR HITL ───────────────────
            //     The chain fires only when the AI deems the document
            //     trustworthy. ComplianceEvaluationQueueable then reads
            //     Raw_Response__c (no second LLM call) and writes the
            //     compliance verdict into Compliance_Assessment__c records.
            Boolean isTrustworthy = (summary.validationVerdict == 'Valid')
                || (String.isBlank(summary.validationVerdict)
                    && summary.overallConfidence >= AI_CONFIDENCE_THRESHOLD);

            System.enqueueJob(new AuthoritativeVerificationQueueable(
                complianceDocId, supplierId
            ));
            System.debug(
                isTrustworthy ? LoggingLevel.INFO : LoggingLevel.WARN,
                '[AIExtractionQueueable] Verdict=' + summary.validationVerdict
                + ' Confidence=' + summary.overallConfidence
                + (isTrustworthy
                    ? ' — chained AuthoritativeVerificationQueueable'
                    : ' — low confidence/invalid, chaining AuthoritativeVerificationQueueable for additional scrutiny')
            );

        } catch (RateLimitException rle) {
            Integer nextAttempt = retryAttempt + 1;
            if (nextAttempt <= MAX_RETRY_ATTEMPTS) {
                System.debug(LoggingLevel.WARN,
                    '[AIExtractionQueueable] 429 rate limit — retry attempt '
                    + nextAttempt + '/' + MAX_RETRY_ATTEMPTS
                    + ' for doc=' + complianceDocId);
                System.enqueueJob(new AIExtractionQueueable(
                    complianceDocId, contentVersionId, supplierId, documentTypeHint, nextAttempt
                ));
            } else {
                System.debug(LoggingLevel.ERROR,
                    '[AIExtractionQueueable] 429 rate limit — exhausted '
                    + MAX_RETRY_ATTEMPTS + ' retries for doc=' + complianceDocId);
                recordExtractionFailure(
                    'Azure OpenAI rate limit exceeded after '
                    + MAX_RETRY_ATTEMPTS + ' retries. Please try again later.'
                );
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                '[AIExtractionQueueable] Exception: ' + e.getMessage()
                + '\n' + e.getStackTraceString());
            recordExtractionFailure(e.getMessage());
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Prompt — single comprehensive pass
    // ═════════════════════════════════════════════════════════════════════════
    @TestVisible
    private String buildPrompt(
        ContentVersion cv,
        Compliance_Document__c compDoc,
        Account supplier,
        Compliance_Requirement__mdt rule
    ) {
        String supplierName       = supplier != null && supplier.Name != null
            ? supplier.Name : 'unknown';
        String supplierIndustry   = supplier != null && supplier.Industry__c != null
            ? supplier.Industry__c : 'unknown';
        String supplierVendorType = supplier != null && supplier.Vendor_Type__c != null
            ? supplier.Vendor_Type__c : 'unknown';
        String supplierCountry    = supplier != null && supplier.BillingCountry != null
            ? supplier.BillingCountry : 'unknown';

        String expectedDocType   = rule != null && rule.Document_Type__c != null
            ? rule.Document_Type__c : (compDoc.Document_Type__c != null
                ? compDoc.Document_Type__c : 'compliance document');
        String severity          = rule != null && rule.Severity_on_Failure__c != null
            ? rule.Severity_on_Failure__c : 'Medium';
        String sourceRegulation  = rule != null && rule.Source_Regulation__c != null
            ? rule.Source_Regulation__c : 'unspecified';
        String ruleLabel         = rule != null && rule.Label != null
            ? rule.Label : (documentTypeHint != null ? documentTypeHint : 'unknown');

        return String.join(new List<String>{
            'You are a compliance document analysis agent for US manufacturing supply chains.',
            'You will perform extraction, validation, and compliance evaluation in ONE pass.',
            '',
            '════════════════════════════════════════════════════════════════',
            'SUPPLIER CONTEXT',
            '════════════════════════════════════════════════════════════════',
            'Supplier name: ' + supplierName,
            'Supplier industry: ' + supplierIndustry,
            'Supplier vendor type: ' + supplierVendorType,
            'Supplier country: ' + supplierCountry,
            '',
            '════════════════════════════════════════════════════════════════',
            'EXPECTED DOCUMENT (what the supplier was asked to upload)',
            '════════════════════════════════════════════════════════════════',
            'Requirement: ' + ruleLabel,
            'Expected document type: ' + expectedDocType,
            'Source regulation: ' + sourceRegulation,
            'Severity if non-compliant: ' + severity,
            '',
            'Filename: ' + (cv.Title != null ? cv.Title : 'unknown'),
            'File type: ' + (cv.FileType != null ? cv.FileType : 'unknown'),
            '',
            '════════════════════════════════════════════════════════════════',
            'YOUR TASKS',
            '════════════════════════════════════════════════════════════════',
            '1. EXTRACT — read the document (text, tables, signatures, stamps,Numbers, dates,company names,scopes,',
            '   watermarks) and extract all compliance-relevant fields.',
            '',
            '2. VALIDATE — judge whether this document can be trusted as',
            '   compliance evidence. Check:',
            '   a) Document type matches the expected type above.',
            '      If supplier uploaded a W-9 when an ISO certificate was',
            '      expected, that is INVALID.',
            '   b) Company name on the document matches supplier name',
            '      "' + supplierName + '". Allow Inc./Ltd./Co. variations.',
            '      Significant mismatch = INVALID.',
            '   c) Issue and expiry dates are coherent (issue before expiry,',
            '      expiry not absurdly far in the future).',
            '   d) Issuer is a recognised authority for this document type.',
            '      ISO certs: BSI, DNV, TÜV, SGS, Lloyd\'s Register, Bureau Veritas, NQA, NSF.',
            '      IATF 16949: IATF-recognised CBs only — SAI Global lost recognition 2017+.',
            '      AS9100 / aerospace: Nadcap, IAQG-approved bodies.',
            '      COI: licensed insurance carriers (AM Best rated).',
            '   e) Look for authenticity concerns — inconsistent fonts,',
            '      missing stamps/seals, suspicious certificate numbers,',
            '      unusual formatting that suggests tampering or forgery.',
            '',
            '3. EVALUATE COMPLIANCE — given everything above, is the supplier',
            '   compliant with the specific requirement "' + ruleLabel + '"?',
            '   - "Compliant": valid document, type matches, dates current,',
            '     issuer accredited, no authenticity concerns.',
            '   - "Non-Compliant": invalid document, wrong type, expired,',
            '     unrecognised issuer, or authenticity concerns.',
            '   - "Needs Human Review": ambiguous case — low extraction',
            '     confidence, edge case on issuer accreditation, expiry',
            '     imminent but not yet past.',
            '',
            '4. RISK — compute a risk contribution score 0-100 for this',
            '   single document. Critical-severity rule failing = 80-100,',
            '   High = 50-79, Medium = 25-49, Low = 5-24, Compliant = 0.',
            '',
            '5. REMEDIATION — if non-compliant or needs review, give a SINGLE',
            '   plain-English instruction telling the supplier what to do.',
            '   Cite the source regulation if helpful.',
            '',
            '════════════════════════════════════════════════════════════════',
            'OUTPUT FORMAT — return ONLY this JSON, no markdown fences',
            '════════════════════════════════════════════════════════════════',
            '{',
            '  "extracted_fields": {',
            '    "document_type":      { "value": "string or null", "confidence": 0.0 },',
            '    "issuer":             { "value": "string or null", "confidence": 0.0 },',
            '    "issue_date":         { "value": "YYYY-MM-DD or null", "confidence": 0.0 },',
            '    "expiry_date":        { "value": "YYYY-MM-DD or null", "confidence": 0.0 },',
            '    "certificate_number": { "value": "string or null", "confidence": 0.0 },',
            '    "subject_company":    { "value": "string or null", "confidence": 0.0 },',
            '    "scope":              { "value": "string or null", "confidence": 0.0 },',
            '    "<any_extra_identifier>": { "value": "string or null", "confidence": 0.0 }',
            '  },',
            '  "validation": {',
            '    "verdict":               "Valid | Invalid | Needs Human Review",',
            '    "reasoning":             "2-3 sentence explanation as a SINGLE STRING",',
            '    "issues":                ["specific issue 1", "specific issue 2"],',
            '    "document_type_matches": true,',
            '    "company_name_matches":  true,',
            '    "dates_coherent":        true,',
            '    "issuer_accredited":     true,',
            '    "authenticity_concerns": ["concern 1", "concern 2"]',
            '  },',
            '  "compliance": {',
            '    "status":              "Compliant | Non-Compliant | Needs Human Review",',
            '    "reason_code":         "Missing Document | Expired | Rule Not Met | Other",',
            '    "reason_detail":       "specific explanation tied to ' + ruleLabel + ' as a SINGLE STRING",',
            '    "regulation_citation": "string or null"',
            '  },',
            '  "risk_contribution": 0,',
            '  "remediation":       "single plain-English instruction as a SINGLE STRING, or null if Compliant",',
            '  "overall_confidence": 0.0',
            '}',
            '',
            '════════════════════════════════════════════════════════════════',
            'CRITICAL RULES — read these carefully',
            '════════════════════════════════════════════════════════════════',
            '- Return ONLY the JSON object. No markdown fences. No prose before or after.',
            '- extracted_fields: include ALL named fields above. ALSO add any additional',
            '  identifiers or compliance-relevant values present in the document using',
            '  snake_case keys (e.g. "database_number", "registration_number",',
            '  "scheme_code", "accreditation_body", "signature_count",',
            '  "has_official_stamp"). Do NOT omit any value that could help verify',
            '  authenticity against an external registry. Each extra field must use the',
            '  same { "value": "...", "confidence": 0.0 } format.',
            '- ALL string fields must be single strings, NEVER arrays.',
            '  Specifically: reasoning, reason_detail, remediation, regulation_citation,',
            '  verdict, status, reason_code, and every "value" field MUST be strings.',
            '- Arrays only for: "issues" and "authenticity_concerns".',
            '- NEVER include: SSN, EIN, tax IDs, bank accounts, routing numbers.',
            '  If you see such values, replace with "[REDACTED]".',
            '- If a value is absent, set it to null with confidence 0.0.',
            '- Be objective. Do not assume validity. Flag every concern explicitly.'
        }, '\n');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Summary — extracts top-level fields the Apex write needs
    //
    // The dashboard reads Raw_Response__c directly for the full reasoning.
    // We only pull out what's needed RIGHT NOW for the immediate DML.
    // ═════════════════════════════════════════════════════════════════════════
    @TestVisible
    public class ExtractionSummary {
        public String  cleanJson;
        public Decimal overallConfidence = 0.0;
        public String  detectedDocumentType;
        public String  validationVerdict;
        public String  complianceStatus;
        public String  reasonCode;
        public String  reasonDetail;
        public Decimal riskContribution = 0;
        public Integer fieldCount = 0;
    }

    @TestVisible
    private ExtractionSummary summarise(String rawJson) {
        ExtractionSummary s = new ExtractionSummary();

        if (String.isBlank(rawJson)) {
            s.cleanJson = '{}';
            return s;
        }

        // Strip markdown fences if the model included them despite instructions
        String cleaned = rawJson
            .replaceAll('```json', '')
            .replaceAll('```', '')
            .trim();
        s.cleanJson = cleaned;

        try {
            Map<String, Object> root =
                (Map<String, Object>) JSON.deserializeUntyped(cleaned);

            // ── Top-level overall_confidence (preferred)
            Object oc = root.get('overall_confidence');
            if (oc != null) {
                try {
                    s.overallConfidence = Decimal.valueOf(String.valueOf(oc))
                        .setScale(2, System.RoundingMode.HALF_UP);
                } catch (Exception ignored) {}
            }

            // ── extracted_fields.document_type.value → detectedDocumentType
            //    Mean field confidence as fallback when overall_confidence missing
            Object ef = root.get('extracted_fields');
            if (ef instanceof Map<String, Object>) {
                Map<String, Object> fields = (Map<String, Object>) ef;

                Decimal sumConf = 0; Integer count = 0;
                for (String key : fields.keySet()) {
                    Object val = fields.get(key);
                    if (!(val instanceof Map<String, Object>)) continue;
                    Map<String, Object> fieldObj = (Map<String, Object>) val;
                    s.fieldCount++;

                    Object conf = fieldObj.get('confidence');
                    if (conf != null) {
                        try {
                            sumConf += Decimal.valueOf(String.valueOf(conf));
                            count++;
                        } catch (Exception ignored) {}
                    }
                    if (key == 'document_type') {
                        Object dtVal = fieldObj.get('value');
                        if (dtVal != null) s.detectedDocumentType = String.valueOf(dtVal);
                    }
                }

                if (s.overallConfidence == 0.0 && count > 0) {
                    s.overallConfidence = (sumConf / count)
                        .setScale(2, System.RoundingMode.HALF_UP);
                }
            }

            // ── validation.verdict
            Object vRaw = root.get('validation');
            if (vRaw instanceof Map<String, Object>) {
                Map<String, Object> v = (Map<String, Object>) vRaw;
                s.validationVerdict = coerceString(v.get('verdict'));
            }

            // ── compliance.{status, reason_code, reason_detail}
            Object cRaw = root.get('compliance');
            if (cRaw instanceof Map<String, Object>) {
                Map<String, Object> c = (Map<String, Object>) cRaw;
                s.complianceStatus = coerceString(c.get('status'));
                s.reasonCode       = coerceString(c.get('reason_code'));
                s.reasonDetail     = coerceString(c.get('reason_detail'));
            }

            // ── risk_contribution
            Object rc = root.get('risk_contribution');
            if (rc != null) {
                try { s.riskContribution = Decimal.valueOf(String.valueOf(rc)); }
                catch (Exception ignored) {}
            }

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                '[AIExtractionQueueable.summarise] Parse failed: ' + e.getMessage()
                + ' | First 500 chars: ' + cleaned.left(500));
            s.cleanJson = '{"_parseError":"' + e.getMessage().replace('"', '\\"') + '"}';
        }

        return s;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Azure OpenAI callout — sends the actual file bytes
    // ═════════════════════════════════════════════════════════════════════════
    @TestVisible
    private String callAzureOpenAI(String base64Body, ContentVersion cv, String prompt) {
        String fileType = cv.FileType != null ? cv.FileType.toLowerCase() : '';
        String fileName = cv.Title != null ? cv.Title : 'document';
        if (cv.FileExtension != null && !fileName.endsWithIgnoreCase('.' + cv.FileExtension)) {
            fileName = fileName + '.' + cv.FileExtension;
        }

        List<Object> userContent = new List<Object>{
            new Map<String, Object>{ 'type' => 'text', 'text' => prompt }
        };

        if (isImageFile(fileType)) {
            userContent.add(new Map<String, Object>{
                'type'      => 'image_url',
                'image_url' => new Map<String, Object>{
                    'url' => 'data:' + imageMediaType(fileType) + ';base64,' + base64Body
                }
            });
        } else {
            // PDFs and other documents — Azure OpenAI native file content type
            userContent.add(new Map<String, Object>{
                'type' => 'file',
                'file' => new Map<String, Object>{
                    'filename'  => fileName,
                    'file_data' => 'data:' + documentMediaType(fileType) + ';base64,' + base64Body
                }
            });
        }

        Map<String, Object> body = new Map<String, Object>{
            'model'       => AI_MODEL_NAME,
            'max_tokens'  => AI_MAX_TOKENS,
            'temperature' => 0.0,
            'messages'    => new List<Object>{
                new Map<String, Object>{
                    'role'    => 'system',
                    'content' => 'You are an expert compliance document analyst. '
                              +  'Return only valid JSON matching the structure specified by the user. '
                              +  'Every string field must be a single string. Arrays only where explicitly allowed.'
                },
                new Map<String, Object>{
                    'role'    => 'user',
                    'content' => userContent
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

        if (res.getStatusCode() == 429) {
            throw new RateLimitException(
                'Azure OpenAI returned HTTP 429: ' + res.getBody().left(500)
            );
        }
        if (res.getStatusCode() != 200) {
            throw new AIExtractionException(
                'Azure OpenAI returned HTTP ' + res.getStatusCode()
                + ': ' + res.getBody().left(1000)
            );
        }

        Map<String, Object> parsed =
            (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> choices = (List<Object>) parsed.get('choices');
        if (choices == null || choices.isEmpty()) {
            throw new AIExtractionException('No choices returned from Azure OpenAI');
        }
        Map<String, Object> choice  = (Map<String, Object>) choices[0];
        Map<String, Object> message = (Map<String, Object>) choice.get('message');
        return (String) message.get('content');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Database loads
    // ═════════════════════════════════════════════════════════════════════════

    private Compliance_Document__c loadComplianceDocument() {
        List<Compliance_Document__c> docs = [
            SELECT  Id, Document_Type__c, Account__c, Status__c
            FROM    Compliance_Document__c
            WHERE   Id = :complianceDocId
            LIMIT   1
        ];
        return docs.isEmpty() ? null : docs[0];
    }

    private ContentVersion loadContentVersion() {
        List<ContentVersion> versions = [
            SELECT  Id, Title, FileType, FileExtension, ContentSize, VersionData
            FROM    ContentVersion
            WHERE   Id      = :contentVersionId
            AND     IsLatest = true
            LIMIT   1
        ];
        return versions.isEmpty() ? null : versions[0];
    }

    /**
     * Load the supplier Account so the prompt can do company-name cross-checks.
     * Null-safe — returns null if supplierId is blank.
     */
    @TestVisible
    private Account loadSupplier(Id accountId) {
        if (accountId == null) return null;
        List<Account> accts = [
            SELECT Id, Name, Industry__c, Vendor_Type__c,
                   BillingCountry, BillingState
            FROM   Account
            WHERE  Id = :accountId
            LIMIT  1
        ];
        return accts.isEmpty() ? null : accts[0];
    }

    /**
     * Resolve a Compliance_Requirement__mdt by DeveloperName.
     * documentTypeHint on the Platform Event is the CMT DeveloperName
     * (e.g. "RULE_A_001"). Returns null if no match — the prompt then
     * falls back to generic guidance.
     */
    @TestVisible
    private Compliance_Requirement__mdt lookupRule(String key) {
        if (String.isBlank(key)) return null;
        try {
            return Compliance_Requirement__mdt.getInstance(key);
        } catch (Exception e) {
            return null;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Map the AI's validation verdict to a Compliance_Document__c.Status__c.
     * Falls back to confidence threshold if no verdict returned.
     */
    @TestVisible
    private String resolveDocStatus(ExtractionSummary summary) {
        if (summary.validationVerdict == 'Valid')              return 'Validated';
        if (summary.validationVerdict == 'Invalid')            return 'Rejected';
        if (summary.validationVerdict == 'Needs Human Review') return 'Pending';
        return summary.overallConfidence >= AI_CONFIDENCE_THRESHOLD
            ? 'Validated' : 'Pending';
    }

    /** Convert a JSON value that might be String / List / Map to a single string. */
    @TestVisible
    private static String coerceString(Object val) {
        if (val == null) return null;
        if (val instanceof String) return (String) val;
        if (val instanceof List<Object>) {
            List<String> parts = new List<String>();
            for (Object o : (List<Object>) val) if (o != null) parts.add(String.valueOf(o));
            return String.join(parts, '\n');
        }
        return String.valueOf(val);
    }

    private Boolean isImageFile(String fileType) {
        return new Set<String>{ 'png', 'jpg', 'jpeg', 'tiff', 'tif', 'gif', 'webp' }
            .contains(fileType);
    }

    private String imageMediaType(String fileType) {
        Map<String, String> mime = new Map<String, String>{
            'png'  => 'image/png',
            'jpg'  => 'image/jpeg', 'jpeg' => 'image/jpeg',
            'tiff' => 'image/tiff', 'tif'  => 'image/tiff',
            'gif'  => 'image/gif',  'webp' => 'image/webp'
        };
        return mime.containsKey(fileType) ? mime.get(fileType) : 'image/jpeg';
    }

    private String documentMediaType(String fileType) {
        Map<String, String> mime = new Map<String, String>{
            'pdf'  => 'application/pdf',
            'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            'doc'  => 'application/msword',
            'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
            'txt'  => 'text/plain'
        };
        return mime.containsKey(fileType) ? mime.get(fileType) : 'application/pdf';
    }

    private void recordExtractionFailure(String errorMessage) {
        try {
            update new Compliance_Document__c(
                Id        = complianceDocId,
                Status__c = 'Pending',
                Notes__c  = ('AI extraction failed: ' + errorMessage).left(32768)
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                '[AIExtractionQueueable.recordExtractionFailure] Could not update doc: '
                + e.getMessage());
        }
    }

    public class AIExtractionException extends Exception {}
    public class RateLimitException    extends Exception {}
}