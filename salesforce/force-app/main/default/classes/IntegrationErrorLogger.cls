/**
 * IntegrationErrorLogger
 * Persists the EXACT backend/callout error so it surfaces in the UI instead of
 * failing silently. Stamps the supplier record + appends to the audit trail.
 * Never throws — error logging must not break the calling job.
 */
public without sharing class IntegrationErrorLogger {

    public static void log(Id supplierId, String source, String message) {
        String msg = String.isBlank(message) ? 'Unknown error' : message;
        String stamped = ('[' + DateTime.now().format('yyyy-MM-dd HH:mm:ss')
            + '] [' + source + '] ' + msg);

        // 1. Stamp the supplier record (portal/dashboard reads this inline)
        if (supplierId != null) {
            try {
                Database.update(new Account(
                    Id = supplierId,
                    Last_Integration_Error__c = stamped.left(32768)
                ), false);
            } catch (Exception ignore) { /* never break the caller */ }
        }

        // 2. Append to the append-only audit trail
        try {
            Database.insert(new Audit_Log__c(
                Event_Type__c        = 'Integration_Error',
                Related_Object__c    = 'Supplier',
                Related_Record_Id__c = supplierId,
                Event_DateTime__c    = DateTime.now(),
                Actor_Type__c        = 'System',
                Source_System__c     = 'Other',
                New_Value__c         = stamped.left(131072)
            ), false);
        } catch (Exception ignore) { /* never break the caller */ }
    }
}