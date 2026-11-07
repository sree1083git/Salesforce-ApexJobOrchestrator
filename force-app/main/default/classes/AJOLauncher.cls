/**
 * Decides what starts at a scheduled check, and hands each start to its own
 * transaction.
 *
 * DISPATCH, NOT EXECUTE. The check's transaction never runs job code. Every
 * job that passes the gates gets its own AJOJobExecutor queueable — delayed to
 * its exact minute when it is due later in the window — so:
 *   - a job that hits a governor limit (uncatchable LimitException) fails
 *     alone, in its own transaction, instead of rolling back the whole check
 *     and every other job's launch and log line with it;
 *   - each job gets the full asynchronous governor limits;
 *   - Runnable jobs can make callouts (the executor implements
 *     Database.AllowsCallouts and performs no DML before the job runs).
 *
 * BULK, NOT PER JOB. Run records are inserted in one DML, patched with their
 * executor ids in one DML, and the job rows updated in one DML, so the check
 * costs a fixed handful of DML statements however many jobs are due. The old
 * per-job open/close spent two DML statements per job and broke at ~70 due
 * jobs, rolling back the check and re-selecting the same jobs forever.
 *
 * BOUNDED. A check launches at most min(Max Launches Per Check, queueable
 * headroom) jobs. The rest keep their Next Run and are taken by the next
 * check: late by one interval, never early, never lost.
 *
 * Gates, in order, per job: suspended, definition policy, activation window,
 * dependency, overlap, dry run, batch throttle, launch budget. Every refusal
 * except the budget leaves a run record, so a job that did not run is visible.
 *
 * Runs without sharing: framework infrastructure acting on every job's state.
 */
public without sharing class AJOLauncher {

    /** Queueable slots left untouched for the platform and other code in the check. */
    @TestVisible
    private static final Integer QUEUEABLE_RESERVE = 2;

    /** Statuses meaning an earlier occurrence has not finished. */
    public static final Set<String> IN_FLIGHT = new Set<String>{ 'Queued', 'Running' };

    /** Statuses the dispatcher never selects. */
    public static final Set<String> NOT_SCHEDULABLE =
        new Set<String>{ 'Suspended', 'Expired', 'Retired', 'Invalid' };

    public static final String JOB_FIELDS =
        'Id, Name, AJO_JobKey__c, AJO_ExecutionType__c, AJO_ApexClassName__c, AJO_BatchSize__c, '
        + 'AJO_CronExpression__c, AJO_TimeZoneSidKey__c, AJO_IsActive__c, AJO_DryRun__c, AJO_Status__c, '
        + 'AJO_NextRunAt__c, AJO_LastRunAt__c, AJO_LastRunStatus__c, AJO_LastDurationSec__c, '
        + 'AJO_LastAsyncApexJobId__c, AJO_OverlapPolicy__c, AJO_Priority__c, AJO_MaxRuntimeMinutes__c, '
        + 'AJO_ConsecutiveFailures__c, AJO_MaxConsecutiveFailures__c, AJO_Parameters__c, '
        + 'AJO_DependsOnJobId__c, AJO_NotifyEmails__c, AJO_LegacyCronJobName__c, '
        + 'AJO_LegacyCronExpression__c, AJO_Pinned__c, AJO_Description__c, '
        + 'AJO_Enabled__c, AJO_StartDate__c, AJO_EndDate__c, AJO_WindowStatus__c, '
        + 'AJO_QueuedForAt__c, AJO_LegacyCronTriggerId__c, AJO_DefinitionManaged__c, '
        + 'AJO_OpsPaused__c, AJO_AllowsCallouts__c, AJO_RunAfterDependency__c, AJO_DependsOnKey__c';

    /** One launch decided in the loop and carried out in bulk after it. */
    private class Planned {
        AJOJob__c job;
        Datetime dueAt;
        Integer delay;
        Planned(AJOJob__c job, Datetime dueAt, Integer delay) {
            this.job = job; this.dueAt = dueAt; this.delay = delay;
        }
    }

    // ================================================================ dispatch

    /**
     * Applies the gates to every due job and enqueues an executor for each one
     * that passes. Mutates and commits the job rows. Never runs job code.
     */
    public static void launch(List<AJOJob__c> jobs, Integer slot) {
        if (jobs == null || jobs.isEmpty()) { return; }

        AJOThrottle throttle = new AJOThrottle();
        Datetime now = Datetime.now();
        Integer budget = launchBudget();
        Integer heldForBudget = 0;

        Map<Id, AJOJobRun__c> parentOutcomes = latestTerminalRuns(dependencyParents(jobs));

        List<Planned> planned = new List<Planned>();
        List<AJOJob__c> toUpdate = new List<AJOJob__c>();
        List<AJOJobRun__c> notes = new List<AJOJobRun__c>();

        for (AJOJob__c job : jobs) {
            Datetime dueAt = job.AJO_NextRunAt__c;
            try {
                if (job.AJO_Status__c == 'Suspended') { continue; }

                // Defence in depth: the dispatcher's query already applies both
                // of these, but the console and the deferred path share this code.
                if (!mayRun(job)) {
                    notes.add(noteRecord(job, dueAt, 'Skipped',
                        'Not backed by a deployed AJO_Job_Definition__mdt record, and unmanaged '
                        + 'jobs are not allowed (AJOSetting__c.AJO_AllowUnmanagedJobs__c).', slot));
                    advance(job, now);
                    toUpdate.add(job);
                    continue;
                }
                if (!AJOWindow.isActive(job)) {
                    notes.add(noteRecord(job, dueAt, 'Skipped',
                        'Outside its activation window: ' + AJOWindow.describe(job), slot));
                    advance(job, now);
                    toUpdate.add(job);
                    continue;
                }
                if (job.AJO_DependsOnJobId__c != null
                    && !dependencySatisfied(job, parentOutcomes, now)) {
                    notes.add(noteRecord(job, dueAt, 'Skipped',
                        'Waiting on dependency ' + dependencyLabel(job)
                        + ': it has not succeeded since this job last ran.', slot));
                    advance(job, now);
                    toUpdate.add(job);
                    continue;
                }
                if (IN_FLIGHT.contains(job.AJO_Status__c) && job.AJO_OverlapPolicy__c != 'Allow') {
                    notes.add(noteRecord(job, dueAt, 'Skipped',
                        'Previous run still ' + job.AJO_Status__c.toLowerCase()
                        + '; overlap policy is ' + job.AJO_OverlapPolicy__c, slot));
                    if (job.AJO_OverlapPolicy__c != 'Queue') { advance(job, now); }
                    toUpdate.add(job);
                    continue;
                }
                if (job.AJO_DryRun__c == true) {
                    notes.add(noteRecord(job, dueAt, 'Dry Run',
                        'Test mode: would have started ' + job.AJO_ApexClassName__c
                        + ' as ' + job.AJO_ExecutionType__c, slot));
                    job.AJO_LastRunStatus__c = 'Dry Run';
                    job.AJO_LastRunAt__c = now;
                    advance(job, now);
                    toUpdate.add(job);
                    continue;
                }
                if (!throttle.claim(job)) {
                    notes.add(noteRecord(job, dueAt, 'Throttled',
                        'Batch capacity is in use (' + AJOConfig.maxConcurrentBatches()
                        + ' concurrent, flex queue cap ' + AJOConfig.flexQueueCap()
                        + '). Retrying at the next check.', slot));
                    continue; // Next Run untouched, so the next check takes it
                }
                if (planned.size() >= budget) {
                    // Next Run untouched: late by one check, never early, never lost.
                    heldForBudget++;
                    continue;
                }

                // The executor waits until the exact minute. A job already due (or
                // overdue) starts now. Rounding is up, so a start is never early.
                Integer delay = deferralMinutes(dueAt, now);
                planned.add(new Planned(job, dueAt, delay));
                job.AJO_Status__c      = 'Queued';
                job.AJO_QueuedForAt__c = dueAt;
                // Advance past the occurrence just taken (not past now), so the next
                // check cannot take the same occurrence again before it lands.
                advance(job, (dueAt != null && dueAt > now) ? dueAt : now);
                toUpdate.add(job);

            } catch (Exception e) {
                // One bad job must never stop the rest of the check.
                notes.add(noteRecord(job, dueAt, 'Failed',
                    e.getTypeName() + ': ' + e.getMessage(), slot));
                recordFailure(job, now, e.getMessage());
                advance(job, now);
                toUpdate.add(job);
            }
        }

        enqueuePlanned(planned, slot, now, toUpdate, notes);

        if (!notes.isEmpty())    { insert notes; }
        if (!toUpdate.isEmpty()) { update dedupe(toUpdate); }

        if (heldForBudget > 0) {
            AJOAlerts.raise(AJOAlerts.WARNING, 'LAUNCH_BACKLOG', null,
                heldForBudget + ' due job(s) were held for the next check because this check '
                + 'reached its launch limit of ' + budget + '. They start late, not early. '
                + 'Raise AJO_MaxLaunchesPerCheck__c only if the queueable headroom allows.');
        }
    }

    /**
     * Inserts the run records, then enqueues one executor per run. A run that
     * cannot be enqueued is closed as Failed and its job handed back to the
     * next check, so nothing is left claiming to be queued when it is not.
     */
    private static void enqueuePlanned(List<Planned> planned, Integer slot, Datetime now,
                                       List<AJOJob__c> toUpdate, List<AJOJobRun__c> notes) {
        if (planned.isEmpty()) { return; }

        List<AJOJobRun__c> runs = new List<AJOJobRun__c>();
        for (Planned p : planned) {
            runs.add(new AJOJobRun__c(
                AJO_Job__c           = p.job.Id,
                AJO_StartedAt__c     = now,   // overwritten by the executor when work starts
                AJO_Status__c        = 'Running',
                AJO_TriggeredBy__c   = 'Heartbeat',
                AJO_ScheduledFor__c  = p.dueAt,
                AJO_HeartbeatSlot__c = slot,
                AJO_Message__c       = p.delay > 0
                    ? 'Queued; starts in ' + p.delay + ' minute(s) on its exact minute.'
                    : 'Queued to start now.'));
        }
        insert runs;

        List<AJOJobRun__c> patches = new List<AJOJobRun__c>();
        for (Integer i = 0; i < planned.size(); i++) {
            Planned p = planned[i];
            AJOJobRun__c run = runs[i];
            try {
                Id asyncId = enqueue(new AJOJobExecutor(p.job.Id, run.Id, p.dueAt), p.delay);
                run.AJO_AsyncApexJobId__c = asyncId;
                p.job.AJO_LastAsyncApexJobId__c = asyncId;
            } catch (Exception e) {
                run.AJO_Status__c       = 'Failed';
                run.AJO_FinishedAt__c   = Datetime.now();
                run.AJO_DurationSec__c  = 0;
                run.AJO_ErrorMessage__c = ('Could not be queued: ' + e.getMessage()).left(4000);
                p.job.AJO_Status__c      = 'Idle';
                p.job.AJO_QueuedForAt__c = null;
                p.job.AJO_NextRunAt__c   = p.dueAt; // hand the occurrence back to the next check
            }
            patches.add(AJORunLogger.patch(run));
        }
        update patches;
    }

    /** How many executors this check may enqueue. */
    @TestVisible
    private static Integer launchBudget() {
        Integer headroom = Limits.getLimitQueueableJobs() - Limits.getQueueableJobs() - QUEUEABLE_RESERVE;
        return Math.max(0, Math.min(AJOConfig.maxLaunchesPerCheck(), headroom));
    }

    private static Id enqueue(Queueable q, Integer delayMinutes) {
        if (delayMinutes == null || delayMinutes <= 0) {
            return System.enqueueJob(q);
        }
        AsyncOptions opts = new AsyncOptions();
        opts.MinimumQueueableDelayInMinutes = Math.min(delayMinutes, AJOConfig.PLATFORM_DELAY_CAP);
        return System.enqueueJob(q, opts);
    }

    // =============================================================== execute

    /**
     * Opens a run and executes the job in THIS transaction. Kept for callers
     * that need a synchronous outcome (tests, the deferred-runner shim). It
     * inserts the run record before the job starts, so a job run this way
     * cannot make callouts; scheduled runs go through AJOJobExecutor instead.
     */
    public static AJOJobRun__c runNow(AJOJob__c job, Datetime dueAt,
                                      String triggeredBy, Integer slot) {
        AJOJobRun__c run = AJORunLogger.open(job, dueAt, triggeredBy, slot);
        execute(job, run);
        return run;
    }

    /**
     * Executes one job against an already-open run. Mutates the job in memory
     * (the caller commits it) and writes the run's outcome.
     *
     * Performs no DML before the job's own code runs, so a Runnable that
     * declares Allows Callouts can call out. Otherwise the job runs inside a
     * savepoint: if it throws, its partial DML is rolled back before the
     * failure is recorded, so a failed run never leaves half its work behind.
     */
    public static void execute(AJOJob__c job, AJOJobRun__c run) {
        if (job.AJO_DefinitionManaged__c == true && !applyDefinition(job)) {
            throw new AJOLegacyAdapter.UnsupportedJobException(
                'Definition ' + job.AJO_JobKey__c + ' is no longer deployed or active.');
        }
        Boolean callouts = job.AJO_AllowsCallouts__c == true && job.AJO_ExecutionType__c == 'Runnable';
        Savepoint sp = callouts ? null : Database.setSavepoint();
        job.AJO_LastRunAt__c = Datetime.now();

        try {
            if (job.AJO_ExecutionType__c == 'Runnable') {
                Object o = AJOLegacyAdapter.instantiate(job.AJO_ApexClassName__c);
                if (!(o instanceof AJORunnable)) {
                    throw new AJOLegacyAdapter.UnsupportedJobException(
                        job.AJO_ApexClassName__c + ' does not implement AJORunnable.');
                }
                AJOContext ctx = new AJOContext(job, run);
                ((AJORunnable) o).run(ctx);

                run.AJO_ItemsProcessed__c = ctx.itemsProcessed;
                run.AJO_ItemsFailed__c    = ctx.itemsFailed;
                run.AJO_Message__c        = ctx.message;
                run.AJO_BatchSize__c      = ctx.batchSize;
                job.AJO_ConsecutiveFailures__c = 0;

                if (ctx.asyncJobId != null) {
                    // The Runnable started async work that outlives this
                    // transaction: keep the run open until reconcile sees the
                    // platform finish it, exactly like a registered Batch.
                    run.AJO_AsyncApexJobId__c     = ctx.asyncJobId;
                    job.AJO_LastAsyncApexJobId__c = ctx.asyncJobId;
                    if (String.isBlank(run.AJO_Message__c)) {
                        run.AJO_Message__c = 'Launched async work; awaiting platform completion.';
                    }
                    update AJORunLogger.patch(run);
                    job.AJO_Status__c        = 'Running';
                    job.AJO_LastRunStatus__c = null;
                    return;
                }
                AJORunLogger.close(run, 'Success', null);
                job.AJO_Status__c          = 'Idle';
                job.AJO_LastRunStatus__c   = 'Success';
                job.AJO_LastDurationSec__c = run.AJO_DurationSec__c;
                return;
            }

            AJOLegacyAdapter.Outcome out = AJOLegacyAdapter.run(
                job.AJO_ApexClassName__c,
                job.AJO_ExecutionType__c,
                job.AJO_BatchSize__c == null ? null : job.AJO_BatchSize__c.intValue());

            job.AJO_LastAsyncApexJobId__c = out.asyncJobId;
            run.AJO_BatchSize__c = out.scopeUsed;
            job.AJO_ConsecutiveFailures__c = 0;

            if (out.asyncJobId == null) {
                // Ran to completion in this transaction: the outcome is known.
                run.AJO_Message__c = 'Ran as ' + out.mode + ' in its own transaction. Any async '
                    + 'work it started itself is not tracked by this run; register the batch '
                    + 'class directly, or implement AJORunnable and set ctx.asyncJobId.';
                AJORunLogger.close(run, 'Success', null);
                job.AJO_Status__c          = 'Idle';
                job.AJO_LastRunStatus__c   = 'Success';
                job.AJO_LastDurationSec__c = run.AJO_DurationSec__c;
            } else {
                // Async work outlives this transaction; reconcile closes the run.
                run.AJO_AsyncApexJobId__c = out.asyncJobId;
                run.AJO_Message__c = 'Launched as ' + out.mode + '; awaiting platform completion.';
                update AJORunLogger.patch(run);
                job.AJO_Status__c        = 'Running';
                job.AJO_LastRunStatus__c = null;
            }

        } catch (Exception e) {
            if (sp != null) { Database.rollback(sp); }
            // Logging the failure must not itself be able to throw.
            try {
                AJORunLogger.fail(run, e);
            } catch (Exception logError) {
                System.debug(LoggingLevel.ERROR, 'AJO could not write the failure for '
                    + job.AJO_JobKey__c + ': ' + logError.getMessage());
            }
            job.AJO_LastDurationSec__c = run.AJO_DurationSec__c;
            recordFailure(job, Datetime.now(), e.getTypeName() + ': ' + e.getMessage());
        }
    }

    /**
     * Overlays the deployed definition onto the in-memory job, so what runs is
     * what the release says even if someone edited the state record. Returns
     * false when the definition is gone or inactive.
     */
    public static Boolean applyDefinition(AJOJob__c job) {
        AJO_Job_Definition__mdt d = AJODefinitions.byKey(job.AJO_JobKey__c);
        if (d == null || d.AJO_Active__c != true) { return false; }
        if (!AJODefinitionValidator.validate(d, AJODefinitions.all()).isEmpty()) { return false; }
        job.AJO_ApexClassName__c  = d.AJO_ApexClass__c;
        job.AJO_ExecutionType__c  = d.AJO_ExecutionType__c;
        job.AJO_BatchSize__c      = d.AJO_BatchSize__c;
        job.AJO_Parameters__c     = d.AJO_Parameters__c;
        job.AJO_AllowsCallouts__c = d.AJO_AllowsCallouts__c == true;
        return true;
    }

    /** True when policy allows this job to run at all. */
    public static Boolean mayRun(AJOJob__c job) {
        return job.AJO_DefinitionManaged__c == true || AJOConfig.allowUnmanagedJobs();
    }

    /**
     * Counts a failure against the circuit breaker and raises the alerts. The
     * job is suspended when it reaches Max Consecutive Failures.
     */
    public static void recordFailure(AJOJob__c job, Datetime at, String reason) {
        job.AJO_LastRunStatus__c = 'Failed';
        job.AJO_LastRunAt__c     = at;
        job.AJO_ConsecutiveFailures__c =
            (job.AJO_ConsecutiveFailures__c == null ? 0 : job.AJO_ConsecutiveFailures__c) + 1;
        Decimal cap = job.AJO_MaxConsecutiveFailures__c;
        if (cap != null && cap > 0 && job.AJO_ConsecutiveFailures__c >= cap) {
            job.AJO_Status__c = 'Suspended';
            AJOAlerts.raise(AJOAlerts.ERROR, 'JOB_SUSPENDED', job.AJO_JobKey__c,
                'Job ' + job.AJO_JobKey__c + ' was switched off after '
                + job.AJO_ConsecutiveFailures__c.intValue() + ' consecutive failures. Last error: '
                + reason, job.AJO_NotifyEmails__c);
        } else {
            job.AJO_Status__c = 'Idle';
            AJOAlerts.raise(AJOAlerts.WARNING, 'JOB_FAILED', job.AJO_JobKey__c,
                'Job ' + job.AJO_JobKey__c + ' failed: ' + reason, job.AJO_NotifyEmails__c);
        }
    }

    // ============================================================= scheduling

    /**
     * Recomputes Next Run forward from the given moment. Missed occurrences
     * never accumulate.
     *
     * Past the job's End Date there is nothing left to schedule: Next Run is
     * cleared and the job marked Expired. A job whose window has not opened is
     * advanced from its Start Date, so the Next Run it shows is one it may take.
     */
    public static void advance(AJOJob__c job, Datetime fromMoment) {
        try {
            Datetime opensAt = AJOWindow.opensAt(job);
            Datetime searchFrom = (opensAt != null && opensAt > fromMoment) ? opensAt : fromMoment;

            Datetime nextRun = AJOCron.next(
                job.AJO_CronExpression__c, searchFrom,
                String.isBlank(job.AJO_TimeZoneSidKey__c)
                    ? AJOConfig.defaultTimeZone() : job.AJO_TimeZoneSidKey__c);

            if (nextRun != null && AJOWindow.isBeyondWindow(job, nextRun)) {
                job.AJO_NextRunAt__c = null;
                // A job still in flight keeps its runtime status; it settles to Expired.
                if (!IN_FLIGHT.contains(job.AJO_Status__c)) { job.AJO_Status__c = 'Expired'; }
                return;
            }
            job.AJO_NextRunAt__c = nextRun;
            if (job.AJO_Status__c == 'Expired' && !AJOWindow.hasExpired(job)) {
                job.AJO_Status__c = 'Idle'; // the window was extended
            }
        } catch (Exception e) {
            // An unparseable expression must not wedge the check.
            job.AJO_NextRunAt__c = null;
            job.AJO_Status__c = 'Suspended';
        }
    }

    /**
     * Minutes until a job due later in this check's window must start, rounded
     * UP and capped at the platform's queueable delay limit. Rounding up keeps
     * a start late by seconds rather than early by a minute. Public because the
     * console previews the same answer.
     */
    public static Integer deferralMinutes(Datetime dueAt, Datetime now) {
        if (dueAt == null || dueAt <= now) { return 0; }
        Long diffMs = dueAt.getTime() - now.getTime();
        Integer mins = (Integer) Math.ceil(diffMs / 60000.0);
        if (mins <= 0) { return 0; }
        return Math.min(mins, AJOConfig.PLATFORM_DELAY_CAP);
    }

    // =========================================================== dependencies

    private static Set<Id> dependencyParents(List<AJOJob__c> jobs) {
        Set<Id> ids = new Set<Id>();
        for (AJOJob__c j : jobs) {
            if (j.AJO_DependsOnJobId__c != null) { ids.add(j.AJO_DependsOnJobId__c); }
        }
        return ids;
    }

    /**
     * The most recent finished run (Success, Failed or Stuck) of each job, in
     * one query. Skips, dry runs and throttle notes are not outcomes.
     */
    public static Map<Id, AJOJobRun__c> latestTerminalRuns(Set<Id> jobIds) {
        Map<Id, AJOJobRun__c> out = new Map<Id, AJOJobRun__c>();
        if (jobIds == null || jobIds.isEmpty()) { return out; }
        for (AJOJobRun__c r : [
                SELECT AJO_Job__c, AJO_Status__c, AJO_FinishedAt__c
                FROM   AJOJobRun__c
                WHERE  AJO_Job__c IN :jobIds
                  AND  AJO_Status__c IN ('Success', 'Failed', 'Stuck')
                  AND  AJO_FinishedAt__c = LAST_N_DAYS:7
                ORDER BY AJO_FinishedAt__c DESC
                LIMIT  2000]) {
            if (!out.containsKey(r.AJO_Job__c)) { out.put(r.AJO_Job__c, r); }
        }
        return out;
    }

    /**
     * A dependency is met when the parent's latest finished run succeeded AND
     * finished after this job last ran (or within the last 24 hours if this job
     * has never run). The old rule — "succeeded at some point today" — let a
     * child run twice on one parent success and was blind across midnight.
     */
    public static Boolean dependencySatisfied(AJOJob__c child, Map<Id, AJOJobRun__c> parentOutcomes,
                                              Datetime now) {
        AJOJobRun__c last = parentOutcomes.get(child.AJO_DependsOnJobId__c);
        if (last == null || last.AJO_Status__c != 'Success' || last.AJO_FinishedAt__c == null) {
            return false;
        }
        Datetime since = child.AJO_LastRunAt__c != null ? child.AJO_LastRunAt__c : now.addHours(-24);
        return last.AJO_FinishedAt__c >= since;
    }

    private static String dependencyLabel(AJOJob__c job) {
        return String.isNotBlank(job.AJO_DependsOnKey__c)
            ? job.AJO_DependsOnKey__c : String.valueOf(job.AJO_DependsOnJobId__c);
    }

    // ================================================================ helpers

    private static List<AJOJob__c> dedupe(List<AJOJob__c> jobs) {
        Map<Id, AJOJob__c> byId = new Map<Id, AJOJob__c>();
        for (AJOJob__c j : jobs) { byId.put(j.Id, j); }
        return byId.values();
    }

    private static AJOJobRun__c noteRecord(AJOJob__c job, Datetime dueAt,
                                           String status, String message, Integer slot) {
        return new AJOJobRun__c(
            AJO_Job__c           = job.Id,
            AJO_StartedAt__c     = Datetime.now(),
            AJO_FinishedAt__c    = Datetime.now(),
            AJO_DurationSec__c   = 0,
            AJO_Status__c        = status,
            AJO_TriggeredBy__c   = 'Heartbeat',
            AJO_ScheduledFor__c  = dueAt,
            AJO_HeartbeatSlot__c = slot,
            AJO_Message__c       = message == null ? null : message.left(4000)
        );
    }
}
