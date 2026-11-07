/**
 * Shared fixtures for the orchestrator's tests.
 *
 * Custom metadata records cannot be inserted in a test, so definitions are
 * built in memory and installed with AJODefinitions.useForTest(); the sync
 * then projects them onto AJOJob__c exactly as it does for deployed records.
 */
@IsTest
public class AJOTestFactory {

    public static final String TZ = 'America/New_York';

    /** A valid, active definition that runs every hour at :00. */
    public static AJO_Job_Definition__mdt definition(String developerName, String apexClass,
                                                     String executionType) {
        AJO_Job_Definition__mdt d = AJODefinitions.build(developerName, apexClass, executionType, '0 0 * * * ?');
        d.AJO_TimeZone__c = TZ;
        d.AJO_MaxConsecutiveFailures__c = 3;
        d.AJO_MaxRuntimeMinutes__c = 60;
        d.AJO_Priority__c = 5;
        return d;
    }

    /** A Runnable definition backed by the demo class, which always succeeds. */
    public static AJO_Job_Definition__mdt runnable(String developerName) {
        AJO_Job_Definition__mdt d = definition(developerName, 'AJODemoRunnable', 'Runnable');
        d.AJO_Parameters__c = '{"object":"User","target":0}';
        return d;
    }

    /** Installs the given definitions in place of the deployed ones. */
    public static void use(List<AJO_Job_Definition__mdt> defs) {
        AJODefinitions.useForTest(defs);
    }

    /**
     * Inserts framework settings. allowUnmanaged=false is the secure default
     * the managed-path tests run under.
     */
    public static AJOSetting__c settings(Boolean allowUnmanaged) {
        AJOSetting__c s = new AJOSetting__c(
            AJO_AllowUnmanagedJobs__c   = allowUnmanaged,
            AJO_KillSwitch__c           = false,
            AJO_HeartbeatMinutes__c     = 10,
            AJO_MaxConcurrentBatches__c = 5,
            AJO_EnableDeferral__c       = true,
            AJO_DefaultTimeZone__c      = TZ,
            AJO_RetentionDaysSuccess__c = 14,
            AJO_RetentionDaysFailure__c = 90);
        insert s;
        AJOConfig.applyOverride(null); // re-read from the database
        return s;
    }

    /** Syncs and returns the state row for one key. */
    public static AJOJob__c syncAndGet(String key) {
        AJODefinitionSync.sync();
        return state(key);
    }

    /** The state row for one key, with every field the engine reads. */
    public static AJOJob__c state(String key) {
        List<AJOJob__c> rows = Database.query('SELECT ' + AJOLauncher.JOB_FIELDS
            + ', AJO_DefinitionHash__c, AJO_DefinitionError__c, AJO_CutoverAt__c'
            + ' FROM AJOJob__c WHERE AJO_JobKey__c = :key LIMIT 1');
        return rows.isEmpty() ? null : rows[0];
    }

    /** Makes a synced job due right now. */
    public static AJOJob__c makeDue(String key) {
        AJOJob__c s = state(key);
        s.AJO_NextRunAt__c = Datetime.now().addMinutes(-1);
        update s;
        return state(key);
    }

    /** Alert codes flushed in this transaction. */
    public static Set<String> sentCodes() {
        Set<String> codes = new Set<String>();
        for (AJOAlerts.Alert a : AJOAlerts.sent) { codes.add(a.code); }
        for (AJOAlerts.Alert a : AJOAlerts.pending) { codes.add(a.code); }
        return codes;
    }
}
