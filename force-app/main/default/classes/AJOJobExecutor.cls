/**
 * Runs ONE job, in its own transaction, at its exact minute.
 *
 * Enqueued by AJOLauncher at a scheduled check (delayed up to ten minutes so
 * the job lands on the minute its cron names) and by the console's Run now.
 * Because each job gets its own executor:
 *   - a job that exceeds a governor limit fails alone; the platform marks this
 *     queueable Failed and AJORunLogger.reconcile closes the run as Failed and
 *     counts it against the circuit breaker on the next check;
 *   - the job has the full asynchronous limits to itself;
 *   - Runnable jobs may make callouts: this class implements
 *     Database.AllowsCallouts and performs NO DML before the job's own code.
 *
 * Before running anything it re-checks, because minutes may have passed since
 * the check queued it: the global pause, the definition (still deployed,
 * active and valid), the activation window, suspension, ownership of the
 * occurrence (an edit or resync may have handed it back to the heartbeat), and
 * batch capacity. Any of those stands it down cleanly: the run is closed as
 * Skipped or Throttled with the reason, and the queued marker released.
 *
 * Runs without sharing: framework infrastructure acting on every job's state.
 * The job's own code runs as the user who enqueued the executor (the
 * scheduler user for heartbeat launches).
 */
public without sharing class AJOJobExecutor implements Queueable, Database.AllowsCallouts {

    private final Id jobId;
    /** The run record the check opened; null for the legacy deferred-runner path. */
    private final Id runId;
    /** The occurrence this executor owns. */
    private final Datetime dueAt;

    public AJOJobExecutor(Id jobId, Id runId, Datetime dueAt) {
        this.jobId = jobId;
        this.runId = runId;
        this.dueAt = dueAt;
    }

    public void execute(QueueableContext qc) {
        try {
            executeNow();
        } finally {
            AJOAlerts.flush();
        }
    }

    /** The body of execute(), callable directly from tests. */
    @TestVisible
    private void executeNow() {
        List<AJOJob__c> jobs = Database.query(
            'SELECT ' + AJOLauncher.JOB_FIELDS + ' FROM AJOJob__c WHERE Id = :jobId LIMIT 1');
        AJOJobRun__c run = loadRun();

        if (jobs.isEmpty()) {
            closeIfOpen(run, 'Skipped', 'The job was deleted before its run started.');
            return;
        }
        AJOJob__c job = jobs[0];

        String standDown = standDownReason(job);
        if (standDown != null) {
            closeIfOpen(run, 'Skipped', standDown);
            release(job);
            return;
        }

        if (!new AJOThrottle().claim(effectiveType(job))) {
            closeIfOpen(run, 'Throttled', 'Batch capacity was full when the run was due to start. '
                + 'Handed back to the next check.');
            // Give the occurrence back: the next check takes it (late, not early).
            AJOJob__c back = new AJOJob__c(Id = job.Id, AJO_QueuedForAt__c = null,
                AJO_Status__c = job.AJO_Status__c == 'Queued' ? 'Idle' : job.AJO_Status__c);
            back.AJO_NextRunAt__c = (job.AJO_NextRunAt__c == null || job.AJO_NextRunAt__c > Datetime.now())
                ? Datetime.now() : job.AJO_NextRunAt__c;
            update back;
            return;
        }

        if (run == null) {
            // Legacy path (an AJODeferredRunner enqueued before the upgrade): no
            // run was opened at the check, so open one now. This is DML before
            // the job runs, so such a run cannot make callouts; it happens only
            // for queueables already in flight at deployment time.
            run = AJORunLogger.open(job, dueAt, 'Heartbeat', null);
        } else {
            run.AJO_StartedAt__c = Datetime.now();
        }

        AJOLauncher.execute(job, run);

        // Release only the marker this executor owned. A Run now executor owns no
        // occurrence (dueAt is null); clearing the marker there would make a
        // heartbeat-queued run of the same job stand down and lose its occurrence.
        if (dueAt != null && job.AJO_QueuedForAt__c == dueAt) {
            job.AJO_QueuedForAt__c = null;
        }
        update job;
    }

    /**
     * Why this executor must not run its job, or null to proceed. Order matters
     * only for the message the run record carries.
     */
    @TestVisible
    private String standDownReason(AJOJob__c job) {
        if (AJOConfig.killSwitch()) {
            return 'Every job is paused (kill switch), so the queued run stood down.';
        }
        if (!AJOLauncher.mayRun(job)) {
            return 'Not backed by a deployed definition, and unmanaged jobs are not allowed.';
        }
        if (job.AJO_DefinitionManaged__c == true) {
            AJO_Job_Definition__mdt d = AJODefinitions.byKey(job.AJO_JobKey__c);
            if (d == null)                 { return 'Its definition is no longer deployed.'; }
            if (d.AJO_Active__c != true)   { return 'Its definition was deactivated.'; }
            if (job.AJO_OpsPaused__c == true) { return 'Paused by operations.'; }
        }
        if (!AJOWindow.isActive(job)) {
            return 'Outside its activation window: ' + AJOWindow.describe(job) + '.';
        }
        if (job.AJO_Status__c == 'Suspended' || job.AJO_Status__c == 'Expired'
            || job.AJO_Status__c == 'Retired' || job.AJO_Status__c == 'Invalid') {
            return 'The job is ' + job.AJO_Status__c + '.';
        }
        // Ownership. An edit, resume, window change or resync recomputes Next
        // Run; when that lands on or before this instant the heartbeat will take
        // the occurrence itself, and running it here too would run it twice.
        if (dueAt != null && (job.AJO_QueuedForAt__c != dueAt
            || (job.AJO_NextRunAt__c != null && job.AJO_NextRunAt__c <= dueAt))) {
            return 'Another run now owns this occurrence (the job was edited, resumed or '
                + 'resynced after it was queued).';
        }
        return null;
    }

    /** The execution type that will actually run: the definition's for managed jobs. */
    private static AJOJob__c effectiveType(AJOJob__c job) {
        if (job.AJO_DefinitionManaged__c == true) {
            AJO_Job_Definition__mdt d = AJODefinitions.byKey(job.AJO_JobKey__c);
            if (d != null) {
                return new AJOJob__c(AJO_ExecutionType__c = d.AJO_ExecutionType__c);
            }
        }
        return job;
    }

    private AJOJobRun__c loadRun() {
        if (runId == null) { return null; }
        List<AJOJobRun__c> rows = [
            SELECT Id, AJO_Job__c, AJO_StartedAt__c, AJO_FinishedAt__c, AJO_Status__c,
                   AJO_DurationSec__c, AJO_AsyncApexJobId__c, AJO_ItemsProcessed__c,
                   AJO_ItemsFailed__c, AJO_BatchSize__c, AJO_Message__c,
                   AJO_ErrorMessage__c, AJO_StackTrace__c, AJO_ScheduledFor__c,
                   AJO_TriggeredBy__c
            FROM   AJOJobRun__c WHERE Id = :runId LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static void closeIfOpen(AJOJobRun__c run, String status, String message) {
        if (run == null || run.AJO_Status__c != 'Running') { return; }
        run.AJO_Message__c = message;
        AJORunLogger.close(run, status, null);
    }

    /**
     * Clears the queued marker this executor owned, so the console stops
     * promising a run that will not happen.
     */
    private void release(AJOJob__c job) {
        if (job.AJO_QueuedForAt__c == null || job.AJO_QueuedForAt__c != dueAt) { return; }
        update new AJOJob__c(Id = job.Id, AJO_QueuedForAt__c = null,
            AJO_Status__c = job.AJO_Status__c == 'Queued' ? 'Idle' : job.AJO_Status__c);
    }
}
