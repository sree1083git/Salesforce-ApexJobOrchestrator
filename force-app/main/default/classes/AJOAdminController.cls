/**
 * Back end for the Apex Job Orchestration console (ajoJobConsole LWC).
 *
 * Under the hybrid model, WHAT a job runs and WHEN is defined in
 * AJO_Job_Definition__mdt and changes only through a release. The console
 * therefore splits into:
 *   - read: jobs, activity, errors, health, the next-check preview;
 *   - operate (no release needed): pause/resume (AJO_OpsPaused__c), Run now,
 *     Run at next check, retry, pause all, maintenance, sync now;
 *   - author (generates files for a release, writes nothing): a new definition,
 *     an export of an unmanaged job, a takeover of a Setup schedule.
 * Editing, deleting and converting directly in the org remain available only
 * for unmanaged jobs while AJO_AllowUnmanagedJobs__c is on (migration period).
 *
 * Every @AuraEnabled method is callable directly from the browser by anyone
 * with access to this class, so permission checks live here, not in the UI.
 */
public with sharing class AJOAdminController {

    // ------------------------------------------------------------ view types

    public class JobView {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String jobKey;
        @AuraEnabled public String apexClass;
        @AuraEnabled public String executionType;
        @AuraEnabled public String cronExpression;
        @AuraEnabled public String schedule;
        @AuraEnabled public String timeZone;
        @AuraEnabled public Boolean isActive;
        @AuraEnabled public Boolean enabled;
        @AuraEnabled public Date startDate;
        @AuraEnabled public Date endDate;
        @AuraEnabled public String windowStatus;
        @AuraEnabled public Integer daysRemaining;
        @AuraEnabled public Boolean dryRun;
        @AuraEnabled public Boolean pinned;
        @AuraEnabled public String status;
        @AuraEnabled public Datetime nextRunAt;
        @AuraEnabled public String nextRunLocal;
        @AuraEnabled public Datetime lastRunAt;
        @AuraEnabled public String lastRunStatus;
        @AuraEnabled public Decimal lastDurationSec;
        @AuraEnabled public Decimal priority;
        @AuraEnabled public Decimal consecutiveFailures;
        @AuraEnabled public String overlapPolicy;
        @AuraEnabled public String legacyCronJobName;
        @AuraEnabled public String legacyCronExpression;
        @AuraEnabled public String description;
        @AuraEnabled public Boolean converted;
        @AuraEnabled public String convertedFrom;
        // A queued run locks the job against edits until it has started.
        @AuraEnabled public Datetime queuedForAt;
        @AuraEnabled public Boolean editLocked;
        @AuraEnabled public String editLockReason;
        // Hybrid model: where the definition lives and its operational state.
        @AuraEnabled public Boolean managed;
        @AuraEnabled public Boolean opsPaused;
        @AuraEnabled public String definitionError;
        @AuraEnabled public Datetime cutoverAt;
    }

    public class RunView {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String jobName;
        @AuraEnabled public String status;
        @AuraEnabled public Datetime startedAt;
        @AuraEnabled public Datetime finishedAt;
        @AuraEnabled public Decimal durationSec;
        @AuraEnabled public Decimal itemsProcessed;
        @AuraEnabled public Decimal itemsFailed;
        @AuraEnabled public String triggeredBy;
        @AuraEnabled public String message;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public String stackTrace;
        @AuraEnabled public String asyncApexJobId;
        @AuraEnabled public Datetime scheduledFor;
        @AuraEnabled public Decimal heartbeatSlot;
        @AuraEnabled public Decimal batchSize;
    }

    /** One job the next scheduled check will consider, and what it will do with it. */
    public class DueView {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String apexClass;
        @AuraEnabled public String executionType;
        @AuraEnabled public Decimal priority;
        @AuraEnabled public Datetime dueAt;
        @AuraEnabled public String dueAtLocal;
        @AuraEnabled public Boolean willRun;
        @AuraEnabled public String verdict;
        @AuraEnabled public String verdictReason;
    }

    public class NextCheckView {
        @AuraEnabled public Boolean installed;
        @AuraEnabled public Boolean paused;
        @AuraEnabled public Datetime checkAt;
        @AuraEnabled public String checkAtLocal;
        @AuraEnabled public String checkName;
        @AuraEnabled public Integer everyMinutes;
        @AuraEnabled public Integer willRunCount;
        @AuraEnabled public List<DueView> due;
    }

    /** One existing Setup schedule, and whether this framework could take it over. */
    public class ConvertibleView {
        @AuraEnabled public Id cronTriggerId;
        @AuraEnabled public String name;
        @AuraEnabled public String className;
        @AuraEnabled public String executionType;
        @AuraEnabled public String cronExpression;
        @AuraEnabled public String schedule;
        @AuraEnabled public String timeZone;
        @AuraEnabled public String state;
        @AuraEnabled public Datetime lastFireTime;
        @AuraEnabled public String lastFireLocal;
        @AuraEnabled public Datetime nextFireTime;
        @AuraEnabled public String nextFireLocal;
        @AuraEnabled public Integer timesTriggered;
        @AuraEnabled public Datetime endTime;
        @AuraEnabled public Boolean convertible;
        /** Why it cannot be converted. Non-empty means the row is refused. */
        @AuraEnabled public List<String> blockers;
        /** Convertible, but read these first. */
        @AuraEnabled public List<String> warnings;
        @AuraEnabled public String suggestedKey;
    }

    /** One row of a bulk conversion: what happened to that schedule. */
    public class ConversionRow {
        @AuraEnabled public Id cronTriggerId;
        @AuraEnabled public String name;
        @AuraEnabled public Boolean converted;
        @AuraEnabled public Id jobId;
        @AuraEnabled public String detail;
    }

    public class RestorePlan {
        @AuraEnabled public Id jobId;
        @AuraEnabled public String jobName;
        @AuraEnabled public String legacyName;
        @AuraEnabled public String legacyCron;
        @AuraEnabled public String originalTimeZone;
        @AuraEnabled public String yourTimeZone;
        @AuraEnabled public Boolean timeZoneMatches;
        @AuraEnabled public List<String> originalFireTimes;
        @AuraEnabled public List<String> restoredFireTimes;
        @AuraEnabled public List<String> blockers;
    }

    public class ConversionResult {
        @AuraEnabled public Id jobId;
        @AuraEnabled public String jobName;
        @AuraEnabled public String nextRunLocal;
        @AuraEnabled public Boolean testMode;
        @AuraEnabled public Integer slotsUsedNow;
        @AuraEnabled public Integer slotLimit;
        @AuraEnabled public String summary;
    }

    public class HealthView {
        @AuraEnabled public Integer slotsUsed;
        @AuraEnabled public Integer slotLimit;
        @AuraEnabled public Integer slotsUsedByFramework;
        @AuraEnabled public Integer heartbeatsExpected;
        @AuraEnabled public Integer heartbeatsArmed;
        @AuraEnabled public Boolean supervisorArmed;
        @AuraEnabled public Integer batchesInFlight;
        @AuraEnabled public Integer maxConcurrentBatches;
        @AuraEnabled public Integer jobsTotal;
        @AuraEnabled public Integer jobsActive;
        @AuraEnabled public Integer jobsSuspended;
        @AuraEnabled public Integer jobsExpired;
        @AuraEnabled public Integer jobsNotStarted;
        @AuraEnabled public Integer jobsEndingWithin7Days;
        @AuraEnabled public Integer failures24h;
        @AuraEnabled public Integer runs24h;
        @AuraEnabled public Boolean killSwitch;
        @AuraEnabled public Integer runLogRows;
        @AuraEnabled public String defaultTimeZone;
        @AuraEnabled public List<TriggerView> triggers;
        // Added for the operating header: one sentence anybody can read, plus
        // the two facts it is built from.
        @AuraEnabled public Boolean installed;
        @AuraEnabled public Boolean canAdminister;
        @AuraEnabled public Integer heartbeatMinutes;
        @AuraEnabled public Datetime nextCheckAt;
        @AuraEnabled public String nextCheckLocal;
        @AuraEnabled public String statusHeadline;
        @AuraEnabled public String statusTone;
        // Watchdog and hybrid model.
        @AuraEnabled public Datetime lastHeartbeatAt;
        @AuraEnabled public Boolean heartbeatStale;
        @AuraEnabled public Integer jobsInvalid;
        @AuraEnabled public Integer definitionsDeployed;
        @AuraEnabled public Boolean unmanagedAllowed;
        @AuraEnabled public Integer flexQueueDepth;
    }

    public class TriggerView {
        @AuraEnabled public String name;
        @AuraEnabled public String cronExpression;
        @AuraEnabled public String state;
        @AuraEnabled public Datetime nextFireTime;
        @AuraEnabled public Datetime previousFireTime;
        @AuraEnabled public Integer timesTriggered;
    }

    // ------------------------------------------------------------------ read

    @AuraEnabled(cacheable=false)
    public static List<JobView> getJobs() {
        List<JobView> out = new List<JobView>();
        for (AJOJob__c j : Database.query(
                'SELECT ' + AJOLauncher.JOB_FIELDS + ', AJO_DefinitionError__c, AJO_CutoverAt__c'
                + ' FROM AJOJob__c ORDER BY AJO_Enabled__c DESC, AJO_Priority__c ASC NULLS LAST, Name ASC')) {
            out.add(toView(j));
        }
        return out;
    }

    private static JobView toView(AJOJob__c j) {
        JobView v = new JobView();
        v.id = j.Id;
        v.name = j.Name;
        v.jobKey = j.AJO_JobKey__c;
        v.apexClass = j.AJO_ApexClassName__c;
        v.executionType = j.AJO_ExecutionType__c;
        v.cronExpression = j.AJO_CronExpression__c;
        v.schedule = AJOCron.describeSchedule(j.AJO_CronExpression__c);
        v.timeZone = String.isBlank(j.AJO_TimeZoneSidKey__c)
                     ? AJOConfig.defaultTimeZone() : j.AJO_TimeZoneSidKey__c;
        v.isActive = j.AJO_IsActive__c;
        v.enabled = j.AJO_Enabled__c;
        v.startDate = j.AJO_StartDate__c;
        v.endDate = j.AJO_EndDate__c;
        v.windowStatus = j.AJO_WindowStatus__c;
        v.daysRemaining = AJOWindow.daysRemaining(j);
        v.dryRun = j.AJO_DryRun__c;
        v.pinned = j.AJO_Pinned__c;
        v.status = j.AJO_Status__c;
        v.nextRunAt = j.AJO_NextRunAt__c;
        v.nextRunLocal = AJOCron.formatLocal(j.AJO_NextRunAt__c, v.timeZone);
        v.lastRunAt = j.AJO_LastRunAt__c;
        v.lastRunStatus = j.AJO_LastRunStatus__c;
        v.lastDurationSec = j.AJO_LastDurationSec__c;
        v.priority = j.AJO_Priority__c;
        v.consecutiveFailures = j.AJO_ConsecutiveFailures__c;
        v.overlapPolicy = j.AJO_OverlapPolicy__c;
        v.legacyCronJobName = j.AJO_LegacyCronJobName__c;
        v.legacyCronExpression = j.AJO_LegacyCronExpression__c;
        v.description = j.AJO_Description__c;
        v.convertedFrom = j.AJO_LegacyCronJobName__c;
        v.converted = String.isNotBlank(j.AJO_LegacyCronTriggerId__c);
        v.queuedForAt = j.AJO_QueuedForAt__c;
        v.managed = j.AJO_DefinitionManaged__c == true;
        v.opsPaused = j.AJO_OpsPaused__c == true;
        v.definitionError = j.AJO_DefinitionError__c;
        v.cutoverAt = j.AJO_CutoverAt__c;
        v.editLocked = v.managed || isEditLocked(j);
        v.editLockReason = v.managed ? managedReason(j) : (v.editLocked ? editLockReason(j) : null);
        return v;
    }

    private static final String RUN_FIELDS =
        'Id, Name, AJO_Job__r.Name, AJO_Status__c, AJO_StartedAt__c, AJO_FinishedAt__c, '
        + 'AJO_DurationSec__c, AJO_ItemsProcessed__c, AJO_ItemsFailed__c, AJO_TriggeredBy__c, '
        + 'AJO_Message__c, AJO_ErrorMessage__c, AJO_StackTrace__c, AJO_AsyncApexJobId__c, '
        + 'AJO_ScheduledFor__c, AJO_HeartbeatSlot__c, AJO_BatchSize__c';

    /**
      * Every run in one table, which is the only view most people want.
      *
      * filter is one of 'all', 'failures', 'today'. slot narrows to a single
      * scheduled check — the heartbeat slot was always recorded on the run and
      * was never shown, which is what made "what did the 14:20 check do" an
      * unanswerable question.
      */
    @AuraEnabled(cacheable=false)
    public static List<RunView> getActivity(Id jobId, String filter, Integer slot,
                                            Integer limitSize) {
        Integer lim = (limitSize == null || limitSize <= 0) ? 100 : Math.min(limitSize, 500);
        List<String> clauses = new List<String>();
        if (jobId != null) { clauses.add('AJO_Job__c = :jobId'); }
        if (filter == 'failures') { clauses.add('AJO_Status__c IN (\'Failed\', \'Stuck\')'); }
        if (filter == 'today')    { clauses.add('AJO_StartedAt__c = LAST_N_DAYS:1'); }
        if (slot != null)         { clauses.add('AJO_HeartbeatSlot__c = :slot'); }

        String soql = 'SELECT ' + RUN_FIELDS + ' FROM AJOJobRun__c '
                    + (clauses.isEmpty() ? '' : 'WHERE ' + String.join(clauses, ' AND ') + ' ')
                    + 'ORDER BY AJO_StartedAt__c DESC NULLS LAST, Name DESC '
                    + 'LIMIT :lim';

        List<RunView> out = new List<RunView>();
        for (AJOJobRun__c r : (List<AJOJobRun__c>) Database.query(soql)) {
            out.add(toRunView(r));
        }
        return out;
    }

    /** The distinct scheduled checks that actually have runs against them. */
    @AuraEnabled(cacheable=false)
    public static List<Integer> getUsedSlots() {
        Set<Integer> seen = new Set<Integer>();
        for (AJOJobRun__c r : [
                SELECT AJO_HeartbeatSlot__c FROM AJOJobRun__c
                WHERE  AJO_HeartbeatSlot__c != null
                  AND  AJO_StartedAt__c = LAST_N_DAYS:7
                LIMIT  2000]) {
            seen.add(((Decimal) r.AJO_HeartbeatSlot__c).intValue());
        }
        List<Integer> out = new List<Integer>(seen);
        out.sort();
        return out;
    }

    /** Kept for the framework tests and for internal callers. */
    public static List<RunView> getRuns(Id jobId, Integer limitSize) {
        return getActivity(jobId, 'all', null, limitSize);
    }

    private static RunView toRunView(AJOJobRun__c r) {
        RunView v = new RunView();
        v.id = r.Id;
        v.name = r.Name;
        v.jobName = r.AJO_Job__r != null ? r.AJO_Job__r.Name : null;
        v.status = r.AJO_Status__c;
        v.startedAt = r.AJO_StartedAt__c;
        v.finishedAt = r.AJO_FinishedAt__c;
        v.durationSec = r.AJO_DurationSec__c;
        v.itemsProcessed = r.AJO_ItemsProcessed__c;
        v.itemsFailed = r.AJO_ItemsFailed__c;
        v.triggeredBy = r.AJO_TriggeredBy__c;
        v.message = r.AJO_Message__c;
        v.errorMessage = r.AJO_ErrorMessage__c;
        v.stackTrace = r.AJO_StackTrace__c;
        v.asyncApexJobId = r.AJO_AsyncApexJobId__c;
        v.scheduledFor = r.AJO_ScheduledFor__c;
        v.heartbeatSlot = r.AJO_HeartbeatSlot__c;
        v.batchSize = r.AJO_BatchSize__c;
        return v;
    }

    @AuraEnabled(cacheable=false)
    public static HealthView getHealth() {
        HealthView h = new HealthView();
        h.slotLimit = AJOConfig.SLOT_LIMIT;
        h.slotsUsed = AJOInstaller.scheduledApexSlotsUsed();
        h.maxConcurrentBatches = AJOConfig.maxConcurrentBatches();
        h.batchesInFlight = AJOThrottle.inFlightBatches();
        h.killSwitch = AJOConfig.killSwitch();
        h.defaultTimeZone = AJOConfig.defaultTimeZone();
        h.heartbeatsExpected = AJOInstaller.slots().size();

        h.triggers = new List<TriggerView>();
        Integer armed = 0;
        Boolean supervisor = false;
        Datetime earliest = null;
        for (CronTrigger ct : AJOInstaller.ownTriggers()) {
            TriggerView t = new TriggerView();
            t.name = ct.CronJobDetail.Name;
            t.cronExpression = ct.CronExpression;
            t.state = ct.State;
            t.nextFireTime = ct.NextFireTime;
            t.previousFireTime = ct.PreviousFireTime;
            t.timesTriggered = ct.TimesTriggered;
            h.triggers.add(t);
            if (t.name == AJOInstaller.SUPERVISOR_NAME) {
                supervisor = true;
            } else {
                armed++;
                if (t.nextFireTime != null && (earliest == null || t.nextFireTime < earliest)) {
                    earliest = t.nextFireTime;
                }
            }
        }
        h.heartbeatsArmed = armed;
        h.supervisorArmed = supervisor;
        h.slotsUsedByFramework = h.triggers.size();

        Date today = Date.today();
        Date weekOut = today.addDays(7);
        h.jobsTotal = [SELECT COUNT() FROM AJOJob__c];
        h.jobsActive = Database.countQuery(
            'SELECT COUNT() FROM AJOJob__c WHERE ' + AJOWindow.SOQL_FILTER);
        h.jobsSuspended = [SELECT COUNT() FROM AJOJob__c WHERE AJO_Status__c = 'Suspended'];
        h.jobsExpired = [
            SELECT COUNT() FROM AJOJob__c
            WHERE AJO_EndDate__c != null AND AJO_EndDate__c < :today
        ];
        h.jobsNotStarted = [
            SELECT COUNT() FROM AJOJob__c
            WHERE AJO_Enabled__c = true
              AND AJO_StartDate__c != null AND AJO_StartDate__c > :today
        ];
        h.jobsEndingWithin7Days = [
            SELECT COUNT() FROM AJOJob__c
            WHERE AJO_Enabled__c = true
              AND AJO_EndDate__c >= :today AND AJO_EndDate__c <= :weekOut
        ];
        h.runs24h = [SELECT COUNT() FROM AJOJobRun__c WHERE AJO_StartedAt__c = LAST_N_DAYS:1];
        h.failures24h = [
            SELECT COUNT() FROM AJOJobRun__c
            WHERE AJO_StartedAt__c = LAST_N_DAYS:1 AND AJO_Status__c IN ('Failed', 'Stuck')
        ];
        h.runLogRows = [SELECT COUNT() FROM AJOJobRun__c];

        h.jobsInvalid         = [SELECT COUNT() FROM AJOJob__c WHERE AJO_Status__c = 'Invalid'];
        h.definitionsDeployed = AJODefinitions.all().size();
        h.unmanagedAllowed    = AJOConfig.allowUnmanagedJobs();
        h.flexQueueDepth      = AJOThrottle.flexQueueDepth();
        h.lastHeartbeatAt     = AJOConfig.lastHeartbeatAt();

        h.heartbeatMinutes = AJOConfig.heartbeatMinutes();
        h.installed        = (armed >= h.heartbeatsExpected) && supervisor;
        h.heartbeatStale   = h.installed && !h.killSwitch
            && (h.lastHeartbeatAt == null
                || h.lastHeartbeatAt.addMinutes(AJOConfig.staleHeartbeatMinutes()) < Datetime.now());
        h.canAdminister    = canAdminister();
        h.nextCheckAt      = earliest;
        h.nextCheckLocal   = AJOCron.formatLocal(earliest, h.defaultTimeZone);
        applySummary(h);
        return h;
    }

    /**
      * One sentence for the header. Written here rather than in the component so
      * the console, a report and a future digest email cannot disagree about
      * what "running normally" means.
      */
    private static void applySummary(HealthView h) {
        if (!h.installed) {
            h.statusTone = 'error';
            h.statusHeadline = h.slotsUsedByFramework == 0
                ? 'The scheduler is not installed, so no job will run.'
                : 'The scheduler is only partly installed — '
                  + h.heartbeatsArmed + ' of ' + h.heartbeatsExpected
                  + ' scheduled checks are in place.';
            return;
        }
        if (h.killSwitch) {
            h.statusTone = 'warning';
            h.statusHeadline = 'Every job is paused. Nothing will run until you resume.';
            return;
        }
        if (h.heartbeatStale == true && h.lastHeartbeatAt != null) {
            h.statusTone = 'error';
            h.statusHeadline = 'The scheduled checks have stopped: the last one ran at '
                + AJOCron.formatLocal(h.lastHeartbeatAt, h.defaultTimeZone)
                + '. Check the scheduling user is active, then reinstall.';
            return;
        }
        if (h.jobsInvalid != null && h.jobsInvalid > 0) {
            h.statusTone = 'error';
            h.statusHeadline = h.jobsInvalid + (h.jobsInvalid == 1 ? ' job definition is' : ' job definitions are')
                + ' invalid and cannot run. See the Jobs tab for the reasons.';
            return;
        }
        String next = String.isBlank(h.nextCheckLocal)
                      ? 'shortly' : 'at ' + h.nextCheckLocal;
        if (h.failures24h != null && h.failures24h > 0) {
            h.statusTone = 'error';
            h.statusHeadline = h.failures24h + (h.failures24h == 1 ? ' job has' : ' jobs have')
                + ' failed in the last 24 hours. Next check ' + next + '.';
            return;
        }
        if (h.jobsSuspended != null && h.jobsSuspended > 0) {
            h.statusTone = 'warning';
            h.statusHeadline = h.jobsSuspended
                + (h.jobsSuspended == 1 ? ' job is' : ' jobs are')
                + ' switched off after repeated failures. Next check ' + next + '.';
            return;
        }
        h.statusTone = 'ok';
        h.statusHeadline = 'Running normally. ' + h.jobsActive
            + (h.jobsActive == 1 ? ' job is active' : ' jobs are active')
            + '; next check ' + next + '.';
    }

    /**
      * What the next scheduled check will consider, and what it will do with
      * each job — evaluated with the launcher's own gates, in the launcher's
      * own order, launching nothing.
      *
      * This is the question the console could never answer: a job that quietly
      * does not run because a previous run is still open, or because five
      * batches already hold the ceiling, used to be visible only afterwards in
      * the log. Here it is visible before the fact.
      */
    @AuraEnabled(cacheable=false)
    public static NextCheckView getNextCheck() {
        NextCheckView out = new NextCheckView();
        out.everyMinutes = AJOConfig.heartbeatMinutes();
        out.paused       = AJOConfig.killSwitch();
        out.due          = new List<DueView>();
        out.willRunCount = 0;

        String tz = AJOConfig.defaultTimeZone();
        Integer heartbeats = 0;
        for (CronTrigger ct : AJOInstaller.ownTriggers()) {
            if (ct.CronJobDetail.Name == AJOInstaller.SUPERVISOR_NAME) { continue; }
            heartbeats++;
            if (ct.NextFireTime != null
                && (out.checkAt == null || ct.NextFireTime < out.checkAt)) {
                out.checkAt   = ct.NextFireTime;
                out.checkName = ct.CronJobDetail.Name;
            }
        }
        out.installed    = heartbeats >= AJOInstaller.slots().size();
        out.checkAtLocal = AJOCron.formatLocal(out.checkAt, tz);
        if (!out.installed) { return out; }

        // A check picks up everything due up to one window past the moment it
        // fires, so the preview has to look that far ahead as well.
        Datetime firesAt   = out.checkAt == null ? Datetime.now() : out.checkAt;
        Datetime windowEnd = firesAt.addMinutes(out.everyMinutes);

        // Every configured job is listed, not only the ones the next check will
        // take. A job that cannot run used to be absent from this tab and absent
        // from the log, which left no way at all to find out why it never ran —
        // the reason for a missed run has to be visible somewhere, and this is
        // the screen people look at.
        List<AJOJob__c> candidates = Database.query(
            'SELECT ' + AJOLauncher.JOB_FIELDS + ', AJO_DefinitionError__c FROM AJOJob__c '
            + 'WHERE AJO_Enabled__c = true OR AJO_QueuedForAt__c != null '
            + '   OR AJO_Status__c = \'Invalid\' '
            + 'ORDER BY AJO_QueuedForAt__c ASC NULLS LAST, '
            + '         AJO_NextRunAt__c ASC NULLS LAST, AJO_Priority__c ASC NULLS LAST '
            + 'LIMIT 500');

        Map<Id, AJOJobRun__c> parentOutcomes = AJOLauncher.latestTerminalRuns(parentIds(candidates));
        Datetime nowForDeps = Datetime.now();
        Integer batchBudget   = AJOThrottle.availableBatchSlots();

        for (AJOJob__c job : candidates) {
            Boolean alreadyQueued = job.AJO_QueuedForAt__c != null;
            String jobTz = String.isBlank(job.AJO_TimeZoneSidKey__c)
                           ? tz : job.AJO_TimeZoneSidKey__c;

            DueView d = new DueView();
            d.id            = job.Id;
            d.name          = job.Name;
            d.apexClass     = job.AJO_ApexClassName__c;
            d.executionType = job.AJO_ExecutionType__c;
            d.priority      = job.AJO_Priority__c;
            d.dueAt         = alreadyQueued ? job.AJO_QueuedForAt__c : job.AJO_NextRunAt__c;
            d.dueAtLocal    = AJOCron.formatLocal(d.dueAt, jobTz);
            d.willRun       = false;

            if (alreadyQueued && !out.paused) {
                // Committed work: a queueable is holding it until its minute, so
                // none of the gates below apply any more.
                d.willRun = true;
                d.verdict = 'Queued';
                d.verdictReason = 'Already queued and waiting for ' + d.dueAtLocal + '.';
                out.willRunCount++;
                out.due.add(d);
                continue;
            }

            if (out.paused) {
                d.verdict = 'Paused';
                d.verdictReason = 'Every job is paused right now.';

            // ---- the reasons a job silently never runs, now stated out loud ----
            } else if (!AJOLauncher.mayRun(job)) {
                d.verdict = 'Never runs';
                d.verdictReason = 'Not backed by a deployed job definition, and unmanaged jobs are '
                    + 'switched off. Export it as a definition and deploy it.';
            } else if (job.AJO_Status__c == 'Invalid' || job.AJO_Status__c == 'Retired') {
                d.verdict = 'Never runs';
                d.verdictReason = job.AJO_Status__c == 'Invalid'
                    ? 'Its definition failed validation: ' + job.AJO_DefinitionError__c
                    : 'Its definition is no longer deployed.';
            } else if (job.AJO_Status__c == 'Suspended') {
                d.verdict = 'Never runs';
                d.verdictReason = 'Switched off after repeated failures. Re-enable it to resume.';
            } else if (!AJOWindow.isActive(job)) {
                d.verdict = 'Never runs';
                d.verdictReason = 'Outside its start and end dates: ' + AJOWindow.describe(job) + '.';
            } else if (job.AJO_Status__c == 'Expired') {
                d.verdict = 'Never runs';
                d.verdictReason = 'Retired: its end date has passed.';
            } else if (job.AJO_NextRunAt__c == null) {
                d.verdict = 'Never runs';
                d.verdictReason = 'It has no next run time, so no check can ever select it. '
                    + 'Open the job and save it again to recompute one.';

            // ---- scheduled, but not for this check ----
            } else if (job.AJO_NextRunAt__c > windowEnd) {
                d.verdict = 'Scheduled';
                d.verdictReason = 'Not due until ' + d.dueAtLocal
                    + '. It appears here for action once a check reaches it.';

            // ---- due at the next check: the launcher's own gates, in its order ----
            } else if (job.AJO_DependsOnJobId__c != null
                       && !AJOLauncher.dependencySatisfied(job, parentOutcomes, nowForDeps)) {
                d.verdict = 'Waiting';
                d.verdictReason = 'The job it depends on has not succeeded since this job last ran.';
            } else if (AJOLauncher.IN_FLIGHT.contains(job.AJO_Status__c)
                       && job.AJO_OverlapPolicy__c != 'Allow') {
                d.verdict = 'Will be skipped';
                d.verdictReason = job.AJO_OverlapPolicy__c == 'Queue'
                    ? 'Its previous run is still going, so this one waits for the next check.'
                    : 'Its previous run is still going, so this one is skipped.';
            } else if (job.AJO_DryRun__c == true) {
                d.verdict = 'Test mode';
                d.verdictReason = 'Records what it would have done and runs nothing.';
            } else if (job.AJO_ExecutionType__c == 'Batch' && batchBudget <= 0) {
                d.verdict = 'Held back';
                d.verdictReason = 'All ' + AJOConfig.maxConcurrentBatches()
                    + ' batch slots are already in use. It retries at the next check.';
            } else {
                if (job.AJO_ExecutionType__c == 'Batch') { batchBudget--; }
                Integer delay = AJOLauncher.deferralMinutes(job.AJO_NextRunAt__c, firesAt);
                d.willRun = true;
                d.verdict = 'Will run';
                d.verdictReason = (delay > 0 && AJOConfig.deferralEnabled())
                    ? 'Starts at ' + d.dueAtLocal + ', held back ' + delay
                      + ' minute(s) so it lands on its exact minute.'
                    : 'Starts as soon as the check runs.';
                out.willRunCount++;
            }
            out.due.add(d);
        }
        return out;
    }

    /** The jobs the candidates depend on, for one bulk outcome query. */
    private static Set<Id> parentIds(List<AJOJob__c> jobs) {
        Set<Id> ids = new Set<Id>();
        for (AJOJob__c j : jobs) {
            if (j.AJO_DependsOnJobId__c != null) { ids.add(j.AJO_DependsOnJobId__c); }
        }
        return ids;
    }

    /**
      * Every scheduled Apex job in Setup that this framework could take over,
      * and for the ones it could not, why.
      *
      * The class a schedule runs is not on CronTrigger or CronJobDetail at all.
      * The only link is AsyncApexJob: scheduling Apex leaves a permanent row
      * with JobType 'ScheduledApex', Status 'Queued', carrying both the
      * CronTriggerId and the ApexClass. Without that join there is no way to
      * know what a schedule actually runs.
      */
    @AuraEnabled(cacheable=false)
    public static List<ConvertibleView> listConvertible() {
        String heartbeats = AJOInstaller.HEARTBEAT_PREFIX + '%';
        String supervisor = AJOInstaller.SUPERVISOR_NAME;

        Map<Id, CronTrigger> triggers = new Map<Id, CronTrigger>([
            SELECT Id, CronJobDetail.Name, CronExpression, State, TimeZoneSidKey,
                   PreviousFireTime, NextFireTime, TimesTriggered, StartTime, EndTime
            FROM   CronTrigger
            WHERE  CronJobDetail.JobType = '7'
              AND  (NOT CronJobDetail.Name LIKE :heartbeats)
              AND  CronJobDetail.Name != :supervisor
            ORDER BY CronJobDetail.Name
            LIMIT  500
        ]);
        if (triggers.isEmpty()) { return new List<ConvertibleView>(); }

        Map<Id, String> classByTrigger = new Map<Id, String>();
        for (AsyncApexJob a : [
                SELECT CronTriggerId, ApexClass.Name
                FROM   AsyncApexJob
                WHERE  JobType = 'ScheduledApex'
                  AND  CronTriggerId IN :triggers.keySet()]) {
            if (a.ApexClass != null) { classByTrigger.put(a.CronTriggerId, a.ApexClass.Name); }
        }

        // A schedule already taken over must never be offered twice.
        Map<String, String> alreadyTaken = new Map<String, String>();
        Set<String> usedKeys = new Set<String>();
        for (AJOJob__c j : [
                SELECT Name, AJO_JobKey__c, AJO_LegacyCronTriggerId__c FROM AJOJob__c LIMIT 2000]) {
            if (String.isNotBlank(j.AJO_LegacyCronTriggerId__c)) {
                alreadyTaken.put(j.AJO_LegacyCronTriggerId__c, j.Name);
            }
            if (String.isNotBlank(j.AJO_JobKey__c)) { usedKeys.add(j.AJO_JobKey__c); }
        }

        String orgTz = AJOConfig.defaultTimeZone();
        Datetime now = Datetime.now();
        List<ConvertibleView> out = new List<ConvertibleView>();

        for (CronTrigger t : triggers.values()) {
            ConvertibleView v = new ConvertibleView();
            v.blockers = new List<String>();
            v.warnings = new List<String>();
            v.cronTriggerId  = t.Id;
            v.name           = t.CronJobDetail.Name;
            v.cronExpression = t.CronExpression;
            v.state          = t.State;
            v.timeZone       = String.isBlank(t.TimeZoneSidKey) ? orgTz : t.TimeZoneSidKey;
            v.lastFireTime   = t.PreviousFireTime;
            v.nextFireTime   = t.NextFireTime;
            v.timesTriggered = t.TimesTriggered;
            v.endTime        = t.EndTime;
            v.lastFireLocal  = AJOCron.formatLocal(t.PreviousFireTime, v.timeZone);
            v.nextFireLocal  = AJOCron.formatLocal(t.NextFireTime, v.timeZone);
            v.className      = classByTrigger.get(t.Id);

            // ---- blockers: anything here means nothing gets deleted ----------
            if (alreadyTaken.containsKey(String.valueOf(t.Id))) {
                v.blockers.add('Already managed by this framework as "'
                    + alreadyTaken.get(String.valueOf(t.Id)) + '".');
            }
            if (String.isBlank(v.className)) {
                v.blockers.add('The Apex class behind this schedule could not be identified, '
                    + 'so there is nothing to re-create it from.');
            } else {
                v.executionType = AJOLegacyAdapter.classify(v.className);
                if (v.executionType == null) {
                    v.blockers.add('Apex class "' + v.className + '" was not found, has no public '
                        + 'no-argument constructor, or implements no interface this framework '
                        + 'can run.');
                }
            }
            try {
                AJOCron.parse(t.CronExpression);
                v.schedule = AJOCron.describeSchedule(t.CronExpression);
            } catch (Exception e) {
                v.schedule = t.CronExpression;
                v.blockers.add('This framework cannot read the schedule: ' + e.getMessage());
            }

            // ---- warnings: convertible, but worth reading --------------------
            // if (t.State == 'PAUSED') {
            //     v.warnings.add('Paused in Setup, so it is not running today. Converting it '
            //         + 'brings it back to life.');
            // }
            if (t.TimesTriggered == null || t.TimesTriggered == 0) {
                v.warnings.add('Has never run.');
            }
            // if (t.NextFireTime != null && t.NextFireTime < now) {
            //     v.warnings.add('Its next run time is in the past ('
            //         + AJOCron.formatLocal(t.NextFireTime, v.timeZone) + '), so the schedule is stale.');
            // }
            if (t.EndTime != null) {
                v.warnings.add('Setup has it ending '
                    + AJOCron.formatLocal(t.EndTime, v.timeZone)
                    + '. Converting makes it recurring unless you set a Last day.');
            }
            if (String.isNotBlank(t.CronExpression)
                && !t.CronExpression.trim().startsWith('0 ')) {
                v.warnings.add('It runs at a seconds offset. The orchestrator works to the '
                    + 'minute, so it will start at the top of the minute instead.');
            }
            v.warnings.add('Any values passed to the class when it was scheduled cannot be '
                + 'recovered — the platform does not expose them — so it will run with its '
                + 'own defaults. This is why the converted job starts in Test mode.');

            v.convertible   = v.blockers.isEmpty();
            v.suggestedKey  = uniqueKey(v.name, usedKeys);
            out.add(v);
        }
        return out;
    }

    /** A stable, unique JobKey derived from the Setup job name. */
    private static String uniqueKey(String name, Set<String> taken) {
        String base = (name == null ? 'CONVERTED' : name).toUpperCase()
                          .replaceAll('[^A-Z0-9]+', '_').replaceAll('^_+|_+$', '');
        if (String.isBlank(base)) { base = 'CONVERTED'; }
        if (base.length() > 70) { base = base.substring(0, 70); }
        String key = base;
        Integer n = 2;
        while (taken.contains(key)) { key = base + '_' + n; n++; }
        taken.add(key);
        return key;
    }

    /** The next five fire times — the thing Setup never shows you. */
    @AuraEnabled(cacheable=false)
    public static List<String> preview(String cronExpression, String timeZone) {
        List<String> out = new List<String>();
        String tz = String.isBlank(timeZone) ? AJOConfig.defaultTimeZone() : timeZone;
        try {
            for (Datetime d : AJOCron.nextN(cronExpression, Datetime.now(), tz, 5)) {
                out.add(AJOCron.formatLocal(d, tz) + '  ' + tz);
            }
            if (out.isEmpty()) { out.add('No occurrence within the next 1500 days.'); }
        } catch (Exception e) {
            out.add('Invalid: ' + e.getMessage());
        }
        return out;
    }

    @AuraEnabled(cacheable=false)
    public static String describeSchedule(String cronExpression) {
        return AJOCron.describeSchedule(cronExpression);
    }

    @AuraEnabled(cacheable=false)
    public static String classifyClass(String className) {
        String t = AJOLegacyAdapter.classify(className);
        return t == null ? '' : t;
    }

    // ----------------------------------------------------------------- write

    /**
      * True when the running user may touch the framework itself — install it,
      * uninstall it, pause every job, or run maintenance by hand.
      *
      * The console hides those controls without it, but hiding is not the
      * control: every @AuraEnabled method below is directly callable by anyone
      * with access to the class, and the Viewer permission set grants exactly
      * that. So the check lives in the method, not in the component.
      */
    @AuraEnabled(cacheable=true)
    public static Boolean canAdminister() {
        if (FeatureManagement.checkPermission('AJO_Administer')) { return true; }
        // A full administrator is never locked out of their own org.
        List<Profile> p = [
            SELECT PermissionsModifyAllData FROM Profile
            WHERE  Id = :UserInfo.getProfileId() LIMIT 1
        ];
        return !p.isEmpty() && p[0].PermissionsModifyAllData == true;
    }

    private static void requireAdmin(String what) {
        if (!canAdminister()) {
            throw new AuraHandledException(
                'You do not have permission to ' + what + '. This needs the '
                + '"Administer Apex Job Orchestration" permission.');
        }
    }

    /** Job configuration follows ordinary object permissions on AJOJob__c. */
    private static void requireJobWrite(Boolean creating, Boolean deleting) {
        Schema.DescribeSObjectResult d = AJOJob__c.SObjectType.getDescribe();
        Boolean ok = deleting ? d.isDeletable() : (creating ? d.isCreateable() : d.isUpdateable());
        if (!ok) {
            throw new AuraHandledException(
                'You have read-only access to Apex Jobs, so this cannot be saved.');
        }
    }

    /**
      * How long past its instant a queued run still locks the job. The deferred
      * run normally lands within seconds; after this the marker is treated as
      * lapsed (the supervisor clears it outright at 30 minutes).
      */
    @TestVisible
    private static final Integer QUEUED_LOCK_GRACE_MINUTES = 5;

    /**
      * True from the heartbeat that queues a deferred run until that run starts.
      * Editing in between recomputed Next Run from now, which put the same
      * occurrence back in front of the next heartbeat while the queued run still
      * fired, so the job ran twice. Pausing and deleting stay allowed: the
      * deferred run re-checks both and stands down.
      */
    public static Boolean isEditLocked(AJOJob__c job) {
        return job.AJO_QueuedForAt__c != null
            && job.AJO_QueuedForAt__c > Datetime.now().addMinutes(-QUEUED_LOCK_GRACE_MINUTES);
    }

    private static String editLockReason(AJOJob__c job) {
        String tz = String.isBlank(job.AJO_TimeZoneSidKey__c)
                    ? AJOConfig.defaultTimeZone() : job.AJO_TimeZoneSidKey__c;
        return 'This job is queued to start at '
            + AJOCron.formatLocal(job.AJO_QueuedForAt__c, tz)
            + ' and cannot be changed until that run has started, or it could run twice. '
            + 'Pause it instead if it must not run.';
    }

    private static void requireNotQueued(AJOJob__c job) {
        if (isEditLocked(job)) {
            throw new AuraHandledException(editLockReason(job));
        }
    }

    private static String managedReason(AJOJob__c job) {
        return 'Defined in custom metadata (AJO_Job_Definition__mdt.' + job.AJO_JobKey__c
            + '), so what it runs and when change only through a release. Pause, resume and '
            + 'Run now still work here.';
    }

    /** Refuses a definition change on a managed job; it changes by release. */
    private static void requireUnmanaged(Id jobId) {
        List<AJOJob__c> rows = [
            SELECT Id, AJO_JobKey__c, AJO_DefinitionManaged__c FROM AJOJob__c WHERE Id = :jobId LIMIT 1
        ];
        if (!rows.isEmpty() && rows[0].AJO_DefinitionManaged__c == true) {
            throw new AuraHandledException(managedReason(rows[0]));
        }
        requireUnmanagedAllowed();
    }

    /** Refuses creating or converting into an unmanaged job outside the migration period. */
    private static void requireUnmanagedAllowed() {
        if (!AJOConfig.allowUnmanagedJobs()) {
            throw new AuraHandledException('Jobs are defined in custom metadata and change through '
                + 'a release. Use "Generate definition" to produce the record file to commit.');
        }
    }


    @AuraEnabled
    public static String runNowById(Id jobId) {
        requireJobWrite(false, false);
        List<AJOJob__c> jobs = Database.query(
            'SELECT ' + AJOLauncher.JOB_FIELDS + ' FROM AJOJob__c WHERE Id = :jobId LIMIT 1');
        if (jobs.isEmpty()) { throw new AuraHandledException('Job not found.'); }
        AJOJob__c job = jobs[0];
        // Run now is still bound by the window. These jobs exist to process a
        // bounded slice of data; letting a manual click run one outside its dates
        // would defeat the point of setting them.
        if (!AJOWindow.isActive(job)) {
            throw new AuraHandledException(
                'This job is outside its start and end dates (' + AJOWindow.describe(job)
                + '). Adjust them first.');
        }
        if (!AJOLauncher.mayRun(job)) {
            throw new AuraHandledException('This job is not backed by a deployed definition and '
                + 'unmanaged jobs are switched off.');
        }
        if (job.AJO_Status__c == 'Invalid' || job.AJO_Status__c == 'Retired') {
            throw new AuraHandledException('This job cannot run: its definition is '
                + job.AJO_Status__c.toLowerCase() + '.');
        }
        // A manual run is a run: it honours the job's overlap policy, so a click
        // cannot start a second copy of a batch or Runnable already in flight.
        if (AJOLauncher.IN_FLIGHT.contains(job.AJO_Status__c) && job.AJO_OverlapPolicy__c != 'Allow') {
            throw new AuraHandledException('This job is already ' + job.AJO_Status__c.toLowerCase()
                + ' (overlap policy: ' + job.AJO_OverlapPolicy__c + '). Wait for it to finish.');
        }
        // Run in its own transaction, with full async limits and callouts
        // allowed — never inside the clicking user's request. The job's code
        // runs as the clicking user; use Run at next check to run it as the
        // scheduling user instead.
        AJOJobRun__c run = AJORunLogger.open(job, Datetime.now(), 'Manual', null);
        run.AJO_Message__c = 'Queued from the console by ' + UserInfo.getName() + '.';
        run.AJO_AsyncApexJobId__c = System.enqueueJob(new AJOJobExecutor(job.Id, run.Id, null));
        update AJORunLogger.patch(run);
        return 'Queued';
    }

    /**
     * Makes the job due now, so the next scheduled check (within one interval)
     * runs it — as the scheduling user, with that user's sharing, exactly as a
     * scheduled run would. Preferred over Run now when the job's results depend
     * on record access.
     */
    @AuraEnabled
    public static String runAtNextCheck(Id jobId) {
        requireJobWrite(false, false);
        AJOJob__c job = [
            SELECT Id, AJO_Enabled__c, AJO_StartDate__c, AJO_EndDate__c, AJO_QueuedForAt__c,
                   AJO_TimeZoneSidKey__c, AJO_Status__c
            FROM   AJOJob__c WHERE Id = :jobId LIMIT 1
        ];
        if (!AJOWindow.isActive(job)) {
            throw new AuraHandledException('This job is not active (' + AJOWindow.describe(job) + ').');
        }
        requireNotQueued(job);
        update new AJOJob__c(Id = jobId, AJO_NextRunAt__c = Datetime.now());
        return 'It will start at the next scheduled check.';
    }

    /**
      * Pause or resume. Writes the manual switch only — the dates keep their own
      * say, so resuming a job whose window has closed does not start it running.
      */
    @AuraEnabled
    public static void setEnabled(Id jobId, Boolean enabled) {
        requireJobWrite(false, false);
        AJOJob__c job = [
            SELECT Id, AJO_Enabled__c, AJO_Status__c, AJO_CronExpression__c,
                   AJO_TimeZoneSidKey__c, AJO_NextRunAt__c,
                   AJO_StartDate__c, AJO_EndDate__c, AJO_QueuedForAt__c
            FROM   AJOJob__c WHERE Id = :jobId LIMIT 1
        ];
        // Pausing stays open while queued; resuming recomputes Next Run.
        if (enabled) { requireNotQueued(job); }
        List<AJOJob__c> managed = [
            SELECT AJO_DefinitionManaged__c, AJO_JobKey__c FROM AJOJob__c WHERE Id = :jobId LIMIT 1
        ];
        if (!managed.isEmpty() && managed[0].AJO_DefinitionManaged__c == true) {
            // Managed: the pause is operational and survives syncs. The job is
            // enabled only while its definition is active AND it is not paused.
            AJO_Job_Definition__mdt d = AJODefinitions.byKey(managed[0].AJO_JobKey__c);
            if (enabled && (d == null || d.AJO_Active__c != true)) {
                throw new AuraHandledException('Its definition is inactive; activate it through a release.');
            }
            job.AJO_OpsPaused__c = !enabled;
        }
        job.AJO_Enabled__c = enabled;
        if (enabled) {
            if (job.AJO_Status__c == 'Suspended') { job.AJO_Status__c = 'Idle'; }
            AJOLauncher.advance(job, Datetime.now());
        }
        update job;
    }

    /** Extends or reopens a job's window without touching anything else. */
    @AuraEnabled
    public static String setWindow(Id jobId, Date startDate, Date endDate) {
        requireJobWrite(false, false);
        requireUnmanaged(jobId);
        AJOWindow.validate(startDate, endDate);
        AJOJob__c job = [
            SELECT Id, AJO_Enabled__c, AJO_Status__c, AJO_CronExpression__c,
                   AJO_TimeZoneSidKey__c, AJO_NextRunAt__c,
                   AJO_StartDate__c, AJO_EndDate__c, AJO_QueuedForAt__c
            FROM   AJOJob__c WHERE Id = :jobId LIMIT 1
        ];
        requireNotQueued(job);
        job.AJO_StartDate__c = startDate;
        job.AJO_EndDate__c   = endDate;
        AJOLauncher.advance(job, Datetime.now());
        update job;
        return AJOWindow.describe(job);
    }

    @AuraEnabled
    public static void setDryRun(Id jobId, Boolean dryRun) {
        requireJobWrite(false, false);
        requireUnmanaged(jobId);
        // The queued run does not re-read Dry Run, so it would ignore the change.
        requireNotQueued([
            SELECT Id, AJO_QueuedForAt__c, AJO_TimeZoneSidKey__c
            FROM   AJOJob__c WHERE Id = :jobId LIMIT 1
        ]);
        update new AJOJob__c(Id = jobId, AJO_DryRun__c = dryRun);
    }

    @AuraEnabled
    public static Id saveJob(String payload) {
        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(payload);
        requireJobWrite(m.get('id') == null, false);
        if (m.get('id') != null) {
            requireUnmanaged((Id) String.valueOf(m.get('id')));
        } else {
            requireUnmanagedAllowed();
        }
        AJOJob__c job = new AJOJob__c();
        if (m.get('id') != null) {
            job.Id = (Id) String.valueOf(m.get('id'));
            List<AJOJob__c> existing = [
                SELECT Id, AJO_QueuedForAt__c, AJO_TimeZoneSidKey__c
                FROM   AJOJob__c WHERE Id = :job.Id LIMIT 1
            ];
            if (!existing.isEmpty()) {
                requireNotQueued(existing[0]);
                // Past the lock any marker left is lapsed. Cleared so a deferred
                // run landing late no longer owns the occurrence.
                job.AJO_QueuedForAt__c = null;
            }
        }
        job.Name              = str(m, 'name');
        job.AJO_JobKey__c         = str(m, 'jobKey');
        job.AJO_ApexClassName__c  = str(m, 'apexClass');
        job.AJO_ExecutionType__c  = str(m, 'executionType');
        job.AJO_CronExpression__c = str(m, 'cronExpression');
        job.AJO_TimeZoneSidKey__c = str(m, 'timeZone');
        job.AJO_Description__c    = str(m, 'description');
        job.AJO_OverlapPolicy__c  = str(m, 'overlapPolicy');
        job.AJO_Parameters__c     = str(m, 'parameters');
        job.AJO_Enabled__c        = bool(m, 'enabled');
        job.AJO_StartDate__c      = dat(m, 'startDate');
        job.AJO_EndDate__c        = dat(m, 'endDate');
        job.AJO_DryRun__c         = bool(m, 'dryRun');
        job.AJO_Pinned__c         = false; // deprecated: pinned jobs never ran
        job.AJO_Priority__c       = dec(m, 'priority');
        job.AJO_BatchSize__c      = dec(m, 'batchSize');
        job.AJO_MaxRuntimeMinutes__c      = dec(m, 'maxRuntimeMinutes');
        job.AJO_MaxConsecutiveFailures__c = dec(m, 'maxConsecutiveFailures');

        // Validate before saving, so the typo surfaces here and not at 3 a.m.
        try {
            AJOCron.parse(job.AJO_CronExpression__c);
        } catch (Exception e) {
            throw new AuraHandledException('Schedule is not valid: ' + e.getMessage());
        }
        if (AJOLegacyAdapter.classify(job.AJO_ApexClassName__c) == null) {
            throw new AuraHandledException(
                'Apex class "' + job.AJO_ApexClassName__c + '" was not found, has no public '
                + 'no-argument constructor, or implements no supported interface.');
        }
        try {
            AJOWindow.validate(job.AJO_StartDate__c, job.AJO_EndDate__c);
        } catch (AJOWindow.WindowException e) {
            throw new AuraHandledException(e.getMessage());
        }

        AJOLauncher.advance(job, Datetime.now());
        if (job.AJO_Status__c == null) { job.AJO_Status__c = 'Idle'; }
        upsert job;
        return job.Id;
    }

    @AuraEnabled
    public static void deleteJob(Id jobId) {
        requireJobWrite(false, true);
        requireUnmanaged(jobId);
        delete [SELECT Id FROM AJOJob__c WHERE Id = :jobId];
    }

    /** Runs the same job again. The row in Problems needs one click, not six. */
    @AuraEnabled
    public static String retryRun(Id runId) {
        List<AJOJobRun__c> rows = [
            SELECT AJO_Job__c FROM AJOJobRun__c WHERE Id = :runId LIMIT 1
        ];
        if (rows.isEmpty()) { throw new AuraHandledException('Run not found.'); }
        return runNowById(rows[0].AJO_Job__c);
    }

    /** Installs the scheduler: the six scheduled checks plus nightly maintenance. */
    @AuraEnabled
    public static List<String> armFramework() {
        requireAdmin('install the scheduler');
        AJOInstaller.ensureSettings();
        return AJOInstaller.arm();
    }

    /** Uninstalls it. Every job stops firing until this is installed again. */
    @AuraEnabled
    public static List<String> disarmFramework() {
        requireAdmin('uninstall the scheduler');
        return AJOInstaller.disarm();
    }

    /** Pause or resume every job at once, without giving up the scheduled slots. */
    @AuraEnabled
    public static void setKillSwitch(Boolean enabled) {
        requireAdmin('pause and resume every job');
        AJOSetting__c s = AJOInstaller.ensureSettings();
        s.AJO_KillSwitch__c = enabled;
        update s;
    }

    /**
      * The nightly tidy-up, on demand: closes out finished batches, marks runs
      * that overran as timed out, retires jobs past their end date, trims the
      * log, and re-creates any scheduled check that went missing.
      */
    @AuraEnabled
    public static String runSupervisor() {
        requireAdmin('run maintenance');
        Map<String, Object> r = AJOSupervisor.sweep();
        List<String> parts = new List<String>();
        parts.add(r.get('reconciled') + ' finished run(s) closed out');
        parts.add(r.get('stuck') + ' timed out');
        parts.add(r.get('expired') + ' job(s) retired');
        parts.add(r.get('purged') + ' old log row(s) removed');
        parts.add(r.get('unqueued') + ' abandoned queue marker(s) cleared');
        parts.add(r.get('rearmed') + ' scheduled check(s) re-created');
        return String.join(parts, ', ') + '.';
    }

    /**
      * Takes over one existing Setup schedule: creates the job here, then
      * deletes the CronTrigger, freeing one of the org's 100 scheduled slots.
      *
      * Order is the safety property. The job is inserted fully formed and the
      * abort is the LAST statement, so:
      *
      *   - if anything fails before the abort, the whole transaction rolls back
      *     and the Setup schedule is untouched;
      *   - the inserted job is not visible to any heartbeat until this
      *     transaction commits, so the two can never both fire.
      *
      * Reversed — abort first, insert second — a failure would leave the org
      * with no schedule at all. Duplicated runs and lost runs are not equally
      * bad, and this orders for the one that is merely inconvenient.
      */
    @AuraEnabled
    public static ConversionResult convert(String payload) {
        requireAdmin('convert a scheduled job');
        requireJobWrite(true, false);
        requireUnmanagedAllowed();

        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(payload);
        Id cronTriggerId = (Id) String.valueOf(m.get('cronTriggerId'));

        // Re-read and re-validate rather than trusting what the screen sent: the
        // schedule may have changed, or been converted already, since it loaded.
        ConvertibleView source = byTrigger(listConvertible()).get(cronTriggerId);
        if (source == null) {
            throw new AuraHandledException(
                'That scheduled job is no longer in Setup, or is not one this framework '
                + 'can take over. Refresh and try again.');
        }
        if (!source.convertible) {
            throw new AuraHandledException(
                'This job cannot be converted: ' + String.join(source.blockers, ' '));
        }

        Boolean testMode = m.get('testMode') == null ? true : bool(m, 'testMode');

        AJOJob__c job = new AJOJob__c(
            Name                  = String.isBlank(str(m, 'name')) ? source.name : str(m, 'name'),
            AJO_JobKey__c         = String.isBlank(str(m, 'jobKey'))
                                    ? source.suggestedKey : str(m, 'jobKey'),
            AJO_ApexClassName__c  = source.className,
            AJO_ExecutionType__c  = source.executionType,
            AJO_CronExpression__c = source.cronExpression,
            // Copied, never assumed. A CronTrigger fires in the zone it was
            // scheduled in, so defaulting this to the org zone would silently
            // move a 12:45 IST job to 18:15 IST.
            AJO_TimeZoneSidKey__c = source.timeZone,
            AJO_Enabled__c        = true,
            AJO_DryRun__c         = testMode,
            AJO_StartDate__c      = Date.today(),
            AJO_Status__c         = 'Idle',
            AJO_OverlapPolicy__c  = 'Skip',
            AJO_Priority__c       = dec(m, 'priority') == null ? 5 : dec(m, 'priority'),
            AJO_BatchSize__c      = dec(m, 'batchSize'),
            AJO_MaxRuntimeMinutes__c      = 60,
            AJO_MaxConsecutiveFailures__c = 3,
            AJO_Description__c    = 'Converted from the Setup scheduled job "' + source.name
                                    + '" on ' + Date.today().format() + '.',
            // Everything below dies with the CronTrigger. Captured so the move
            // can be audited, and so a job with 98 runs behind it can be told
            // apart from one that never ran.
            AJO_LegacyCronJobName__c     = source.name,
            AJO_LegacyCronExpression__c  = source.cronExpression,
            AJO_LegacyCronTriggerId__c   = String.valueOf(cronTriggerId),
            AJO_LegacyLastFireTime__c    = source.lastFireTime,
            AJO_LegacyTimesTriggered__c  = source.timesTriggered
        );

        AJOLauncher.advance(job, Datetime.now());
        if (job.AJO_NextRunAt__c == null) {
            throw new AuraHandledException(
                'This schedule produces no future run time, so converting it would create a '
                + 'job that never runs. Nothing has been changed.');
        }
        insert job;

        // Last statement, deliberately. Nothing after it can fail and strand the org.
        System.abortJob(cronTriggerId);

        ConversionResult r = new ConversionResult();
        r.jobId        = job.Id;
        r.jobName      = job.Name;
        r.testMode     = testMode;
        r.nextRunLocal = AJOCron.formatLocal(job.AJO_NextRunAt__c, source.timeZone);
        r.slotLimit    = AJOConfig.SLOT_LIMIT;
        r.slotsUsedNow = AJOInstaller.scheduledApexSlotsUsed();
        r.summary      = 'Now runs from the orchestrator, next at ' + r.nextRunLocal + '. '
            + (testMode
               ? 'It is in Test mode: it will record what it would have done without running '
                 + 'anything. Turn Test mode off on the job once a cycle looks right.'
               : 'It is live.')
            + ' The Setup schedule has been removed, freeing one slot.';
        return r;
    }

    private static Map<Id, ConvertibleView> byTrigger(List<ConvertibleView> rows) {
        Map<Id, ConvertibleView> m = new Map<Id, ConvertibleView>();
        for (ConvertibleView v : rows) { m.put(v.cronTriggerId, v); }
        return m;
    }

    /**
      * Takes over several Setup schedules at once — the shape the source org
      * needs, where 43 jobs all fire at the same minute.
      *
      * Every job is inserted first, in one DML, and only then are the schedules
      * aborted one by one. An abort that fails leaves that job immediately
      * disabled rather than running alongside a Setup schedule that is still
      * alive: in bulk the partial-failure case is the one that matters, and a
      * job that did not start is always preferable to one that ran twice.
      */
    @AuraEnabled
    public static List<ConversionRow> convertMany(List<Id> cronTriggerIds, Boolean testMode) {
        requireAdmin('convert scheduled jobs');
        requireJobWrite(true, false);
        requireUnmanagedAllowed();
        if (cronTriggerIds == null || cronTriggerIds.isEmpty()) {
            return new List<ConversionRow>();
        }
        if (cronTriggerIds.size() > 25) {
            throw new AuraHandledException(
                'Convert at most 25 at a time, so a partial failure stays small enough '
                + 'to see and to undo.');
        }
        Boolean dryRun = testMode == null ? true : testMode;

        Map<Id, ConvertibleView> available = byTrigger(listConvertible());
        List<ConversionRow> results = new List<ConversionRow>();
        List<AJOJob__c> toInsert = new List<AJOJob__c>();
        List<ConvertibleView> queued = new List<ConvertibleView>();

        for (Id ctId : cronTriggerIds) {
            ConvertibleView v = available.get(ctId);
            ConversionRow row = new ConversionRow();
            row.cronTriggerId = ctId;
            row.name = v == null ? String.valueOf(ctId) : v.name;

            if (v == null) {
                row.converted = false;
                row.detail = 'No longer in Setup, or already converted.';
                results.add(row);
                continue;
            }
            if (!v.convertible) {
                row.converted = false;
                row.detail = String.join(v.blockers, ' ');
                results.add(row);
                continue;
            }
            AJOJob__c job = buildConverted(v, v.name, v.suggestedKey, null, null, dryRun);
            AJOLauncher.advance(job, Datetime.now());
            if (job.AJO_NextRunAt__c == null) {
                row.converted = false;
                row.detail = 'Produces no future run time, so it was left in Setup.';
                results.add(row);
                continue;
            }
            toInsert.add(job);
            queued.add(v);
        }

        if (toInsert.isEmpty()) { return results; }

        // Partial success: one bad key must not discard the other twenty-four.
        List<Database.SaveResult> saved = Database.insert(toInsert, false);
        List<AJOJob__c> strandedJobs = new List<AJOJob__c>();

        for (Integer i = 0; i < saved.size(); i++) {
            ConvertibleView v = queued[i];
            ConversionRow row = new ConversionRow();
            row.cronTriggerId = v.cronTriggerId;
            row.name = v.name;

            if (!saved[i].isSuccess()) {
                row.converted = false;
                row.detail = 'Could not be saved: ' + saved[i].getErrors()[0].getMessage()
                           + ' Its Setup schedule is untouched.';
                results.add(row);
                continue;
            }
            row.jobId = saved[i].getId();
            try {
                System.abortJob(v.cronTriggerId);
                row.converted = true;
                row.detail = 'Moved across' + (dryRun ? ' in Test mode.' : '.');
            } catch (Exception e) {
                // The job exists but its Setup schedule survives. Disabling it is
                // the only way to stop both firing.
                row.converted = false;
                row.detail = 'Saved here but the Setup schedule could not be removed ('
                    + e.getMessage() + '), so this job has been left switched off to stop '
                    + 'it running twice.';
                strandedJobs.add(new AJOJob__c(Id = row.jobId, AJO_Enabled__c = false));
            }
            results.add(row);
        }
        if (!strandedJobs.isEmpty()) { update strandedJobs; }
        return results;
    }

    /** The job record a conversion produces. Shared by the single and bulk paths. */
    private static AJOJob__c buildConverted(ConvertibleView source, String name, String key,
                                            Decimal priority, Decimal batchSize, Boolean dryRun) {
        return new AJOJob__c(
            Name                  = String.isBlank(name) ? source.name : name,
            AJO_JobKey__c         = String.isBlank(key) ? source.suggestedKey : key,
            AJO_ApexClassName__c  = source.className,
            AJO_ExecutionType__c  = source.executionType,
            AJO_CronExpression__c = source.cronExpression,
            AJO_TimeZoneSidKey__c = source.timeZone,
            AJO_Enabled__c        = true,
            AJO_DryRun__c         = dryRun,
            AJO_StartDate__c      = Date.today(),
            AJO_Status__c         = 'Idle',
            AJO_OverlapPolicy__c  = 'Skip',
            AJO_Priority__c       = priority == null ? 5 : priority,
            AJO_BatchSize__c      = batchSize,
            AJO_MaxRuntimeMinutes__c      = 60,
            AJO_MaxConsecutiveFailures__c = 3,
            AJO_Description__c    = 'Converted from the Setup scheduled job "' + source.name
                                    + '" on ' + Date.today().format() + '.',
            AJO_LegacyCronJobName__c     = source.name,
            AJO_LegacyCronExpression__c  = source.cronExpression,
            AJO_LegacyCronTriggerId__c   = String.valueOf(source.cronTriggerId),
            AJO_LegacyLastFireTime__c    = source.lastFireTime,
            AJO_LegacyTimesTriggered__c  = source.timesTriggered
        );
    }

    // ------------------------------------------------------------- restore

    /**
      * What restoring a converted job to Setup would do, before doing it.
      *
      * The whole plan exists for one reason: System.schedule always uses the
      * RUNNING USER'S time zone and offers no way to override it. A job captured
      * as 12:45 Asia/Kolkata, restored by somebody on America/Chicago, becomes
      * 12:45 Chicago — a silent ten-and-a-half hour move on a production
      * schedule. So the two zones are compared and both sets of fire times are
      * shown side by side rather than assuming they agree.
      */
    @AuraEnabled(cacheable=false)
    public static RestorePlan planRestore(Id jobId) {
        AJOJob__c j = [
            SELECT Id, Name, AJO_ApexClassName__c, AJO_CronExpression__c, AJO_TimeZoneSidKey__c,
                   AJO_LegacyCronJobName__c, AJO_LegacyCronExpression__c,
                   AJO_LegacyCronTriggerId__c
            FROM   AJOJob__c WHERE Id = :jobId LIMIT 1
        ];
        RestorePlan p = new RestorePlan();
        p.blockers   = new List<String>();
        p.jobId      = j.Id;
        p.jobName    = j.Name;
        p.legacyName = String.isBlank(j.AJO_LegacyCronJobName__c) ? j.Name : j.AJO_LegacyCronJobName__c;
        p.legacyCron = String.isBlank(j.AJO_LegacyCronExpression__c)
                       ? j.AJO_CronExpression__c : j.AJO_LegacyCronExpression__c;
        p.originalTimeZone = String.isBlank(j.AJO_TimeZoneSidKey__c)
                             ? AJOConfig.defaultTimeZone() : j.AJO_TimeZoneSidKey__c;
        p.yourTimeZone     = UserInfo.getTimeZone().getID();
        p.timeZoneMatches  = (p.originalTimeZone == p.yourTimeZone);

        if (String.isBlank(j.AJO_LegacyCronTriggerId__c)) {
            p.blockers.add('This job was created here, not converted from Setup, so there is '
                + 'nothing to restore it to.');
        }
        Object instance;
        try {
            instance = AJOLegacyAdapter.instantiate(j.AJO_ApexClassName__c);
            if (!(instance instanceof Schedulable)) {
                p.blockers.add('Apex class "' + j.AJO_ApexClassName__c + '" does not implement '
                    + 'Schedulable, and only a Schedulable class can be put back into Setup.');
            }
        } catch (Exception e) {
            p.blockers.add('Apex class "' + j.AJO_ApexClassName__c + '" cannot be created: '
                + e.getMessage());
        }
        if (!existingScheduleNames().isEmpty()
            && existingScheduleNames().contains(p.legacyName.toLowerCase())) {
            p.blockers.add('A scheduled job called "' + p.legacyName
                + '" already exists in Setup. Rename or remove it first.');
        }

        p.originalFireTimes = preview(p.legacyCron, p.originalTimeZone);
        p.restoredFireTimes = preview(p.legacyCron, p.yourTimeZone);
        return p;
    }

    private static Set<String> existingScheduleNames() {
        Set<String> names = new Set<String>();
        for (CronTrigger t : [SELECT CronJobDetail.Name FROM CronTrigger
                              WHERE CronJobDetail.JobType = '7' LIMIT 500]) {
            names.add(t.CronJobDetail.Name.toLowerCase());
        }
        return names;
    }

    /**
      * Puts a converted job back into Setup and switches it off here.
      *
      * Ordered the mirror image of convert(): the job is disabled FIRST and
      * System.schedule is the last statement, so a failure rolls back to the
      * job still running here with nothing in Setup. Both alive at once is the
      * outcome worth engineering against.
      */
    @AuraEnabled
    public static String restore(Id jobId, Boolean acceptTimeZoneShift) {
        requireAdmin('restore a job to Setup');
        requireJobWrite(false, false);

        RestorePlan p = planRestore(jobId);
        if (!p.blockers.isEmpty()) {
            throw new AuraHandledException(String.join(p.blockers, ' '));
        }
        if (!p.timeZoneMatches && acceptTimeZoneShift != true) {
            throw new AuraHandledException(
                'This job was scheduled in ' + p.originalTimeZone + ' but your user is set to '
                + p.yourTimeZone + ', and Setup can only schedule in your own zone. Restoring '
                + 'now would move when it runs. Either change your time zone to '
                + p.originalTimeZone + ' first, or confirm you accept the shift.');
        }

        // OpsPaused as well as disabled: a managed job would otherwise be re-enabled
        // by the next sync. Cut Over At stays set, so the sync never re-aborts the
        // restored Setup schedule.
        update new AJOJob__c(Id = jobId, AJO_Enabled__c = false, AJO_OpsPaused__c = true,
                             AJO_Status__c = 'Idle');

        AJOJob__c j = [SELECT AJO_ApexClassName__c FROM AJOJob__c WHERE Id = :jobId LIMIT 1];
        Schedulable s = (Schedulable) AJOLegacyAdapter.instantiate(j.AJO_ApexClassName__c);

        // Last statement, for the same reason the abort is last in convert().
        Id cronId = System.schedule(p.legacyName, p.legacyCron, s);
        return 'Restored "' + p.legacyName + '" to Setup as ' + cronId
             + ', and switched the orchestrated job off. It holds one scheduled slot again'
             + (p.timeZoneMatches ? '.' : ', now running in ' + p.yourTimeZone + '.');
    }

    /**
     * Seeds one job per execution shape, so the proof of concept can be driven
     * from the console without any data loading. Idempotent on AJO_JobKey__c.
     */
    @AuraEnabled
    public static Integer seedDemoJobs() {
        requireAdmin('seed demo jobs');
        if (!AJOConfig.allowUnmanagedJobs()) {
            throw new AuraHandledException('Demo jobs ship as inactive definitions (DEMO_*) in '
                + 'org-config/main/default/customMetadata/. Deploy and activate them through a '
                + 'release, then use Sync now.');
        }
        AJOInstaller.ensureSettings();
        String tz = AJOConfig.defaultTimeZone();
        Datetime now = Datetime.now();

        List<AJOJob__c> seeds = new List<AJOJob__c>{
            new AJOJob__c(
                Name = 'Legacy scheduler, unchanged',
                AJO_JobKey__c = 'DEMO_LEGACY',
                AJO_ExecutionType__c = 'Legacy Schedulable',
                AJO_ApexClassName__c = 'AJODemoLegacyScheduler',
                AJO_CronExpression__c = '0 0 * * * ?',
                AJO_Description__c = 'An existing Schedulable class called through the adapter '
                    + 'with a null SchedulableContext. Nothing about the class changed.',
                AJO_Priority__c = 5),
            new AJOJob__c(
                Name = 'Dual-interface scheduler',
                AJO_JobKey__c = 'DEMO_DUAL',
                AJO_ExecutionType__c = 'Legacy Schedulable',
                AJO_ApexClassName__c = 'AJODemoDualScheduler',
                AJO_CronExpression__c = '0 17 * * * ?',
                AJO_Description__c = 'Implements Schedulable AND Batchable, and chooses its own '
                    + 'scope size. Proves the adapter enters through Schedulable first.',
                AJO_Priority__c = 5),
            new AJOJob__c(
                Name = 'Batch with a configured scope',
                AJO_JobKey__c = 'DEMO_BATCH',
                AJO_ExecutionType__c = 'Batch',
                AJO_ApexClassName__c = 'AJODemoBatch',
                AJO_CronExpression__c = '0 30 * * * ?',
                AJO_BatchSize__c = 200,
                AJO_Description__c = 'Launched as a batch; the run stays open until a later '
                    + 'heartbeat reconciles it against AsyncApexJob.',
                AJO_Priority__c = 2),
            new AJOJob__c(
                Name = 'Queueable',
                AJO_JobKey__c = 'DEMO_QUEUEABLE',
                AJO_ExecutionType__c = 'Queueable',
                AJO_ApexClassName__c = 'AJODemoQueueable',
                AJO_CronExpression__c = '0 45 * * * ?',
                AJO_Description__c = 'Enqueued by the launcher.',
                AJO_Priority__c = 6),
            new AJOJob__c(
                Name = 'Runnable with parameters',
                AJO_JobKey__c = 'DEMO_RUNNABLE_USERS',
                AJO_ExecutionType__c = 'Runnable',
                AJO_ApexClassName__c = 'AJODemoRunnable',
                AJO_CronExpression__c = '0 0 6 * * ?',
                AJO_Parameters__c = '{"object":"User","target":1}',
                AJO_Description__c = 'Written against the framework. Reads its configuration from '
                    + 'the context and reports its own counters into the run record.',
                AJO_Priority__c = 4),
            new AJOJob__c(
                Name = 'Runnable, same class different config',
                AJO_JobKey__c = 'DEMO_RUNNABLE_ACCOUNTS',
                AJO_ExecutionType__c = 'Runnable',
                AJO_ApexClassName__c = 'AJODemoRunnable',
                AJO_CronExpression__c = '0 30 6 * * ?',
                AJO_Parameters__c = '{"object":"Account","target":5}',
                AJO_Description__c = 'The same Apex class backing a second configured job. '
                    + 'One class, many schedules.',
                AJO_Priority__c = 4),
            new AJOJob__c(
                Name = 'Always fails, to show the breaker',
                AJO_JobKey__c = 'DEMO_FAIL',
                AJO_ExecutionType__c = 'Legacy Schedulable',
                AJO_ApexClassName__c = 'AJODemoFailingJob',
                AJO_CronExpression__c = '0 0 3 * * ?',
                AJO_MaxConsecutiveFailures__c = 3,
                AJO_Description__c = 'Throws every time. After three consecutive failures the job '
                    + 'suspends itself rather than failing forever.',
                AJO_Priority__c = 9),
            new AJOJob__c(
                Name = 'Ten-day data fix',
                AJO_JobKey__c = 'DEMO_WINDOW_10DAY',
                AJO_ExecutionType__c = 'Batch',
                AJO_ApexClassName__c = 'AJODemoBatch',
                AJO_CronExpression__c = '0 15 1 * * ?',
                AJO_BatchSize__c = 200,
                AJO_StartDate__c = Date.today(),
                AJO_EndDate__c = Date.today().addDays(9),
                AJO_Description__c = 'Runs nightly for ten days and then retires itself. '
                    + 'This is the shape of a bounded data correction: the End Date is the '
                    + 'guarantee, so nobody has to remember to switch it off.',
                AJO_Priority__c = 3),
            new AJOJob__c(
                Name = 'Scheduled to start next week',
                AJO_JobKey__c = 'DEMO_WINDOW_FUTURE',
                AJO_ExecutionType__c = 'Legacy Schedulable',
                AJO_ApexClassName__c = 'AJODemoLegacyScheduler',
                AJO_CronExpression__c = '0 0 4 * * ?',
                AJO_StartDate__c = Date.today().addDays(7),
                AJO_EndDate__c = Date.today().addDays(21),
                AJO_Description__c = 'Enabled, but its window has not opened yet. Reads as '
                    + 'inactive until the Start Date, then runs for a fortnight.',
                AJO_Priority__c = 6),
            new AJOJob__c(
                Name = 'Shadow mode example',
                AJO_JobKey__c = 'DEMO_SHADOW',
                AJO_ExecutionType__c = 'Legacy Schedulable',
                AJO_ApexClassName__c = 'AJODemoLegacyScheduler',
                AJO_CronExpression__c = '0 0 2 * * ?',
                AJO_DryRun__c = true,
                AJO_Description__c = 'Registered in shadow mode: the dispatcher records what it '
                    + 'would have started and launches nothing. This is how Wave 2 proves '
                    + 'the schedules before any cutover.',
                AJO_Priority__c = 7)
        };

        for (AJOJob__c j : seeds) {
            j.AJO_TimeZoneSidKey__c = tz;
            j.AJO_Enabled__c = true;
            // Left blank unless the seed sets one: no End Date means run forever,
            // which is what all but the two window demonstrations want.
            if (j.AJO_StartDate__c == null) { j.AJO_StartDate__c = Date.today(); }
            j.AJO_Status__c = 'Idle';
            j.AJO_OverlapPolicy__c = 'Skip';
            if (j.AJO_MaxRuntimeMinutes__c == null) { j.AJO_MaxRuntimeMinutes__c = 60; }
            j.AJO_LegacyCronJobName__c = j.Name + ' (legacy)';
            j.AJO_LegacyCronExpression__c = j.AJO_CronExpression__c;
            AJOLauncher.advance(j, now);
        }

        upsert seeds AJO_JobKey__c;
        return seeds.size();
    }

    // --------------------------------------------------- hybrid model: author

    /**
     * Pulls deployed definitions into job state now instead of waiting for the
     * next check. Run after a release.
     */
    @AuraEnabled
    public static String syncNow() {
        requireAdmin('sync job definitions');
        AJODefinitionSync.Result r = AJODefinitionSync.syncSafely();
        AJOAlerts.flush();
        return r.summary() + (r.messages.isEmpty() ? '' : ' ' + String.join(r.messages, ' '));
    }

    /**
     * Builds the custom metadata record file for a new job from the editor's
     * fields (same payload as saveJob). Writes nothing: the file is committed
     * and deployed like any other change.
     */
    @AuraEnabled
    public static AJODefinitionExporter.DefinitionFile generateDefinition(String payload) {
        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(payload);
        AJOJob__c j = new AJOJob__c(
            Name                          = str(m, 'name'),
            AJO_JobKey__c                 = str(m, 'jobKey'),
            AJO_ApexClassName__c          = str(m, 'apexClass'),
            AJO_ExecutionType__c          = str(m, 'executionType'),
            AJO_CronExpression__c         = str(m, 'cronExpression'),
            AJO_TimeZoneSidKey__c         = str(m, 'timeZone'),
            AJO_Description__c            = str(m, 'description'),
            AJO_OverlapPolicy__c          = str(m, 'overlapPolicy'),
            AJO_Parameters__c             = str(m, 'parameters'),
            AJO_Enabled__c                = bool(m, 'enabled'),
            AJO_StartDate__c              = dat(m, 'startDate'),
            AJO_EndDate__c                = dat(m, 'endDate'),
            AJO_DryRun__c                 = bool(m, 'dryRun'),
            AJO_Priority__c               = dec(m, 'priority'),
            AJO_BatchSize__c              = dec(m, 'batchSize'),
            AJO_MaxRuntimeMinutes__c      = dec(m, 'maxRuntimeMinutes'),
            AJO_MaxConsecutiveFailures__c = dec(m, 'maxConsecutiveFailures'));
        return AJODefinitionExporter.fromJob(j);
    }

    /** The definition file for an existing unmanaged job, to migrate it. */
    @AuraEnabled
    public static AJODefinitionExporter.DefinitionFile exportDefinition(Id jobId) {
        List<AJOJob__c> rows = Database.query(
            'SELECT ' + AJOLauncher.JOB_FIELDS + ' FROM AJOJob__c WHERE Id = :jobId LIMIT 1');
        if (rows.isEmpty()) { throw new AuraHandledException('Job not found.'); }
        return AJODefinitionExporter.fromJob(rows[0]);
    }

    /**
     * Definition files that take over the selected Setup schedules. Each ships
     * active, in Dry Run, with Replaces Setup Job set: when the release deploys
     * it, the next sync aborts the Setup schedule in the same transaction that
     * creates the job, so it never runs twice or not at all.
     */
    @AuraEnabled
    public static List<AJODefinitionExporter.DefinitionFile> generateConversionDefinitions(
            List<Id> cronTriggerIds) {
        requireAdmin('take over scheduled jobs');
        List<AJODefinitionExporter.DefinitionFile> out = new List<AJODefinitionExporter.DefinitionFile>();
        if (cronTriggerIds == null || cronTriggerIds.isEmpty()) { return out; }
        Map<Id, ConvertibleView> available = byTrigger(listConvertible());
        for (Id ctId : cronTriggerIds) {
            ConvertibleView v = available.get(ctId);
            if (v == null) { continue; }
            AJODefinitionExporter.DefinitionFile f = AJODefinitionExporter.fromSetupSchedule(
                v.name, v.className, v.executionType, v.cronExpression, v.timeZone);
            f.problems.addAll(v.blockers);
            out.add(f);
        }
        return out;
    }

    // ---------------------------------------------------------------- helpers

    private static String str(Map<String, Object> m, String k) {
        Object v = m.get(k);
        return v == null ? null : String.valueOf(v);
    }
    private static Boolean bool(Map<String, Object> m, String k) {
        Object v = m.get(k);
        return v == null ? false : String.valueOf(v) == 'true';
    }
    private static Date dat(Map<String, Object> m, String k) {
        Object v = m.get(k);
        if (v == null || String.isBlank(String.valueOf(v))) { return null; }
        // The console sends an ISO yyyy-MM-dd from lightning-input type=date.
        try { return Date.valueOf(String.valueOf(v).left(10) + ' 00:00:00'); }
        catch (Exception e) { return null; }
    }
    private static Decimal dec(Map<String, Object> m, String k) {
        Object v = m.get(k);
        if (v == null || String.isBlank(String.valueOf(v))) { return null; }
        try { return Decimal.valueOf(String.valueOf(v)); } catch (Exception e) { return null; }
    }
}