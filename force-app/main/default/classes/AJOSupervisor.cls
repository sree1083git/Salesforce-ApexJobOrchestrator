/**
 * The piece that makes the framework safe to leave alone. Runs hourly at :05.
 *
 * Every step is isolated: each runs inside its own savepoint and try/catch,
 * so one failing step is rolled back, alerted, and does not stop the others.
 * The order is deliberate:
 *
 *   1. heal        re-create missing heartbeats FIRST — self-healing must never
 *                  be skipped because a later step failed (previously re-arm
 *                  ran last and a purge failure took it down too);
 *   2. watchdog    alert HEARTBEAT_STALE when no check has run recently;
 *   3. sync        project definitions (same as each heartbeat does);
 *   4. reconcile   close out finished async runs;
 *   5. reap        time out overrunning runs AND abort their async job, so the
 *                  next occurrence cannot overlap a job still running;
 *   6. expire      retire jobs past their End Date;
 *   7. unqueue     clear queued markers whose run never arrived;
 *   8. purge       hand log retention to AJOPurgeBatch, so deletes never
 *                  compete with the steps above for the 10,000 DML-row limit.
 *
 * Runs without sharing: framework infrastructure.
 */
global without sharing class AJOSupervisor implements Schedulable {

    global void execute(SchedulableContext sc) { sweep(); }

    public static Map<String, Object> sweep() {
        Map<String, Object> result = new Map<String, Object>();
        try {
            result.put('rearmed',    step('heal',      new HealStep()));
            result.put('stale',      step('watchdog',  new WatchdogStep()));
            result.put('synced',     step('sync',      new SyncStep()));
            result.put('reconciled', step('reconcile', new ReconcileStep()));
            result.put('stuck',      step('reap',      new ReapStep()));
            result.put('expired',    step('expire',    new ExpireStep()));
            result.put('unqueued',   step('unqueue',   new UnqueueStep()));
            result.put('purged',     step('purge',     new PurgeStep()));
            result.put('slotsUsed',  AJOInstaller.scheduledApexSlotsUsed());
        } finally {
            AJOAlerts.flush();
        }
        return result;
    }

    // ------------------------------------------------------------ step runner

    private interface Step { Object run(); }

    /** Runs one step in a savepoint; a failure is rolled back, alerted, and returns -1. */
    private static Object step(String name, Step s) {
        Savepoint sp = Database.setSavepoint();
        try {
            return s.run();
        } catch (Exception e) {
            Database.rollback(sp);
            AJOAlerts.raise(AJOAlerts.ERROR, 'MAINTENANCE_FAILED', null,
                'Maintenance step "' + name + '" failed and was rolled back: '
                + e.getTypeName() + ': ' + e.getMessage());
            return -1;
        }
    }

    private class HealStep implements Step { public Object run() { return AJOInstaller.healSafely(); } }
    private class WatchdogStep implements Step { public Object run() { return checkHeartbeat(Datetime.now()); } }
    private class SyncStep implements Step { public Object run() { return AJODefinitionSync.syncSafely().summary(); } }
    private class ReconcileStep implements Step { public Object run() { return AJORunLogger.reconcile(); } }
    private class ReapStep implements Step { public Object run() { return reapStuck(); } }
    private class ExpireStep implements Step { public Object run() { return expireLapsed(); } }
    private class UnqueueStep implements Step { public Object run() { return clearLapsedQueue(); } }
    private class PurgeStep implements Step { public Object run() { return purge(); } }

    // ---------------------------------------------------------------- steps

    /**
     * True (and an alert raised) when the last heartbeat is older than the
     * stale threshold while the framework is installed and not paused. With
     * self-healing in every check, a stale heartbeat usually means the
     * scheduling user was deactivated or lost access — something only a
     * person can fix.
     */
    public static Boolean checkHeartbeat(Datetime now) {
        if (AJOConfig.killSwitch() || AJOInstaller.ownTriggers().isEmpty()) { return false; }
        Datetime last = AJOConfig.lastHeartbeatAt();
        Integer threshold = AJOConfig.staleHeartbeatMinutes();
        if (last != null && last.addMinutes(threshold) >= now) { return false; }
        AJOAlerts.raise(AJOAlerts.ERROR, 'HEARTBEAT_STALE', null,
            (last == null
                ? 'No scheduled check has ever recorded a heartbeat.'
                : 'The last scheduled check ran at ' + last.formatGmt('yyyy-MM-dd HH:mm') + ' GMT, more than '
                  + threshold + ' minutes ago.')
            + ' No orchestrated job is running. Check that the user who installed the '
            + 'scheduler is active and still has the Apex Job Orchestration Admin permission set, '
            + 'then re-install from the console.');
        return true;
    }

    /**
     * A run past its job's Max Runtime is marked Stuck, its async job aborted,
     * and the job freed. Aborting matters: freeing the job while the batch kept
     * running let the next occurrence start on top of it.
     */
    public static Integer reapStuck() {
        List<AJOJobRun__c> openRuns = [
            SELECT Id, AJO_Job__c, AJO_StartedAt__c, AJO_FinishedAt__c, AJO_Status__c,
                   AJO_DurationSec__c, AJO_AsyncApexJobId__c, AJO_ItemsProcessed__c,
                   AJO_ItemsFailed__c, AJO_BatchSize__c, AJO_Message__c,
                   AJO_ErrorMessage__c, AJO_StackTrace__c,
                   AJO_Job__r.AJO_MaxRuntimeMinutes__c
            FROM   AJOJobRun__c
            WHERE  AJO_Status__c = 'Running'
              AND  AJO_StartedAt__c = LAST_N_DAYS:7
            LIMIT  500
        ];
        List<AJOJobRun__c> stuck = new List<AJOJobRun__c>();
        Set<Id> jobIds = new Set<Id>();
        Datetime now = Datetime.now();

        for (AJOJobRun__c r : openRuns) {
            Decimal cap = r.AJO_Job__r.AJO_MaxRuntimeMinutes__c;
            Integer limitMins = (cap == null || cap <= 0) ? 240 : cap.intValue();
            if (r.AJO_StartedAt__c.addMinutes(limitMins) >= now) { continue; }

            String aborted = abortQuietly(r.AJO_AsyncApexJobId__c);
            r.AJO_Status__c       = 'Stuck';
            r.AJO_FinishedAt__c   = now;
            r.AJO_DurationSec__c  = AJORunLogger.seconds(r.AJO_StartedAt__c, now);
            r.AJO_ErrorMessage__c = 'Exceeded ' + limitMins + ' minutes without completing. '
                + aborted + ' Released by the supervisor.';
            stuck.add(AJORunLogger.patch(r));
            jobIds.add(r.AJO_Job__c);
        }
        if (stuck.isEmpty()) { return 0; }
        update stuck;

        List<AJOJob__c> jobs = [
            SELECT Id, AJO_Status__c FROM AJOJob__c WHERE Id IN :jobIds AND AJO_Status__c = 'Running'
        ];
        for (AJOJob__c j : jobs) { j.AJO_Status__c = 'Idle'; }
        if (!jobs.isEmpty()) { update jobs; }
        return stuck.size();
    }

    /** Aborts an async job if it is still alive; describes what happened. */
    private static String abortQuietly(String asyncId) {
        if (String.isBlank(asyncId)) { return 'No async job to abort.'; }
        try {
            List<AsyncApexJob> a = [
                SELECT Id, Status FROM AsyncApexJob WHERE Id = :asyncId LIMIT 1
            ];
            if (a.isEmpty()) { return 'Its async job no longer exists.'; }
            if (a[0].Status == 'Completed' || a[0].Status == 'Failed' || a[0].Status == 'Aborted') {
                return 'Its async job had already ended (' + a[0].Status + ').';
            }
            System.abortJob(a[0].Id);
            return 'Its async job ' + a[0].Id + ' was aborted.';
        } catch (Exception e) {
            return 'Its async job could not be aborted: ' + e.getMessage() + '.';
        }
    }

    /**
     * Retires jobs whose End Date has passed. The dispatcher already refuses
     * them; this makes a finished job LOOK finished rather than reading Idle.
     */
    public static Integer expireLapsed() {
        Date today = Date.today();
        List<AJOJob__c> lapsed = [
            SELECT Id, AJO_Status__c, AJO_NextRunAt__c, AJO_EndDate__c
            FROM   AJOJob__c
            WHERE  AJO_EndDate__c != null
              AND  AJO_EndDate__c < :today
              AND  AJO_Status__c NOT IN ('Expired', 'Running', 'Queued', 'Suspended', 'Retired', 'Invalid')
            LIMIT  2000
        ];
        if (lapsed.isEmpty()) { return 0; }
        for (AJOJob__c j : lapsed) {
            j.AJO_Status__c    = 'Expired';
            j.AJO_NextRunAt__c = null;
        }
        update lapsed;
        return lapsed.size();
    }

    /**
     * Clears queued markers whose instant is long past. An executor normally
     * clears its own marker; if the platform ever drops the queueable, the
     * marker would otherwise leave the console advertising a run that is never
     * coming.
     */
    public static Integer clearLapsedQueue() {
        Datetime cutoff = Datetime.now().addMinutes(-30);
        List<AJOJob__c> stale = [
            SELECT Id, AJO_Status__c, AJO_QueuedForAt__c
            FROM   AJOJob__c
            WHERE  AJO_QueuedForAt__c != null
              AND  AJO_QueuedForAt__c < :cutoff
            LIMIT  2000
        ];
        if (stale.isEmpty()) { return 0; }
        for (AJOJob__c j : stale) {
            j.AJO_QueuedForAt__c = null;
            if (j.AJO_Status__c == 'Queued') { j.AJO_Status__c = 'Idle'; }
        }
        update stale;
        return stale.size();
    }

    /**
     * Starts AJOPurgeBatch unless one is already running. Returns 1 when a
     * purge was started, 0 otherwise. The batch deletes in chunks, so no single
     * transaction approaches the DML row limit however large the log grows.
     */
    public static Integer purge() {
        Integer running = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE  JobType = 'BatchApex' AND ApexClass.Name = 'AJOPurgeBatch'
              AND  Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
        ];
        if (running > 0) { return 0; }
        Database.executeBatch(new AJOPurgeBatch(), AJOPurgeBatch.SCOPE);
        return 1;
    }
}
