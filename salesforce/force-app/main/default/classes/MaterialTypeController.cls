/**
 * MaterialTypeController
 * ═══════════════════════════════════════════════════════════════════════════
 * Read-only @AuraEnabled accessor for the Material_Type__mdt catalog.
 *
 * Single source of truth for the "Raw material type" / "Service category"
 * dropdowns on supplier intake (scProcurementConsole). Replaces the hardcoded
 * MATERIAL_TYPES/SERVICE_CATEGORIES JS arrays so a new material — for ANY
 * industry — can be added by creating a Custom Metadata record, with no code
 * change on either the Salesforce or engine side (the Domains__c mapping
 * travels to /scope in the request, replacing the engine's own hardcoded
 * MATERIAL_TYPE_DOMAINS/SERVICE_CATEGORY_DOMAINS dicts — see ScopeService.cls).
 *
 * Mirrors ComplianceDomainController's pattern exactly.
 */
public with sharing class MaterialTypeController {

    public class MaterialTypeOption {
        @AuraEnabled public String  valueKey;      // Value_Key__c — sent to ScopeRequest.materialType/serviceCategory
        @AuraEnabled public String  label;         // display text
        @AuraEnabled public String  kind;           // 'Material' | 'Service'
        @AuraEnabled public List<String> domains;  // Domains__c split on comma — sent to /scope
        @AuraEnabled public Decimal displayOrder;
    }

    /**
     * Returns the full active catalog (both Material and Service kinds),
     * ordered for display. Cacheable — this is config, not transactional data.
     */
    @AuraEnabled(cacheable=true)
    public static List<MaterialTypeOption> getMaterialTypeCatalog() {
        // Custom metadata has no CRUD/sharing model (WITH USER_MODE is rejected
        // at runtime for it); the describe check is the applicable guard.
        if (!Schema.sObjectType.Material_Type__mdt.isAccessible()) {
            throw new AuraHandledException('You do not have permission to read the material catalog.');
        }
        List<MaterialTypeOption> out = new List<MaterialTypeOption>();
        for (Material_Type__mdt m : [
            SELECT Kind__c, Value_Key__c, Label__c, Domains__c, Display_Order__c
            FROM   Material_Type__mdt
            WHERE  Active__c = true
            ORDER BY Kind__c ASC, Display_Order__c ASC NULLS LAST, Label__c ASC
        ]) {
            MaterialTypeOption o = new MaterialTypeOption();
            o.valueKey     = m.Value_Key__c;
            o.label        = m.Label__c;
            o.kind         = m.Kind__c;
            o.displayOrder = m.Display_Order__c;
            o.domains      = new List<String>();
            if (String.isNotBlank(m.Domains__c)) {
                for (String d : m.Domains__c.split(',')) {
                    String trimmed = d.trim();
                    if (String.isNotBlank(trimmed)) o.domains.add(trimmed);
                }
            }
            out.add(o);
        }
        return out;
    }
}