/**
 * EngineCalloutMock — one HttpCalloutMock for every engine route the Apex
 * calls (/scope, /verify, /assess, /copilot, /policy/ingest, /policy/ingest/
 * status/{id}, /policy/delete). Routes on the endpoint string, so a single
 * Test.setMock covers a test that fans out to several queueables.
 *
 * Knobs are static so a test can flip them before Test.startTest():
 *   statusCode    — non-200 makes EVERY route fail (exercises error branches)
 *   assessVerdict — 'Compliant' | 'Non-Compliant' | 'Needs Analyst'
 *   policyStatus  — 'done' | 'failed' | 'processing'
 */
@IsTest
public class EngineCalloutMock implements HttpCalloutMock {

    public static Integer statusCode    = 200;
    public static String  assessVerdict = 'Compliant';
    public static String  assessSeverity = 'Low';
    public static String  policyStatus  = 'done';
    public static String  scopeTier     = 'Medium';
    public static List<String> requests = new List<String>();

    public HttpResponse respond(HttpRequest req) {
        String ep = req.getEndpoint();
        requests.add(ep);
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');
        res.setStatusCode(statusCode);
        if (statusCode != 200) {
            res.setBody('{"detail":"engine error"}');
            return res;
        }
        if (ep.contains('/policy/ingest/status/')) {
            res.setBody(policyStatusBody());
        } else if (ep.contains('/policy/ingest')) {
            res.setBody('{"jobId":"job-test-1","status":"queued","fileName":"policy.md"}');
        } else if (ep.contains('/policy/delete')) {
            res.setBody('{"fileName":"policy.md","chunksDeleted":3}');
        } else if (ep.contains('/scope')) {
            res.setBody(scopeBody());
        } else if (ep.contains('/verify')) {
            res.setBody(verifyBody());
        } else if (ep.contains('/assess')) {
            res.setBody(assessBody());
        } else if (ep.contains('/copilot')) {
            res.setBody(copilotBody());
        } else {
            res.setBody('{}');
        }
        return res;
    }

    private static String scopeBody() {
        return JSON.serialize(new Map<String, Object>{
            'supplierId'    => 'PREVIEW',
            'riskTier'      => scopeTier,
            'riskSummary'   => 'Medium-risk manufacturing supplier in a regulated market.',
            'riskReasons'   => new List<Object>{ 'Cross-border shipments', 'Hazardous materials handled' },
            'notes'         => new List<Object>(),
            'noPolicyMatch' => false,
            'checklist'     => new List<Object>{
                new Map<String, Object>{ 'document' => 'Certificate of Insurance', 'domain' => 'finance',
                    'justificationClauseId' => 'POL-FIN-01', 'justification' => 'Liability cover required.' },
                new Map<String, Object>{ 'document' => 'ISO 9001 Certificate', 'domain' => 'quality',
                    'justificationClauseId' => 'POL-QUA-03', 'justification' => 'Quality management system required.' }
            }
        });
    }

    private static String verifyBody() {
        return JSON.serialize(new Map<String, Object>{
            'legalName' => 'Test Supplier',
            'signal'    => 'review',
            'results'   => new List<Object>{
                new Map<String, Object>{ 'authority' => 'GLEIF', 'category' => 'Financials',
                    'status' => 'Verified', 'summary' => 'LEI active' },
                new Map<String, Object>{ 'authority' => 'OpenSanctions', 'category' => 'Sanctions',
                    'status' => 'Clear', 'summary' => 'No matches' },
                new Map<String, Object>{ 'authority' => 'RMI', 'category' => 'Conflict Minerals',
                    'status' => 'NotConfigured', 'summary' => 'No public API' }
            }
        });
    }

    private static String assessBody() {
        Boolean bad = (assessVerdict == 'Non-Compliant');
        return JSON.serialize(new Map<String, Object>{
            'supplierId'      => 'x',
            'requirementKey'  => 'x__COI',
            'domain'          => 'finance',
            'verdict'         => assessVerdict,
            'severity'        => assessSeverity,
            'confidence'      => 88,
            'reasons'         => 'Assessment reasons.',
            'summary'         => new Map<String, Object>{
                'headline'      => bad ? 'Coverage below the required minimum.' : 'Document meets the policy.',
                'checks_passed' => new List<Object>{ 'Issuer identified', 'Document is current' },
                'concerns'      => bad ? new List<Object>{ 'Coverage amount is below 1M' } : new List<Object>()
            },
            'citations'       => new List<Object>{ 'POL-FIN-01 §2' },
            'model'           => 'gpt-4o',
            'extractionChars' => 1200,
            'extractedFields' => new Map<String, Object>{ 'issuer' => 'Acme Insurance', 'subject_company' => 'Test Supplier' },
            'keyDates'        => new Map<String, Object>{ 'expiry_date' => '2027-03-01', 'is_expired' => false, 'days_to_expiry' => 500 },
            'clauseChecks'    => new List<Object>{
                new Map<String, Object>{ 'requirement' => 'Coverage >= 1M', 'expected' => '1M', 'found' => bad ? '500k' : '2M', 'pass' => !bad },
                new Map<String, Object>{ 'requirement' => 'Named insured present', 'expected' => 'yes', 'found' => 'yes', 'pass' => true }
            },
            'registryValidation' => new Map<String, Object>{ 'authority' => 'GLEIF', 'method' => 'api',
                'status' => bad ? 'FAIL' : 'PASS', 'detail' => 'LEI lookup' }
        });
    }

    private static String copilotBody() {
        return JSON.serialize(new Map<String, Object>{
            'answer'            => 'The supplier has uploaded 1 of 2 required documents.',
            'verdict'           => 'Incomplete',
            'keyFindings'       => new List<Object>{ 'Insurance certificate present' },
            'blockers'          => new List<Object>{ 'ISO 9001 missing' },
            'recommendedAction' => 'Request the ISO certificate.',
            'nextStep'          => 'Email the supplier.',
            'citations'         => new List<Object>{ 'POL-QUA-03' }
        });
    }

    private static String policyStatusBody() {
        Map<String, Object> m = new Map<String, Object>{
            'jobId' => 'job-test-1', 'status' => policyStatus, 'fileName' => 'policy.md'
        };
        if (policyStatus == 'done') {
            m.put('domain', 'finance'); m.put('industry', 'Manufacturing');
            m.put('chunkCount', 12);    m.put('version', 'v3');
        }
        if (policyStatus == 'failed') m.put('error', 'bad parse');
        return JSON.serialize(m);
    }
}
