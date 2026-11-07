/**
 * Covers the engine fixes: dispatch-only checks with bulk logging and a launch
 * budget, the executor's isolation and stand-down rules, the savepoint, the
 * definition overriding a tampered record, the unmanaged-job policy, early
 * starts, throttle accounting, dependency semantics and chaining, failure
 * reconciliation, and the console's operate/author endpoints for managed jobs.
 */
@IsTest
private class AJOEngineHardeningTest {

    @TestSetup
    static void setup() {
        AJOTestFactory.settings(false);
    }

    // ============================================================ dispatching

    @IsTest
    static void aCheckDispatchesEveryJobToItsOwnExecutor() {
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{
            AJOTestFactory.runnable('ENG_A'), AJOTestFactory.runnable('ENG_B') });
        AJODefinitionSync.sync();
        AJOTestFactory.makeDue('ENG_A');
        AJOTestFactory.makeDue('ENG_B');

        Test.startTest();
        Integer picked = AJODispatcher.run(0);
        // Nothing has run yet: the check only dispatches.
        List<AJOJobRun__c> queued = [SELECT AJO_Status__c, AJO_AsyncApexJobId__c FROM AJOJobRun__c];
        Test.stopTest();

        System.assertEquals(2, picked);
        System.assertEquals(2, queued.size());
        for (AJOJobRun__c r : queued) {
            System.assertEquals('Running', r.AJO_Status__c, 'Open until the executor runs.');
            System.assertNotEquals(null, r.AJO_AsyncApexJobId__c, 'Each run points at its executor.');
        }
        System.assertEquals(2, [SELECT COUNT() FROM AJOJobRun__c WHERE AJO_Status__c = 'Success'],
            'Each executor ran its job when the queue drained.');
        System.assertEquals('Idle', AJOTestFactory.state('ENG_A').AJO_Status__c);
        System.assertEquals(null, AJOTestFactory.state('ENG_A').AJO_QueuedForAt__c);
    }

    @IsTest
    static void aLargeCheckStaysWithinItsBudgetAndHoldsTheRest() {
        List<AJO_Job_Definition__mdt> defs = new List<AJO_Job_Definition__mdt>();
        for (Integer i = 0; i < 60; i++) {
            AJO_Job_Definition__mdt d = AJOTestFactory.runnable('ENG_BULK_' + i);
            d.AJO_DryRun__c = false;
            defs.add(d);
        }
        AJOTestFactory.use(defs);
        AJODefinitionSync.sync();
        List<AJOJob__c> all = [SELECT Id FROM AJOJob__c WHERE AJO_JobKey__c LIKE 'ENG_BULK_%'];
        for (AJOJob__c j : all) { j.AJO_NextRunAt__c = Datetime.now().addMinutes(-1); }
        update all;

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        AJODispatcher.run(0);
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Integer queuedRuns = [SELECT COUNT() FROM AJOJobRun__c];
        Integer stillDue = [SELECT COUNT() FROM AJOJob__c
                            WHERE AJO_JobKey__c LIKE 'ENG_BULK_%' AND AJO_NextRunAt__c <= :Datetime.now()];
        Set<String> codes = AJOTestFactory.sentCodes();
        Test.stopTest();

        System.assert(dmlUsed < 20, 'DML must not grow with the job count; used ' + dmlUsed);
        System.assert(queuedRuns <= AJOConfig.DEFAULT_MAX_LAUNCHES, 'Launches are capped: ' + queuedRuns);
        System.assertEquals(60 - queuedRuns, stillDue,
            'Jobs over the budget keep their Next Run for the next check (late, never lost).');
        System.assert(codes.contains('LAUNCH_BACKLOG'), 'The backlog is alerted.');
    }

    @IsTest
    static void unmanagedJobsAreIgnoredByDefault() {
        insert new AJOJob__c(Name = 'Rogue', AJO_JobKey__c = 'ENG_ROGUE',
            AJO_ApexClassName__c = 'AJODemoRunnable', AJO_ExecutionType__c = 'Runnable',
            AJO_CronExpression__c = '0 0 * * * ?', AJO_Enabled__c = true, AJO_Status__c = 'Idle',
            AJO_NextRunAt__c = Datetime.now().addMinutes(-1));
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>());

        Test.startTest();
        Integer picked = AJODispatcher.run(0);
        Test.stopTest();

        System.assertEquals(0, picked, 'A record with no deployed definition never runs.');
        System.assertEquals(0, [SELECT COUNT() FROM AJOJobRun__c]);
    }

    @IsTest
    static void withDeferralOffNothingStartsEarly() {
        AJOSetting__c s = AJOSetting__c.getOrgDefaults();
        s.AJO_EnableDeferral__c = false;
        update s;
        AJOConfig.applyOverride(null);
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ AJOTestFactory.runnable('ENG_LATER') });
        AJODefinitionSync.sync();
        AJOJob__c j = AJOTestFactory.state('ENG_LATER');
        j.AJO_NextRunAt__c = Datetime.now().addMinutes(5);
        update j;

        Test.startTest();
        Integer picked = AJODispatcher.run(0);
        Test.stopTest();

        System.assertEquals(0, picked, 'A job due in five minutes waits for its own check.');
    }

    @IsTest
    static void aJobDueLaterInTheWindowIsHeldToItsMinute() {
        Datetime now = Datetime.now();
        System.assertEquals(0, AJOLauncher.deferralMinutes(now.addMinutes(-3), now));
        System.assertEquals(1, AJOLauncher.deferralMinutes(now.addSeconds(5), now), 'Rounded up, never early.');
        System.assertEquals(10, AJOLauncher.deferralMinutes(now.addMinutes(25), now), 'Capped at the platform limit.');
    }

    // ============================================================== executor

    @IsTest
    static void theDefinitionDecidesWhatRunsEvenIfTheRecordWasEdited() {
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ AJOTestFactory.runnable('ENG_TAMPER') });
        AJODefinitionSync.sync();
        AJOJob__c j = AJOTestFactory.state('ENG_TAMPER');
        j.AJO_ApexClassName__c = 'AJODemoFailingJob';
        j.AJO_ExecutionType__c = 'Legacy Schedulable';
        update j;

        Test.startTest();
        AJOJobRun__c run = AJOLauncher.runNow(AJOTestFactory.state('ENG_TAMPER'), Datetime.now(), 'Manual', null);
        Test.stopTest();

        System.assertEquals('Success', [SELECT AJO_Status__c FROM AJOJobRun__c WHERE Id = :run.Id].AJO_Status__c,
            'The executor ran the definition\'s class, not the edited one.');
    }

    @IsTest
    static void aFailedJobLeavesNoPartialWork() {
        AJO_Job_Definition__mdt d = AJOTestFactory.definition('ENG_PARTIAL', 'AJODemoPartialFailJob', 'Runnable');
        d.AJO_Parameters__c = '{"marker":"ENG_PARTIAL_MARKER"}';
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });
        AJODefinitionSync.sync();

        Test.startTest();
        AJOJob__c j = AJOTestFactory.state('ENG_PARTIAL');
        AJOJobRun__c run = AJOLauncher.runNow(j, Datetime.now(), 'Manual', null);
        update j;
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM AJOJob__c WHERE AJO_JobKey__c = 'ENG_PARTIAL_MARKER'],
            'The savepoint rolls the job\'s own writes back before the failure is recorded.');
        AJOJobRun__c after = [SELECT AJO_Status__c, AJO_ErrorMessage__c FROM AJOJobRun__c WHERE Id = :run.Id];
        System.assertEquals('Failed', after.AJO_Status__c);
        System.assert(after.AJO_ErrorMessage__c.contains('PartialFailureException'), after.AJO_ErrorMessage__c);
        System.assertEquals(1, AJOTestFactory.state('ENG_PARTIAL').AJO_ConsecutiveFailures__c);
    }

    @IsTest
    static void theExecutorStandsDownWhenEverythingIsPaused() {
        AJOJobRun__c run = queuedRunFor('ENG_PAUSED_ALL');
        AJOSetting__c s = AJOSetting__c.getOrgDefaults();
        s.AJO_KillSwitch__c = true;
        update s;
        AJOConfig.applyOverride(null);

        Test.startTest();
        executorFor('ENG_PAUSED_ALL', run).executeNow();
        Test.stopTest();

        assertSkipped(run, 'paused');
    }

    @IsTest
    static void theExecutorStandsDownWhenTheDefinitionWasDeactivated() {
        AJOJobRun__c run = queuedRunFor('ENG_DEACTIVATED');
        AJO_Job_Definition__mdt d = AJOTestFactory.runnable('ENG_DEACTIVATED');
        d.AJO_Active__c = false;
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });

        Test.startTest();
        executorFor('ENG_DEACTIVATED', run).executeNow();
        Test.stopTest();

        assertSkipped(run, 'deactivated');
    }

    @IsTest
    static void theExecutorStandsDownWhenAnotherRunOwnsTheOccurrence() {
        AJOJobRun__c run = queuedRunFor('ENG_OWNER');
        AJOJob__c j = AJOTestFactory.state('ENG_OWNER');
        j.AJO_NextRunAt__c = j.AJO_QueuedForAt__c.addMinutes(-1); // an edit handed it back
        update j;

        Test.startTest();
        executorFor('ENG_OWNER', run).executeNow();
        Test.stopTest();

        assertSkipped(run, 'owns this occurrence');
    }

    @IsTest
    static void runNowLeavesAHeartbeatQueuedRunInPlace() {
        AJOJobRun__c queued = queuedRunFor('ENG_RUNNOW_KEEPS');
        AJOJob__c j = AJOTestFactory.state('ENG_RUNNOW_KEEPS');
        Datetime marker = j.AJO_QueuedForAt__c;

        Test.startTest();
        new AJOJobExecutor(j.Id, null, null).executeNow(); // what Run now enqueues
        Test.stopTest();

        System.assertEquals(marker, AJOTestFactory.state('ENG_RUNNOW_KEEPS').AJO_QueuedForAt__c,
            'The heartbeat\'s queued occurrence must survive a manual run, or it would stand down.');
        System.assertEquals('Running', [SELECT AJO_Status__c FROM AJOJobRun__c WHERE Id = :queued.Id].AJO_Status__c,
            'The queued run is untouched until its own executor lands.');
    }

    @IsTest
    static void aRunNowExecutorDoesNotOverwriteNewerSchedulingState() {
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ AJOTestFactory.runnable('ENG_NO_CLOBBER') });
        AJODefinitionSync.sync();
        AJOJob__c j = AJOTestFactory.state('ENG_NO_CLOBBER');
        AJOJobRun__c run = AJORunLogger.open(j, Datetime.now(), 'Manual', null);
        Datetime later = Datetime.now().addHours(5);

        Test.startTest();
        AJOJobExecutor ex = new AJOJobExecutor(j.Id, run.Id, null);
        // A sync or edit moves Next Run after the executor could have read it; the
        // executor must commit only the run's outcome and leave this alone.
        update new AJOJob__c(Id = j.Id, AJO_NextRunAt__c = later);
        ex.executeNow();
        Test.stopTest();

        AJOJob__c after = AJOTestFactory.state('ENG_NO_CLOBBER');
        System.assertEquals(later, after.AJO_NextRunAt__c, 'Next Run set meanwhile must survive the run.');
        System.assertEquals('Success', after.AJO_LastRunStatus__c);
    }

    @IsTest
    static void aManualRunIsRefusedWhileTheJobIsAlreadyInFlight() {
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ AJOTestFactory.runnable('ENG_MANUAL_OVERLAP') });
        AJODefinitionSync.sync();
        AJOJob__c j = AJOTestFactory.state('ENG_MANUAL_OVERLAP');
        update new AJOJob__c(Id = j.Id, AJO_Status__c = 'Running');

        expectRefusal(new RunNowCall(j.Id), 'already');
    }

    @IsTest
    static void anExecutorThatDiedIsReconciledAsAFailure() {
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ AJOTestFactory.runnable('ENG_DIED') });
        AJODefinitionSync.sync();
        AJOJob__c j = AJOTestFactory.state('ENG_DIED');

        // An executor for a job id that no longer exists completes without
        // touching any run — standing in for one killed by a governor limit.
        Test.startTest();
        AJOJob__c doomed = new AJOJob__c(Name = 'Doomed', AJO_JobKey__c = 'ENG_DOOMED',
            AJO_ApexClassName__c = 'AJODemoRunnable', AJO_ExecutionType__c = 'Runnable',
            AJO_CronExpression__c = '0 0 * * * ?');
        insert doomed;
        Id doomedId = doomed.Id;
        delete doomed;
        Id asyncId = System.enqueueJob(new AJOJobExecutor(doomedId, null, null));
        Test.stopTest();

        insert new AJOJobRun__c(AJO_Job__c = j.Id, AJO_Status__c = 'Running',
            AJO_StartedAt__c = Datetime.now(), AJO_AsyncApexJobId__c = asyncId);
        AJORunLogger.reconcile();

        AJOJobRun__c r = [SELECT AJO_Status__c, AJO_ErrorMessage__c FROM AJOJobRun__c WHERE AJO_Job__c = :j.Id];
        System.assertEquals('Failed', r.AJO_Status__c);
        System.assert(r.AJO_ErrorMessage__c.contains('without recording an outcome'), r.AJO_ErrorMessage__c);
        System.assertEquals(1, AJOTestFactory.state('ENG_DIED').AJO_ConsecutiveFailures__c,
            'The death counts against the circuit breaker.');
    }

    // ===================================================== breaker and alerts

    @IsTest
    static void reachingTheFailureLimitSuspendsAndAlerts() {
        AJOJob__c j = new AJOJob__c(AJO_JobKey__c = 'ENG_BREAKER', AJO_ConsecutiveFailures__c = 2,
                                    AJO_MaxConsecutiveFailures__c = 3, AJO_NotifyEmails__c = 'ops@example.com');
        AJOLauncher.recordFailure(j, Datetime.now(), 'Boom');
        System.assertEquals('Suspended', j.AJO_Status__c);
        System.assertEquals(3, j.AJO_ConsecutiveFailures__c);
        System.assert(AJOTestFactory.sentCodes().contains('JOB_SUSPENDED'));

        AJOJob__c k = new AJOJob__c(AJO_JobKey__c = 'ENG_ONE_FAILURE', AJO_MaxConsecutiveFailures__c = 3);
        AJOLauncher.recordFailure(k, Datetime.now(), 'Boom');
        System.assertEquals('Idle', k.AJO_Status__c);
        System.assert(AJOTestFactory.sentCodes().contains('JOB_FAILED'));
    }

    // ============================================================= throttle

    @IsTest
    static void theThrottleOnlyGovernsBatches() {
        AJOThrottle t = new AJOThrottle();
        Integer before = t.remaining();
        System.assert(t.claim(new AJOJob__c(AJO_ExecutionType__c = 'Runnable')));
        System.assertEquals(before, t.remaining(), 'Non-batch work consumes no batch capacity.');
        System.assert(AJOThrottle.flexQueueDepth() >= 0);
        System.assert(AJOThrottle.availableBatchSlots() <= AJOConfig.maxConcurrentBatches());
        if (before > 0) {
            System.assert(t.claim(new AJOJob__c(AJO_ExecutionType__c = 'Batch')));
            System.assertEquals(before - 1, t.remaining());
        }
    }

    @IsTest
    static void batchCapacitySettingsAreBounded() {
        AJOConfig.applyOverride(new AJOSetting__c(AJO_FlexQueueCap__c = 500, AJO_MaxConcurrentBatches__c = 3));
        System.assertEquals(100, AJOConfig.flexQueueCap(), 'The flex queue never holds more than 100.');
        System.assertEquals(3, AJOConfig.maxConcurrentBatches());
        System.assert(AJOThrottle.availableBatchSlots() <= 3);
        AJOConfig.applyOverride(new AJOSetting__c());
        System.assertEquals(AJOConfig.DEFAULT_FLEX_QUEUE_CAP, AJOConfig.flexQueueCap());
        System.assertEquals(AJOConfig.DEFAULT_MAX_LAUNCHES, AJOConfig.maxLaunchesPerCheck());
        System.assertEquals(30, AJOConfig.staleHeartbeatMinutes(), 'Three ten-minute checks by default.');
    }

    // ========================================================== dependencies

    @IsTest
    static void aDependencyMustHaveSucceededSinceTheChildLastRan() {
        AJOJob__c parent = new AJOJob__c(Name = 'Parent', AJO_JobKey__c = 'ENG_DEP_PARENT',
            AJO_ApexClassName__c = 'AJODemoRunnable', AJO_ExecutionType__c = 'Runnable',
            AJO_CronExpression__c = '0 0 * * * ?');
        insert parent;
        Id parentId = parent.Id;
        Datetime now = Datetime.now();
        AJOJobRun__c ok = new AJOJobRun__c(AJO_Job__c = parentId, AJO_Status__c = 'Success',
                                           AJO_FinishedAt__c = now.addMinutes(-5));
        Map<Id, AJOJobRun__c> outcomes = new Map<Id, AJOJobRun__c>{ parentId => ok };

        AJOJob__c neverRan = new AJOJob__c(AJO_DependsOnJobId__c = parentId);
        System.assert(AJOLauncher.dependencySatisfied(neverRan, outcomes, now), 'Recent success, first run.');

        AJOJob__c ranAfter = new AJOJob__c(AJO_DependsOnJobId__c = parentId, AJO_LastRunAt__c = now.addMinutes(-1));
        System.assert(!AJOLauncher.dependencySatisfied(ranAfter, outcomes, now),
            'One parent success must not feed two child runs.');

        ok.AJO_Status__c = 'Failed';
        System.assert(!AJOLauncher.dependencySatisfied(neverRan, outcomes, now));
        System.assert(!AJOLauncher.dependencySatisfied(neverRan, new Map<Id, AJOJobRun__c>(), now));
    }

    @IsTest
    static void aParentsSuccessMakesItsChainedChildDue() {
        AJO_Job_Definition__mdt parent = AJOTestFactory.runnable('ENG_CHAIN_PARENT');
        AJO_Job_Definition__mdt child = AJOTestFactory.runnable('ENG_CHAIN_CHILD');
        child.AJO_DependsOn__c = 'ENG_CHAIN_PARENT';
        child.AJO_RunAfterDependency__c = true;
        child.AJO_CronExpression__c = '0 0 4 * * ?';
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ parent, child });
        AJODefinitionSync.sync();
        AJOJob__c p = AJOTestFactory.state('ENG_CHAIN_PARENT');
        Id fakeBatchId = '707000000000001';
        insert new AJOJobRun__c(AJO_Job__c = p.Id, AJO_Status__c = 'Running', AJO_StartedAt__c = Datetime.now(),
                                AJO_AsyncApexJobId__c = String.valueOf(fakeBatchId));

        Test.startTest();
        Boolean closed = AJORunLogger.report(fakeBatchId, 100, 0, 'All good.');
        Test.stopTest();

        System.assert(closed);
        System.assert(AJOTestFactory.state('ENG_CHAIN_CHILD').AJO_NextRunAt__c <= Datetime.now(),
            'The child is due at the next check instead of waiting for its own 04:00.');
    }

    // ===================================================== console (managed)

    @IsTest
    static void managedJobsAreOperatedButNotEdited() {
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ AJOTestFactory.runnable('ENG_CONSOLE') });
        AJODefinitionSync.sync();
        AJOJob__c j = AJOTestFactory.state('ENG_CONSOLE');

        Test.startTest();
        expectRefusal(new SaveCall(j.Id), 'release');
        expectRefusal(new DeleteCall(j.Id), 'release');
        String status = AJOAdminController.runNowById(j.Id);
        String next = AJOAdminController.runAtNextCheck(j.Id);
        Test.stopTest();

        System.assertEquals('Queued', status);
        System.assert(next.containsIgnoreCase('next scheduled check'));
        System.assert(AJOTestFactory.state('ENG_CONSOLE').AJO_NextRunAt__c <= Datetime.now());
        List<AJOAdminController.JobView> views = AJOAdminController.getJobs();
        System.assertEquals(true, views[0].managed);
        System.assertEquals(true, views[0].editLocked);
    }

    @IsTest
    static void newJobsBecomeDefinitionFilesNotRecords() {
        Map<String, Object> draft = new Map<String, Object>{
            'name' => 'Weekly cleanup', 'jobKey' => 'WEEKLY_CLEANUP', 'apexClass' => 'AJODemoRunnable',
            'executionType' => 'Runnable', 'cronExpression' => '0 0 6 ? * MON',
            'timeZone' => 'America/New_York', 'enabled' => true, 'parameters' => '{"object":"User"}' };

        Test.startTest();
        AJODefinitionExporter.DefinitionFile f = AJOAdminController.generateDefinition(JSON.serialize(draft));
        Test.stopTest();

        System.assertEquals('AJO_Job_Definition.WEEKLY_CLEANUP.md-meta.xml', f.fileName);
        System.assert(f.problems.isEmpty(), String.join(f.problems, ' | '));
        System.assert(f.xml.contains('<field>AJO_ApexClass__c</field>'));
        System.assert(f.xml.contains('AJODemoRunnable'));
        System.assert(f.xml.contains('&quot;object&quot;'), 'JSON is escaped for XML.');
        System.assertEquals(0, [SELECT COUNT() FROM AJOJob__c], 'Nothing is written to the org.');
        expectRefusal(new SaveCall(null), 'release');
    }

    // ================================================================ helpers

    private static AJOJobRun__c queuedRunFor(String key) {
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ AJOTestFactory.runnable(key) });
        AJODefinitionSync.sync();
        AJOJob__c j = AJOTestFactory.state(key);
        Datetime dueAt = Datetime.newInstance(Datetime.now().addMinutes(5).getTime() / 1000 * 1000);
        j.AJO_Status__c = 'Queued';
        j.AJO_QueuedForAt__c = dueAt;
        j.AJO_NextRunAt__c = dueAt.addHours(1);
        update j;
        AJOJobRun__c run = new AJOJobRun__c(AJO_Job__c = j.Id, AJO_Status__c = 'Running',
                                            AJO_StartedAt__c = Datetime.now(), AJO_ScheduledFor__c = dueAt);
        insert run;
        return run;
    }

    private static AJOJobExecutor executorFor(String key, AJOJobRun__c run) {
        AJOJob__c j = AJOTestFactory.state(key);
        return new AJOJobExecutor(j.Id, run.Id, j.AJO_QueuedForAt__c);
    }

    private static void assertSkipped(AJOJobRun__c run, String fragment) {
        AJOJobRun__c r = [SELECT AJO_Status__c, AJO_Message__c FROM AJOJobRun__c WHERE Id = :run.Id];
        System.assertEquals('Skipped', r.AJO_Status__c);
        System.assert(r.AJO_Message__c.containsIgnoreCase(fragment), r.AJO_Message__c);
    }

    private interface Call { void invoke(); }

    private class RunNowCall implements Call {
        Id jobId;
        RunNowCall(Id jobId) { this.jobId = jobId; }
        public void invoke() { AJOAdminController.runNowById(jobId); }
    }

    private class SaveCall implements Call {
        Id jobId;
        SaveCall(Id jobId) { this.jobId = jobId; }
        public void invoke() {
            AJOAdminController.saveJob(JSON.serialize(new Map<String, Object>{
                'id' => jobId, 'name' => 'x', 'jobKey' => 'X', 'apexClass' => 'AJODemoRunnable',
                'executionType' => 'Runnable', 'cronExpression' => '0 0 * * * ?' }));
        }
    }

    private class DeleteCall implements Call {
        Id jobId;
        DeleteCall(Id jobId) { this.jobId = jobId; }
        public void invoke() { AJOAdminController.deleteJob(jobId); }
    }

    /**
     * The call must be refused. AuraHandledException does not expose its text
     * to Apex (getMessage() returns "Script-thrown exception"), so the reason
     * is documented by the fragment rather than asserted.
     */
    private static void expectRefusal(Call c, String fragment) {
        Boolean refused = false;
        try {
            c.invoke();
        } catch (AuraHandledException e) {
            refused = true;
        }
        System.assert(refused, 'Expected a refusal (' + fragment + ').');
    }
}
