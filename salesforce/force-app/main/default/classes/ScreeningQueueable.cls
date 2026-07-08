/**
 * ScreeningQueueable — runs pre-document screening for a supplier asynchronously.
 *
 * Submit (Procurement P1) persists the supplier synchronously, then enqueues this
 * so the AI engine conducts registry/sanctions/conflict/media screening in its own
 * transaction (callout-after-DML can't happen inline). Results are persisted as
 * Compliance_Assessment__c rows, so when the supplier is opened from the screening
 * queue the pre-document screening details are already there.
 */
public class ScreeningQueueable implements Queueable, Database.AllowsCallouts {
    private final Id accountId;

    public ScreeningQueueable(Id accountId) {
        this.accountId = accountId;
    }

    public void execute(QueueableContext ctx) {
        try {
            VendorPortalController.runScreeningAndPersist(accountId);
        } catch (Exception e) {
            // Don't fail silently — record so the analyst sees screening didn't complete.
            Database.insert(new Audit_Log__c(
                Event_Type__c        = 'Status_Changed',
                Related_Object__c    = 'Supplier',
                Related_Record_Id__c = accountId,
                Event_DateTime__c    = DateTime.now(),
                Actor_Type__c        = 'System',
                Source_System__c     = 'Other',
                New_Value__c         = 'Pre-document screening failed: ' + e.getMessage()
            ), false);
        }
    }
}