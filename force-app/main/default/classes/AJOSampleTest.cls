/**
 * Covers the two things the run record used to lose: the id of async work a job
 * started for itself, and the scope that work actually ran at.
 */
@IsTest
private class AJOSampleTest {

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


    private static AJOJob__c makeJob(String key, String cls, String type, Integer scope) {
        AJOJob__c j = new AJOJob__c(
            Name                  = key,
            AJO_JobKey__c         = key,
            AJO_ApexClassName__c  = cls,
            AJO_ExecutionType__c  = type,
            AJO_CronExpression__c = '0 0 * * * ?',
            AJO_TimeZoneSidKey__c = 'Asia/Kolkata',
            AJO_Enabled__c        = true,
            AJO_StartDate__c      = Date.today(),
            AJO_Status__c         = 'Idle',
            AJO_OverlapPolicy__c  = 'Skip',
            AJO_BatchSize__c      = scope,
            AJO_Parameters__c     = '{"object":"User","days":3650,"limit":50}',
            AJO_NextRunAt__c      = Datetime.now()
        );
        insert j;
        return j;
    }

    private static AJOJobRun__c runFor(Id jobId) {
        return [
            SELECT AJO_Status__c, AJO_AsyncApexJobId__c, AJO_BatchSize__c,
                   AJO_ItemsProcessed__c, AJO_ItemsFailed__c, AJO_Message__c
            FROM   AJOJobRun__c WHERE AJO_Job__c = :jobId
            ORDER BY AJO_StartedAt__c DESC LIMIT 1
        ];
    }

    /**
     * A directly registered batch: the framework runs executeBatch itself, so it
     * owns the id and the scope from the first instant.
     */
    @IsTest
    static void aRegisteredBatchRecordsItsIdAndItsScope() {
        AJOJob__c j = makeJob('SAMPLE_BATCH', 'AJOSampleBatch', 'Batch', 50);

        Test.startTest();
        AJOLauncher.runNow(j, Datetime.now(), 'Manual', 0);
        update j;
        Test.stopTest();

        AJOJobRun__c run = runFor(j.Id);
        System.assertNotEquals(null, run.AJO_AsyncApexJobId__c,
            'A batch launch must record the Apex Job Id.');
        System.assertEquals(50, run.AJO_BatchSize__c,
            'Records Per Batch must be the scope actually used, not blank.');
    }

    /** A blank Records Per Batch still records the 200 the platform really used. */
    @IsTest
    static void anUnsetScopeRecordsThePlatformDefault() {
        AJOJob__c j = makeJob('SAMPLE_DEFAULT', 'AJOSampleBatch', 'Batch', null);

        Test.startTest();
        AJOLauncher.runNow(j, Datetime.now(), 'Manual', 0);
        update j;
        Test.stopTest();

        System.assertEquals(200, runFor(j.Id).AJO_BatchSize__c,
            'Blank on the job means 200 in practice, and the run should say 200.');
    }

    /**
     * The case that used to lose everything. A job that starts a batch for
     * itself now hands the id back, so the run stays open instead of claiming
     * Success a tenth of a second after launch.
     */
    @IsTest
    static void aRunnableThatStartsABatchKeepsItsRunOpen() {
        AJOJob__c j = makeJob('SAMPLE_SCHED', 'AJOSampleScheduler', 'Runnable', 75);

        Test.startTest();
        AJOLauncher.runNow(j, Datetime.now(), 'Manual', 0);
        update j;

        // Read before stopTest() forces the batch to run. This instant is where
        // the old behaviour wrote Success with a blank Apex Job Id.
        AJOJobRun__c open = runFor(j.Id);
        System.assertNotEquals(null, open.AJO_AsyncApexJobId__c,
            'The batch the job started for itself must appear on the run.');
        System.assertEquals(75, open.AJO_BatchSize__c,
            'The Runnable must honour the job\'s configured Records Per Batch.');
        System.assertEquals('Running', open.AJO_Status__c,
            'The run stays open until the batch finishes; Success at launch was the bug.');

        Test.stopTest();   // the batch runs here, and its finish() closes the run

        AJOJobRun__c done = runFor(j.Id);
        System.assertEquals('Success', done.AJO_Status__c,
            'Once the batch finishes, the run settles on the real outcome.');
        System.assertNotEquals(null, done.AJO_ItemsProcessed__c,
            'finish() reports the true record count back onto the run.');
        System.assertEquals(75, done.AJO_BatchSize__c,
            'Records Per Batch must survive the close.');
    }

    /**
     * Nothing to do means no batch, no id, and a run that says why. Account is
     * empty inside a test, which is exactly the "nothing waiting" case.
     */
    @IsTest
    static void aRunnableWithNothingToDoSaysSoInsteadOfLaunching() {
        AJOJob__c j = makeJob('SAMPLE_EMPTY', 'AJOSampleScheduler', 'Runnable', 75);
        j.AJO_Parameters__c = '{"object":"Account","days":1,"limit":50}';
        update j;

        Test.startTest();
        AJOLauncher.runNow(j, Datetime.now(), 'Manual', 0);
        update j;
        Test.stopTest();

        AJOJobRun__c run = runFor(j.Id);
        System.assertEquals(null, run.AJO_AsyncApexJobId__c,
            'No async work was started, so there is no id to show.');
        System.assertEquals('Success', run.AJO_Status__c);
        System.assert(run.AJO_Message__c.containsIgnoreCase('no batch started'),
            'A run that did nothing must read differently from one that did: '
            + run.AJO_Message__c);
    }

    /** report() closes the run with true record counts, not the chunk count. */
    @IsTest
    static void reportClosesTheRunWithRealRecordCounts() {
        AJOJob__c j = makeJob('SAMPLE_REPORT', 'AJOSampleBatch', 'Batch', 200);
        AJOJobRun__c run = AJORunLogger.open(j, Datetime.now(), 'Manual', 0);

        // Stored the way the launcher stores it: assigning an Id to the text
        // field yields the 18-character form, which is what report() looks up.
        Id asyncId = (Id) '707000000000001AAA';
        run.AJO_AsyncApexJobId__c = asyncId;
        update AJORunLogger.patch(run);

        Test.startTest();
        Boolean found = AJORunLogger.report(
            asyncId, 9876, 4, 'Processed 9876 record(s), 4 failed.');
        Test.stopTest();

        System.assert(found, 'report() should find the open run by its job id.');
        AJOJobRun__c after = runFor(j.Id);
        System.assertEquals(9876, after.AJO_ItemsProcessed__c,
            'Real records, not the number of chunks.');
        System.assertEquals(4, after.AJO_ItemsFailed__c);
        System.assertEquals('Failed', after.AJO_Status__c,
            'Failed records mean a failed run.');
    }

    /** A batch nobody orchestrated must not blow up when it reports. */
    @IsTest
    static void reportIsHarmlessWhenNoRunIsWaiting() {
        Test.startTest();
        System.assert(!AJORunLogger.report((Id) '707000000000002AAA', 1, 0, 'x'));
        System.assert(!AJORunLogger.report(null, 1, 0, 'x'));
        Test.stopTest();
    }
}
