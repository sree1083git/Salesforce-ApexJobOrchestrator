/**
 * Covers the activation window: the Start Date / End Date pair that lets a
 * bounded piece of data processing be scheduled for a fixed number of days and
 * retire itself afterwards.
 *
 * The test that matters most is formulaFieldAgreesWithApex. The rule lives in
 * three places — the AJO_IsActive__c formula, AJOWindow.SOQL_FILTER and
 * AJOWindow.isActive — and the only thing keeping them honest is a test that
 * compares all three against the same records.
 */
@IsTest
private class AJOWindowTest {

    private static final String TZ = 'Asia/Kolkata';

    private static AJOJob__c makeJob(String key, Date startDate, Date endDate,
                                     Boolean enabled) {
        AJOJob__c j = new AJOJob__c(
            Name                     = 'Window ' + key,
            AJO_JobKey__c            = key,
            AJO_ExecutionType__c     = 'Legacy Schedulable',
            AJO_ApexClassName__c     = 'AJODemoLegacyScheduler',
            AJO_CronExpression__c    = '0 0 * * * ?',
            AJO_TimeZoneSidKey__c    = TZ,
            AJO_Enabled__c           = enabled,
            AJO_StartDate__c         = startDate,
            AJO_EndDate__c           = endDate,
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
            AJO_DefaultTimeZone__c      = TZ,
            AJO_EnableDeferral__c       = false,
            SetupOwnerId                = UserInfo.getOrganizationId()
        );
    }

    // ------------------------------------------------------- the rule itself

    /**
     * The whole point of the design: whatever combination of dates a user picks,
     * the formula field, the SOQL filter and the Apex predicate must agree. If
     * this ever fails, a list view and the dispatcher are telling different
     * stories about the same job and neither can be trusted.
     */
    @IsTest
    static void formulaFieldAgreesWithApex() {
        Date today = Date.today();
        Map<String, AJOJob__c> made = new Map<String, AJOJob__c>();
        made.put('open_ended',   makeJob('W_OPEN',    today.addDays(-5), null,               true));
        made.put('inside',       makeJob('W_INSIDE',  today.addDays(-1), today.addDays(8),   true));
        made.put('ends_today',   makeJob('W_TODAY',   today.addDays(-9), today,              true));
        made.put('starts_today', makeJob('W_START',   today,             today.addDays(9),   true));
        made.put('not_started',  makeJob('W_FUTURE',  today.addDays(3),  today.addDays(13),  true));
        made.put('expired',      makeJob('W_PAST',    today.addDays(-20), today.addDays(-1), true));
        made.put('no_dates',     makeJob('W_NONE',    null,              null,               true));
        made.put('paused',       makeJob('W_PAUSED',  today.addDays(-1), today.addDays(8),   false));

        Map<String, Boolean> expected = new Map<String, Boolean>{
            'open_ended'   => true,
            'inside'       => true,
            'ends_today'   => true,   // End Date is inclusive
            'starts_today' => true,
            'not_started'  => false,
            'expired'      => false,
            'no_dates'     => true,
            'paused'       => false
        };

        // 1. the formula field
        Map<Id, AJOJob__c> reread = new Map<Id, AJOJob__c>([
            SELECT Id, AJO_JobKey__c, AJO_IsActive__c, AJO_WindowStatus__c,
                   AJO_Enabled__c, AJO_StartDate__c, AJO_EndDate__c
            FROM   AJOJob__c
        ]);

        // 2. the SOQL filter
        Set<Id> filterSaysActive = new Set<Id>();
        for (AJOJob__c j : Database.query(
                'SELECT Id FROM AJOJob__c WHERE ' + AJOWindow.SOQL_FILTER)) {
            filterSaysActive.add(j.Id);
        }

        for (String label : expected.keySet()) {
            AJOJob__c j = reread.get(made.get(label).Id);
            Boolean want = expected.get(label);

            System.assertEquals(want, j.AJO_IsActive__c,
                'AJO_IsActive__c formula disagrees for the "' + label + '" case.');
            // 3. the Apex predicate
            System.assertEquals(want, AJOWindow.isActive(j),
                'AJOWindow.isActive disagrees for the "' + label + '" case.');
            System.assertEquals(want, filterSaysActive.contains(j.Id),
                'AJOWindow.SOQL_FILTER disagrees for the "' + label + '" case.');
            System.assertNotEquals(null, j.AJO_WindowStatus__c,
                'Every job should be able to explain its own window.');
        }
    }

    @IsTest
    static void endDateIsInclusiveAndDaysRemainingCountsToday() {
        Date today = Date.today();
        AJOJob__c endsToday = makeJob('W_D0', today.addDays(-3), today, true);
        AJOJob__c tenDays   = makeJob('W_D10', today, today.addDays(9), true);

        System.assertEquals(1, AJOWindow.daysRemaining(endsToday),
            'A window ending today still has today left in it.');
        System.assertEquals(10, AJOWindow.daysRemaining(tenDays),
            'Today plus nine more days is a ten-day window.');
        System.assertEquals(null, AJOWindow.daysRemaining(
            new AJOJob__c(AJO_Enabled__c = true)),
            'No end date means no countdown.');
        System.assert(AJOWindow.describe(tenDays).contains('10 day'),
            'The description should say how long is left: ' + AJOWindow.describe(tenDays));
    }

    // ----------------------------------------------------------- dispatching

    @IsTest
    static void heartbeatSkipsJobsOutsideTheirWindow() {
        Date today = Date.today();
        AJOJob__c due     = makeJob('W_DUE',    today.addDays(-1), today.addDays(5),  true);
        AJOJob__c future   = makeJob('W_LATER',  today.addDays(4),  today.addDays(14), true);
        AJOJob__c finished = makeJob('W_DONE',   today.addDays(-9), today.addDays(-1), true);

        Test.startTest();
        Integer picked = AJODispatcher.run(0);
        Test.stopTest();

        System.assertEquals(1, picked,
            'Only the job inside its window is due; the other two are invisible '
            + 'to the heartbeat query.');
        System.assertEquals('Success',
            [SELECT AJO_LastRunStatus__c FROM AJOJob__c WHERE Id = :due.Id].AJO_LastRunStatus__c);
        System.assertEquals(null,
            [SELECT AJO_LastRunAt__c FROM AJOJob__c WHERE Id = :future.Id].AJO_LastRunAt__c,
            'A job whose window has not opened must not have run.');
        System.assertEquals(null,
            [SELECT AJO_LastRunAt__c FROM AJOJob__c WHERE Id = :finished.Id].AJO_LastRunAt__c,
            'A job whose window has closed must not have run.');
        System.assertEquals(0, [SELECT COUNT() FROM AJOJobRun__c WHERE AJO_Job__c = :future.Id]);
    }

    /**
     * The last day of the window is a normal working day: an hourly job keeps
     * whatever occurrences it has left, and stays Idle rather than retiring early.
     */
    @IsTest
    static void theLastDayOfTheWindowStillRuns() {
        Date today = Date.today();
        AJOJob__c job = makeJob('W_LAST', today.addDays(-9), today, true);

        Test.startTest();
        Integer picked = AJODispatcher.run(0);
        Test.stopTest();

        System.assertEquals(1, picked, 'A job ending today is still due today.');
        AJOJob__c after = [
            SELECT AJO_Status__c, AJO_LastRunStatus__c, AJO_NextRunAt__c, AJO_EndDate__c
            FROM AJOJob__c WHERE Id = :job.Id
        ];
        System.assertEquals('Success', after.AJO_LastRunStatus__c,
            'The last day of the window still runs.');
        System.assertNotEquals('Expired', after.AJO_Status__c,
            'An hourly job on its last day has occurrences left; it must not '
            + 'retire until one of them would fall past the End Date.');
    }

    /**
     * The other half: once the next occurrence would fall past the End Date the
     * job clears its own NextRunAt and reports Expired, rather than being
     * re-examined and re-rejected by every heartbeat from now on.
     *
     * Advancing from one minute before midnight on the End Date is what makes
     * this deterministic — a daily schedule can then only fire on a later day,
     * whatever time of day the test itself happens to run.
     */
    @IsTest
    static void aJobRetiresOnceItsNextRunWouldFallPastTheEndDate() {
        Date today = Date.today();
        AJOJob__c job = makeJob('W_RETIRE', today.addDays(-9), today, true);
        job.AJO_CronExpression__c = '0 0 3 * * ?';   // once a day, at 03:00

        Datetime lastMinuteOfTheWindow =
            Datetime.newInstance(job.AJO_EndDate__c, Time.newInstance(23, 59, 0, 0));

        Test.startTest();
        AJOLauncher.advance(job, lastMinuteOfTheWindow);
        Test.stopTest();

        System.assertEquals('Expired', job.AJO_Status__c,
            'The next 03:00 falls after the End Date, so the job is finished.');
        System.assertEquals(null, job.AJO_NextRunAt__c,
            'A retired job must not keep a NextRunAt the heartbeat has to re-read.');
    }

    @IsTest
    static void advanceKeepsSchedulingWhileTheWindowIsOpen() {
        Date today = Date.today();
        AJOJob__c job = makeJob('W_MID', today, today.addDays(9), true);

        Test.startTest();
        AJOLauncher.advance(job, Datetime.now());
        Test.stopTest();

        System.assertNotEquals(null, job.AJO_NextRunAt__c,
            'Mid-window there is always a next occurrence.');
        System.assertEquals('Idle', job.AJO_Status__c);
        System.assert(job.AJO_NextRunAt__c.date() <= job.AJO_EndDate__c,
            'A scheduled occurrence must never fall past the End Date.');
    }

    /**
     * A job whose window opens next week must not advertise a run this week.
     * Advancing from now would put the first occurrence inside a period the
     * dispatcher will refuse, and the console's Next Run column would be a lie.
     */
    @IsTest
    static void notYetStartedJobsScheduleFromTheirStartDate() {
        Date today = Date.today();
        AJOJob__c job = makeJob('W_AHEAD', today.addDays(7), today.addDays(21), true);

        Test.startTest();
        AJOLauncher.advance(job, Datetime.now());
        Test.stopTest();

        System.assertNotEquals(null, job.AJO_NextRunAt__c);
        System.assert(job.AJO_NextRunAt__c.date() >= job.AJO_StartDate__c,
            'Next run ' + job.AJO_NextRunAt__c + ' falls before the Start Date '
            + job.AJO_StartDate__c + ', which the dispatcher would refuse.');
        System.assert(job.AJO_NextRunAt__c.date() <= job.AJO_EndDate__c,
            'The first permitted occurrence must still be inside the window.');
        System.assertEquals(false, AJOWindow.isActive(job),
            'Scheduled is not the same as active.');
    }

    @IsTest
    static void extendingTheWindowReschedulesAnExpiredJob() {
        Date today = Date.today();
        AJOJob__c job = makeJob('W_REOPEN', today.addDays(-20), today.addDays(-1), true);
        update new AJOJob__c(Id = job.Id, AJO_Status__c = 'Expired', AJO_NextRunAt__c = null);

        Test.startTest();
        String summary = AJOAdminController.setWindow(job.Id, today.addDays(-20), today.addDays(6));
        Test.stopTest();

        AJOJob__c after = [
            SELECT AJO_Status__c, AJO_NextRunAt__c, AJO_IsActive__c, AJO_EndDate__c
            FROM AJOJob__c WHERE Id = :job.Id
        ];
        System.assertEquals('Idle', after.AJO_Status__c,
            'Extending the window puts the job back in service.');
        System.assertNotEquals(null, after.AJO_NextRunAt__c);
        System.assertEquals(true, after.AJO_IsActive__c);
        System.assert(summary.startsWith('Active'), 'Unexpected summary: ' + summary);
    }

    @IsTest
    static void setWindowRejectsAnEndBeforeItsStart() {
        AJOJob__c job = makeJob('W_BAD', Date.today(), Date.today().addDays(5), true);
        try {
            AJOAdminController.setWindow(job.Id, Date.today(), Date.today().addDays(-1));
            System.assert(false, 'A backwards window should not be accepted.');
        } catch (AJOWindow.WindowException e) {
            System.assert(e.getMessage().contains('End Date'), e.getMessage());
        }
    }

    // ------------------------------------------------------------ the console

    @IsTest
    static void runNowRefusesAJobOutsideItsWindow() {
        Date today = Date.today();
        AJOJob__c job = makeJob('W_MANUAL', today.addDays(-9), today.addDays(-1), true);

        Test.startTest();
        try {
            AJOAdminController.runNowById(job.Id);
            System.assert(false,
                'Run now must respect the window; these jobs process a bounded '
                + 'slice of data and the dates are the guarantee.');
        } catch (Exception e) { /* expected */ }
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM AJOJobRun__c WHERE AJO_Job__c = :job.Id]);
    }

    @IsTest
    static void consoleReportsTheWindowOnEveryJob() {
        Date today = Date.today();
        makeJob('W_V1', today.addDays(-1), today.addDays(3),  true);   // closing soon
        makeJob('W_V2', today.addDays(-1), null,              true);   // forever
        makeJob('W_V3', today.addDays(5),  today.addDays(15), true);   // not started
        makeJob('W_V4', today.addDays(-9), today.addDays(-2), true);   // expired

        Test.startTest();
        List<AJOAdminController.JobView> views = AJOAdminController.getJobs();
        AJOAdminController.HealthView health = AJOAdminController.getHealth();
        Test.stopTest();

        Map<String, AJOAdminController.JobView> byKey =
            new Map<String, AJOAdminController.JobView>();
        for (AJOAdminController.JobView v : views) { byKey.put(v.jobKey, v); }

        System.assertEquals(4, views.size());
        System.assertEquals(4, byKey.get('W_V1').daysRemaining,
            'Today plus three more days.');
        System.assertEquals(null, byKey.get('W_V2').daysRemaining,
            'No end date means no countdown.');
        System.assertEquals(true,  byKey.get('W_V1').isActive);
        System.assertEquals(false, byKey.get('W_V3').isActive);
        System.assertEquals(false, byKey.get('W_V4').isActive);
        System.assertNotEquals(null, byKey.get('W_V4').windowStatus);

        System.assertEquals(2, health.jobsActive,
            'W_V1 and W_V2 are inside their windows.');
        System.assertEquals(1, health.jobsExpired);
        System.assertEquals(1, health.jobsNotStarted);
        System.assertEquals(1, health.jobsEndingWithin7Days);
    }

    // --------------------------------------------------------- the supervisor

    @IsTest
    static void supervisorRetiresLapsedJobs() {
        Date today = Date.today();
        AJOJob__c lapsed = makeJob('W_LAPSED', today.addDays(-30), today.addDays(-2), true);
        AJOJob__c live   = makeJob('W_LIVE',   today.addDays(-1),  today.addDays(5),  true);

        Test.startTest();
        Map<String, Object> summary = AJOSupervisor.sweep();
        Test.stopTest();

        System.assertEquals(1, (Integer) summary.get('expired'),
            'Only the lapsed job should be retired.');
        System.assertEquals('Expired',
            [SELECT AJO_Status__c FROM AJOJob__c WHERE Id = :lapsed.Id].AJO_Status__c);
        System.assertEquals(null,
            [SELECT AJO_NextRunAt__c FROM AJOJob__c WHERE Id = :lapsed.Id].AJO_NextRunAt__c);
        System.assertEquals('Idle',
            [SELECT AJO_Status__c FROM AJOJob__c WHERE Id = :live.Id].AJO_Status__c);

        // Idempotent: a second sweep finds nothing new to do.
        System.assertEquals(0, AJOSupervisor.expireLapsed());
    }

    @IsTest
    static void deferredRunnerRechecksTheWindowBeforeStarting() {
        Date today = Date.today();
        AJOJob__c job = makeJob('W_DEFER', today.addDays(-9), today.addDays(-1), true);

        Test.startTest();
        new AJODeferredRunner(job.Id, Datetime.now()).execute(null);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM AJOJobRun__c WHERE AJO_Job__c = :job.Id],
            'Up to ten minutes pass between queueing and running; the window has '
            + 'to be re-checked rather than assumed.');
    }

    @IsTest
    static void launcherLogsAJobItRefusesToRun() {
        Date today = Date.today();
        // Reaches the launcher directly, as the deferred and manual paths can.
        AJOJob__c job = makeJob('W_GUARD', today.addDays(4), today.addDays(14), true);

        Test.startTest();
        AJOLauncher.launch(new List<AJOJob__c>{ job }, 0);
        Test.stopTest();

        AJOJobRun__c note = [
            SELECT AJO_Status__c, AJO_Message__c
            FROM   AJOJobRun__c WHERE AJO_Job__c = :job.Id LIMIT 1
        ];
        System.assertEquals('Skipped', note.AJO_Status__c);
        System.assert(note.AJO_Message__c.contains('activation window'),
            'A job that did not run must say why: ' + note.AJO_Message__c);
    }

    @IsTest
    static void describeCoversEveryWindowState() {
        Date today = Date.today();
        System.assertEquals('Paused', AJOWindow.describe(
            new AJOJob__c(AJO_Enabled__c = false)));
        System.assert(AJOWindow.describe(new AJOJob__c(
            AJO_Enabled__c = true, AJO_StartDate__c = today.addDays(3))).startsWith('Starts'));
        System.assert(AJOWindow.describe(new AJOJob__c(
            AJO_Enabled__c = true, AJO_EndDate__c = today.addDays(-3))).startsWith('Expired'));
        System.assertEquals('Active, no end date', AJOWindow.describe(
            new AJOJob__c(AJO_Enabled__c = true)));
        System.assertEquals(true, AJOWindow.hasNotStarted(
            new AJOJob__c(AJO_Enabled__c = true, AJO_StartDate__c = today.addDays(1))));
        System.assertEquals(false, AJOWindow.isBeyondWindow(
            new AJOJob__c(AJO_EndDate__c = null), Datetime.now().addYears(5)));
        System.assertEquals(true, AJOWindow.isBeyondWindow(
            new AJOJob__c(AJO_EndDate__c = today), Datetime.now().addDays(2)));
    }
}
