/**
 * Projects AJO_Job_Definition__mdt onto AJOJob__c, the runtime state.
 *
 * The split:
 *   - A definition (custom metadata) says WHAT runs, HOW and WHEN. It changes
 *     only through a release, so every change is reviewed and tested.
 *   - A state record (AJOJob__c) holds what the engine needs at runtime: next
 *     run, status, last outcome, failure count, the queued marker, and the
 *     operations pause. It is keyed by the definition's DeveloperName in
 *     AJO_JobKey__c and is the only thing the dispatcher's indexed query reads.
 *
 * The sync runs at the start of every scheduled check (so a deployment takes
 * effect within one heartbeat), after a release via the console's "Sync now",
 * and from the supervisor. It is idempotent and only writes rows that changed.
 *
 * What it does, in order:
 *   1. Validates every definition. An invalid one parks its state at
 *      'Invalid' with the reasons and raises DEFINITION_INVALID; it never runs.
 *   2. Creates state for new definitions and re-projects any whose definition
 *      changed OR whose projected fields were edited directly on the record.
 *      That second check is the security property: someone with edit access
 *      to AJOJob__c cannot point a job at another class, because the next sync
 *      overwrites the tampering, and the executor reads the class from the
 *      definition anyway.
 *   3. Recomputes Next Run only when the schedule itself changed (cron, zone,
 *      window, activation), so a resync never moves a job that is about to run.
 *   4. Retires state whose definition was removed from the release.
 *   5. Resolves Depends On keys into the AJO_DependsOnJobId__c lookup.
 *   6. Performs pending cut-overs: aborts the Setup scheduled job named in
 *      AJO_ReplacesCronJobName__c. The abort is the LAST statement, after the
 *      state is written, so if it fails the caller's savepoint rolls the whole
 *      sync back and the old schedule keeps running. A job is therefore never
 *      run by both, and never by neither.
 *
 * Runs without sharing: it is framework infrastructure that must see and
 * write every job's state regardless of who owns the record. Access to it is
 * controlled by who can schedule or call it (the Admin permission set).
 */
public without sharing class AJODefinitionSync {

    public class Result {
        public Integer created   = 0;
        public Integer updated   = 0;
        public Integer invalid   = 0;
        public Integer retired   = 0;
        public Integer cutOver   = 0;
        public Integer unchanged = 0;
        public List<String> messages = new List<String>();

        public String summary() {
            return created + ' created, ' + updated + ' updated, ' + invalid + ' invalid, '
                + retired + ' retired, ' + cutOver + ' cut over, ' + unchanged + ' unchanged.';
        }
    }

    /** Fields the sync reads on state rows, beyond the launcher's own set. */
    private static final String STATE_FIELDS = AJOLauncher.JOB_FIELDS
        + ', AJO_DefinitionManaged__c, AJO_DefinitionHash__c, AJO_DefinitionError__c, '
        + 'AJO_OpsPaused__c, AJO_CutoverAt__c, AJO_DependsOnKey__c, AJO_LegacyLastFireTime__c, '
        + 'AJO_LegacyTimesTriggered__c';

    /**
     * Runs the sync inside a savepoint and never throws. Used by the heartbeat:
     * a broken definition or a failed cut-over must not stop every other job.
     */
    public static Result syncSafely() {
        Savepoint sp = Database.setSavepoint();
        try {
            return sync();
        } catch (Exception e) {
            Database.rollback(sp);
            AJOAlerts.raise(AJOAlerts.ERROR, 'SYNC_FAILED', null,
                'Definition sync failed and was rolled back; jobs keep their previous state. '
                + e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
            Result r = new Result();
            r.messages.add('Sync failed: ' + e.getMessage());
            return r;
        }
    }

    /** The sync itself. Throws on failure; callers wanting isolation use syncSafely(). */
    public static Result sync() {
        Result res = new Result();
        Datetime now = Datetime.now();
        Map<String, AJO_Job_Definition__mdt> defs = AJODefinitions.all();
        Map<String, List<String>> problems = AJODefinitionValidator.validateAll(defs);

        Set<String> keys = defs.keySet();
        Map<String, AJOJob__c> stateByKey = new Map<String, AJOJob__c>();
        for (AJOJob__c s : (List<AJOJob__c>) Database.query(
                'SELECT ' + STATE_FIELDS + ' FROM AJOJob__c '
                + 'WHERE AJO_JobKey__c IN :keys OR AJO_DefinitionManaged__c = true')) {
            stateByKey.put(s.AJO_JobKey__c, s);
        }

        List<AJOJob__c> toUpsert = new List<AJOJob__c>();

        // ---- 1-3: project each definition -----------------------------------
        for (AJO_Job_Definition__mdt d : defs.values()) {
            AJOJob__c s = stateByKey.get(d.DeveloperName);
            Boolean isNew = (s == null);
            if (isNew) {
                s = new AJOJob__c(AJO_JobKey__c = d.DeveloperName, AJO_Status__c = 'Idle',
                                  AJO_OpsPaused__c = false, AJO_ConsecutiveFailures__c = 0);
                stateByKey.put(d.DeveloperName, s);
            }

            List<String> errs = problems.get(d.DeveloperName);
            if (errs != null) {
                String why = String.join(errs, '\n');
                if (isNew || s.AJO_Status__c != 'Invalid' || s.AJO_DefinitionError__c != why
                    || s.AJO_DefinitionManaged__c != true) {
                    s.Name = d.MasterLabel;
                    s.AJO_DefinitionManaged__c = true;
                    s.AJO_DefinitionError__c   = why;
                    s.AJO_Enabled__c           = false;
                    s.AJO_NextRunAt__c         = null;
                    // A run already in flight finishes; it will settle to Invalid.
                    if (s.AJO_Status__c != 'Running') { s.AJO_Status__c = 'Invalid'; }
                    toUpsert.add(s);
                    res.invalid++;
                    AJOAlerts.raise(AJOAlerts.ERROR, 'DEFINITION_INVALID', d.DeveloperName,
                        'Definition ' + d.DeveloperName + ' cannot run:\n' + why,
                        d.AJO_NotifyEmails__c);
                } else {
                    res.unchanged++;
                }
                continue;
            }

            String wanted = fingerprint(d);
            Boolean effectiveEnabled = d.AJO_Active__c == true && s.AJO_OpsPaused__c != true;
            Boolean scheduleChanged = isNew || scheduleDiffers(d, s)
                || s.AJO_Status__c == 'Invalid' || s.AJO_Status__c == 'Retired'
                || s.AJO_Enabled__c != effectiveEnabled;
            Boolean drifted = isNew || s.AJO_DefinitionManaged__c != true
                || fingerprint(s) != wanted || s.AJO_DefinitionHash__c != wanted;

            if (!scheduleChanged && !drifted) {
                res.unchanged++;
                continue;
            }

            project(d, s);
            s.AJO_DefinitionManaged__c = true;
            s.AJO_DefinitionHash__c    = wanted;
            s.AJO_DefinitionError__c   = null;
            s.AJO_Enabled__c           = effectiveEnabled;
            if (s.AJO_Status__c == 'Invalid' || s.AJO_Status__c == 'Retired') {
                s.AJO_Status__c = 'Idle';
            }
            if (scheduleChanged) {
                if (effectiveEnabled) {
                    AJOLauncher.advance(s, now);
                } else {
                    s.AJO_NextRunAt__c = null;
                }
            }
            toUpsert.add(s);
            if (isNew) { res.created++; } else { res.updated++; }
        }

        // ---- 4: retire state whose definition left the release ---------------
        for (AJOJob__c s : stateByKey.values()) {
            if (s.AJO_DefinitionManaged__c == true && !defs.containsKey(s.AJO_JobKey__c)
                && s.AJO_Status__c != 'Retired') {
                s.AJO_Enabled__c   = false;
                s.AJO_NextRunAt__c = null;
                if (s.AJO_Status__c != 'Running') { s.AJO_Status__c = 'Retired'; }
                toUpsert.add(s);
                res.retired++;
                AJOAlerts.raise(AJOAlerts.INFO, 'DEFINITION_RETIRED', s.AJO_JobKey__c,
                    'Definition ' + s.AJO_JobKey__c + ' is no longer deployed; its state was retired. '
                    + 'Run history is kept.');
            }
        }

        if (!toUpsert.isEmpty()) {
            // By Id: rows read from the database carry one, new rows do not and
            // are inserted. Unmanaged records with a matching key were read
            // above, so they are adopted rather than duplicated.
            upsert toUpsert;
        }

        // ---- 5: resolve dependency keys into the lookup -------------------------
        List<AJOJob__c> depFix = new List<AJOJob__c>();
        for (AJOJob__c s : stateByKey.values()) {
            if (s.Id == null || s.AJO_DefinitionManaged__c != true) { continue; }
            Id wantedParent = null;
            if (String.isNotBlank(s.AJO_DependsOnKey__c) && stateByKey.containsKey(s.AJO_DependsOnKey__c)) {
                wantedParent = stateByKey.get(s.AJO_DependsOnKey__c).Id;
            }
            if (s.AJO_DependsOnJobId__c != wantedParent) {
                s.AJO_DependsOnJobId__c = wantedParent;
                depFix.add(new AJOJob__c(Id = s.Id, AJO_DependsOnJobId__c = wantedParent));
            }
        }
        if (!depFix.isEmpty()) { update depFix; }

        // ---- 6: cut-overs, abort last -------------------------------------------
        res.cutOver = cutOver(defs, problems, stateByKey);
        return res;
    }

    /**
     * Takes over the Setup schedules named in AJO_ReplacesCronJobName__c, once
     * per job. Writes the audit fields first, then aborts. Returns the count.
     */
    private static Integer cutOver(Map<String, AJO_Job_Definition__mdt> defs,
                                   Map<String, List<String>> problems,
                                   Map<String, AJOJob__c> stateByKey) {
        Map<String, AJOJob__c> byLegacyName = new Map<String, AJOJob__c>();
        for (AJO_Job_Definition__mdt d : defs.values()) {
            AJOJob__c s = stateByKey.get(d.DeveloperName);
            if (s == null || s.Id == null || problems.containsKey(d.DeveloperName)) { continue; }
            if (d.AJO_Active__c != true || String.isBlank(d.AJO_ReplacesCronJobName__c)
                || s.AJO_CutoverAt__c != null) { continue; }
            String legacy = d.AJO_ReplacesCronJobName__c.trim();
            if (legacy.startsWith(AJOInstaller.HEARTBEAT_PREFIX) || legacy == AJOInstaller.SUPERVISOR_NAME) {
                AJOAlerts.raise(AJOAlerts.ERROR, 'CUTOVER_FAILED', d.DeveloperName,
                    'Replaces Setup Job names one of the framework\'s own schedules ("' + legacy
                    + '"). Refused.');
                continue;
            }
            byLegacyName.put(legacy, s);
        }
        if (byLegacyName.isEmpty()) { return 0; }

        Set<String> names = byLegacyName.keySet();
        Map<String, CronTrigger> found = new Map<String, CronTrigger>();
        for (CronTrigger ct : [
                SELECT Id, CronExpression, TimeZoneSidKey, PreviousFireTime, TimesTriggered,
                       CronJobDetail.Name
                FROM   CronTrigger
                WHERE  CronJobDetail.JobType = '7' AND CronJobDetail.Name IN :names]) {
            found.put(ct.CronJobDetail.Name, ct);
        }

        Datetime now = Datetime.now();
        List<AJOJob__c> audit = new List<AJOJob__c>();
        List<Id> toAbort = new List<Id>();
        for (String legacy : names) {
            AJOJob__c s = byLegacyName.get(legacy);
            CronTrigger ct = found.get(legacy);
            AJOJob__c a = new AJOJob__c(Id = s.Id, AJO_CutoverAt__c = now,
                                        AJO_LegacyCronJobName__c = legacy);
            if (ct == null) {
                AJOAlerts.raise(AJOAlerts.INFO, 'CUTOVER_DONE', s.AJO_JobKey__c,
                    'No Setup scheduled job named "' + legacy + '" exists; nothing to abort.');
            } else {
                a.AJO_LegacyCronTriggerId__c  = String.valueOf(ct.Id);
                a.AJO_LegacyCronExpression__c = ct.CronExpression;
                a.AJO_LegacyLastFireTime__c   = ct.PreviousFireTime;
                a.AJO_LegacyTimesTriggered__c = ct.TimesTriggered;
                toAbort.add(ct.Id);
                String jobTz = String.isBlank(s.AJO_TimeZoneSidKey__c)
                    ? AJOConfig.defaultTimeZone() : s.AJO_TimeZoneSidKey__c;
                AJOAlerts.raise(AJOAlerts.INFO, 'CUTOVER_DONE', s.AJO_JobKey__c,
                    'Took over Setup scheduled job "' + legacy + '" (' + ct.CronExpression + ' '
                    + ct.TimeZoneSidKey + '). One scheduled slot freed.'
                    + (ct.TimeZoneSidKey != jobTz
                       ? ' Note: the Setup job ran in ' + ct.TimeZoneSidKey + ' and the definition '
                         + 'runs in ' + jobTz + '.'
                       : ''));
            }
            s.AJO_CutoverAt__c = now;
            audit.add(a);
        }
        update audit;
        // LAST: a failure here propagates, and the caller's savepoint undoes the audit
        // and the state together, leaving the Setup schedule in charge.
        for (Id ctId : toAbort) { System.abortJob(ctId); }
        return audit.size();
    }

    /** Copies every projected field from the definition onto the state record. */
    @TestVisible
    private static void project(AJO_Job_Definition__mdt d, AJOJob__c s) {
        s.Name                          = d.MasterLabel;
        s.AJO_ApexClassName__c          = d.AJO_ApexClass__c;
        s.AJO_ExecutionType__c          = d.AJO_ExecutionType__c;
        s.AJO_CronExpression__c         = d.AJO_CronExpression__c;
        s.AJO_TimeZoneSidKey__c         = d.AJO_TimeZone__c;
        s.AJO_BatchSize__c              = d.AJO_BatchSize__c;
        s.AJO_Parameters__c             = d.AJO_Parameters__c;
        s.AJO_OverlapPolicy__c          = String.isBlank(d.AJO_OverlapPolicy__c) ? 'Skip' : d.AJO_OverlapPolicy__c;
        s.AJO_Priority__c               = d.AJO_Priority__c;
        s.AJO_MaxRuntimeMinutes__c      = d.AJO_MaxRuntimeMinutes__c;
        s.AJO_MaxConsecutiveFailures__c = d.AJO_MaxConsecutiveFailures__c;
        s.AJO_StartDate__c              = d.AJO_StartDate__c;
        s.AJO_EndDate__c                = d.AJO_EndDate__c;
        s.AJO_DryRun__c                 = d.AJO_DryRun__c == true;
        s.AJO_Description__c            = d.AJO_Description__c;
        s.AJO_NotifyEmails__c           = d.AJO_NotifyEmails__c;
        s.AJO_DependsOnKey__c           = d.AJO_DependsOn__c;
        s.AJO_RunAfterDependency__c     = d.AJO_RunAfterDependency__c == true;
        s.AJO_AllowsCallouts__c         = d.AJO_AllowsCallouts__c == true;
        s.AJO_Pinned__c                 = false;
    }

    /** True when anything that decides WHEN the job runs differs. */
    private static Boolean scheduleDiffers(AJO_Job_Definition__mdt d, AJOJob__c s) {
        return d.AJO_CronExpression__c != s.AJO_CronExpression__c
            || nz(d.AJO_TimeZone__c) != nz(s.AJO_TimeZoneSidKey__c)
            || d.AJO_StartDate__c != s.AJO_StartDate__c
            || d.AJO_EndDate__c != s.AJO_EndDate__c;
    }

    /** SHA-256 of the projected values as the definition states them. */
    @TestVisible
    private static String fingerprint(AJO_Job_Definition__mdt d) {
        return digest(new List<String>{
            nz(d.MasterLabel), nz(d.AJO_ApexClass__c), nz(d.AJO_ExecutionType__c),
            nz(d.AJO_CronExpression__c), nz(d.AJO_TimeZone__c), num(d.AJO_BatchSize__c),
            nz(d.AJO_Parameters__c),
            String.isBlank(d.AJO_OverlapPolicy__c) ? 'Skip' : d.AJO_OverlapPolicy__c,
            num(d.AJO_Priority__c), num(d.AJO_MaxRuntimeMinutes__c),
            num(d.AJO_MaxConsecutiveFailures__c), String.valueOf(d.AJO_StartDate__c),
            String.valueOf(d.AJO_EndDate__c), String.valueOf(d.AJO_DryRun__c == true),
            nz(d.AJO_Description__c), nz(d.AJO_NotifyEmails__c), nz(d.AJO_DependsOn__c),
            String.valueOf(d.AJO_RunAfterDependency__c == true),
            String.valueOf(d.AJO_AllowsCallouts__c == true)
        });
    }

    /** SHA-256 of the same values as the state record currently holds them. */
    @TestVisible
    private static String fingerprint(AJOJob__c s) {
        return digest(new List<String>{
            nz(s.Name), nz(s.AJO_ApexClassName__c), nz(s.AJO_ExecutionType__c),
            nz(s.AJO_CronExpression__c), nz(s.AJO_TimeZoneSidKey__c), num(s.AJO_BatchSize__c),
            nz(s.AJO_Parameters__c), nz(s.AJO_OverlapPolicy__c),
            num(s.AJO_Priority__c), num(s.AJO_MaxRuntimeMinutes__c),
            num(s.AJO_MaxConsecutiveFailures__c), String.valueOf(s.AJO_StartDate__c),
            String.valueOf(s.AJO_EndDate__c), String.valueOf(s.AJO_DryRun__c == true),
            nz(s.AJO_Description__c), nz(s.AJO_NotifyEmails__c), nz(s.AJO_DependsOnKey__c),
            String.valueOf(s.AJO_RunAfterDependency__c == true),
            String.valueOf(s.AJO_AllowsCallouts__c == true)
        });
    }

    private static String digest(List<String> parts) {
        return EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(String.join(parts, '\u001F'))));
    }

    private static String nz(String s) { return s == null ? '' : s; }

    /** Numbers compared as integers, so 200 and 200.0 hash the same. */
    private static String num(Decimal d) { return d == null ? '' : String.valueOf(d.intValue()); }
}
