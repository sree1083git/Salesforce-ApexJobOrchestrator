/**
 * Covers taking over a Setup schedule.
 *
 * CronTrigger is not isolated inside a test — the org's own scheduled jobs are
 * visible — so nothing here asserts on counts. Every assertion is about the
 * specific schedule the test created.
 */
@IsTest
private class AJOConvertTest {

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


    private static final String LIVE    = 'ZZ Test Convertible';
    private static final String BLOCKED = 'ZZ Test Unreadable Cron';

    private static AJOAdminController.ConvertibleView find(String name) {
        for (AJOAdminController.ConvertibleView v : AJOAdminController.listConvertible()) {
            if (v.name == name) { return v; }
        }
        return null;
    }

    @IsTest
    static void aScheduleIsListedWithEverythingNeededToJudgeIt() {
        System.schedule(LIVE, '0 30 3 * * ?', new AJODemoLegacyScheduler());

        Test.startTest();
        AJOAdminController.ConvertibleView v = find(LIVE);
        Test.stopTest();

        System.assertNotEquals(null, v, 'The schedule should be offered for conversion.');
        System.assert(v.convertible, 'A plain daily Schedulable is convertible.');
        System.assertEquals('AJODemoLegacyScheduler', v.className,
            'The class must be recovered from AsyncApexJob; CronTrigger does not carry it.');
        System.assertEquals('Legacy Schedulable', v.executionType);
        System.assertEquals('Daily at 03:30', v.schedule);
        System.assertNotEquals(null, v.timeZone, 'The zone decides when it fires.');
        System.assertEquals('ZZ_TEST_CONVERTIBLE', v.suggestedKey);
        System.assert(v.blockers.isEmpty());
        System.assert(!v.warnings.isEmpty(),
            'The constructor-arguments caveat applies to every conversion.');
    }

    /**
     * L, W and # are legal for the platform's scheduler and unreadable to this
     * evaluator. Converting one would delete a working schedule and leave a job
     * that could never run, so it has to be refused before anything is touched.
     */
    @IsTest
    static void aCronThisFrameworkCannotReadIsRefusedWithItsReason() {
        System.schedule(BLOCKED, '0 0 2 L * ?', new AJODemoLegacyScheduler());

        Test.startTest();
        AJOAdminController.ConvertibleView v = find(BLOCKED);
        Test.stopTest();

        System.assertNotEquals(null, v, 'It is still listed — refused, not hidden.');
        System.assert(!v.convertible);
        System.assertEquals(1, v.blockers.size());
        System.assert(v.blockers[0].contains('L'),
            'The reason must name the character: ' + v.blockers[0]);
    }

    @IsTest
    static void theFrameworkNeverOffersItsOwnJobs() {
        AJOInstaller.arm();

        Test.startTest();
        List<AJOAdminController.ConvertibleView> all = AJOAdminController.listConvertible();
        Test.stopTest();

        for (AJOAdminController.ConvertibleView v : all) {
            System.assert(!v.name.startsWith(AJOInstaller.HEARTBEAT_PREFIX),
                'Converting a heartbeat would stop the whole framework: ' + v.name);
            System.assertNotEquals(AJOInstaller.SUPERVISOR_NAME, v.name);
        }
    }

    @IsTest
    static void convertingMovesTheScheduleAndLandsInTestMode() {
        Id cronId = System.schedule(LIVE, '0 30 3 * * ?', new AJODemoLegacyScheduler());

        Test.startTest();
        AJOAdminController.ConversionResult r = AJOAdminController.convert(
            JSON.serialize(new Map<String, Object>{
                'cronTriggerId' => cronId, 'testMode' => true }));
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM CronTrigger WHERE Id = :cronId],
            'The Setup schedule must be gone, which is what frees the slot.');

        AJOJob__c j = [
            SELECT Name, AJO_ApexClassName__c, AJO_ExecutionType__c, AJO_CronExpression__c,
                   AJO_TimeZoneSidKey__c, AJO_Enabled__c, AJO_DryRun__c, AJO_NextRunAt__c,
                   AJO_LegacyCronJobName__c, AJO_LegacyCronExpression__c,
                   AJO_LegacyCronTriggerId__c
            FROM   AJOJob__c WHERE Id = :r.jobId
        ];
        System.assertEquals('AJODemoLegacyScheduler', j.AJO_ApexClassName__c);
        System.assertEquals('0 30 3 * * ?', j.AJO_CronExpression__c);
        System.assert(j.AJO_Enabled__c, 'It takes over immediately.');
        System.assert(j.AJO_DryRun__c,
            'Test mode is the whole mitigation for constructor state that cannot be recovered.');
        System.assertNotEquals(null, j.AJO_NextRunAt__c,
            'A converted job with no next run time would be a silent dead end.');
        System.assertEquals(LIVE, j.AJO_LegacyCronJobName__c,
            'What it came from survives the CronTrigger being destroyed.');
        System.assertEquals(String.valueOf(cronId), j.AJO_LegacyCronTriggerId__c);
    }

    @IsTest
    static void aConvertedScheduleIsNeverOfferedTwice() {
        Id cronId = System.schedule(LIVE, '0 30 3 * * ?', new AJODemoLegacyScheduler());
        AJOAdminController.convert(JSON.serialize(
            new Map<String, Object>{ 'cronTriggerId' => cronId, 'testMode' => true }));

        Test.startTest();
        Boolean threw = false;
        try {
            AJOAdminController.convert(JSON.serialize(
                new Map<String, Object>{ 'cronTriggerId' => cronId, 'testMode' => true }));
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'The schedule is gone; converting it again must be refused.');
    }

    @IsTest
    static void convertingABlockedScheduleLeavesSetupUntouched() {
        Id cronId = System.schedule(BLOCKED, '0 0 2 L * ?', new AJODemoLegacyScheduler());

        Test.startTest();
        Boolean threw = false;
        try {
            AJOAdminController.convert(JSON.serialize(
                new Map<String, Object>{ 'cronTriggerId' => cronId, 'testMode' => true }));
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A blocked schedule must be refused.');
        System.assertEquals(1, [SELECT COUNT() FROM CronTrigger WHERE Id = :cronId],
            'Refusing must not delete anything — that is the point of checking first.');
        System.assertEquals(0, [SELECT COUNT() FROM AJOJob__c
                                WHERE AJO_LegacyCronTriggerId__c = :String.valueOf(cronId)],
            'And no half-made job should be left behind.');
    }

    // ------------------------------------------------------------ bulk

    @IsTest
    static void bulkConvertsWhatItCanAndSaysWhyForTheRest() {
        Id good    = System.schedule('ZZ Bulk A', '0 30 3 * * ?', new AJODemoLegacyScheduler());
        Id blocked = System.schedule('ZZ Bulk B', '0 0 2 L * ?',  new AJODemoLegacyScheduler());

        Test.startTest();
        List<AJOAdminController.ConversionRow> rows = AJOAdminController.convertMany(
            new List<Id>{ good, blocked }, true);
        Test.stopTest();

        System.assertEquals(2, rows.size(), 'Every requested row is accounted for.');
        Map<String, AJOAdminController.ConversionRow> byName =
            new Map<String, AJOAdminController.ConversionRow>();
        for (AJOAdminController.ConversionRow r : rows) { byName.put(r.name, r); }

        System.assert(byName.get('ZZ Bulk A').converted);
        System.assertEquals(0, [SELECT COUNT() FROM CronTrigger WHERE Id = :good]);

        System.assert(!byName.get('ZZ Bulk B').converted,
            'The unreadable cron must not be converted just because it was in a batch.');
        System.assert(byName.get('ZZ Bulk B').detail.contains('L'),
            'The reason travels with the row: ' + byName.get('ZZ Bulk B').detail);
        System.assertEquals(1, [SELECT COUNT() FROM CronTrigger WHERE Id = :blocked],
            'One failure in a bulk run must not delete the schedule it refused.');
    }

    @IsTest
    static void bulkRefusesAnUnreasonablyLargeBatch() {
        List<Id> tooMany = new List<Id>();
        for (Integer i = 0; i < 26; i++) { tooMany.add(UserInfo.getUserId()); }

        Test.startTest();
        Boolean threw = false;
        try { AJOAdminController.convertMany(tooMany, true); }
        catch (Exception e) { threw = true; }
        Test.stopTest();
        System.assert(threw, 'A partial failure has to stay small enough to see.');
    }

    // --------------------------------------------------------- restore

    @IsTest
    static void restorePutsTheScheduleBackAndSwitchesTheJobOff() {
        Id cronId = System.schedule(LIVE, '0 30 3 * * ?', new AJODemoLegacyScheduler());
        AJOAdminController.ConversionResult c = AJOAdminController.convert(JSON.serialize(
            new Map<String, Object>{ 'cronTriggerId' => cronId, 'testMode' => true }));

        Test.startTest();
        String msg = AJOAdminController.restore(c.jobId, false);
        Test.stopTest();

        System.assert(msg.contains('Restored'), msg);
        System.assertEquals(1, [SELECT COUNT() FROM CronTrigger
                                WHERE CronJobDetail.Name = :LIVE],
            'The Setup schedule must exist again.');
        System.assert(![SELECT AJO_Enabled__c FROM AJOJob__c WHERE Id = :c.jobId]
                        .AJO_Enabled__c,
            'Leaving it enabled here would have it running in both places at once.');
    }

    @IsTest
    static void restoreIsRefusedForAJobThatNeverCameFromSetup() {
        AJOJob__c home = new AJOJob__c(
            Name = 'ZZ Home Grown', AJO_JobKey__c = 'ZZ_HOME_GROWN',
            AJO_ApexClassName__c = 'AJODemoLegacyScheduler',
            AJO_ExecutionType__c = 'Legacy Schedulable',
            AJO_CronExpression__c = '0 0 4 * * ?', AJO_TimeZoneSidKey__c = 'Asia/Kolkata',
            AJO_Enabled__c = true, AJO_StartDate__c = Date.today(), AJO_Status__c = 'Idle');
        insert home;

        Test.startTest();
        AJOAdminController.RestorePlan p = AJOAdminController.planRestore(home.Id);
        Boolean threw = false;
        try { AJOAdminController.restore(home.Id, true); }
        catch (Exception e) { threw = true; }
        Test.stopTest();

        System.assertEquals(1, p.blockers.size());
        System.assert(p.blockers[0].contains('created here'), p.blockers[0]);
        System.assert(threw, 'There is nowhere to put it back to.');
    }

    /**
     * System.schedule offers no way to set the time zone — it always uses the
     * running user's. Restoring a job captured in another zone therefore moves
     * when it runs, so the plan has to surface both sets of fire times rather
     * than let it happen quietly.
     */
    @IsTest
    static void restorePlanComparesTheTwoTimeZones() {
        Id cronId = System.schedule(LIVE, '0 30 3 * * ?', new AJODemoLegacyScheduler());
        AJOAdminController.ConversionResult c = AJOAdminController.convert(JSON.serialize(
            new Map<String, Object>{ 'cronTriggerId' => cronId, 'testMode' => true }));
        // Pretend it was captured somewhere other than this user's zone.
        update new AJOJob__c(Id = c.jobId, AJO_TimeZoneSidKey__c = 'America/Chicago');

        Test.startTest();
        AJOAdminController.RestorePlan p = AJOAdminController.planRestore(c.jobId);
        Boolean threwWithoutConsent = false;
        try { AJOAdminController.restore(c.jobId, false); }
        catch (Exception e) { threwWithoutConsent = true; }
        Test.stopTest();

        System.assertEquals('America/Chicago', p.originalTimeZone);
        System.assert(!p.timeZoneMatches);
        System.assertEquals(5, p.originalFireTimes.size());
        System.assertEquals(5, p.restoredFireTimes.size());
        System.assertNotEquals(p.originalFireTimes[0], p.restoredFireTimes[0],
            'Different zones must produce visibly different times, or the warning is empty.');
        System.assert(threwWithoutConsent,
            'A silent shift of a production schedule is exactly what must not happen.');
    }
}
