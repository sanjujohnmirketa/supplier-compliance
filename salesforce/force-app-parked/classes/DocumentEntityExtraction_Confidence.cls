public class DocumentEntityExtraction_Confidence {

    private static final String MODEL       = 'prebuilt-layout';
    private static final String API_VERSION = '2024-11-30';

    // ----------------------------------------------------------------
    // Entry point from Flow
    // ----------------------------------------------------------------
    @InvocableMethod(label='Call Azure Document Intelligence')
    public static void callDocumentIntelligence(List<Id> complianceDocumentIds) {
        List<ContentVersion> versions = [
            SELECT Id, Title, VersionData
            FROM ContentVersion
            WHERE Id IN :complianceDocumentIds
        ];
        for (ContentVersion cv : versions) {
            System.enqueueJob(new SubmitJob(cv.Id, cv.VersionData));
        }
    }

    // ----------------------------------------------------------------
    // Step 1 — POST the PDF, capture Operation-Location, hand off to PollJob
    // ----------------------------------------------------------------
    public class SubmitJob implements Queueable, Database.AllowsCallouts {
        private final Id contentVersionId;
        private final Blob pdfBlob;

        public SubmitJob(Id contentVersionId, Blob pdfBlob) {
            this.contentVersionId = contentVersionId;
            this.pdfBlob = pdfBlob;
        }

        public void execute(QueueableContext ctx) {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(
                'callout:AzureDocIntelCredentials' +
                '/documentintelligence/documentModels/' +
                MODEL + ':analyze' +
                '?api-version=' + API_VERSION +
                '&features=keyValuePairs'
            );
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/pdf');
            req.setBodyAsBlob(pdfBlob);
            req.setTimeout(120000);

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 202) {
                System.debug(LoggingLevel.ERROR,
                    'DI submit failed: ' + res.getStatusCode() + ' ' + res.getBody());
                return;
            }

            String operationLocation = res.getHeader('Operation-Location');
            System.debug('DI accepted. Operation-Location: ' + operationLocation);

            // First poll goes through Queueable directly; subsequent polls trampoline.
            System.enqueueJob(new PollJob(contentVersionId, operationLocation, 0));
        }
    }

    // ----------------------------------------------------------------
    // Step 2 — Poll Operation-Location until succeeded / failed / timed out
    // ----------------------------------------------------------------
    public class PollJob implements Queueable, Database.AllowsCallouts {
        private final Id contentVersionId;
        private final String operationLocation;
        private final Integer attempt;
        private final Integer MAX_ATTEMPTS = 10;   // ~10 minutes at 1-min spacing

        public PollJob(Id contentVersionId, String operationLocation, Integer attempt) {
            this.contentVersionId = contentVersionId;
            this.operationLocation = operationLocation;
            this.attempt = attempt;
        }

        public void execute(QueueableContext ctx) {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:AzureDocIntelCredentials' + stripHost(operationLocation));
            req.setMethod('GET');
            req.setTimeout(120000);

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                System.debug(LoggingLevel.ERROR,
                    'DI poll failed: ' + res.getStatusCode() + ' ' + res.getBody());
                return;
            }

            // --- RAW JSON DEBUG ---------------------------------------
            String rawBody = res.getBody();
            System.debug('===== DI RAW JSON (attempt ' + (attempt + 1) + ') =====');
            System.debug(rawBody);
            System.debug('===== END DI RAW JSON =====');
            // -----------------------------------------------------------

            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(rawBody);
            String status = (String) body.get('status');
            System.debug('DI poll attempt ' + (attempt + 1) + ' status=' + status);

            if (status == 'succeeded') {
                handleResult(body, rawBody);
                return;
            }
            if (status == 'failed') {
                System.debug(LoggingLevel.ERROR, 'DI analysis failed: ' + rawBody);
                return;
            }
            if (attempt + 1 >= MAX_ATTEMPTS) {
                System.debug(LoggingLevel.ERROR, 'DI poll timed out after ' + MAX_ATTEMPTS + ' attempts.');
                return;
            }

            // Break the Queueable chain: schedule a trampoline 1 minute out,
            // which will re-enqueue PollJob in a fresh chain (no stack-depth cap).
            Datetime runAt = Datetime.now().addMinutes(1);
            String cron = '' + runAt.second() + ' ' + runAt.minute() + ' '
                          + runAt.hour() + ' ' + runAt.day() + ' '
                          + runAt.month() + ' ? ' + runAt.year();
            String jobName = 'DI_Poll_' + contentVersionId + '_' + (attempt + 1)
                             + '_' + System.currentTimeMillis();
            System.schedule(
                jobName,
                cron,
                new PollTrampoline(contentVersionId, operationLocation, attempt + 1)
            );
        }

        private String stripHost(String absoluteUrl) {
            Integer idx = absoluteUrl.indexOf('/', 8); // skip past "https://"
            return absoluteUrl.substring(idx);
        }

        private void handleResult(Map<String, Object> body, String rawBody) {
            // Full raw payload once we have the final answer — useful for mapping fields later.
            System.debug('===== DI FINAL RAW JSON =====');
            System.debug(rawBody);
            System.debug('===== END DI FINAL RAW JSON =====');

            Map<String, Object> analyzeResult = (Map<String, Object>) body.get('analyzeResult');
            if (analyzeResult == null) {
                System.debug(LoggingLevel.ERROR, 'analyzeResult missing in DI response.');
                return;
            }

            String content = (String) analyzeResult.get('content');
            System.debug('DI content (first 600): ' +
                (content != null ? content.left(Math.min(600, content.length())) : '(empty)'));

            List<Object> kvPairs = (List<Object>) analyzeResult.get('keyValuePairs');
            if (kvPairs != null) {
                for (Object o : kvPairs) {
                    Map<String, Object> kv = (Map<String, Object>) o;
                    Map<String, Object> k = (Map<String, Object>) kv.get('key');
                    Map<String, Object> v = (Map<String, Object>) kv.get('value');
                    System.debug('KV: ' +
                        (k != null ? k.get('content') : '') + ' = ' +
                        (v != null ? v.get('content') : '') +
                        ' (conf ' + kv.get('confidence') + ')');
                }
            }
            // TODO: insert/update Document_Extraction__c for contentVersionId once field list is known.
        }
    }

    // ----------------------------------------------------------------
    // Trampoline — fires once, immediately re-enqueues PollJob in a fresh chain
    // (gets us past the DE/Trial 5-deep Queueable chain limit)
    // ----------------------------------------------------------------
    public class PollTrampoline implements Schedulable {
        private final Id contentVersionId;
        private final String operationLocation;
        private final Integer attempt;

        public PollTrampoline(Id contentVersionId, String operationLocation, Integer attempt) {
            this.contentVersionId = contentVersionId;
            this.operationLocation = operationLocation;
            this.attempt = attempt;
        }

        public void execute(SchedulableContext sc) {
            try {
                System.enqueueJob(new PollJob(contentVersionId, operationLocation, attempt));
            } finally {
                // Clean up this one-shot scheduled job whether enqueue succeeded or not.
                System.abortJob(sc.getTriggerId());
            }
        }
    }
}