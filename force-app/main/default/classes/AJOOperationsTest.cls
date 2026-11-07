/**
 * Covers operability: self-healing of the scheduled slots, the supervisor's
 * hourly schedule and isolated steps, the stale-heartbeat watchdog, reaping
 * with abort, batched log retention, the external health endpoint, alert
 * delivery, and the definition exporter.
 *
 * CronTrigger is not isolated in tests (the org's real schedules are visible),
 * so assertions are about the schedules each test touches, never org totals.
 */
@IsTest
private class AJOOperationsTest {

    @TestSetup
    static void setup() {
        AJOTestFactory.settings(false);
    }

    // ============================================================ self-healing

    @IsTest
    static void aMissingHeartbeatIsRecreatedByTheNextCheck() {
        AJOInstaller.arm();
        CronTrigger victim = [
            SELECT Id FROM CronTrigger
            WHERE CronJobDetail.Name = :AJOInstaller.heartbeatName(20) LIMIT 1
        ];
        System.abortJob(victim.Id);

        Test.startTest();
        Integer healed = AJOInstaller.healSafely();
        Test.stopTest();

        System.assertEquals(1, healed);
        System.assertEquals(1, [SELECT COUNT() FROM CronTrigger
                                WHERE CronJobDetail.Name = :AJOInstaller.heartbeatName(20)]);
        System.assert(AJOTestFactory.sentCodes().contains('SLOTS_REARMED'));
    }

    @IsTest
    static void anUninstalledFrameworkStaysUninstalled() {
        AJOInstaller.arm();
        AJOInstaller.disarm();
        Test.startTest();
        Integer healed = AJOInstaller.healSafely();
        Test.stopTest();
        System.assertEquals(0, healed, 'Healing never undoes a deliberate uninstall.');
        System.assertEquals(0, AJOInstaller.ownTriggers().size());
    }

    @IsTest
    static void anOldDailySupervisorIsMovedToHourly() {
        AJOInstaller.disarm();
        System.schedule(AJOInstaller.SUPERVISOR_NAME, '0 5 2 * * ?', new AJOSupervisor());

        Test.startTest();
        AJOInstaller.arm();
        Test.stopTest();

        CronTrigger sup = [SELECT CronExpression FROM CronTrigger
                           WHERE CronJobDetail.Name = :AJOInstaller.SUPERVISOR_NAME LIMIT 1];
        System.assertEquals(AJOInstaller.SUPERVISOR_CRON, sup.CronExpression);
    }

    @IsTest
    static void theHeartbeatStampsItselfEvenWhilePaused() {
        AJOSetting__c s = AJOSetting__c.getOrgDefaults();
        s.AJO_KillSwitch__c = true;
        update s;
        AJOConfig.applyOverride(null);

        Test.startTest();
        AJODispatcher.run(0);
        Test.stopTest();

        System.assertNotEquals(null, AJOSetting__c.getOrgDefaults().AJO_LastHeartbeatAt__c,
            'The watchdog measures the scheduler, not whether jobs are paused.');
    }

    // ================================================================ watchdog

    @IsTest
    static void aStaleHeartbeatRaisesAnAlert() {
        AJOInstaller.arm();
        AJOSetting__c s = AJOSetting__c.getOrgDefaults();
        s.AJO_LastHeartbeatAt__c = Datetime.now().addHours(-2);
        update s;
        AJOConfig.applyOverride(null);

        Test.startTest();
        Boolean stale = AJOSupervisor.checkHeartbeat(Datetime.now());
        Test.stopTest();

        System.assert(stale);
        System.assert(AJOTestFactory.sentCodes().contains('HEARTBEAT_STALE'));
    }

    @IsTest
    static void aFreshHeartbeatIsHealthy() {
        AJOInstaller.arm();
        AJOSetting__c s = AJOSetting__c.getOrgDefaults();
        s.AJO_LastHeartbeatAt__c = Datetime.now().addMinutes(-5);
        update s;
        AJOConfig.applyOverride(null);
        System.assert(!AJOSupervisor.checkHeartbeat(Datetime.now()));
    }

    // ============================================================== supervisor

    @IsTest
    static void theSweepRunsEveryStepAndReportsEach() {
        Test.startTest();
        Map<String, Object> r = AJOSupervisor.sweep();
        Test.stopTest();
        for (String key : new List<String>{ 'rearmed', 'stale', 'synced', 'reconciled', 'stuck',
                                            'expired', 'unqueued', 'purged', 'slotsUsed' }) {
            System.assert(r.containsKey(key), 'Missing step result: ' + key);
            System.assertNotEquals(-1, r.get(key), 'Step failed: ' + key);
        }
    }

    @IsTest
    static void anOverrunningRunIsTimedOutAndItsJobFreed() {
        AJOJob__c j = new AJOJob__c(Name = 'Slow', AJO_JobKey__c = 'OPS_SLOW', AJO_Status__c = 'Running',
            AJO_ApexClassName__c = 'AJODemoSlowJob', AJO_ExecutionType__c = 'Legacy Schedulable',
            AJO_CronExpression__c = '0 0 * * * ?', AJO_MaxRuntimeMinutes__c = 30);
        insert j;
        AJOJobRun__c run = new AJOJobRun__c(AJO_Job__c = j.Id, AJO_Status__c = 'Running',
            AJO_StartedAt__c = Datetime.now().addHours(-2));
        insert run;

        Test.startTest();
        Integer reaped = AJOSupervisor.reapStuck();
        Test.stopTest();

        System.assertEquals(1, reaped);
        AJOJobRun__c after = [SELECT AJO_Status__c, AJO_ErrorMessage__c FROM AJOJobRun__c WHERE Id = :run.Id];
        System.assertEquals('Stuck', after.AJO_Status__c);
        System.assert(after.AJO_ErrorMessage__c.contains('No async job to abort'), after.AJO_ErrorMessage__c);
        System.assertEquals('Idle', [SELECT AJO_Status__c FROM AJOJob__c WHERE Id = :j.Id].AJO_Status__c);
    }

    @IsTest
    static void retentionRunsAsABatchAndKeepsRecentRows() {
        AJOJob__c j = new AJOJob__c(Name = 'Logged', AJO_JobKey__c = 'OPS_LOG',
            AJO_ApexClassName__c = 'AJODemoRunnable', AJO_ExecutionType__c = 'Runnable',
            AJO_CronExpression__c = '0 0 * * * ?');
        insert j;
        AJOJobRun__c oldOk   = new AJOJobRun__c(AJO_Job__c = j.Id, AJO_Status__c = 'Success');
        AJOJobRun__c oldFail = new AJOJobRun__c(AJO_Job__c = j.Id, AJO_Status__c = 'Failed');
        AJOJobRun__c fresh   = new AJOJobRun__c(AJO_Job__c = j.Id, AJO_Status__c = 'Success');
        insert new List<AJOJobRun__c>{ oldOk, oldFail, fresh };
        Test.setCreatedDate(oldOk.Id, Datetime.now().addDays(-30));
        Test.setCreatedDate(oldFail.Id, Datetime.now().addDays(-30)); // inside the 90-day failure window

        Test.startTest();
        Integer started = AJOSupervisor.purge();
        Test.stopTest();

        System.assertEquals(1, started);
        Set<Id> left = new Map<Id, AJOJobRun__c>([SELECT Id FROM AJOJobRun__c]).keySet();
        System.assert(!left.contains(oldOk.Id), 'A month-old success is past retention.');
        System.assert(left.contains(oldFail.Id), 'Failures are kept for 90 days.');
        System.assert(left.contains(fresh.Id));
    }

    // ========================================================== health endpoint

    @IsTest
    static void healthIsUnhealthyWhenNotInstalled() {
        AJOInstaller.disarm();
        AJOHealthResource.Health h = AJOHealthResource.evaluate(Datetime.now());
        System.assertEquals(false, h.healthy);
        System.assert(String.join(h.problems, ' ').contains('supervisor'), String.join(h.problems, ' '));
    }

    @IsTest
    static void healthIsHealthyWhenInstalledAndBeating() {
        AJOInstaller.arm();
        AJOSetting__c s = AJOSetting__c.getOrgDefaults();
        s.AJO_LastHeartbeatAt__c = Datetime.now();
        update s;
        AJOConfig.applyOverride(null);

        RestContext.request = new RestRequest();
        RestContext.response = new RestResponse();
        Test.startTest();
        AJOHealthResource.Health h = AJOHealthResource.get();
        Test.stopTest();

        System.assert(h.healthy, String.join(h.problems, ' '));
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(true, h.supervisorArmed);
    }

    // ================================================================= alerts

    @IsTest
    static void alertsAreDedupedAndPublished() {
        AJOSetting__c s = AJOSetting__c.getOrgDefaults();
        s.AJO_DigestEmail__c = 'ops@example.com';
        update s;
        AJOConfig.applyOverride(null);

        Test.startTest();
        AJOAlerts.raise(AJOAlerts.ERROR, 'JOB_FAILED', 'K1', 'first', 'owner@example.com');
        AJOAlerts.raise(AJOAlerts.ERROR, 'JOB_FAILED', 'K1', 'duplicate, dropped');
        AJOAlerts.raise(AJOAlerts.INFO, 'CUTOVER_DONE', 'K2', 'informational');
        AJOAlerts.flush();
        AJOAlerts.flush(); // nothing left; must not throw or resend
        Test.stopTest();

        System.assertEquals(2, AJOAlerts.sent.size());
        System.assertEquals('first', AJOAlerts.sent[0].message);
        System.assertEquals(new List<String>{ 'owner@example.com' }, AJOAlerts.sent[0].recipients);
    }

    // =============================================================== exporter

    @IsTest
    static void developerNamesAreAlwaysValid() {
        System.assertEquals('Nightly_Sync', AJODefinitionExporter.developerName(null, 'Nightly  Sync!'));
        System.assertEquals('J_2024_cleanup', AJODefinitionExporter.developerName(null, '2024 cleanup'));
        System.assertEquals('KEY_ONE', AJODefinitionExporter.developerName('KEY_ONE', 'ignored'));
        System.assert(AJODefinitionExporter.developerName(null, 'x'.repeat(80)).length() <= 40);
        System.assertEquals('JOB', AJODefinitionExporter.developerName(null, '***'));
    }

    @IsTest
    static void aTakeoverDefinitionShipsInDryRunNamingTheSetupJob() {
        AJODefinitionExporter.DefinitionFile f = AJODefinitionExporter.fromSetupSchedule(
            'Old Nightly Job', 'AJODemoLegacyScheduler', 'Legacy Schedulable', '0 0 2 * * ?',
            'America/New_York');
        System.assertEquals('Old_Nightly_Job', f.developerName);
        System.assert(f.problems.isEmpty(), String.join(f.problems, ' | '));
        System.assert(f.xml.contains('<field>AJO_ReplacesCronJobName__c</field>'));
        System.assert(f.xml.contains('Old Nightly Job'));
        System.assert(f.xml.contains('<field>AJO_DryRun__c</field>\n        <value xsi:type="xsd:boolean">true</value>'));
    }

    @IsTest
    static void anExportedUnmanagedJobCarriesItsConfiguration() {
        AJOJob__c j = new AJOJob__c(Name = 'Legacy config', AJO_JobKey__c = 'OPS_EXPORT',
            AJO_ApexClassName__c = 'AJODemoBatch', AJO_ExecutionType__c = 'Batch', AJO_BatchSize__c = 150,
            AJO_CronExpression__c = '0 30 1 * * ?', AJO_TimeZoneSidKey__c = 'America/New_York',
            AJO_Enabled__c = true, AJO_EndDate__c = Date.newInstance(2030, 1, 31));
        insert j;
        AJODefinitionExporter.DefinitionFile f = AJOAdminController.exportDefinition(j.Id);
        System.assertEquals('OPS_EXPORT', f.developerName);
        System.assert(f.xml.contains('<value xsi:type="xsd:double">150</value>'), f.xml);
        System.assert(f.xml.contains('<value xsi:type="xsd:date">2030-01-31</value>'), f.xml);
        System.assert(f.problems.isEmpty(), String.join(f.problems, ' | '));
    }
}
