/**
 * Covers the operating console's back end: the plain-English status header,
 * the preview of what the next scheduled check will do, the single activity
 * table and its filters, and the permission gate on the framework controls.
 */
@IsTest
private class AJOConsoleTest {

    /**
     * These tests exercise the engine with directly-inserted AJOJob__c rows
     * (unmanaged jobs), so they run in the migration mode that allows them.
     * The definition-backed (managed) path is covered by AJODefinitionSyncTest,
     * AJOEngineHardeningTest and AJODefinitionValidationTest.
     */
    @TestSetup
    static void allowUnmanagedJobs() {
        insert new AJOSetting__c(AJO_AllowUnmanagedJobs__c = true, AJO_HeartbeatMinutes__c = 10,
                                 AJO_MaxConcurrentBatches__c = 5, AJO_EnableDeferral__c = true);
    }


    private static AJOJob__c job(String key, String name) {
        return new AJOJob__c(
            Name                  = name,
            AJO_JobKey__c         = key,
            AJO_ExecutionType__c  = 'Runnable',
            AJO_ApexClassName__c  = 'AJODemoRunnable',
            AJO_CronExpression__c = '0 0 * * * ?',
            AJO_TimeZoneSidKey__c = 'Asia/Kolkata',
            AJO_Enabled__c        = true,
            AJO_StartDate__c      = Date.today(),
            AJO_Status__c         = 'Idle',
            AJO_OverlapPolicy__c  = 'Skip',
            AJO_Priority__c       = 5,
            AJO_NextRunAt__c      = Datetime.now().addMinutes(1)
        );
    }

    // ------------------------------------------------------------- header

    @IsTest
    static void healthCarriesAReadableHeadline() {
        insert job('CONSOLE_HEALTH', 'Health');

        Test.startTest();
        AJOAdminController.HealthView h = AJOAdminController.getHealth();
        Test.stopTest();

        System.assertNotEquals(null, h.statusHeadline, 'The header needs a sentence.');
        System.assert(h.statusHeadline.length() > 10, 'Headline was: ' + h.statusHeadline);
        System.assert(new Set<String>{'ok', 'warning', 'error'}.contains(h.statusTone),
            'Tone drives the banner colour and must be one of three values: ' + h.statusTone);
        System.assertEquals(AJOConfig.heartbeatMinutes(), h.heartbeatMinutes);
        System.assertNotEquals(null, h.canAdminister);
    }

    @IsTest
    static void headlineSaysSoWhenEverythingIsPaused() {
        AJOInstaller.arm();
        AJOSetting__c s = AJOInstaller.ensureSettings();
        s.AJO_KillSwitch__c = true;
        update s;
        AJOConfig.applyOverride(s);

        Test.startTest();
        AJOAdminController.HealthView h = AJOAdminController.getHealth();
        Test.stopTest();

        System.assertEquals('warning', h.statusTone);
        System.assert(h.statusHeadline.containsIgnoreCase('paused'),
            'A paused org must say so before anything else: ' + h.statusHeadline);
    }

    // ------------------------------------------------- what runs next, and why

    @IsTest
    static void nextCheckExplainsWhatEachDueJobWillDo() {
        AJOJob__c willRun  = job('CONSOLE_RUN',   'Runs normally');
        AJOJob__c testMode = job('CONSOLE_SHADOW','In test mode');
        AJOJob__c stillOn  = job('CONSOLE_OPEN',  'Previous run open');
        testMode.AJO_DryRun__c = true;
        stillOn.AJO_Status__c  = 'Running';
        insert new List<AJOJob__c>{ willRun, testMode, stillOn };

        AJOJob__c waiting = job('CONSOLE_DEP', 'Waits on another job');
        waiting.AJO_DependsOnJobId__c = willRun.Id;
        insert waiting;

        AJOInstaller.arm();

        Test.startTest();
        AJOAdminController.NextCheckView v = AJOAdminController.getNextCheck();
        Test.stopTest();

        System.assert(v.installed, 'The scheduler was armed, so the preview must be live.');
        Map<String, AJOAdminController.DueView> byName =
            new Map<String, AJOAdminController.DueView>();
        for (AJOAdminController.DueView d : v.due) { byName.put(d.name, d); }

        System.assertEquals(4, v.due.size(), 'All four jobs are due inside the window.');
        System.assertEquals('Will run',        byName.get('Runs normally').verdict);
        System.assertEquals('Test mode',       byName.get('In test mode').verdict);
        System.assertEquals('Will be skipped', byName.get('Previous run open').verdict);
        System.assertEquals('Waiting',         byName.get('Waits on another job').verdict);

        System.assert(byName.get('Runs normally').willRun);
        System.assert(!byName.get('In test mode').willRun,
            'Test mode launches nothing, so it must not be counted as running.');
        System.assertEquals(1, v.willRunCount,
            'Only one of the four actually starts work.');
        for (AJOAdminController.DueView d : v.due) {
            System.assert(String.isNotBlank(d.verdictReason),
                d.name + ' gave no reason, which is the whole point of the tab.');
        }
    }

    @IsTest
    static void nextCheckSaysNothingRunsWhilePaused() {
        insert job('CONSOLE_PAUSED', 'Paused org');
        AJOInstaller.arm();
        AJOSetting__c s = AJOInstaller.ensureSettings();
        s.AJO_KillSwitch__c = true;
        update s;
        AJOConfig.applyOverride(s);

        Test.startTest();
        AJOAdminController.NextCheckView v = AJOAdminController.getNextCheck();
        Test.stopTest();

        System.assert(v.paused);
        System.assertEquals(0, v.willRunCount);
        for (AJOAdminController.DueView d : v.due) {
            System.assertEquals('Paused', d.verdict);
        }
    }

    /**
     * CronTrigger is not isolated inside a test, so whether the scheduler reads
     * as installed depends on the org the suite happens to run in. The invariant
     * is what matters: an uninstalled scheduler must never advertise a run.
     */
    @IsTest
    static void nextCheckNeverPromisesARunItCannotMake() {
        insert job('CONSOLE_NOINSTALL', 'Install state');

        Test.startTest();
        AJOAdminController.NextCheckView v = AJOAdminController.getNextCheck();
        Test.stopTest();

        System.assertNotEquals(null, v.due);
        System.assertEquals(AJOConfig.heartbeatMinutes(), v.everyMinutes);
        if (!v.installed) {
            System.assertEquals(0, v.due.size(),
                'With nothing scheduled, nothing is due — the tab must not imply otherwise.');
            System.assertEquals(0, v.willRunCount);
        } else {
            for (AJOAdminController.DueView d : v.due) {
                System.assert(String.isNotBlank(d.verdict), 'Every row needs a verdict.');
            }
        }
    }

    /**
     * The regression behind "it showed as pending, then vanished at 14:50".
     *
     * The heartbeat that queues a deferred run also advances NextRunAt past the
     * instant it just queued, so the job stopped matching the preview window and
     * dropped off the tab for exactly the ten minutes someone was watching it.
     */
    @IsTest
    static void aQueuedRunStaysVisibleUntilItLands() {
        AJOJob__c j = job('CONSOLE_QUEUED', 'Queued for 15:00');
        // What the 14:50 heartbeat leaves behind: the instant it queued, and a
        // NextRunAt already moved on to the following occurrence.
        j.AJO_QueuedForAt__c = Datetime.now().addMinutes(9);
        j.AJO_NextRunAt__c   = Datetime.now().addMinutes(39);
        j.AJO_Status__c      = 'Queued';
        insert j;
        AJOInstaller.arm();

        Test.startTest();
        AJOAdminController.NextCheckView v = AJOAdminController.getNextCheck();
        Test.stopTest();

        AJOAdminController.DueView row;
        for (AJOAdminController.DueView d : v.due) {
            if (d.name == 'Queued for 15:00') { row = d; }
        }
        System.assertNotEquals(null, row,
            'A queued run must stay on the tab until it actually runs.');
        System.assertEquals('Queued', row.verdict);
        System.assert(row.willRun, 'It is committed work, so it counts as running.');
        System.assertEquals(j.AJO_QueuedForAt__c, row.dueAt,
            'The row must show the instant it is waiting for, not the next occurrence.');
    }

    @IsTest
    static void anAbandonedQueueMarkerIsClearedByMaintenance() {
        AJOJob__c j = job('CONSOLE_LOSTQUEUE', 'Lost queueable');
        j.AJO_QueuedForAt__c = Datetime.now().addMinutes(-45);
        j.AJO_Status__c      = 'Queued';
        insert j;

        Test.startTest();
        Integer cleared = AJOSupervisor.clearLapsedQueue();
        Test.stopTest();

        System.assertEquals(1, cleared);
        AJOJob__c after = [
            SELECT AJO_QueuedForAt__c, AJO_Status__c FROM AJOJob__c WHERE Id = :j.Id
        ];
        System.assertEquals(null, after.AJO_QueuedForAt__c,
            'A marker for a run that never came must not keep promising one.');
        System.assertEquals('Idle', after.AJO_Status__c);
    }

    // ------------------------------------------------- queued runs lock edits

    /**
     * What a heartbeat leaves when it queues a deferred run: the instant it
     * queued, and Next Run already moved past it.
     */
    private static AJOJob__c queuedJob(String key, Integer minutesAhead) {
        AJOJob__c j = job(key, 'Queued ' + key);
        j.AJO_QueuedForAt__c = Datetime.now().addMinutes(minutesAhead);
        j.AJO_NextRunAt__c   = Datetime.now().addMinutes(minutesAhead + 60);
        j.AJO_Status__c      = 'Queued';
        insert j;
        return [
            SELECT Id, AJO_QueuedForAt__c, AJO_NextRunAt__c FROM AJOJob__c WHERE Id = :j.Id
        ];
    }

    private static String editPayload(Id jobId, String key) {
        return JSON.serialize(new Map<String, Object>{
            'id'             => jobId,
            'name'           => 'Edited ' + key,
            'jobKey'         => key,
            'apexClass'      => 'AJODemoRunnable',
            'executionType'  => 'Runnable',
            'cronExpression' => '0 */15 * * * ?',
            'timeZone'       => 'Asia/Kolkata',
            'overlapPolicy'  => 'Skip',
            'enabled'        => true
        });
    }

    /**
     * The regression behind "it ran twice at 11:00". The 10:50 heartbeat queued
     * the 11:00 run; saving the job at 10:50:20 reset Next Run to 11:00, so the
     * 11:00 heartbeat started it as well as the queued run.
     */
    @IsTest
    static void aJobWithARunQueuedCannotBeEdited() {
        AJOJob__c j = queuedJob('LOCK_SAVE', 9);

        Test.startTest();
        Boolean refused = false;
        try {
            AJOAdminController.saveJob(editPayload(j.Id, 'LOCK_SAVE'));
        } catch (AuraHandledException e) {
            refused = true;
        }
        Test.stopTest();

        System.assert(refused, 'Saving while a run is queued has to be refused.');
        AJOJob__c after = [
            SELECT AJO_Status__c, AJO_QueuedForAt__c, AJO_NextRunAt__c, AJO_CronExpression__c
            FROM AJOJob__c WHERE Id = :j.Id
        ];
        System.assertEquals('Queued', after.AJO_Status__c);
        System.assertEquals(j.AJO_QueuedForAt__c, after.AJO_QueuedForAt__c);
        System.assertEquals(j.AJO_NextRunAt__c, after.AJO_NextRunAt__c,
            'Next Run must not be pulled back onto the queued instant.');
        System.assertEquals('0 0 * * * ?', after.AJO_CronExpression__c);
    }

    @IsTest
    static void aQueuedJobCanStillBePausedButNotOtherwiseChanged() {
        AJOJob__c j = queuedJob('LOCK_OTHERS', 5);

        Test.startTest();
        Integer refused = 0;
        try { AJOAdminController.setDryRun(j.Id, true); }
        catch (AuraHandledException e) { refused++; }
        try { AJOAdminController.setWindow(j.Id, Date.today(), Date.today().addDays(5)); }
        catch (AuraHandledException e) { refused++; }
        AJOAdminController.setEnabled(j.Id, false);
        try { AJOAdminController.setEnabled(j.Id, true); }
        catch (AuraHandledException e) { refused++; }
        Test.stopTest();

        System.assertEquals(3, refused,
            'Dry run, window and resume all have to wait for the queued run.');
        AJOJob__c after = [SELECT AJO_Enabled__c, AJO_DryRun__c FROM AJOJob__c WHERE Id = :j.Id];
        System.assertEquals(false, after.AJO_Enabled__c,
            'Pausing is how a queued run is stopped, so it stays open.');
        System.assertEquals(false, after.AJO_DryRun__c);
    }

    @IsTest
    static void theConsoleShowsTheLockAndItsReason() {
        AJOJob__c j = queuedJob('LOCK_VIEW', 9);

        Test.startTest();
        List<AJOAdminController.JobView> rows = AJOAdminController.getJobs();
        Test.stopTest();

        AJOAdminController.JobView row;
        for (AJOAdminController.JobView v : rows) {
            if (v.id == j.Id) { row = v; }
        }
        System.assert(row.editLocked, 'The console greys out Edit from this flag.');
        System.assert(row.editLockReason.contains('queued to start at'), row.editLockReason);
        System.assertEquals(j.AJO_QueuedForAt__c, row.queuedForAt);
    }

    @IsTest
    static void aLapsedQueueMarkerDoesNotLockTheJob() {
        AJOJob__c j = queuedJob('LOCK_LAPSED',
            -(AJOAdminController.QUEUED_LOCK_GRACE_MINUTES + 1));

        Test.startTest();
        AJOAdminController.saveJob(editPayload(j.Id, 'LOCK_LAPSED'));
        Test.stopTest();

        AJOJob__c after = [
            SELECT AJO_QueuedForAt__c, AJO_CronExpression__c FROM AJOJob__c WHERE Id = :j.Id
        ];
        System.assertEquals('0 */15 * * * ?', after.AJO_CronExpression__c,
            'A run that never came must not lock the job for good.');
        System.assertEquals(null, after.AJO_QueuedForAt__c,
            'Saving clears the lapsed marker so a late deferred run no longer owns it.');
    }

    @IsTest
    static void theQueuedRunStandsDownWhenTheHeartbeatOwnsItsInstant() {
        AJOJob__c j = queuedJob('OWN_HANDBACK', 0);
        Datetime dueAt = j.AJO_QueuedForAt__c;
        // What an edit made before the lock left behind: Next Run back on the
        // queued instant, so the heartbeat at that instant starts it itself.
        update new AJOJob__c(Id = j.Id, AJO_NextRunAt__c = dueAt, AJO_Status__c = 'Idle');

        Test.startTest();
        new AJODeferredRunner(j.Id, dueAt).execute(null);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM AJOJobRun__c WHERE AJO_Job__c = :j.Id],
            'Starting it here as well as from the heartbeat ran it twice.');
        System.assertEquals(null,
            [SELECT AJO_QueuedForAt__c FROM AJOJob__c WHERE Id = :j.Id].AJO_QueuedForAt__c);
    }

    @IsTest
    static void theQueuedRunStillStartsWhenItOwnsItsInstant() {
        AJOJob__c j = queuedJob('OWN_KEEP', 0);

        Test.startTest();
        new AJODeferredRunner(j.Id, j.AJO_QueuedForAt__c).execute(null);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM AJOJobRun__c WHERE AJO_Job__c = :j.Id]);
        System.assertEquals(null,
            [SELECT AJO_QueuedForAt__c FROM AJOJob__c WHERE Id = :j.Id].AJO_QueuedForAt__c);
    }

    /**
     * The gap behind "it never ran and it was not on the tab either".
     *
     * A job that cannot run was absent from this tab AND left nothing in the run
     * log, so there was no surface anywhere that said why. Every enabled job now
     * appears with a reason, whatever state it is in.
     */
    @IsTest
    static void everyEnabledJobIsListedWithAReason() {
        AJOJob__c pinned = job('WHY_PINNED', 'Pinned and therefore dead');
        pinned.AJO_Pinned__c = true;

        AJOJob__c noNext = job('WHY_NONEXT', 'No next run time');
        noNext.AJO_NextRunAt__c = null;

        AJOJob__c future = job('WHY_FUTURE', 'Window not open yet');
        future.AJO_StartDate__c = Date.today().addDays(3);

        AJOJob__c later = job('WHY_LATER', 'Due much later today');
        later.AJO_NextRunAt__c = Datetime.now().addHours(6);

        insert new List<AJOJob__c>{ pinned, noNext, future, later };
        AJOInstaller.arm();

        Test.startTest();
        AJOAdminController.NextCheckView v = AJOAdminController.getNextCheck();
        Test.stopTest();

        Map<String, AJOAdminController.DueView> byName =
            new Map<String, AJOAdminController.DueView>();
        for (AJOAdminController.DueView d : v.due) { byName.put(d.name, d); }

        System.assertEquals(4, byName.size(),
            'Every enabled job belongs on the tab, not only the ones about to run.');

        // Pinned is deprecated and ignored: the trap that made such jobs never run is gone.
        System.assert(!byName.get('Pinned and therefore dead').verdictReason
                        .containsIgnoreCase('exact minute'),
            'A pinned job is treated like any other now: '
            + byName.get('Pinned and therefore dead').verdictReason);

        System.assertEquals('Never runs', byName.get('No next run time').verdict);
        System.assertEquals('Never runs', byName.get('Window not open yet').verdict);
        System.assertEquals('Scheduled', byName.get('Due much later today').verdict);

        for (AJOAdminController.DueView d : v.due) {
            System.assert(String.isNotBlank(d.verdictReason),
                d.name + ' was listed with no reason, which is the whole point.');
            System.assert(!d.willRun,
                d.name + ' should not be counted as starting at the next check.');
        }
        System.assertEquals(0, v.willRunCount);
    }

    // ----------------------------------------------------------- activity

    @IsTest
    static void activityFiltersByOutcomeAndByScheduledCheck() {
        AJOJob__c j = job('CONSOLE_ACTIVITY', 'Activity');
        insert j;
        insert new List<AJOJobRun__c>{
            new AJOJobRun__c(AJO_Job__c = j.Id, AJO_Status__c = 'Success',
                AJO_StartedAt__c = Datetime.now().addMinutes(-5),
                AJO_TriggeredBy__c = 'Heartbeat', AJO_HeartbeatSlot__c = 20),
            new AJOJobRun__c(AJO_Job__c = j.Id, AJO_Status__c = 'Failed',
                AJO_StartedAt__c = Datetime.now().addMinutes(-4),
                AJO_ErrorMessage__c = 'Boom', AJO_StackTrace__c = 'Class.X.y: line 1',
                AJO_TriggeredBy__c = 'Heartbeat', AJO_HeartbeatSlot__c = 20),
            new AJOJobRun__c(AJO_Job__c = j.Id, AJO_Status__c = 'Stuck',
                AJO_StartedAt__c = Datetime.now().addMinutes(-3),
                AJO_TriggeredBy__c = 'Heartbeat', AJO_HeartbeatSlot__c = 30),
            new AJOJobRun__c(AJO_Job__c = j.Id, AJO_Status__c = 'Success',
                AJO_StartedAt__c = Datetime.now().addDays(-9),
                AJO_TriggeredBy__c = 'Manual')
        };

        Test.startTest();
        List<AJOAdminController.RunView> all      =
            AJOAdminController.getActivity(null, 'all', null, 100);
        List<AJOAdminController.RunView> failures =
            AJOAdminController.getActivity(null, 'failures', null, 100);
        List<AJOAdminController.RunView> today    =
            AJOAdminController.getActivity(null, 'today', null, 100);
        List<AJOAdminController.RunView> slot20   =
            AJOAdminController.getActivity(null, 'all', 20, 100);
        List<Integer> slots = AJOAdminController.getUsedSlots();
        Test.stopTest();

        System.assertEquals(4, all.size());
        System.assertEquals(2, failures.size(), 'Failed and Stuck are both errors.');
        System.assertEquals(3, today.size(), 'The nine-day-old run is outside 24 hours.');
        System.assertEquals(2, slot20.size(), 'Two runs came from the :20 check.');
        System.assertEquals(new List<Integer>{20, 30}, slots,
            'The picker offers only checks that actually have runs.');

        // The fields the old console captured but never showed.
        for (AJOAdminController.RunView r : failures) {
            if (r.status == 'Failed') {
                System.assertEquals('Boom', r.errorMessage);
                System.assertEquals('Class.X.y: line 1', r.stackTrace,
                    'The stack trace was recorded all along and never reached the UI.');
                System.assertEquals(20, r.heartbeatSlot);
            }
        }
    }

    @IsTest
    static void activityNarrowsToOneJob() {
        AJOJob__c a = job('CONSOLE_A', 'Job A');
        AJOJob__c b = job('CONSOLE_B', 'Job B');
        insert new List<AJOJob__c>{ a, b };
        insert new List<AJOJobRun__c>{
            new AJOJobRun__c(AJO_Job__c = a.Id, AJO_Status__c = 'Success',
                AJO_StartedAt__c = Datetime.now()),
            new AJOJobRun__c(AJO_Job__c = b.Id, AJO_Status__c = 'Success',
                AJO_StartedAt__c = Datetime.now())
        };

        Test.startTest();
        List<AJOAdminController.RunView> mine = AJOAdminController.getActivity(a.Id, 'all', null, 50);
        List<AJOAdminController.RunView> legacy = AJOAdminController.getRuns(a.Id, 50);
        Test.stopTest();

        System.assertEquals(1, mine.size());
        System.assertEquals('Job A', mine[0].jobName);
        System.assertEquals(1, legacy.size(), 'The older two-argument entry point still works.');
    }

    @IsTest
    static void retryRunStartsTheSameJobAgain() {
        AJOJob__c j = job('CONSOLE_RETRY', 'Retry me');
        insert j;
        AJOJobRun__c failed = new AJOJobRun__c(
            AJO_Job__c = j.Id, AJO_Status__c = 'Failed',
            AJO_StartedAt__c = Datetime.now(), AJO_ErrorMessage__c = 'Boom');
        insert failed;

        Test.startTest();
        String status = AJOAdminController.retryRun(failed.Id);
        Test.stopTest();

        System.assertEquals('Queued', status, 'Running again hands the job to its own transaction.');
        System.assertEquals(1, [SELECT COUNT() FROM AJOJobRun__c
                                WHERE AJO_Job__c = :j.Id AND AJO_Status__c = 'Success'],
            'The demo Runnable succeeds when run again.');
        System.assert([SELECT COUNT() FROM AJOJobRun__c WHERE AJO_Job__c = :j.Id] > 1,
            'Running again must leave its own run record behind.');
    }

    @IsTest
    static void retryRunRejectsAnUnknownRun() {
        Boolean threw = false;
        Test.startTest();
        try {
            AJOAdminController.retryRun(
                Id.valueOf(AJOJobRun__c.SObjectType.getDescribe().getKeyPrefix()
                           + '000000000000AAA'));
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'A missing run must be reported, not silently ignored.');
    }

    // -------------------------------------------------------- the gate

    @IsTest
    static void anAdministratorMayOperateTheFramework() {
        Test.startTest();
        System.assert(AJOAdminController.canAdminister(),
            'A user with Modify All Data is never locked out of their own org.');
        Test.stopTest();
    }

    /**
     * The point of the gate. The Viewer permission set grants access to
     * AJOAdminController, so before this check a read-only user could call
     * disarmFramework() straight from the browser console and stop every
     * scheduled job in the org. Hiding the buttons was never the control.
     */
    @IsTest
    static void aReadOnlyUserCannotTouchTheFramework() {
        User viewer = readOnlyUser();
        if (viewer == null) { return; }

        System.runAs(viewer) {
            System.assert(!AJOAdminController.canAdminister(),
                'A Viewer must not be able to administer the framework.');

            assertBlocked('uninstall');
            assertBlocked('install');
            assertBlocked('pause');
            assertBlocked('maintenance');
            assertBlocked('seed');
        }
    }

    private static void assertBlocked(String which) {
        try {
            if (which == 'uninstall')        { AJOAdminController.disarmFramework(); }
            else if (which == 'install')     { AJOAdminController.armFramework(); }
            else if (which == 'pause')       { AJOAdminController.setKillSwitch(true); }
            else if (which == 'maintenance') { AJOAdminController.runSupervisor(); }
            else                             { AJOAdminController.seedDemoJobs(); }
            System.assert(false, which + ' was allowed for a read-only user.');
        } catch (AuraHandledException e) {
            // Expected.
        }
    }

    /** Null when the org has no spare licence, so the suite stays green anywhere. */
    private static User readOnlyUser() {
        List<Profile> p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        if (p.isEmpty()) { return null; }
        List<PermissionSet> ps = [
            SELECT Id FROM PermissionSet WHERE Name = 'AJOJobOrchestrationViewer' LIMIT 1
        ];
        User u = new User(
            ProfileId = p[0].Id,
            LastName = 'AjoViewer',
            Email = 'ajo.viewer@example.invalid',
            Username = 'ajo.viewer.' + DateTime.now().getTime() + '@example.invalid',
            Alias = 'ajovw',
            TimeZoneSidKey = 'Asia/Kolkata',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        try {
            insert u;
            if (!ps.isEmpty()) {
                insert new PermissionSetAssignment(
                    AssigneeId = u.Id, PermissionSetId = ps[0].Id);
            }
        } catch (Exception e) {
            return null;
        }
        return u;
    }
}