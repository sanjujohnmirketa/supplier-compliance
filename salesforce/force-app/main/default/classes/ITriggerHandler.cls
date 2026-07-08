/**
 * ITriggerHandler
 *
 * Interface that every trigger handler must implement.
 * The TriggerDispatcher calls the correct method based on
 * Trigger.isBefore / isAfter and Trigger.isInsert / isUpdate.
 *
 * DESIGN RULE: Handler classes implement this interface.
 *   Service classes contain all business logic.
 *   Handler methods contain exactly ONE service call each — nothing else.
 *
 * Only the four operations used by this platform are included.
 * Add beforeDelete / afterDelete if needed in a future phase.
 */
public interface ITriggerHandler {

    /**
     * Fires before new records are inserted.
     * Use for: defaulting fields, validation that can't be done in
     * a validation rule (e.g. cross-object checks needing SOQL).
     * @param newList  Trigger.new — records being inserted (no Ids yet)
     */
    void beforeInsert(List<SObject> newList);

    /**
     * Fires before existing records are updated.
     * Use for: recalculating fields, enforcing field immutability.
     * @param newList  Trigger.new — new field values
     * @param oldMap   Trigger.oldMap — values before the update
     */
    void beforeUpdate(List<SObject> newList, Map<Id, SObject> oldMap);

    /**
     * Fires after new records are inserted and committed.
     * Use for: creating related records, publishing events, async jobs.
     * Records now have Ids.
     * @param newList  Trigger.new — inserted records with Ids
     */
    void afterInsert(List<SObject> newList);

    /**
     * Fires after existing records are updated and committed.
     * Use for: cascading updates to related records, publishing events.
     * @param newList  Trigger.new — new field values with Ids
     * @param oldMap   Trigger.oldMap — values before the update
     */
    void afterUpdate(List<SObject> newList, Map<Id, SObject> oldMap);
}