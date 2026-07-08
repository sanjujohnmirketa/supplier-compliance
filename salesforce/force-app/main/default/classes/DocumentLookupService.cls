/**
 * DocumentLookupService
 * ═══════════════════════════════════════════════════════════════════════════
 * Agent action: Find Documents For Supplier.
 * Lists Compliance_Document__c records for a supplier so the agent can
 * feed individual document IDs into the Validate Document action.
 *
 * Split from ComplianceLookupService because Apex allows only one
 * @InvocableMethod per class.
 */
public with sharing class DocumentLookupService {

    public class FindDocumentsRequest {
        @InvocableVariable(
            label='Supplier Name or Id'
            description='Either a supplier name (will be looked up) or a Salesforce Account ID. Required.'
            required=true
        )
        public String supplierNameOrId;

        @InvocableVariable(
            label='Document Type Filter'
            description='Optional. Restrict the result to documents of a specific type (e.g. "ISO 9001 Certificate", "Certificate of Insurance"). Leave blank to return all documents.'
        )
        public String documentTypeFilter;

        @InvocableVariable(
            label='Status Filter'
            description='Optional. Restrict the result by document status: Pending, Validated, or Rejected. Leave blank to return all statuses.'
        )
        public String statusFilter;
    }

    public class FindDocumentsResponse {
        @InvocableVariable(
            label='Document Count'
            description='Total number of documents found for this supplier matching the filters. 0 means none.'
        )
        public Integer documentCount;

        @InvocableVariable(
            label='Supplier Name'
            description='The full name of the supplier whose documents were searched.'
        )
        public String supplierName;

        @InvocableVariable(
            label='Documents'
            description='Numbered list of documents with ID, type, status, and upload date. Empty if no documents found. If exactly one document matches and the user asked for "the document" generically, use its ID directly. Otherwise present this list and ask the user to clarify.'
        )
        public String documents;

        @InvocableVariable(
            label='Single Document Id'
            description='If exactly one document matched the filters, this is its ID — safe to pass directly to Validate Document. Empty if zero or multiple documents matched.'
        )
        public String singleDocumentId;

        @InvocableVariable(
            label='Status Message'
            description='Plain-English status describing what was found. Always populated.'
        )
        public String statusMessage;
    }

    @InvocableMethod(
        label='Find Documents For Supplier'
        description='Lists compliance documents uploaded by a supplier. Use this when the user asks to validate or check documents for a supplier without specifying a document ID. Accepts either a supplier name or ID. Optionally filter by document type or status. Returns the document IDs needed by Validate Document.'
        category='Compliance'
    )
    public static List<FindDocumentsResponse> findDocumentsForSupplier(
        List<FindDocumentsRequest> requests
    ) {
        List<FindDocumentsResponse> results = new List<FindDocumentsResponse>();
        for (FindDocumentsRequest req : requests) {
            results.add(findOneDocumentSet(req));
        }
        return results;
    }

    private static FindDocumentsResponse findOneDocumentSet(FindDocumentsRequest req) {
        FindDocumentsResponse resp = new FindDocumentsResponse();
        resp.documentCount = 0;

        if (String.isBlank(req.supplierNameOrId)) {
            resp.statusMessage = 'No supplier name or ID provided.';
            return resp;
        }

        Id supplierId = resolveSupplierId(req.supplierNameOrId, resp);
        if (supplierId == null) return resp;

        String baseQuery = 'SELECT Id, Name, Document_Type__c, Status__c, '
            + 'CreatedDate, Expiry_Date__c, Issuer__c, Confidence_Score__c '
            + 'FROM Compliance_Document__c '
            + 'WHERE Account__c = :supplierId';

        if (String.isNotBlank(req.documentTypeFilter)) {
            baseQuery += ' AND Document_Type__c LIKE :typeLikePattern';
        }
        if (String.isNotBlank(req.statusFilter)) {
            baseQuery += ' AND Status__c = :statusValue';
        }
        baseQuery += ' ORDER BY CreatedDate DESC LIMIT 20';

        String typeLikePattern = '%' + String.valueOf(req.documentTypeFilter) + '%';
        String statusValue = req.statusFilter;

        List<Compliance_Document__c> docs;
        try {
            docs = Database.query(baseQuery);
        } catch (Exception e) {
            resp.statusMessage = 'Query failed: ' + e.getMessage();
            return resp;
        }

        resp.documentCount = docs.size();

        if (docs.isEmpty()) {
            resp.statusMessage = 'No documents found for supplier "' + resp.supplierName + '"'
                + (String.isNotBlank(req.documentTypeFilter)
                    ? ' of type "' + req.documentTypeFilter + '"' : '')
                + (String.isNotBlank(req.statusFilter)
                    ? ' with status "' + req.statusFilter + '"' : '')
                + '. The supplier may not have uploaded any documents yet.';
            return resp;
        }

        List<String> docLines = new List<String>();
        for (Integer i = 0; i < docs.size(); i++) {
            Compliance_Document__c d = docs[i];
            String line = (i + 1) + '. '
                + (String.isNotBlank(d.Document_Type__c) ? d.Document_Type__c : 'Unknown type')
                + ' — Status: ' + d.Status__c
                + (d.Expiry_Date__c != null ? ' — Expires: ' + d.Expiry_Date__c.format() : '')
                + (d.Issuer__c != null ? ' — Issuer: ' + d.Issuer__c : '')
                + ' [ID: ' + d.Id + ']';
            docLines.add(line);
        }
        resp.documents = String.join(docLines, '\n');

        if (docs.size() == 1) {
            resp.singleDocumentId = docs[0].Id;
            resp.statusMessage = 'Found 1 document for "' + resp.supplierName + '". '
                + 'Use the Single Document Id for the validation action.';
        } else {
            resp.statusMessage = 'Found ' + docs.size() + ' documents for "' + resp.supplierName
                + '". If the user wants to validate ALL of them, call Validate Document for each. '
                + 'If they want a specific one, ask which using the Documents list.';
        }

        return resp;
    }

    private static Id resolveSupplierId(String nameOrId, FindDocumentsResponse resp) {
        if (nameOrId.length() == 15 || nameOrId.length() == 18) {
            try {
                Id candidate = Id.valueOf(nameOrId);
                if (candidate.getSObjectType() == Account.SObjectType) {
                    List<Account> accts = [
                        SELECT Id, Name FROM Account WHERE Id = :candidate LIMIT 1
                    ];
                    if (!accts.isEmpty()) {
                        resp.supplierName = accts[0].Name;
                        return accts[0].Id;
                    }
                }
            } catch (Exception e) {}
        }

        ComplianceLookupService.FindSupplierResponse lookup =
            ComplianceLookupService.findOneSupplier(nameOrId);
        if (lookup.matchCount == 0) {
            resp.statusMessage = lookup.statusMessage;
            return null;
        }
        if (lookup.matchCount > 1) {
            resp.statusMessage = lookup.statusMessage + '\nCandidates:\n' + lookup.candidates;
            return null;
        }
        resp.supplierName = lookup.supplierName;
        return Id.valueOf(lookup.supplierId);
    }
}