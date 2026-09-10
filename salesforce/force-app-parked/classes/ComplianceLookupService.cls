/**
 * ComplianceLookupService
 * ═══════════════════════════════════════════════════════════════════════════
 * Agent action: Find Supplier By Name.
 * Resolves a supplier name to an Account ID so the agent can chain into
 * Evaluate Compliance or Validate Document without asking the user for IDs.
 *
 * The companion class DocumentLookupService exposes Find Documents For Supplier.
 * They are separate classes because Apex allows only one @InvocableMethod per class.
 */
public with sharing class ComplianceLookupService {

    // ═════════════════════════════════════════════════════════════════════════
    // ACTION — findSupplier(name)
    // ═════════════════════════════════════════════════════════════════════════

    public class FindSupplierRequest {
        @InvocableVariable(
            label='Supplier Name'
            description='The name (or partial name) of the supplier to find. Examples: "Acme", "vv", "Acme Manufacturing". The lookup is case-insensitive and uses CONTAINS matching, so partial names work. Required.'
            required=true
        )
        public String supplierName;
    }

    public class FindSupplierResponse {
        @InvocableVariable(
            label='Supplier Id'
            description='The Salesforce Account ID of the matched supplier. Empty if zero matches or multiple ambiguous matches. Use this ID as input to Evaluate Compliance or Validate Document actions.'
        )
        public String supplierId;

        @InvocableVariable(
            label='Supplier Name'
            description='The full official name of the matched supplier from the Account record.'
        )
        public String supplierName;

        @InvocableVariable(
            label='Match Count'
            description='Number of suppliers matching the search. 0 means none found. 1 means clean match — proceed with the returned ID. Greater than 1 means ambiguous — ask the user to clarify using the Candidates field.'
        )
        public Integer matchCount;

        @InvocableVariable(
            label='Candidates'
            description='If multiple suppliers match, this is a human-readable list of candidates with disambiguating details (city, industry, ID). Present this to the user and ask them to choose. Empty if matchCount is 0 or 1.'
        )
        public String candidates;

        @InvocableVariable(
            label='Status Message'
            description='Plain-English status. Examples: "Found supplier vv Manufacturing in San Jose", "No suppliers matched name vv", "Found 3 suppliers matching vv — please specify which one." Always populated.'
        )
        public String statusMessage;
    }

    @InvocableMethod(
        label='Find Supplier By Name'
        description='Looks up a supplier (Account) by name. Use this BEFORE calling Evaluate Compliance or Validate Document when the user has provided a supplier name instead of an ID. Returns the supplier ID for further actions, or an ambiguity message if multiple suppliers match the name.'
        category='Compliance'
    )
    public static List<FindSupplierResponse> findSupplier(List<FindSupplierRequest> requests) {
        List<FindSupplierResponse> results = new List<FindSupplierResponse>();
        for (FindSupplierRequest req : requests) {
            results.add(findOneSupplier(req.supplierName));
        }
        return results;
    }

    // Public so DocumentLookupService can reuse the same lookup logic
    public static FindSupplierResponse findOneSupplier(String name) {
        FindSupplierResponse resp = new FindSupplierResponse();

        if (String.isBlank(name)) {
            resp.matchCount = 0;
            resp.statusMessage = 'No supplier name provided.';
            return resp;
        }

        Id supplierRtId = getSupplierRecordTypeId();

        List<Account> matches;
        if (supplierRtId != null) {
            matches = [
                SELECT Id, Name, BillingCity, BillingState, BillingCountry,
                       Industry__c, Vendor_Type__c
                FROM   Account
                WHERE  Name LIKE :('%' + name.trim() + '%')
                AND    RecordTypeId = :supplierRtId
                WITH   USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT  10
            ];
        } else {
            matches = [
                SELECT Id, Name, BillingCity, BillingState, BillingCountry,
                       Industry__c, Vendor_Type__c
                FROM   Account
                WHERE  Name LIKE :('%' + name.trim() + '%')
                WITH   USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT  10
            ];
        }

        resp.matchCount = matches.size();

        if (matches.isEmpty()) {
            resp.statusMessage = 'No suppliers found matching name "' + name
                + '". Ask the user to verify the supplier name or provide a Salesforce ID.';
            return resp;
        }

        if (matches.size() == 1) {
            Account a = matches[0];
            resp.supplierId    = a.Id;
            resp.supplierName  = a.Name;
            resp.statusMessage = 'Found supplier "' + a.Name + '"'
                + (a.BillingCity != null ? ' in ' + a.BillingCity : '')
                + (a.Industry__c != null ? ' (' + a.Industry__c + ')' : '')
                + '. Proceed with this supplier ID.';
            return resp;
        }

        // Multiple matches — build disambiguation list
        List<String> candidateLines = new List<String>();
        for (Integer i = 0; i < matches.size(); i++) {
            Account a = matches[i];
            String line = (i + 1) + '. ' + a.Name
                + (a.BillingCity  != null ? ' — ' + a.BillingCity  : '')
                + (a.BillingState != null ? ', '  + a.BillingState : '')
                + (a.Industry__c  != null ? ' (' + a.Industry__c + ')' : '')
                + ' [ID: ' + a.Id + ']';
            candidateLines.add(line);
        }
        resp.candidates = String.join(candidateLines, '\n');
        resp.statusMessage = 'Found ' + matches.size() + ' suppliers matching "'
            + name + '". Ask the user which one they mean by name, city, or industry. '
            + 'Do NOT pick one automatically.';
        return resp;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Shared helpers (also used by DocumentLookupService)
    // ═════════════════════════════════════════════════════════════════════════

    public static Id resolveSupplierIdSimple(String nameOrId) {
        if (String.isBlank(nameOrId)) return null;
        // instanceOf Id validates the format without throwing — a non-Id
        // simply falls through to the name-based lookup below.
        if ((nameOrId.length() == 15 || nameOrId.length() == 18)
                && nameOrId instanceOf Id
                && ((Id) nameOrId).getSObjectType() == Account.SObjectType) {
            return (Id) nameOrId;
        }
        FindSupplierResponse lookup = findOneSupplier(nameOrId);
        if (lookup.matchCount == 1) return Id.valueOf(lookup.supplierId);
        return null;
    }

    public static Id getSupplierRecordTypeId() {
        Map<String, Schema.RecordTypeInfo> rtMap =
            Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
        return rtMap.containsKey('Supplier')
            ? rtMap.get('Supplier').getRecordTypeId()
            : null;
    }
}