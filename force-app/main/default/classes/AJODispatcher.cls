/**
 * The heartbeat: a scheduled check. Six registrations (minutes :00, :10 …
 * :50) hold six of the org's 100 scheduled Apex slots and between them carry
 * an unlimited number of configured jobs.
 *
 *   0 0  * * * ?    AJO Heartbeat 00
 *   0 10 * * * ?    AJO Heartbeat 10    ... and so on to :50
 *
 * Each check, in order:
 *   1. stamps AJO_LastHeartbeatAt__c, so the watchdog can tell it is alive;
 *   2. re-creates any missing heartbeat or the supervisor (the checks heal
 *      each other every ten minutes instead of waiting for a daily sweep);
 *   3. stops here if every job is paused;
 *   4. syncs AJO_Job_Definition__mdt into the state records (a deployment
 *      takes effect within one interval), isolated by a savepoint;
 *   5. closes out async runs that finished since the last check;
 *   6. selects what is due in this check's window and hands it to the
 *      launcher, which only dispatches — no job code runs in this transaction;
 *   7. sends any alerts raised along the way.
 *
 * Keeps no state but the slot minute: the platform serializes a Schedulable
 * when it is scheduled, so all configuration is read fresh on every check.
 */
global without sharing class AJODispatcher implements Schedulable {

    global Integer slotMinute;

    global AJODispatcher() { this.slotMinute = 0; }

    global AJODispatcher(Integer slotMinute) { this.slotMinute = slotMinute; }

    global void execute(SchedulableContext sc) {
        run(slotMinute);
    }

    /** One check. Returns how many due jobs it considered. */
    public static Integer run(Integer slot) {
        try {
            AJOConfig.stampHeartbeat();
            AJOInstaller.healSafely();
            if (AJOConfig.killSwitch()) { return 0; }

            AJODefinitionSync.syncSafely();

            // Close out async work first, or the overlap gate reads a stale 'Running'.
            try {
                AJORunLogger.reconcile();
            } catch (Exception e) {
                AJOAlerts.raise(AJOAlerts.WARNING, 'RECONCILE_FAILED', null,
                    'Closing out finished runs failed: ' + e.getMessage());
            }

            List<AJOJob__c> due = selectDue(Datetime.now());
            AJOLauncher.launch(due, slot);
            return due.size();
        } finally {
            AJOAlerts.flush();
        }
    }

    /**
     * What this check should consider. The activation window is filtered with
     * real date comparisons rather than the AJO_IsActive__c formula: the
     * formula is not indexed and this query must stay selective as jobs grow.
     *
     * With deferral on, the window reaches one interval ahead (jobs due later
     * are held in a delayed executor until their minute). With it off, only
     * jobs already due are taken: they start late, never early.
     */
    public static List<AJOJob__c> selectDue(Datetime now) {
        Datetime windowEnd = AJOConfig.deferralEnabled()
            ? now.addMinutes(AJOConfig.heartbeatMinutes()) : now;
        Set<String> excluded = AJOLauncher.NOT_SCHEDULABLE;
        String managedOnly = AJOConfig.allowUnmanagedJobs()
            ? '' : '  AND AJO_DefinitionManaged__c = true ';
        return Database.query(
            'SELECT ' + AJOLauncher.JOB_FIELDS + ' FROM AJOJob__c '
            + 'WHERE ' + AJOWindow.SOQL_FILTER
            + managedOnly
            + '  AND AJO_Status__c NOT IN :excluded '
            + '  AND AJO_NextRunAt__c != null '
            + '  AND AJO_NextRunAt__c <= :windowEnd '
            + 'ORDER BY AJO_Priority__c ASC NULLS LAST, AJO_NextRunAt__c ASC '
            + 'LIMIT 200');
    }
}
