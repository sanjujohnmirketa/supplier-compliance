/**
 * AuthoritativeVerificationQueueable
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Chained from AIExtractionQueueable after successful extraction. Calls the
 * external authoritative registry (e.g. IATF Customer Portal), persists the
 * result back into Raw_Response__c, and overrides Compliance_Document__c
 * status if the registry contradicts the AI verdict.
 *
 * CHAIN POSITION
 * ──────────────
 *   AIExtractionQueueable           → 1 LLM call · extract + validate
 *     → AuthoritativeVerificationQueueable  (this class)
 *       → calls IATF / IAF / OFAC API
 *       → writes verification_result into Raw_Response__c
 *       → IF registry says Cancelled/Expired/NotFound: downgrades doc status
 *     → ComplianceEvaluationQueueable  · supplier-wide rollup
 *
 * ERROR ISOLATION
 * ───────────────
 * If the registry API is down or returns an error, this Queueable logs the
 * failure but does NOT throw — the next queueable in the chain
 * (ComplianceEvaluationQueueable) still runs against the AI verdict alone.
 * Manual verification remains available via the verification_guidance block.
 */
public class AuthoritativeVerificationQueueable
    implements Queueable, Database.AllowsCallouts {

    private final Id complianceDocId;
    private final Id supplierId;

    public AuthoritativeVerificationQueueable(Id complianceDocId, Id supplierId) {
        this.complianceDocId = complianceDocId;
        this.supplierId      = supplierId;
    }

    public void execute(QueueableContext ctx) {
        System.debug(LoggingLevel.INFO,
            '[AuthoritativeVerificationQueueable] Starting for ComplianceDoc='
            + complianceDocId + ' Job=' + ctx.getJobId());

        try {
            // ── 1. Call the registry ──────────────────────────────────────
            AuthoritativeVerificationService.VerificationResult result =
                AuthoritativeVerificationService.verifyDocument(complianceDocId);

            // ── 2. Persist back to Raw_Response__c as verification_result block
            persistResult(result);

            // ── 3. Override document status if registry contradicts AI ────
            if (result.outcome == AuthoritativeVerificationService.OUTCOME_INVALID
                    || result.outcome == AuthoritativeVerificationService.OUTCOME_NOT_FOUND) {
                downgradeDocumentStatus(result);
            }

            System.debug(LoggingLevel.INFO,
                '[AuthoritativeVerificationQueueable] Outcome=' + result.outcome
                + ' RegistryStatus=' + result.registryStatus
                + ' Discrepancies=' + result.discrepancies.size());

        } catch (Exception e) {
            // Never throw — extraction has already succeeded, this is enrichment
            System.debug(LoggingLevel.ERROR,
                '[AuthoritativeVerificationQueueable] Exception (non-fatal): '
                + e.getMessage() + '\n' + e.getStackTraceString());
        } finally {
            // ── 4. Chain compliance evaluation regardless of verification outcome
            //     Skip in test context — test class can enqueue separately
            if (!Test.isRunningTest() && supplierId != null) {
                System.enqueueJob(new ComplianceEvaluationQueueable(supplierId));
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Persist verification result into Raw_Response__c
    // ═════════════════════════════════════════════════════════════════════════
    private void persistResult(
        AuthoritativeVerificationService.VerificationResult result
    ) {
        Document_Extraction__c ext = loadLatestExtraction();
        if (ext == null) {
            System.debug(LoggingLevel.WARN,
                '[AuthoritativeVerificationQueueable] No extraction to update');
            return;
        }

        // Parse existing JSON, append verification_result block
        Map<String, Object> root;
        try {
            String cleaned = (ext.Raw_Response__c == null ? '{}'
                : ext.Raw_Response__c.replaceAll('```json', '').replaceAll('```', '').trim());
            root = (Map<String, Object>) JSON.deserializeUntyped(cleaned);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                '[AuthoritativeVerificationQueueable] Raw_Response__c not parseable, '
                + 'creating new envelope: ' + e.getMessage());
            root = new Map<String, Object>();
        }

        Map<String, Object> block = new Map<String, Object>{
            'outcome'           => result.outcome,
            'authority'         => result.authority,
            'verified_at'       => result.verifiedAt != null
                ? result.verifiedAt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
                : null,
            'registry_status'   => result.registryStatus,
            'is_currently_valid' => result.isCurrentlyValid,
            'registry_match'    => result.registryMatch,
            'discrepancies'     => result.discrepancies,
            'verdict_impact'    => result.verdictImpact,
            'error_detail'      => result.errorDetail
        };
        root.put('verification_result', block);

        update new Document_Extraction__c(
            Id              = ext.Id,
            Raw_Response__c = JSON.serialize(root).left(131072)
        );
    }

    /**
     * When the registry contradicts the AI verdict, the registry wins.
     * Override Compliance_Document__c.Status__c to Rejected and add a note.
     */
    private void downgradeDocumentStatus(
        AuthoritativeVerificationService.VerificationResult result
    ) {
        List<Compliance_Document__c> docs = [
            SELECT Id, Status__c, Notes__c
            FROM   Compliance_Document__c
            WHERE  Id = :complianceDocId
            LIMIT  1
        ];
        if (docs.isEmpty()) return;
        Compliance_Document__c doc = docs[0];

        String newNote = '[Registry Override] ' + result.verdictImpact;
        String combinedNotes = String.isNotBlank(doc.Notes__c)
            ? (doc.Notes__c + '\n\n' + newNote)
            : newNote;

        update new Compliance_Document__c(
            Id        = complianceDocId,
            Status__c = 'Rejected',
            Notes__c  = combinedNotes.left(32768)
        );
    }

    private Document_Extraction__c loadLatestExtraction() {
        List<Document_Extraction__c> ext = [
            SELECT Id, Raw_Response__c
            FROM   Document_Extraction__c
            WHERE  Compliance_Document__c = :complianceDocId
            ORDER  BY Extraction_DateTime__c DESC
            LIMIT  1
        ];
        return ext.isEmpty() ? null : ext[0];
    }
}