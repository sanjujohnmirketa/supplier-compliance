/**
 * CopilotService — HTTP client for the engine's grounded co-pilot Q&A (/copilot).
 * Same Named Credential + token + tunnel header as the other engine callouts.
 */
public with sharing class CopilotService {

    @TestVisible private static final String  NAMED_CRED = 'callout:Local_Compliance_Service';
    @TestVisible private static final Integer TIMEOUT_MS = 120000;

    public class CopilotResponse {
        @AuraEnabled public String       answer;
        @AuraEnabled public String       verdict;             // structured narrator fields
        @AuraEnabled public List<String> keyFindings;
        @AuraEnabled public List<String> blockers;
        @AuraEnabled public String       recommendedAction;
        @AuraEnabled public String       nextStep;            // role-aware next concrete action
        @AuraEnabled public List<String> citations;
    }

    public static CopilotResponse ask(String question, String supplierName, String context) {
        return ask(question, supplierName, context, null, null);
    }

    /** Role-aware, case-grounded ask. role drives the next-step recommendation;
     *  caseId grounds the answer in the live agent CaseState. */
    public static CopilotResponse ask(String question, String supplierName, String context,
                                      String role, String caseId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CRED + '/copilot');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('X-Tunnel-Skip-AntiPhishing-Page', 'true');
        req.setTimeout(TIMEOUT_MS);
        Map<String, Object> body = new Map<String, Object>{
            'question'     => question,
            'supplierName' => supplierName,
            'context'      => context
        };
        if (String.isNotBlank(role))   body.put('role', role);
        if (String.isNotBlank(caseId)) body.put('caseId', caseId);
        req.setBody(JSON.serialize(body));
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new CalloutException('Co-pilot returned HTTP ' + res.getStatusCode()
                + ': ' + res.getBody());
        }
        return (CopilotResponse) JSON.deserialize(res.getBody(), CopilotResponse.class);
    }
}