/**
 * Reads AJO_Job_Definition__mdt — the source of truth for what runs, how and
 * when. Everything else in the framework asks this class, never the CMDT
 * directly, so tests can substitute definitions (custom metadata records
 * cannot be inserted in a test) and the read happens once per transaction.
 *
 * Why SOQL and not AJO_Job_Definition__mdt.getAll(): getAll() truncates long
 * text area fields to 255 characters, which would silently cut the
 * Parameters JSON. A SOQL query returns the full value. The query counts
 * against the SOQL limit only because it selects a long text area field —
 * one query per transaction, cached below.
 */
public inherited sharing class AJODefinitions {

    /** In-memory definitions a test installs instead of the deployed records. */
    @TestVisible
    private static List<AJO_Job_Definition__mdt> testDefinitions;

    private static Map<String, AJO_Job_Definition__mdt> cache;

    /** Every definition, active or not, keyed by DeveloperName. */
    public static Map<String, AJO_Job_Definition__mdt> all() {
        if (cache == null) {
            cache = new Map<String, AJO_Job_Definition__mdt>();
            List<AJO_Job_Definition__mdt> rows = testDefinitions != null
                ? testDefinitions
                : [
                    SELECT DeveloperName, MasterLabel, AJO_Active__c, AJO_ApexClass__c,
                           AJO_ExecutionType__c, AJO_CronExpression__c, AJO_TimeZone__c,
                           AJO_BatchSize__c, AJO_Parameters__c, AJO_OverlapPolicy__c,
                           AJO_Priority__c, AJO_MaxRuntimeMinutes__c,
                           AJO_MaxConsecutiveFailures__c, AJO_DependsOn__c,
                           AJO_RunAfterDependency__c, AJO_StartDate__c, AJO_EndDate__c,
                           AJO_DryRun__c, AJO_AllowsCallouts__c, AJO_NotifyEmails__c,
                           AJO_ReplacesCronJobName__c, AJO_Description__c
                    FROM   AJO_Job_Definition__mdt
                    ORDER BY DeveloperName
                ];
            for (AJO_Job_Definition__mdt d : rows) {
                cache.put(d.DeveloperName, d);
            }
        }
        return cache;
    }

    /** One definition by DeveloperName (the state record's AJO_JobKey__c), or null. */
    public static AJO_Job_Definition__mdt byKey(String key) {
        return String.isBlank(key) ? null : all().get(key);
    }

    /**
     * Installs in-memory definitions for a test and clears the cache. Custom
     * metadata sObjects can be constructed and populated in memory, which is
     * how tests exercise every definition shape without deploying records.
     */
    @TestVisible
    private static void useForTest(List<AJO_Job_Definition__mdt> rows) {
        testDefinitions = rows;
        cache = null;
    }

    /** Forgets the cached read, e.g. after useForTest or within long tests. */
    @TestVisible
    private static void reset() {
        cache = null;
    }

    /**
     * Convenience constructor for tests and for the console's "generate a
     * definition" preview: a definition populated from the common fields.
     */
    public static AJO_Job_Definition__mdt build(String developerName, String apexClass,
                                                String executionType, String cron) {
        return new AJO_Job_Definition__mdt(
            DeveloperName          = developerName,
            MasterLabel            = developerName,
            AJO_Active__c          = true,
            AJO_ApexClass__c       = apexClass,
            AJO_ExecutionType__c   = executionType,
            AJO_CronExpression__c  = cron,
            AJO_OverlapPolicy__c   = 'Skip',
            AJO_DryRun__c          = false,
            AJO_AllowsCallouts__c  = false,
            AJO_RunAfterDependency__c = false
        );
    }
}
