/**
 * TriggerDispatcher
 *
 * Central entry point for all trigger execution.
 * Every trigger on every object calls exactly one line:
 *   TriggerDispatcher.run(new XxxTriggerHandler());
 *
 * Responsibilities:
 *  1. Route to the correct ITriggerHandler method based on trigger context.
 *  2. Guard against infinite recursion (trigger A updates B which re-fires A).
 *  3. Provide a bypass mechanism for data migration / test scenarios.
 *
 * RECURSION GUARD:
 *   Tracks which handler+operation combinations have already executed in
 *   this transaction. Key = ClassName + OperationType (e.g.
 *   "AccountTriggerHandler_AFTER_INSERT"). If that key is already in the
 *   set, the handler is skipped.
 *
 *   IMPORTANT: This is a per-transaction guard, not a per-record guard.
 *   If your service legitimately needs to update Account records from an
 *   Account trigger (e.g. rollup), that second update will be blocked.
 *   In that case, use Database.update() in a @future or Queueable instead,
 *   which runs in a new transaction context.
 *
 * BYPASS:
 *   Set TriggerDispatcher.bypassAll = true before a data load or test
 *   where trigger side-effects are unwanted. Reset to false after.
 *   Per-handler bypass: add the handler class name to bypassedHandlers.
 */
public without sharing class TriggerDispatcher {

    // ── Bypass controls ───────────────────────────────────────────────────────

    /** Set true to skip ALL trigger handlers in this transaction. */
    @TestVisible
    public static Boolean bypassAll = false;

    /**
     * Add a handler class name (e.g. 'AccountTriggerHandler') to skip
     * just that handler while letting others run.
     */
    @TestVisible
    public static Set<String> bypassedHandlers = new Set<String>();

    // ── Recursion guard ───────────────────────────────────────────────────────

    /**
     * Tracks handler+operation keys already executed this transaction.
     * Format: 'ClassName_TRIGGER_OPERATION' e.g. 'AccountTriggerHandler_AFTER_INSERT'
     */
    @TestVisible
    private static Set<String> executedHandlers = new Set<String>();

    // ── Main dispatch method ──────────────────────────────────────────────────

    /**
     * Called from every trigger. Routes to the correct handler method.
     * @param handler  An instance of the object-specific handler class.
     */
    public static void run(ITriggerHandler handler) {

        // Global bypass
        if (bypassAll) return;

        // Per-handler bypass
        String handlerName = String.valueOf(handler).substringBefore(':');
        if (bypassedHandlers.contains(handlerName)) return;

        // Build the key for this handler + operation
        String key = handlerName + '_' + Trigger.operationType.name();

        // Recursion guard — skip if already executed in this transaction
        if (executedHandlers.contains(key)) return;
        executedHandlers.add(key);

        // Route to correct method
        try {
            if (Trigger.isBefore) {
                if (Trigger.isInsert) handler.beforeInsert(Trigger.new);
                if (Trigger.isUpdate) handler.beforeUpdate(Trigger.new, Trigger.oldMap);
            } else if (Trigger.isAfter) {
                if (Trigger.isInsert) handler.afterInsert(Trigger.new);
                if (Trigger.isUpdate) handler.afterUpdate(Trigger.new, Trigger.oldMap);
            }
        } catch (Exception e) {
            // Re-throw with handler context for easier debugging
            throw new TriggerDispatcherException(
                'Error in ' + handlerName + ' [' + Trigger.operationType + ']: ' + e.getMessage(),
                e
            );
        }
    }

    /**
     * Resets the recursion guard. Call this in test methods that need to
     * fire the same handler multiple times within one test transaction.
     * NOT for production use.
     */
    @TestVisible
    public static void resetExecutionState() {
        executedHandlers.clear();
    }

    // ── Custom exception ──────────────────────────────────────────────────────

    public class TriggerDispatcherException extends Exception {}
}