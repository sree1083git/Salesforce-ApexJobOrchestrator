/**
 * Covers AJODefinitionSync: projection of custom metadata definitions onto
 * AJOJob__c state, tamper correction, schedule recomputation, invalid and
 * retired definitions, the operations pause, dependency resolution and the
 * atomic takeover of Setup scheduled jobs.
 */
@IsTest
private class AJODefinitionSyncTest {

    @TestSetup
    static void setup() {
        AJOTestFactory.settings(false);
    }

    @IsTest
    static void aNewDefinitionCreatesItsStateWithAFutureRun() {
        AJO_Job_Definition__mdt d = AJOTestFactory.runnable('SYNC_NEW');
        d.MasterLabel = 'Nightly counter';
        d.AJO_Priority__c = 3;
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });

        Test.startTest();
        AJODefinitionSync.Result r = AJODefinitionSync.sync();
        Test.stopTest();

        System.assertEquals(1, r.created, r.summary());
        AJOJob__c s = AJOTestFactory.state('SYNC_NEW');
        System.assertNotEquals(null, s);
        System.assertEquals(true, s.AJO_DefinitionManaged__c);
        System.assertEquals('Nightly counter', s.Name);
        System.assertEquals('AJODemoRunnable', s.AJO_ApexClassName__c);
        System.assertEquals('Runnable', s.AJO_ExecutionType__c);
        System.assertEquals(3, s.AJO_Priority__c);
        System.assertEquals(true, s.AJO_Enabled__c);
        System.assertEquals('Idle', s.AJO_Status__c);
        System.assert(s.AJO_NextRunAt__c > Datetime.now(), 'A future run is computed.');
        System.assertEquals(64, s.AJO_DefinitionHash__c.length());
    }

    @IsTest
    static void aSecondSyncChangesNothing() {
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ AJOTestFactory.runnable('SYNC_IDEMPOTENT') });
        AJODefinitionSync.sync();
        AJOJob__c before = AJOTestFactory.state('SYNC_IDEMPOTENT');

        Test.startTest();
        AJODefinitionSync.Result r = AJODefinitionSync.sync();
        Test.stopTest();

        System.assertEquals(0, r.created + r.updated, r.summary());
        System.assertEquals(1, r.unchanged);
        System.assertEquals(before.AJO_NextRunAt__c, AJOTestFactory.state('SYNC_IDEMPOTENT').AJO_NextRunAt__c);
    }

    @IsTest
    static void editingTheStateRecordDirectlyIsUndone() {
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ AJOTestFactory.runnable('SYNC_TAMPER') });
        AJOJob__c s = AJOTestFactory.syncAndGet('SYNC_TAMPER');
        Datetime next = s.AJO_NextRunAt__c;

        // Someone with edit access points the job at another class.
        s.AJO_ApexClassName__c = 'AJODemoFailingJob';
        s.AJO_ExecutionType__c = 'Legacy Schedulable';
        update s;

        Test.startTest();
        AJODefinitionSync.Result r = AJODefinitionSync.sync();
        Test.stopTest();

        AJOJob__c after = AJOTestFactory.state('SYNC_TAMPER');
        System.assertEquals(1, r.updated, r.summary());
        System.assertEquals('AJODemoRunnable', after.AJO_ApexClassName__c,
            'The definition, not the record, decides what runs.');
        System.assertEquals('Runnable', after.AJO_ExecutionType__c);
        System.assertEquals(next, after.AJO_NextRunAt__c,
            'A non-schedule correction must not move the next run.');
    }

    @IsTest
    static void aScheduleChangeRecomputesTheNextRun() {
        AJO_Job_Definition__mdt d = AJOTestFactory.runnable('SYNC_RESCHEDULE');
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });
        AJOJob__c s = AJOTestFactory.syncAndGet('SYNC_RESCHEDULE');
        s.AJO_NextRunAt__c = Datetime.now().addDays(30); // something a resync would have to replace
        update s;

        d.AJO_CronExpression__c = '0 15 * * * ?';
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });

        Test.startTest();
        AJODefinitionSync.sync();
        Test.stopTest();

        AJOJob__c after = AJOTestFactory.state('SYNC_RESCHEDULE');
        System.assertEquals('0 15 * * * ?', after.AJO_CronExpression__c);
        System.assert(after.AJO_NextRunAt__c < Datetime.now().addHours(2),
            'The new hourly schedule must replace the stale next run.');
    }

    @IsTest
    static void aDescriptionChangeDoesNotMoveTheNextRun() {
        AJO_Job_Definition__mdt d = AJOTestFactory.runnable('SYNC_DESC');
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });
        Datetime next = AJOTestFactory.syncAndGet('SYNC_DESC').AJO_NextRunAt__c;

        d.AJO_Description__c = 'Now with an owner.';
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });
        Test.startTest();
        AJODefinitionSync.sync();
        Test.stopTest();

        AJOJob__c after = AJOTestFactory.state('SYNC_DESC');
        System.assertEquals('Now with an owner.', after.AJO_Description__c);
        System.assertEquals(next, after.AJO_NextRunAt__c);
    }

    @IsTest
    static void anInvalidDefinitionIsParkedAndAlerted() {
        AJO_Job_Definition__mdt d = AJOTestFactory.runnable('SYNC_INVALID');
        d.AJO_ApexClass__c = 'NoSuchClassAnywhere';
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });

        Test.startTest();
        AJODefinitionSync.Result r = AJODefinitionSync.sync();
        Test.stopTest();

        AJOJob__c s = AJOTestFactory.state('SYNC_INVALID');
        System.assertEquals(1, r.invalid, r.summary());
        System.assertEquals('Invalid', s.AJO_Status__c);
        System.assertEquals(false, s.AJO_Enabled__c);
        System.assertEquals(null, s.AJO_NextRunAt__c, 'An invalid job is never selected.');
        System.assert(s.AJO_DefinitionError__c.contains('NoSuchClassAnywhere'), s.AJO_DefinitionError__c);
        System.assert(AJOTestFactory.sentCodes().contains('DEFINITION_INVALID'));
    }

    @IsTest
    static void fixingAnInvalidDefinitionBringsTheJobBack() {
        AJO_Job_Definition__mdt d = AJOTestFactory.runnable('SYNC_FIXED');
        d.AJO_CronExpression__c = 'nonsense';
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });
        AJODefinitionSync.sync();
        System.assertEquals('Invalid', AJOTestFactory.state('SYNC_FIXED').AJO_Status__c);

        d.AJO_CronExpression__c = '0 0 * * * ?';
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });
        Test.startTest();
        AJODefinitionSync.sync();
        Test.stopTest();

        AJOJob__c s = AJOTestFactory.state('SYNC_FIXED');
        System.assertEquals('Idle', s.AJO_Status__c);
        System.assertEquals(null, s.AJO_DefinitionError__c);
        System.assertNotEquals(null, s.AJO_NextRunAt__c);
    }

    @IsTest
    static void aRemovedDefinitionRetiresItsState() {
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ AJOTestFactory.runnable('SYNC_GONE') });
        AJODefinitionSync.sync();

        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>());
        Test.startTest();
        AJODefinitionSync.Result r = AJODefinitionSync.sync();
        Test.stopTest();

        AJOJob__c s = AJOTestFactory.state('SYNC_GONE');
        System.assertEquals(1, r.retired, r.summary());
        System.assertEquals('Retired', s.AJO_Status__c);
        System.assertEquals(false, s.AJO_Enabled__c);
        System.assertEquals(null, s.AJO_NextRunAt__c);
    }

    @IsTest
    static void anInactiveDefinitionHasNoNextRun() {
        AJO_Job_Definition__mdt d = AJOTestFactory.runnable('SYNC_INACTIVE');
        d.AJO_Active__c = false;
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });
        Test.startTest();
        AJOJob__c s = AJOTestFactory.syncAndGet('SYNC_INACTIVE');
        Test.stopTest();
        System.assertEquals(false, s.AJO_Enabled__c);
        System.assertEquals(null, s.AJO_NextRunAt__c);
    }

    @IsTest
    static void theOperationsPauseSurvivesASync() {
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ AJOTestFactory.runnable('SYNC_PAUSED') });
        AJOJob__c s = AJOTestFactory.syncAndGet('SYNC_PAUSED');

        Test.startTest();
        AJOAdminController.setEnabled(s.Id, false);
        AJODefinitionSync.sync();
        Test.stopTest();

        AJOJob__c after = AJOTestFactory.state('SYNC_PAUSED');
        System.assertEquals(true, after.AJO_OpsPaused__c);
        System.assertEquals(false, after.AJO_Enabled__c, 'A sync must not undo an operational pause.');
    }

    @IsTest
    static void dependencyKeysBecomeLookups() {
        AJO_Job_Definition__mdt parent = AJOTestFactory.runnable('SYNC_PARENT');
        AJO_Job_Definition__mdt child = AJOTestFactory.runnable('SYNC_CHILD');
        child.AJO_DependsOn__c = 'SYNC_PARENT';
        child.AJO_RunAfterDependency__c = true;
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ parent, child });

        Test.startTest();
        AJODefinitionSync.sync();
        Test.stopTest();

        AJOJob__c c = AJOTestFactory.state('SYNC_CHILD');
        System.assertEquals(AJOTestFactory.state('SYNC_PARENT').Id, c.AJO_DependsOnJobId__c);
        System.assertEquals(true, c.AJO_RunAfterDependency__c);
    }

    @IsTest
    static void anExistingUnmanagedRecordIsAdoptedNotDuplicated() {
        insert new AJOJob__c(Name = 'Old config', AJO_JobKey__c = 'SYNC_ADOPT',
            AJO_ApexClassName__c = 'AJODemoLegacyScheduler', AJO_ExecutionType__c = 'Legacy Schedulable',
            AJO_CronExpression__c = '0 30 * * * ?', AJO_Enabled__c = true, AJO_Status__c = 'Idle');
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ AJOTestFactory.runnable('SYNC_ADOPT') });

        Test.startTest();
        AJODefinitionSync.sync();
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM AJOJob__c WHERE AJO_JobKey__c = 'SYNC_ADOPT']);
        AJOJob__c s = AJOTestFactory.state('SYNC_ADOPT');
        System.assertEquals(true, s.AJO_DefinitionManaged__c);
        System.assertEquals('AJODemoRunnable', s.AJO_ApexClassName__c);
    }

    @IsTest
    static void duringDryRunTheSetupJobKeepsDoingTheRealWork() {
        String legacy = 'ZZ AJO Sync Rehearsal ' + Crypto.getRandomInteger();
        Id ctId = System.schedule(legacy, '0 0 3 * * ?', new AJODemoLegacyScheduler());

        AJO_Job_Definition__mdt d = AJOTestFactory.definition('SYNC_REHEARSAL', 'AJODemoLegacyScheduler',
                                                              'Legacy Schedulable');
        d.AJO_ReplacesCronJobName__c = legacy;
        d.AJO_DryRun__c = true;
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });

        Test.startTest();
        AJODefinitionSync.Result r = AJODefinitionSync.sync();
        Test.stopTest();

        System.assertEquals(0, r.cutOver, 'No takeover while the definition only rehearses.');
        System.assertEquals(1, [SELECT COUNT() FROM CronTrigger WHERE Id = :ctId],
            'The Setup schedule still runs the job for real during Dry Run.');
        System.assertEquals(null, AJOTestFactory.state('SYNC_REHEARSAL').AJO_CutoverAt__c);
    }

    @IsTest
    static void activationTakesOverTheNamedSetupJobOnce() {
        String legacy = 'ZZ AJO Sync Takeover ' + Crypto.getRandomInteger();
        Id ctId = System.schedule(legacy, '0 0 3 * * ?', new AJODemoLegacyScheduler());

        AJO_Job_Definition__mdt d = AJOTestFactory.definition('SYNC_TAKEOVER', 'AJODemoLegacyScheduler',
                                                              'Legacy Schedulable');
        d.AJO_ReplacesCronJobName__c = legacy;
        d.AJO_DryRun__c = true;
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });

        Test.startTest();
        AJODefinitionSync.Result rehearsal = AJODefinitionSync.sync();
        d.AJO_DryRun__c = false; // the release that ends the rehearsal
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });
        AJODefinitionSync.Result r = AJODefinitionSync.sync();
        AJODefinitionSync.Result again = AJODefinitionSync.sync();
        Test.stopTest();

        System.assertEquals(0, rehearsal.cutOver);

        System.assertEquals(1, r.cutOver, r.summary());
        System.assertEquals(0, again.cutOver, 'A takeover happens once.');
        System.assertEquals(0, [SELECT COUNT() FROM CronTrigger WHERE Id = :ctId],
            'The Setup schedule is gone, freeing its slot.');
        AJOJob__c s = AJOTestFactory.state('SYNC_TAKEOVER');
        System.assertNotEquals(null, s.AJO_CutoverAt__c);
        System.assertEquals(String.valueOf(ctId), s.AJO_LegacyCronTriggerId__c);
        System.assertEquals(legacy, s.AJO_LegacyCronJobName__c);
        System.assertEquals('0 0 3 * * ?', s.AJO_LegacyCronExpression__c);
    }

    @IsTest
    static void aTakeoverOfAMissingSetupJobStillCompletes() {
        AJO_Job_Definition__mdt d = AJOTestFactory.runnable('SYNC_TAKEOVER_MISSING');
        d.AJO_ReplacesCronJobName__c = 'ZZ No Such Setup Job Exists';
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });
        Test.startTest();
        AJODefinitionSync.Result r = AJODefinitionSync.sync();
        Test.stopTest();
        System.assertEquals(1, r.cutOver);
        System.assertNotEquals(null, AJOTestFactory.state('SYNC_TAKEOVER_MISSING').AJO_CutoverAt__c);
    }

    @IsTest
    static void theFrameworksOwnSchedulesCanNeverBeTakenOver() {
        AJO_Job_Definition__mdt d = AJOTestFactory.runnable('SYNC_SELF_TAKEOVER');
        d.AJO_ReplacesCronJobName__c = AJOInstaller.SUPERVISOR_NAME;
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });
        Test.startTest();
        AJODefinitionSync.Result r = AJODefinitionSync.sync();
        Test.stopTest();
        System.assertEquals(0, r.cutOver);
        System.assert(AJOTestFactory.sentCodes().contains('CUTOVER_FAILED'));
    }

    @IsTest
    static void theHeartbeatSyncsBeforeItSelects() {
        AJO_Job_Definition__mdt d = AJOTestFactory.runnable('SYNC_VIA_HEARTBEAT');
        AJOTestFactory.use(new List<AJO_Job_Definition__mdt>{ d });
        Test.startTest();
        AJODispatcher.run(0);
        Test.stopTest();
        System.assertNotEquals(null, AJOTestFactory.state('SYNC_VIA_HEARTBEAT'),
            'A deployment takes effect at the next check without anyone pressing Sync.');
    }

    @IsTest
    static void fingerprintsOfADefinitionAndItsProjectionAgree() {
        AJO_Job_Definition__mdt d = AJOTestFactory.runnable('SYNC_HASH');
        d.AJO_BatchSize__c = 200;
        AJOJob__c s = new AJOJob__c();
        AJODefinitionSync.project(d, s);
        System.assertEquals(AJODefinitionSync.fingerprint(d), AJODefinitionSync.fingerprint(s),
            'An untouched projection must not look drifted, or every sync would rewrite it.');
    }
}
