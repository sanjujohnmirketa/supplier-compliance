/**
 * ComplianceDomainController
 * ═══════════════════════════════════════════════════════════════════════════
 * Read-only @AuraEnabled accessor for the Compliance_Domain__mdt catalog.
 *
 * Single source of truth for the dynamic "Scope & risk domains" selector on the
 * supplier intake screen (scVendorConsole). Replaces the hardcoded JS array so
 * domains can be added/retired by editing Custom Metadata — no code change.
 *
 * The LWC merges this catalog with the supplier's Account.Risk_Domains__c
 * (written by /scope auto-detection) to decide which tags are pre-selected:
 *   - if the account already has scoped domains → select those
 *   - otherwise → fall back to the catalog's Default_Selected__c flags
 */
public with sharing class ComplianceDomainController {

    public class DomainOption {
        @AuraEnabled public String  key;             // Domain_Key__c — joins to Python corpus + Risk_Domains__c
        @AuraEnabled public String  label;           // display tag text
        @AuraEnabled public String  description;     // tooltip / help
        @AuraEnabled public String  authority;       // registry/body it verifies against
        @AuraEnabled public Boolean defaultSelected; // pre-checked before /scope runs
        @AuraEnabled public Decimal displayOrder;
    }

    /**
     * Returns the active domain catalog, ordered for display. Cacheable —
     * the catalog is config, not transactional data.
     */
    @AuraEnabled(cacheable=true)
    public static List<DomainOption> getDomainCatalog() {
        // Custom metadata has no CRUD/sharing model (WITH USER_MODE is rejected
        // at runtime for it); the describe check is the applicable guard.
        if (!Schema.sObjectType.Compliance_Domain__mdt.isAccessible()) {
            throw new AuraHandledException('You do not have permission to read the domain catalog.');
        }
        List<DomainOption> out = new List<DomainOption>();
        for (Compliance_Domain__mdt d : [
            SELECT Domain_Key__c, Label__c, Description__c, Verifier_Authority__c,
                   Default_Selected__c, Display_Order__c
            FROM   Compliance_Domain__mdt
            WHERE  Active__c = true
            ORDER BY Display_Order__c ASC NULLS LAST, Label__c ASC
        ]) {
            DomainOption o = new DomainOption();
            o.key             = d.Domain_Key__c;
            o.label           = d.Label__c;
            o.description     = d.Description__c;
            o.authority       = d.Verifier_Authority__c;
            o.defaultSelected = d.Default_Selected__c;
            o.displayOrder    = d.Display_Order__c;
            out.add(o);
        }
        return out;
    }
}