/**
 * Opens, closes and reconciles run records, and settles their outcomes back
 * onto the job (last-run fields, circuit breaker, alerts, dependency chaining).
 * Retention is enforced by AJOSupervisor/AJOPurgeBatch: the log grows by one
 * row per run and per refusal, so it must not be unbounded.
 *
 * Runs without sharing: it settles outcomes onto job records whatever their
 * owner, from asynchronous contexts (executor, batch finish, heartbeat).
 */
public without sharing class AJORunLogger {

    public static AJOJobRun__c open(AJOJob__c job, Datetime scheduledFor,
                                    String triggeredBy, Integer slot) {
        AJOJobRun__c run = new AJOJobRun__c(
            AJO_Job__c          = job.Id,
            AJO_StartedAt__c    = Datetime.now(),
            AJO_Status__c       = 'Running',
            AJO_TriggeredBy__c  = triggeredBy,
            AJO_ScheduledFor__c = scheduledFor,
            AJO_HeartbeatSlot__c = slot
        );
        insert run;
        return run;
    }

    public static void close(AJOJobRun__c run, String status, Id asyncJobId) {
        run.AJO_FinishedAt__c = Datetime.now();
        run.AJO_Status__c     = status;
        run.AJO_AsyncApexJobId__c = asyncJobId;
        run.AJO_DurationSec__c = seconds(run.AJO_StartedAt__c, run.AJO_FinishedAt__c);
        update patch(run);
    }

    /**
     * AJO_Job__c is a non-reparentable master-detail field, so it cannot appear in
     * an update payload — the platform rejects the whole DML with
     * CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY. Writing through a fresh instance
     * keyed on Id sends only the fields that are actually mutable.
     */
    public static AJOJobRun__c patch(AJOJobRun__c run) {
        return new AJOJobRun__c(
            Id                = run.Id,
            AJO_Status__c         = run.AJO_Status__c,
            AJO_StartedAt__c      = run.AJO_StartedAt__c,
            AJO_FinishedAt__c     = run.AJO_FinishedAt__c,
            AJO_DurationSec__c    = run.AJO_DurationSec__c,
            AJO_AsyncApexJobId__c = run.AJO_AsyncApexJobId__c,
            AJO_ItemsProcessed__c = run.AJO_ItemsProcessed__c,
            AJO_ItemsFailed__c    = run.AJO_ItemsFailed__c,
            AJO_BatchSize__c      = run.AJO_BatchSize__c,
            AJO_Message__c        = run.AJO_Message__c,
            AJO_ErrorMessage__c   = run.AJO_ErrorMessage__c,
            AJO_StackTrace__c     = run.AJO_StackTrace__c
        );
    }

    public static void fail(AJOJobRun__c run, Exception e) {
        run.AJO_FinishedAt__c  = Datetime.now();
        run.AJO_Status__c      = 'Failed';
        run.AJO_ErrorMessage__c = truncate(e.getTypeName() + ': ' + e.getMessage(), 4000);
        run.AJO_StackTrace__c   = truncate(e.getStackTraceString(), 8000);
        run.AJO_DurationSec__c  = seconds(run.AJO_StartedAt__c, run.AJO_FinishedAt__c);
        update patch(run);
    }

    /** A run that never started — throttled, skipped, or a dry run. */
    public static void note(AJOJob__c job, Datetime scheduledFor, String status,
                            String message, Integer slot) {
        insert new AJOJobRun__c(
            AJO_Job__c           = job.Id,
            AJO_StartedAt__c     = Datetime.now(),
            AJO_FinishedAt__c    = Datetime.now(),
            AJO_DurationSec__c   = 0,
            AJO_Status__c        = status,
            AJO_TriggeredBy__c   = 'Heartbeat',
            AJO_ScheduledFor__c  = scheduledFor,
            AJO_HeartbeatSlot__c = slot,
            AJO_ErrorMessage__c  = truncate(message, 4000)
        );
    }

    /**
     * Async work outlives the dispatcher transaction, so the run record is left
     * open with its AsyncApexJobId and closed here on a later heartbeat.
     */
    public static Integer reconcile() {
        List<AJOJobRun__c> openRuns = [
            SELECT Id, AJO_Job__c, AJO_StartedAt__c, AJO_FinishedAt__c, AJO_Status__c,
                   AJO_DurationSec__c, AJO_AsyncApexJobId__c, AJO_ItemsProcessed__c,
                   AJO_ItemsFailed__c, AJO_BatchSize__c, AJO_Message__c,
                   AJO_ErrorMessage__c, AJO_StackTrace__c
            FROM   AJOJobRun__c
            WHERE  AJO_Status__c = 'Running'
              AND  AJO_AsyncApexJobId__c != null
              AND  AJO_StartedAt__c = LAST_N_DAYS:3
            LIMIT  500
        ];
        if (openRuns.isEmpty()) { return 0; }

        Set<Id> asyncIds = new Set<Id>();
        for (AJOJobRun__c r : openRuns) {
            try { asyncIds.add((Id) r.AJO_AsyncApexJobId__c); } catch (Exception e) { /* stale id */ }
        }
        if (asyncIds.isEmpty()) { return 0; }

        Map<Id, AsyncApexJob> jobs = new Map<Id, AsyncApexJob>([
            SELECT Id, Status, ExtendedStatus, NumberOfErrors,
                   JobItemsProcessed, TotalJobItems, CompletedDate, ApexClass.Name
            FROM   AsyncApexJob
            WHERE  Id IN :asyncIds
        ]);

        List<AJOJobRun__c> toUpdate = new List<AJOJobRun__c>();
        Map<Id, String> jobOutcome = new Map<Id, String>();
        Map<Id, String> failureReason = new Map<Id, String>();

        for (AJOJobRun__c r : openRuns) {
            AsyncApexJob a = jobs.get((Id) r.AJO_AsyncApexJobId__c);
            if (a == null) { continue; }
            if (a.Status == 'Completed' || a.Status == 'Failed' || a.Status == 'Aborted') {
                r.AJO_FinishedAt__c   = a.CompletedDate != null ? a.CompletedDate : Datetime.now();
                r.AJO_DurationSec__c  = seconds(r.AJO_StartedAt__c, r.AJO_FinishedAt__c);
                // The run still points at its executor. The executor always closes
                // its run or re-points it at the async work it started, so an
                // executor that finished while its run is still open died with an
                // uncatchable exception (a governor limit, typically) that rolled
                // back its own bookkeeping. Without this branch that failure would
                // be invisible and would never count against the circuit breaker.
                if (a.ApexClass != null && a.ApexClass.Name == 'AJOJobExecutor') {
                    r.AJO_Status__c = 'Failed';
                    r.AJO_ErrorMessage__c = truncate('The job\'s transaction ended without '
                        + 'recording an outcome (' + a.Status + '). '
                        + (String.isBlank(a.ExtendedStatus)
                           ? 'Most often a governor limit was exceeded.' : a.ExtendedStatus), 4000);
                    toUpdate.add(patch(r));
                    jobOutcome.put(r.AJO_Job__c, 'Failed');
                    failureReason.put(r.AJO_Job__c, r.AJO_ErrorMessage__c);
                    continue;
                }
                r.AJO_ItemsProcessed__c = a.JobItemsProcessed;
                r.AJO_ItemsFailed__c    = a.NumberOfErrors;
                Boolean ok = (a.Status == 'Completed' && a.NumberOfErrors == 0);
                r.AJO_Status__c = ok ? 'Success' : 'Failed';
                // AsyncApexJob counts chunks, not records: a 10,000-record batch
                // at a scope of 200 reports 50. Saying so on the record stops
                // Items Processed being read as a record count.
                if (r.AJO_Message__c == null || r.AJO_Message__c.startsWith('Launched as')) {
                    r.AJO_Message__c = 'Finished ' + a.JobItemsProcessed + ' of '
                        + a.TotalJobItems + ' batch(es)'
                        + (r.AJO_BatchSize__c == null
                           ? '' : ' at ' + r.AJO_BatchSize__c.intValue() + ' records each')
                        + '; ' + a.NumberOfErrors + ' error(s).';
                }
                if (!ok) {
                    r.AJO_ErrorMessage__c = truncate(
                        String.isBlank(a.ExtendedStatus)
                            ? a.Status + ' with ' + a.NumberOfErrors + ' errors'
                            : a.ExtendedStatus, 4000);
                }
                toUpdate.add(patch(r));
                jobOutcome.put(r.AJO_Job__c, r.AJO_Status__c);
                if (!ok) { failureReason.put(r.AJO_Job__c, r.AJO_ErrorMessage__c); }
            }
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
            settleJobs(jobOutcome, failureReason);
        }
        return toUpdate.size();
    }

    /**
      * Lets a batch close its own run record with real record counts.
      *
      * Call it from finish(). Reconciliation can only read AsyncApexJob, which
      * counts chunks — a 10,000 record batch at a scope of 200 reports 50 — so
      * Items Processed never meant what people read it to mean. A batch knows
      * the true figures and this is how it hands them over. Closing the run here
      * also takes it out of reconcile()'s reach, since that only considers runs
      * still marked Running, so nothing overwrites what you report.
      *
      * Safe to call from any batch, whether or not AJO launched it: when no open
      * run matches the job id it does nothing and returns false.
      */
    public static Boolean report(Id asyncJobId, Integer itemsProcessed,
                                 Integer itemsFailed, String message) {
        if (asyncJobId == null) { return false; }
        List<AJOJobRun__c> runs = [
            SELECT Id, AJO_Job__c, AJO_StartedAt__c, AJO_FinishedAt__c, AJO_Status__c,
                   AJO_DurationSec__c, AJO_AsyncApexJobId__c, AJO_ItemsProcessed__c,
                   AJO_ItemsFailed__c, AJO_BatchSize__c, AJO_Message__c,
                   AJO_ErrorMessage__c, AJO_StackTrace__c
            FROM   AJOJobRun__c
            WHERE  AJO_AsyncApexJobId__c = :String.valueOf(asyncJobId)
              AND  AJO_Status__c = 'Running'
            LIMIT  1
        ];
        if (runs.isEmpty()) { return false; }

        AJOJobRun__c run = runs[0];
        run.AJO_ItemsProcessed__c = itemsProcessed;
        run.AJO_ItemsFailed__c    = itemsFailed;
        if (String.isNotBlank(message)) { run.AJO_Message__c = truncate(message, 4000); }
        run.AJO_FinishedAt__c  = Datetime.now();
        run.AJO_DurationSec__c = seconds(run.AJO_StartedAt__c, run.AJO_FinishedAt__c);

        Boolean ok = (itemsFailed == null || itemsFailed == 0);
        run.AJO_Status__c = ok ? 'Success' : 'Failed';
        if (!ok && String.isBlank(run.AJO_ErrorMessage__c)) {
            run.AJO_ErrorMessage__c = itemsFailed + ' record(s) could not be processed.';
        }
        update patch(run);
        settleJobs(new Map<Id, String>{ run.AJO_Job__c => run.AJO_Status__c },
                   new Map<Id, String>{ run.AJO_Job__c => run.AJO_ErrorMessage__c });
        // report() is called from a batch's finish(), outside any check, so it
        // sends its own alerts.
        AJOAlerts.flush();
        return true;
    }

    /** Applies a run outcome back onto the job: last-run fields and the breaker. */
    public static void settle(Id jobId, String outcome, Decimal durationSec, Id asyncJobId) {
        settleJobs(new Map<Id, String>{ jobId => outcome });
    }

    private static void settleJobs(Map<Id, String> outcomes) {
        settleJobs(outcomes, new Map<Id, String>());
    }

    /**
     * Applies run outcomes back onto their jobs: last-run fields, the circuit
     * breaker and its alerts, window expiry, and dependency chaining.
     *
     * A job that is 'Queued' keeps that status: its NEXT occurrence is already
     * waiting in an executor, and flipping it to Idle would let the overlap
     * gate start yet another one.
     */
    private static void settleJobs(Map<Id, String> outcomes, Map<Id, String> reasons) {
        if (outcomes.isEmpty()) { return; }
        List<AJOJob__c> jobs = [
            SELECT Id, AJO_JobKey__c, AJO_Status__c, AJO_ConsecutiveFailures__c,
                   AJO_MaxConsecutiveFailures__c, AJO_LastRunStatus__c, AJO_LastRunAt__c,
                   AJO_LastDurationSec__c, AJO_Enabled__c, AJO_StartDate__c, AJO_EndDate__c,
                   AJO_NextRunAt__c, AJO_NotifyEmails__c
            FROM   AJOJob__c
            WHERE  Id IN :outcomes.keySet()
        ];
        Set<Id> succeeded = new Set<Id>();
        for (AJOJob__c j : jobs) {
            String outcome = outcomes.get(j.Id);
            Boolean queued = j.AJO_Status__c == 'Queued';
            j.AJO_LastRunStatus__c = outcome;
            j.AJO_LastRunAt__c     = Datetime.now();

            if (outcome == 'Failed') {
                String reason = reasons.get(j.Id);
                AJOLauncher.recordFailure(j, Datetime.now(), reason == null ? 'see the run record' : reason);
                if (queued && j.AJO_Status__c != 'Suspended') { j.AJO_Status__c = 'Queued'; }
            } else {
                j.AJO_ConsecutiveFailures__c = 0;
                if (j.AJO_Status__c != 'Suspended' && !queued) { j.AJO_Status__c = 'Idle'; }
                if (outcome == 'Success') { succeeded.add(j.Id); }
            }

            // A job whose window closed while its last run was in flight settles
            // straight into Expired. Suspended outranks it: a circuit-broken job
            // still needs a human to look at it.
            if (j.AJO_Status__c != 'Suspended' && !queued && AJOWindow.hasExpired(j)) {
                j.AJO_Status__c = 'Expired';
                j.AJO_NextRunAt__c = null;
            }
        }
        update jobs;
        chainDependents(succeeded);
    }

    /**
     * Dependency chaining. When a job succeeds, every active dependent that
     * asked to Run After Dependency is made due now, so the next check starts
     * it (within one interval) instead of the child waiting for its own cron
     * and finding the dependency stale.
     */
    @TestVisible
    private static void chainDependents(Set<Id> parentIds) {
        if (parentIds == null || parentIds.isEmpty()) { return; }
        Datetime now = Datetime.now();
        Set<String> blocked = AJOLauncher.NOT_SCHEDULABLE;
        List<AJOJob__c> children = Database.query(
            'SELECT Id, AJO_NextRunAt__c FROM AJOJob__c '
            + 'WHERE AJO_DependsOnJobId__c IN :parentIds '
            + '  AND AJO_RunAfterDependency__c = true '
            + '  AND AJO_Status__c NOT IN :blocked '
            + '  AND ' + AJOWindow.SOQL_FILTER);
        List<AJOJob__c> toUpdate = new List<AJOJob__c>();
        for (AJOJob__c c : children) {
            if (c.AJO_NextRunAt__c == null || c.AJO_NextRunAt__c > now) {
                toUpdate.add(new AJOJob__c(Id = c.Id, AJO_NextRunAt__c = now));
            }
        }
        if (!toUpdate.isEmpty()) { update toUpdate; }
    }

    public static Decimal seconds(Datetime a, Datetime b) {
        if (a == null || b == null) { return null; }
        return ((Decimal) (b.getTime() - a.getTime())) / 1000;
    }

    private static String truncate(String s, Integer n) {
        if (s == null) { return null; }
        return s.length() <= n ? s : s.substring(0, n);
    }
}