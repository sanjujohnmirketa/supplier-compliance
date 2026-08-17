/**
 * PolicyIngestQueueable
 * ═══════════════════════════════════════════════════════════════════════════
 * Enqueued directly by PolicyDocumentController.startIngestion() once a policy
 * file finishes uploading (no Platform Event hop — that pattern was already
 * tried for document uploads and abandoned as unreliable; see
 * DocumentProcessingController.cls's comment on Document_Uploaded__e).
 *
 * ASYNC two-phase design: the engine's /policy/ingest no longer blocks on the
 * actual parse/chunk/embed work (a 40-100 page PDF can exceed Salesforce's
 * 120s hard callout ceiling) — it returns a jobId immediately. So this class
 * has two roles depending on how it's constructed:
 *
 *   1. SUBMIT (policyDocumentId + contentVersionId set): loads the file,
 *      POSTs /policy/ingest, writes Ingest_Job_Id__c + Status__c='Processing',
 *      then chains a POLL run of itself.
 *   2. POLL (policyDocumentId + jobId set): GETs /policy/ingest/status/{jobId}.
 *      If still queued/processing, re-chains itself per pollDelayMinutesFor()'s
 *      graduated backoff (fast at first, since most documents finish in well
 *      under a second; slower for a genuinely long-running large document).
 *      If done/failed, writes the final Policy_Document__c fields and stops.
 *
 * Chain depth: Developer Edition orgs cap chained Queueable depth at 5 by
 * default, which a slow (large-PDF) ingest could exceed — this uses the
 * AsyncOptions overload of System.enqueueJob to explicitly raise the ceiling
 * for THIS chain (MaximumQueueableStackDepth) alongside the per-poll delay
 * (MinimumQueueableDelayInMinutes).
 *
 * Callout-then-DML ordering preserved in both phases: callout -> DML.
 */
public without sharing class PolicyIngestQueueable
        implements Queueable, Database.AllowsCallouts {

    // Generous enough for even a slow large-document embed while still
    // bounded — a job that hasn't finished by MAX_STACK_DEPTH polls is
    // treated as hung rather than polled forever.
    private static final Integer MAX_STACK_DEPTH = 30;

    // How many synchronous status checks to make inline in submitPhase()
    // before falling back to the async poll chain. Each is a real HTTP
    // callout (counts against the 100-callout-per-transaction governor
    // limit, and submit() + checkStatus() already use 1 each), so this stays
    // well under that ceiling — 5 is generous for a fast engine response
    // while keeping the whole inline loop itself fast if the engine is
    // genuinely slow (no artificial delay between attempts; a callout
    // round-trip is itself the only pacing).
    private static final Integer INLINE_CHECK_ATTEMPTS = 5;

    // How many times to re-try the SAME poll attempt after a transient
    // status-check failure before actually marking the document Failed.
    // Confirmed live (2026-08-13): PolicyIngestService.checkStatus() can
    // return HTTP 200 with an empty/malformed body on a transient blip — that
    // raises a JSONException, not a CalloutException, so it slips past
    // checkStatus()'s own retry-once-on-CalloutException logic entirely. One
    // bad status check used to permanently fail a document whose ingest had
    // ALREADY SUCCEEDED on the engine side — the poll couldn't tell "the job
    // failed" apart from "I failed to ask whether it failed." This gives a
    // transient blip one more chance before treating it as real.
    private static final Integer STATUS_CHECK_RETRIES = 1;

    // Graduated backoff instead of a flat delay: most real uploads (a small
    // .txt/.md, or even a modest PDF) finish in under a second on the engine
    // side — a fixed 1-minute-per-poll cadence was making EVERY document sit
    // on "Processing" for up to 60s doing nothing, even ones already done.
    // Poll fast at first (0min = next platform cycle, effectively a few
    // seconds), then back off for genuinely slow (large-PDF) documents so a
    // long-running job doesn't hammer the status endpoint every few seconds
    // for 10+ minutes straight.
    private static Integer pollDelayMinutesFor(Integer attempt) {
        if (attempt <= 3)  return 0;   // first ~4 polls: as fast as the platform allows
        if (attempt <= 8)  return 1;   // then back off to 1/minute
        return 2;                       // long-tail (large documents): every 2 minutes
    }

    private final Id policyDocumentId;
    private final Id contentVersionId;   // set only on the initial SUBMIT run
    private final String jobId;          // set only on POLL runs
    private final Integer pollAttempt;
    private final Integer statusCheckRetriesLeft;

    // Initial submit constructor.
    public PolicyIngestQueueable(Id policyDocumentId, Id contentVersionId) {
        this.policyDocumentId = policyDocumentId;
        this.contentVersionId = contentVersionId;
        this.jobId = null;
        this.pollAttempt = 0;
        this.statusCheckRetriesLeft = 0;
    }

    // Poll-chain constructor. statusCheckRetriesLeft resets to
    // STATUS_CHECK_RETRIES on every NEW poll attempt (real progress) and is
    // consumed only when re-trying the SAME pollAttempt after a transient
    // status-check failure — see pollPhase()'s catch block.
    private PolicyIngestQueueable(Id policyDocumentId, String jobId, Integer pollAttempt) {
        this(policyDocumentId, jobId, pollAttempt, STATUS_CHECK_RETRIES);
    }

    private PolicyIngestQueueable(Id policyDocumentId, String jobId, Integer pollAttempt, Integer statusCheckRetriesLeft) {
        this.policyDocumentId = policyDocumentId;
        this.contentVersionId = null;
        this.jobId = jobId;
        this.pollAttempt = pollAttempt;
        this.statusCheckRetriesLeft = statusCheckRetriesLeft;
    }

    public void execute(QueueableContext ctx) {
        if (jobId == null) {
            submitPhase();
        } else {
            pollPhase();
        }
    }

    private void submitPhase() {
        Policy_Document__c pd = [
            SELECT Id, Name, Domain__c
            FROM   Policy_Document__c
            WHERE  Id = :policyDocumentId
            LIMIT  1
        ];
        ContentVersion cv = [
            SELECT Title, PathOnClient, VersionData
            FROM   ContentVersion
            WHERE  Id = :contentVersionId
            LIMIT  1
        ];

        String fileName = String.isNotBlank(cv.PathOnClient) ? cv.PathOnClient : cv.Title;

        PolicyIngestService.IngestRequest req = new PolicyIngestService.IngestRequest();
        req.fileName = fileName;
        req.documentBase64 = EncodingUtil.base64Encode(cv.VersionData);
        req.domainHint = pd.Domain__c;   // 'Auto-Detect' or an explicit domain override

        try {
            PolicyIngestService.IngestSubmitResponse resp = PolicyIngestService.submit(req);
            update new Policy_Document__c(
                Id               = policyDocumentId,
                Status__c        = 'Processing',
                Ingest_Job_Id__c = resp.jobId
            );

            // Inline check loop, same transaction, NO poll hop consumed for
            // any of it. Confirmed live (2026-08-13): a .md/.txt/.docx-sized
            // document finishes parse+chunk+embed on the engine well within
            // /policy/ingest's own callout window. What actually caused
            // multi-minute "Processing" waits was NOT engine speed — it was
            // Salesforce's own async Apex QUEUE being congested (Developer
            // Edition's concurrent-job allocation is small; heavy same-day
            // test/upload volume competes for the same slots), so each
            // Queueable hop could sit for 30-60s just waiting for an
            // execution slot, even at a 0-minute requested delay. Every hop
            // this loop avoids is one less job competing for that scarce
            // resource. INLINE_CHECK_ATTEMPTS repeated synchronous callouts
            // (no Queueable re-enqueue between them) resolve almost every
            // real upload without ever touching the async queue at all.
            Boolean resolvedInline = false;
            for (Integer i = 0; i < INLINE_CHECK_ATTEMPTS; i++) {
                try {
                    if (applyStatus(PolicyIngestService.checkStatus(resp.jobId))) {
                        resolvedInline = true;
                        break;
                    }
                } catch (Exception inlineCheckEx) {
                    System.debug(LoggingLevel.WARN,
                        '[PolicyIngestQueueable] inline status check ' + (i + 1) + '/' + INLINE_CHECK_ATTEMPTS
                        + ' failed for ' + resp.jobId + ': ' + inlineCheckEx.getMessage());
                    // keep looping — a transient blip on one inline attempt
                    // shouldn't burn the whole budget; only genuinely still
                    // "queued/processing" responses count toward giving up
                    // early below.
                }
            }
            if (resolvedInline) {
                return;   // resolved inline (done or failed) — the async queue was never touched
            }

            // Still genuinely processing after every inline attempt (a large
            // PDF, a slow embed, or the engine itself under load) — fall back
            // to the async poll chain, unchanged from before. The FIRST
            // enqueue in a chain sets MaximumQueueableStackDepth for the
            // whole chain — every subsequent link inherits it automatically
            // and is NOT allowed to set it again (see the isFirstHop=false
            // path in enqueuePoll below; the platform throws "Cannot reset
            // Maximum Queueable Stack Depth in a queueable" if you try).
            enqueuePoll(new PolicyIngestQueueable(policyDocumentId, resp.jobId, 2), pollDelayMinutesFor(2), true);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                '[PolicyIngestQueueable] /policy/ingest submit failed for ' + policyDocumentId + ': ' + e.getMessage());
            update new Policy_Document__c(
                Id                = policyDocumentId,
                Status__c         = 'Failed',
                Failure_Reason__c = e.getMessage().left(255)
            );
        }
    }

    private void pollPhase() {
        PolicyIngestService.IngestStatusResponse status;
        try {
            status = PolicyIngestService.checkStatus(jobId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                '[PolicyIngestQueueable] status check failed for job ' + jobId + ' (retries left: '
                + statusCheckRetriesLeft + '): ' + e.getMessage());
            if (statusCheckRetriesLeft > 0) {
                // Transient blip (e.g. a 200 with an empty/malformed body —
                // confirmed live) — re-try the SAME pollAttempt rather than
                // failing a document whose ingest may have already succeeded
                // on the engine side. Does not advance pollAttempt, so this
                // doesn't erode the real MAX_STACK_DEPTH budget.
                enqueuePoll(new PolicyIngestQueueable(
                    policyDocumentId, jobId, pollAttempt, statusCheckRetriesLeft - 1),
                    pollDelayMinutesFor(pollAttempt), false);
                return;
            }
            update new Policy_Document__c(
                Id                = policyDocumentId,
                Status__c         = 'Failed',
                Failure_Reason__c = ('Status check failed: ' + e.getMessage()).left(255),
                Ingest_Job_Id__c  = null
            );
            return;
        }

        if (applyStatus(status)) {
            return;   // reached a terminal state — no further poll needed
        }
        if (pollAttempt >= MAX_STACK_DEPTH) {
            update new Policy_Document__c(
                Id                = policyDocumentId,
                Status__c         = 'Failed',
                Failure_Reason__c = 'Ingestion is taking longer than expected. Please try again — if this keeps happening, the document may be too large or complex.',
                Ingest_Job_Id__c  = null
            );
            return;
        }
        Integer nextAttempt = pollAttempt + 1;
        // isFirstHop=false: the stack depth was already set on the chain's
        // first enqueue (submitPhase) — setting it again here throws
        // "Cannot reset Maximum Queueable Stack Depth in a queueable"
        // (confirmed live — every re-poll was failing with this exact error,
        // silently stalling every in-flight ingest).
        enqueuePoll(new PolicyIngestQueueable(policyDocumentId, jobId, nextAttempt), pollDelayMinutesFor(nextAttempt), false);
    }

    // Shared by submitPhase()'s inline first check and pollPhase(): writes
    // the Policy_Document__c record when the engine status is a TERMINAL
    // state (done/failed). Deliberately does NOT decide whether to poll
    // again or what isFirstHop should be — that differs between the two
    // callers (submitPhase has no chain yet; pollPhase is already mid-chain)
    // and mixing that decision in here previously caused a double-enqueue
    // bug (both this helper AND its caller tried to start a chain, tripping
    // "Cannot reset Maximum Queueable Stack Depth" on the second attempt —
    // caught in review before deploy).
    // Returns true if the status was terminal (record written, caller should
    // stop) — false if the engine is still queued/processing (caller decides
    // how to continue).
    private Boolean applyStatus(PolicyIngestService.IngestStatusResponse status) {
        if (status.status == 'done') {
            update new Policy_Document__c(
                Id                = policyDocumentId,
                Status__c         = 'Ingested',
                Domain__c         = status.domain,
                Chunk_Count__c    = status.chunkCount,
                Corpus_Version__c = status.version,
                Ingested_Date__c  = DateTime.now(),
                Ingest_Job_Id__c  = null
            );
            return true;
        }
        if (status.status == 'failed') {
            update new Policy_Document__c(
                Id                = policyDocumentId,
                Status__c         = 'Failed',
                Failure_Reason__c = (status.error != null ? status.error : 'Ingestion failed').left(255),
                Ingest_Job_Id__c  = null
            );
            return true;
        }
        return false;   // still queued/processing
    }

    // Wraps System.enqueueJob. isFirstHop controls whether AsyncOptions sets
    // MaximumQueueableStackDepth: that option is establish-once-per-chain —
    // the platform rejects any attempt to set it again on a later link in the
    // same chain. MinimumQueueableDelayInMinutes, by contrast, is set fresh
    // on every hop (each poll wants its own graduated-backoff delay).
    private void enqueuePoll(PolicyIngestQueueable next, Integer delayMinutes, Boolean isFirstHop) {
        AsyncOptions opts = new AsyncOptions();
        if (isFirstHop) {
            opts.MaximumQueueableStackDepth = MAX_STACK_DEPTH;
        }
        opts.MinimumQueueableDelayInMinutes = delayMinutes;
        System.enqueueJob(next, opts);
    }
}