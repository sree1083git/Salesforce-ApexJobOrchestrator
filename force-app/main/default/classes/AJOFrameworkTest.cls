@IsTest
private class AJOFrameworkTest {

    private static final String TZ = 'Asia/Kolkata';

    private static AJOJob__c makeJob(String name, String key, String type,
                                     String cls, String cron) {
        AJOJob__c j = new AJOJob__c(
            Name                 = name,
            AJO_JobKey__c            = key,
            AJO_ExecutionType__c     = type,
            AJO_ApexClassName__c     = cls,
            AJO_CronExpression__c    = cron,
            AJO_TimeZoneSidKey__c    = TZ,
            AJO_Enabled__c           = true,
            AJO_StartDate__c         = Date.today(),
            AJO_DryRun__c            = false,
            AJO_Pinned__c            = false,
            AJO_Status__c            = 'Idle',
            AJO_OverlapPolicy__c     = 'Skip',
            AJO_Priority__c          = 5,
            AJO_MaxRuntimeMinutes__c = 60,
            AJO_NextRunAt__c         = Datetime.now().addMinutes(-1)
        );
        insert j;
        return j;
    }

    @TestSetup
    static void setup() {
        insert new AJOSetting__c(
            AJO_AllowUnmanagedJobs__c   = true,
            AJO_KillSwitch__c           = false,
            AJO_HeartbeatMinutes__c     = 10,
            AJO_MaxConcurrentBatches__c = 5,
            AJO_RetentionDaysSuccess__c = 14,
            AJO_RetentionDaysFailure__c = 90,
            AJO_DefaultTimeZone__c      = 'Asia/Kolkata',
            AJO_EnableDeferral__c       = false,
            SetupOwnerId            = UserInfo.getOrganizationId()
        );
    }

    // ------------------------------------------------------------ dispatching

    @IsTest
    static void heartbeatRunsADueLegacySchedulable() {
        AJOJob__c job = makeJob('Legacy demo', 'DEMO_LEGACY', 'Legacy Schedulable',
                                'AJODemoLegacyScheduler', '0 0 * * * ?');

        Test.startTest();
        Integer picked = AJODispatcher.run(0);
        Test.stopTest();

        System.assertEquals(1, picked, 'The heartbeat should have picked the due job.');

        AJOJob__c after = [
            SELECT AJO_Status__c, AJO_LastRunStatus__c, AJO_NextRunAt__c, AJO_LastRunAt__c
            FROM AJOJob__c WHERE Id = :job.Id
        ];
        System.assertEquals('Success', after.AJO_LastRunStatus__c,
            'A synchronous Schedulable completes inside the heartbeat.');
        System.assertEquals('Idle', after.AJO_Status__c);
        System.assert(after.AJO_NextRunAt__c > Datetime.now(),
            'NextRunAt must be advanced past now.');

        List<AJOJobRun__c> runs = [
            SELECT AJO_Status__c, AJO_TriggeredBy__c, AJO_Message__c, AJO_DurationSec__c
            FROM AJOJobRun__c WHERE AJO_Job__c = :job.Id
        ];
        System.assertEquals(1, runs.size(), 'One run record should exist.');
        System.assertEquals('Success', runs[0].AJO_Status__c);
        System.assertEquals('Heartbeat', runs[0].AJO_TriggeredBy__c);
    }

    @IsTest
    static void heartbeatIgnoresJobsThatAreNotDue() {
        AJOJob__c job = makeJob('Not due', 'DEMO_NOTDUE', 'Legacy Schedulable',
                                'AJODemoLegacyScheduler', '0 0 * * * ?');
        job.AJO_NextRunAt__c = Datetime.now().addHours(6);
        update job;

        Test.startTest();
        Integer picked = AJODispatcher.run(0);
        Test.stopTest();

        System.assertEquals(0, picked, 'A job six hours out is not in the window.');
        System.assertEquals(0, [SELECT COUNT() FROM AJOJobRun__c]);
    }

    @IsTest
    static void killSwitchStopsEverything() {
        makeJob('Killed', 'DEMO_KILL', 'Legacy Schedulable',
                'AJODemoLegacyScheduler', '0 0 * * * ?');
        AJOConfig.applyOverride(new AJOSetting__c(AJO_KillSwitch__c = true));

        Test.startTest();
        Integer picked = AJODispatcher.run(0);
        Test.stopTest();

        System.assertEquals(0, picked, 'The kill switch must short-circuit the dispatcher.');
        System.assertEquals(0, [SELECT COUNT() FROM AJOJobRun__c]);
    }

    // ----------------------------------------------------------- run modes

    @IsTest
    static void runnableReceivesParametersAndReportsCounters() {
        AJOJob__c job = makeJob('Runnable demo', 'DEMO_RUNNABLE', 'Runnable',
                                'AJODemoRunnable', '0 0 * * * ?');
        job.AJO_Parameters__c = '{"object":"User","target":1}';
        update job;

        Test.startTest();
        AJODispatcher.run(0);
        Test.stopTest();

        AJOJobRun__c run = [
            SELECT AJO_Status__c, AJO_ItemsProcessed__c, AJO_Message__c
            FROM AJOJobRun__c WHERE AJO_Job__c = :job.Id LIMIT 1
        ];
        System.assertEquals('Success', run.AJO_Status__c);
        System.assert(run.AJO_ItemsProcessed__c > 0,
            'The Runnable should have counted at least one user.');
        System.assert(run.AJO_Message__c.contains('DEMO_RUNNABLE'),
            'The context should carry the job key through to the run record.');
    }

    @IsTest
    static void dryRunLogsTheIntentionWithoutRunningAnything() {
        AJOJob__c job = makeJob('Shadow', 'DEMO_SHADOW', 'Legacy Schedulable',
                                'AJODemoLegacyScheduler', '0 0 * * * ?');
        job.AJO_DryRun__c = true;
        update job;

        Test.startTest();
        AJODispatcher.run(0);
        Test.stopTest();

        AJOJobRun__c run = [
            SELECT AJO_Status__c, AJO_Message__c FROM AJOJobRun__c WHERE AJO_Job__c = :job.Id LIMIT 1
        ];
        System.assertEquals('Dry Run', run.AJO_Status__c,
            'Shadow mode records what it would have done.');
        System.assert(run.AJO_Message__c.contains('would have started'));

        AJOJob__c after = [SELECT AJO_NextRunAt__c FROM AJOJob__c WHERE Id = :job.Id];
        System.assert(after.AJO_NextRunAt__c > Datetime.now(),
            'Shadow mode still advances the schedule, so the log stays realistic.');
    }

    @IsTest
    static void batchIsLaunchedAndLeftOpenForReconciliation() {
        AJOJob__c job = makeJob('Batch demo', 'DEMO_BATCH', 'Batch',
                                'AJODemoBatch', '0 0 * * * ?');
        job.AJO_BatchSize__c = 200;
        update job;

        Test.startTest();
        AJODispatcher.run(0);
        Test.stopTest();

        AJOJobRun__c run = [
            SELECT AJO_Status__c, AJO_AsyncApexJobId__c, AJO_Message__c
            FROM AJOJobRun__c WHERE AJO_Job__c = :job.Id LIMIT 1
        ];
        System.assertNotEquals(null, run.AJO_AsyncApexJobId__c,
            'The platform job id must be captured so the run can be reconciled.');
        System.assert(run.AJO_Message__c.contains('Launched as Batch'));
    }

    @IsTest
    static void overlapPolicySkipsWhileAPreviousRunIsOpen() {
        AJOJob__c job = makeJob('Overlapping', 'DEMO_OVERLAP', 'Legacy Schedulable',
                                'AJODemoLegacyScheduler', '0 0 * * * ?');
        job.AJO_Status__c = 'Running';
        update job;

        Test.startTest();
        AJODispatcher.run(0);
        Test.stopTest();

        AJOJobRun__c run = [
            SELECT AJO_Status__c, AJO_Message__c FROM AJOJobRun__c WHERE AJO_Job__c = :job.Id LIMIT 1
        ];
        System.assertEquals('Skipped', run.AJO_Status__c,
            'A gap must be visible, not silent.');
        System.assert(run.AJO_Message__c.contains('still in progress'));
    }

    // ------------------------------------------------------- circuit breaker

    @IsTest
    static void repeatedFailuresSuspendTheJob() {
        AJOJob__c job = makeJob('Always fails', 'DEMO_FAIL', 'Legacy Schedulable',
                                'AJODemoFailingJob', '0 0 * * * ?');
        job.AJO_MaxConsecutiveFailures__c = 2;
        update job;

        Test.startTest();
        AJOLauncher.runNow(job, Datetime.now(), 'Heartbeat', 0);
        update job;
        AJOJob__c mid = [
            SELECT AJO_Status__c, AJO_ConsecutiveFailures__c FROM AJOJob__c WHERE Id = :job.Id
        ];
        System.assertEquals(1, mid.AJO_ConsecutiveFailures__c, 'First failure counted.');
        System.assertEquals('Idle', mid.AJO_Status__c, 'One failure is not enough to suspend.');

        AJOJob__c again = Database.query('SELECT ' + AJOLauncher.JOB_FIELDS
            + ' FROM AJOJob__c WHERE Id = \'' + job.Id + '\'');
        AJOLauncher.runNow(again, Datetime.now(), 'Heartbeat', 0);
        update again;
        Test.stopTest();

        AJOJob__c after = [
            SELECT AJO_Status__c, AJO_ConsecutiveFailures__c, AJO_LastRunStatus__c
            FROM AJOJob__c WHERE Id = :job.Id
        ];
        System.assertEquals(2, after.AJO_ConsecutiveFailures__c);
        System.assertEquals('Suspended', after.AJO_Status__c,
            'The breaker must open at the configured threshold.');

        List<AJOJobRun__c> runs = [
            SELECT AJO_Status__c, AJO_ErrorMessage__c FROM AJOJobRun__c WHERE AJO_Job__c = :job.Id
        ];
        System.assertEquals(2, runs.size());
        System.assert(runs[0].AJO_ErrorMessage__c.contains('DeliberateFailureException')
                   || runs[1].AJO_ErrorMessage__c.contains('DeliberateFailureException'),
            'The failure reason is captured on the run.');
    }

    @IsTest
    static void oneBadJobDoesNotStopTheOthers() {
        makeJob('Bad class', 'DEMO_BADCLASS', 'Legacy Schedulable',
                'ThisClassDoesNotExistAnywhere', '0 0 * * * ?');
        AJOJob__c good = makeJob('Good', 'DEMO_GOOD', 'Legacy Schedulable',
                                 'AJODemoLegacyScheduler', '0 0 * * * ?');

        Test.startTest();
        AJODispatcher.run(0);
        Test.stopTest();

        AJOJob__c after = [SELECT AJO_LastRunStatus__c FROM AJOJob__c WHERE Id = :good.Id];
        System.assertEquals('Success', after.AJO_LastRunStatus__c,
            'A neighbour with a broken class name must not block this one.');
        System.assertEquals(2, [SELECT COUNT() FROM AJOJobRun__c],
            'Both the failure and the success are recorded.');
    }

    // ------------------------------------------------------------- adapter

    @IsTest
    static void adapterPrefersSchedulableOverBatchable() {
        // AJODemoDualScheduler implements both. Schedulable must win, because its
        // execute() picks its own scope size.
        Test.startTest();
        AJOLegacyAdapter.Outcome out =
            AJOLegacyAdapter.run('AJODemoDualScheduler', 'Legacy Schedulable', 200);
        Test.stopTest();
        System.assertEquals('Schedulable', out.mode,
            'A dual-interface class must be entered through Schedulable.');
    }

    @IsTest
    static void adapterClassifiesEachSupportedShape() {
        System.assertEquals('Legacy Schedulable',
            AJOLegacyAdapter.classify('AJODemoLegacyScheduler'));
        System.assertEquals('Batch',    AJOLegacyAdapter.classify('AJODemoBatch'));
        System.assertEquals('Queueable', AJOLegacyAdapter.classify('AJODemoQueueable'));
        System.assertEquals('Runnable', AJOLegacyAdapter.classify('AJODemoRunnable'));
        System.assertEquals(null, AJOLegacyAdapter.classify('NoSuchClassHere'));
    }

    @IsTest
    static void adapterRefusesAnUnknownClass() {
        try {
            AJOLegacyAdapter.run('NoSuchClassHere', 'Legacy Schedulable', null);
            System.assert(false, 'Expected an UnsupportedJobException.');
        } catch (AJOLegacyAdapter.UnsupportedJobException e) {
            System.assert(e.getMessage().contains('not found'));
        }
    }

    // ------------------------------------------------------------ supervisor

    @IsTest
    static void supervisorReleasesAStuckRun() {
        AJOJob__c job = makeJob('Stuck', 'DEMO_STUCK', 'Batch',
                                'AJODemoBatch', '0 0 * * * ?');
        job.AJO_Status__c = 'Running';
        job.AJO_MaxRuntimeMinutes__c = 5;
        update job;

        AJOJobRun__c run = new AJOJobRun__c(
            AJO_Job__c = job.Id,
            AJO_Status__c = 'Running',
            AJO_StartedAt__c = Datetime.now().addHours(-3),
            AJO_TriggeredBy__c = 'Heartbeat'
        );
        insert run;

        Test.startTest();
        Integer reaped = AJOSupervisor.reapStuck();
        Test.stopTest();

        System.assertEquals(1, reaped);
        System.assertEquals('Stuck',
            [SELECT AJO_Status__c FROM AJOJobRun__c WHERE Id = :run.Id].AJO_Status__c);
        System.assertEquals('Idle',
            [SELECT AJO_Status__c FROM AJOJob__c WHERE Id = :job.Id].AJO_Status__c,
            'The job must be released so the next heartbeat can run it.');
    }

    @IsTest
    static void supervisorSweepCompletes() {
        makeJob('Sweep', 'DEMO_SWEEP', 'Legacy Schedulable',
                'AJODemoLegacyScheduler', '0 0 * * * ?');
        Test.startTest();
        Map<String, Object> result = AJOSupervisor.sweep();
        Test.stopTest();
        System.assertNotEquals(null, result.get('slotsUsed'));
        System.assertNotEquals(null, result.get('purged'));
    }

    // ------------------------------------------------------------ controller

    @IsTest
    static void consoleReadsJobsRunsAndHealth() {
        AJOJob__c job = makeJob('Console', 'DEMO_CONSOLE', 'Runnable',
                                'AJODemoRunnable', '0 17 * * * ?');

        Test.startTest();
        List<AJOAdminController.JobView> jobs = AJOAdminController.getJobs();
        String status = AJOAdminController.runNowById(job.Id);
        List<AJOAdminController.RunView> runs = AJOAdminController.getRuns(job.Id, 10);
        AJOAdminController.HealthView health = AJOAdminController.getHealth();
        List<String> preview = AJOAdminController.preview('0 17 * * * ?', TZ);
        Test.stopTest();

        System.assertEquals(1, jobs.size());
        System.assertEquals('Every hour at :17', jobs[0].schedule,
            'The console shows plain English, not cron.');
        // Run now no longer executes inside the clicking user's request: it opens
        // the run and hands the job to its own executor transaction.
        System.assertEquals('Queued', status);
        System.assertEquals(1, runs.size());
        System.assertEquals('Success', [SELECT AJO_Status__c FROM AJOJobRun__c WHERE AJO_Job__c = :job.Id LIMIT 1].AJO_Status__c,
            'The executor ran the job when the queue drained.');
        System.assertEquals('Manual', runs[0].triggeredBy);
        System.assertEquals(5, preview.size(), 'Five upcoming fire times.');
        System.assertEquals(100, health.slotLimit);
        System.assertEquals(1, health.jobsTotal);
    }

    @IsTest
    static void consoleSavesAndValidatesAJob() {
        Test.startTest();
        Id newId = AJOAdminController.saveJob(JSON.serialize(new Map<String, Object>{
            'name' => 'Created from the console',
            'jobKey' => 'DEMO_SAVED',
            'apexClass' => 'AJODemoRunnable',
            'executionType' => 'Runnable',
            'cronExpression' => '0 30 6 * * ?',
            'timeZone' => TZ,
            'enabled' => true,
            'startDate' => String.valueOf(Date.today()),
            'endDate' => String.valueOf(Date.today().addDays(9)),
            'priority' => 3
        }));
        Test.stopTest();

        AJOJob__c saved = [
            SELECT Name, AJO_NextRunAt__c, AJO_Status__c, AJO_IsActive__c,
                   AJO_StartDate__c, AJO_EndDate__c
            FROM AJOJob__c WHERE Id = :newId
        ];
        System.assertNotEquals(null, saved.AJO_NextRunAt__c,
            'Saving must compute the first run time.');
        System.assertEquals('Idle', saved.AJO_Status__c);
        System.assertEquals(Date.today(), saved.AJO_StartDate__c);
        System.assertEquals(Date.today().addDays(9), saved.AJO_EndDate__c);
        System.assertEquals(true, saved.AJO_IsActive__c,
            'A window that opens today makes the job active immediately.');
    }

    @IsTest
    static void consoleRejectsABadScheduleAndABadClass() {
        try {
            AJOAdminController.saveJob(JSON.serialize(new Map<String, Object>{
                'name' => 'Bad cron', 'jobKey' => 'X1',
                'apexClass' => 'AJODemoRunnable', 'executionType' => 'Runnable',
                'cronExpression' => 'nonsense'
            }));
            System.assert(false, 'Expected the schedule to be rejected.');
        } catch (Exception e) { /* expected */ }

        try {
            AJOAdminController.saveJob(JSON.serialize(new Map<String, Object>{
                'name' => 'Bad class', 'jobKey' => 'X2',
                'apexClass' => 'NoSuchClassHere', 'executionType' => 'Runnable',
                'cronExpression' => '0 0 9 * * ?'
            }));
            System.assert(false, 'Expected the class name to be rejected.');
        } catch (Exception e) { /* expected */ }

        try {
            AJOAdminController.saveJob(JSON.serialize(new Map<String, Object>{
                'name' => 'Backwards window', 'jobKey' => 'X3',
                'apexClass' => 'AJODemoRunnable', 'executionType' => 'Runnable',
                'cronExpression' => '0 0 9 * * ?',
                'startDate' => String.valueOf(Date.today()),
                'endDate' => String.valueOf(Date.today().addDays(-1))
            }));
            System.assert(false, 'Expected the window to be rejected.');
        } catch (Exception e) { /* expected */ }
    }

    @IsTest
    static void consoleTogglesActivationAndKillSwitch() {
        AJOJob__c job = makeJob('Toggle', 'DEMO_TOGGLE', 'Legacy Schedulable',
                                'AJODemoLegacyScheduler', '0 0 * * * ?');
        Test.startTest();
        AJOAdminController.setEnabled(job.Id, false);
        AJOAdminController.setDryRun(job.Id, true);
        AJOAdminController.setKillSwitch(true);
        Test.stopTest();

        AJOJob__c after = [
            SELECT AJO_Enabled__c, AJO_IsActive__c, AJO_DryRun__c
            FROM AJOJob__c WHERE Id = :job.Id
        ];
        System.assertEquals(false, after.AJO_Enabled__c);
        System.assertEquals(false, after.AJO_IsActive__c,
            'Pausing must make the derived Active flag false too.');
        System.assertEquals(true, after.AJO_DryRun__c);
        System.assertEquals(true, AJOSetting__c.getOrgDefaults().AJO_KillSwitch__c);
    }

    // ------------------------------------------------------------- installer

    @IsTest
    static void installerHoldsSevenSlotsWhateverTheJobCount() {
        // CronTrigger is real org data, not test data, so this asserts on the
        // resulting state rather than on what this call happened to create —
        // and it never disarms, which would abort the org's live heartbeats.
        Test.startTest();
        AJOInstaller.ensureSettings();
        AJOInstaller.arm();
        Test.stopTest();

        System.assertEquals(6, AJOInstaller.slots().size(),
            'A ten-minute heartbeat gives six slots an hour.');

        Set<String> names = new Set<String>();
        for (CronTrigger ct : AJOInstaller.ownTriggers()) {
            names.add(ct.CronJobDetail.Name);
        }
        System.assertEquals(7, names.size(),
            'Six heartbeats plus one supervisor — seven registrations, whatever the job count.');
        System.assert(names.contains('AJO Heartbeat 00'));
        System.assert(names.contains('AJO Heartbeat 50'));
        System.assert(names.contains(AJOInstaller.SUPERVISOR_NAME));
    }

    @IsTest
    static void armingTwiceDoesNotDoubleUp() {
        Test.startTest();
        AJOInstaller.arm();
        List<String> second = AJOInstaller.arm();
        Test.stopTest();
        System.assertEquals(0, second.size(), 'Arming must be idempotent.');
    }

    @IsTest
    static void throttleReportsAvailableBatchSlots() {
        Integer free = AJOThrottle.availableBatchSlots();
        System.assert(free >= 0 && free <= AJOConfig.maxConcurrentBatches(),
            'Available slots must sit within the configured ceiling.');
    }

    @IsTest
    static void aDeferredJobIsNotQueuedTwiceByTheNextHeartbeat() {
        // Found by the proof of concept: advancing from now rather than from the
        // deferred instant left NextRunAt inside the current window, so every
        // heartbeat before the deferred run landed queued the job again.
        //
        // The schedule below is deliberately once a year. Both heartbeats run at
        // the same wall-clock instant, so with the original hourly fixture the
        // recomputed NextRunAt landed inside the second heartbeat's ten-minute
        // lookahead whenever the test happened to run after :50, and the
        // assertions failed for reasons that had nothing to do with deferral.
        AJOConfig.applyOverride(new AJOSetting__c(
            AJO_AllowUnmanagedJobs__c = true,
            AJO_KillSwitch__c = false, AJO_HeartbeatMinutes__c = 10,
            AJO_MaxConcurrentBatches__c = 5, AJO_EnableDeferral__c = true,
            AJO_DefaultTimeZone__c = TZ));

        AJOJob__c job = makeJob('Deferred', 'DEMO_DEFER', 'Legacy Schedulable',
                                'AJODemoLegacyScheduler', '0 0 3 1 1 ?');
        Datetime dueAt = Datetime.now().addMinutes(4);   // inside the window, not yet due
        job.AJO_NextRunAt__c = dueAt;
        update job;

        Test.startTest();
        AJODispatcher.run(0);
        AJOJob__c afterFirst = [
            SELECT AJO_Status__c, AJO_NextRunAt__c FROM AJOJob__c WHERE Id = :job.Id
        ];
        System.assertEquals('Queued', afterFirst.AJO_Status__c,
            'The job should have been deferred to its exact minute.');
        System.assert(afterFirst.AJO_NextRunAt__c > dueAt,
            'NextRunAt must advance past the deferred instant, not sit on it.');
        System.assert(afterFirst.AJO_NextRunAt__c > Datetime.now().addMinutes(10),
            'NextRunAt must move past the current heartbeat window, not stay inside it.');

        Integer pickedAgain = AJODispatcher.run(10);
        Test.stopTest();

        System.assertEquals(0, pickedAgain,
            'A second heartbeat must not queue the same deferred job again.');
    }

    @IsTest
    static void contextParsesParametersDefensively() {
        AJOJob__c j = makeJob('Ctx', 'DEMO_CTX', 'Runnable', 'AJODemoRunnable', '0 0 * * * ?');
        j.AJO_Parameters__c = 'this is not json';
        update j;
        AJOContext ctx = new AJOContext(j, null);
        System.assertEquals('fallback', ctx.getString('missing', 'fallback'));
        System.assertEquals(7, ctx.getInteger('missing', 7));
        System.assertEquals(true, ctx.getBoolean('missing', true));
    }

    /**
     * A heartbeat firing one second late left a 9m59s gap to the job's minute,
     * and flooring that to 9 started the job a minute BEFORE its configured
     * time — a 15:00 job ran at 14:59:01. Late by seconds is fine; early is not.
     */
    @IsTest
    static void aDeferredRunIsNeverStartedBeforeItsMinute() {
        Datetime dueAt = Datetime.newInstance(2026, 9, 11, 15, 0, 0);

        Test.startTest();
        // The heartbeat fired at 14:50:01, one second late.
        Integer late = AJOLauncher.deferralMinutes(
            dueAt, Datetime.newInstance(2026, 9, 11, 14, 50, 1));
        // And exactly on time.
        Integer onTime = AJOLauncher.deferralMinutes(
            dueAt, Datetime.newInstance(2026, 9, 11, 14, 50, 0));
        Integer past = AJOLauncher.deferralMinutes(
            dueAt, Datetime.newInstance(2026, 9, 11, 15, 0, 1));
        Test.stopTest();

        System.assertEquals(10, late,
            'A one-second-late heartbeat must still wait until 15:00, not 14:59.');
        System.assertEquals(10, onTime);
        System.assertEquals(0, past, 'An overdue run starts immediately.');
        System.assert(late <= AJOConfig.PLATFORM_DELAY_CAP,
            'The delay must stay inside the platform cap.');
    }
}