/**
 * THE DEPLOYMENT GATE, plus unit coverage of every validation rule.
 *
 * deployedDefinitionsAreAllValid() reads the REAL AJO_Job_Definition__mdt
 * records in the org being deployed to (custom metadata is visible to tests)
 * and fails if any of them is invalid. Run it in every deployment (RunLocalTests
 * or a named test level) and a misspelt class, a cron that never fires, a bad
 * time zone, a dependency on a job that does not exist or a dependency cycle
 * fails the release instead of failing silently at 2 a.m.
 */
@IsTest
private class AJODefinitionValidationTest {

    @IsTest
    static void deployedDefinitionsAreAllValid() {
        Map<String, AJO_Job_Definition__mdt> deployed = AJODefinitions.all();
        Map<String, List<String>> problems = AJODefinitionValidator.validateAll(deployed);

        List<String> report = new List<String>();
        for (String key : problems.keySet()) {
            report.add(key + ': ' + String.join(problems.get(key), ' | '));
        }
        System.assert(problems.isEmpty(),
            'Every deployed AJO_Job_Definition__mdt record must be valid. Fix these before '
            + 'deploying:\n' + String.join(report, '\n'));
    }

    @IsTest
    static void aWellFormedDefinitionHasNoProblems() {
        AJO_Job_Definition__mdt d = AJOTestFactory.runnable('GOOD');
        System.assertEquals(0, AJODefinitionValidator.validate(d, defs(d)).size(),
            String.join(AJODefinitionValidator.validate(d, defs(d)), ' | '));
    }

    @IsTest
    static void eachExecutionTypeIsCheckedAgainstTheClass() {
        assertValid(AJOTestFactory.definition('R', 'AJODemoRunnable', 'Runnable'));
        assertValid(AJOTestFactory.definition('B', 'AJODemoBatch', 'Batch'));
        assertValid(AJOTestFactory.definition('Q', 'AJODemoQueueable', 'Queueable'));
        assertValid(AJOTestFactory.definition('L', 'AJODemoLegacyScheduler', 'Legacy Schedulable'));

        assertProblem(AJOTestFactory.definition('X1', 'AJODemoLegacyScheduler', 'Runnable'), 'does not implement');
        assertProblem(AJOTestFactory.definition('X2', 'AJODemoRunnable', 'Batch'), 'does not implement');
        assertProblem(AJOTestFactory.definition('X3', 'AJODemoBatch', 'Queueable'), 'does not implement');
        assertProblem(AJOTestFactory.definition('X4', 'AJODemoRunnable', 'Sometimes'), 'Execution Type');
    }

    @IsTest
    static void aMissingOrBlankClassIsRefused() {
        assertProblem(AJOTestFactory.definition('NOPE', 'NoSuchClassAnywhere', 'Runnable'), 'not found');
        assertProblem(AJOTestFactory.definition('BLANK', null, 'Runnable'), 'blank');
    }

    @IsTest
    static void schedulesAreParsedAndMustFire() {
        AJO_Job_Definition__mdt bad = AJOTestFactory.runnable('BADCRON');
        bad.AJO_CronExpression__c = 'every day at nine';
        assertProblem(bad, 'Cron Expression');

        AJO_Job_Definition__mdt unsupported = AJOTestFactory.runnable('LCRON');
        unsupported.AJO_CronExpression__c = '0 0 9 L * ?';
        assertProblem(unsupported, 'Cron Expression');

        AJO_Job_Definition__mdt never = AJOTestFactory.runnable('PASTYEAR');
        never.AJO_CronExpression__c = '0 0 9 1 1 ? 1999';
        assertProblem(never, 'never fires');
    }

    @IsTest
    static void anUnknownTimeZoneIsRefused() {
        AJO_Job_Definition__mdt d = AJOTestFactory.runnable('BADTZ');
        d.AJO_TimeZone__c = 'Mars/Olympus_Mons';
        assertProblem(d, 'Time Zone');
        System.assert(AJODefinitionValidator.isValidTimeZone('America/New_York'));
        System.assert(!AJODefinitionValidator.isValidTimeZone(''));
    }

    @IsTest
    static void windowsAndNumbersAreBounded() {
        AJO_Job_Definition__mdt w = AJOTestFactory.runnable('WIN');
        w.AJO_StartDate__c = Date.today();
        w.AJO_EndDate__c = Date.today().addDays(-1);
        assertProblem(w, 'before Start Date');

        AJO_Job_Definition__mdt b = AJOTestFactory.definition('BIGSCOPE', 'AJODemoBatch', 'Batch');
        b.AJO_BatchSize__c = 5000;
        assertProblem(b, 'Batch Size');

        AJO_Job_Definition__mdt r = AJOTestFactory.runnable('RUNTIME');
        r.AJO_MaxRuntimeMinutes__c = 0;
        assertProblem(r, 'Max Runtime');

        AJO_Job_Definition__mdt f = AJOTestFactory.runnable('FAILS');
        f.AJO_MaxConsecutiveFailures__c = -1;
        assertProblem(f, 'Max Consecutive Failures');

        AJO_Job_Definition__mdt o = AJOTestFactory.runnable('OVERLAP');
        o.AJO_OverlapPolicy__c = 'Sometimes';
        assertProblem(o, 'Overlap Policy');
    }

    @IsTest
    static void parametersMustBeAJsonObject() {
        AJO_Job_Definition__mdt notJson = AJOTestFactory.runnable('PJ1');
        notJson.AJO_Parameters__c = '{not json';
        assertProblem(notJson, 'not valid JSON');

        AJO_Job_Definition__mdt array = AJOTestFactory.runnable('PJ2');
        array.AJO_Parameters__c = '[1,2,3]';
        assertProblem(array, 'JSON object');
    }

    @IsTest
    static void calloutsAndEmailsAreChecked() {
        AJO_Job_Definition__mdt c = AJOTestFactory.definition('CALL', 'AJODemoBatch', 'Batch');
        c.AJO_AllowsCallouts__c = true;
        assertProblem(c, 'Allows Callouts');

        AJO_Job_Definition__mdt e = AJOTestFactory.runnable('MAIL');
        e.AJO_NotifyEmails__c = 'ops@example.com, not-an-address';
        assertProblem(e, 'not-an-address');
        System.assertEquals(2, AJODefinitionValidator.splitEmails('a@b.co; c@d.co').size());
    }

    @IsTest
    static void dependenciesMustExistAndNotLoop() {
        AJO_Job_Definition__mdt self = AJOTestFactory.runnable('SELF');
        self.AJO_DependsOn__c = 'SELF';
        assertProblem(self, 'itself');

        AJO_Job_Definition__mdt orphan = AJOTestFactory.runnable('ORPHAN');
        orphan.AJO_DependsOn__c = 'NOT_DEPLOYED';
        assertProblem(orphan, 'not a deployed definition');

        AJO_Job_Definition__mdt a = AJOTestFactory.runnable('CYCLE_A');
        AJO_Job_Definition__mdt b = AJOTestFactory.runnable('CYCLE_B');
        a.AJO_DependsOn__c = 'CYCLE_B';
        b.AJO_DependsOn__c = 'CYCLE_A';
        Map<String, AJO_Job_Definition__mdt> both = defs(a);
        both.put(b.DeveloperName, b);
        String joined = String.join(AJODefinitionValidator.validate(a, both), ' | ');
        System.assert(joined.contains('cycle'), joined);

        AJO_Job_Definition__mdt after = AJOTestFactory.runnable('AFTER');
        after.AJO_RunAfterDependency__c = true;
        assertProblem(after, 'Depends On is blank');
    }

    @IsTest
    static void validateAllReportsOnlyTheInvalid() {
        AJO_Job_Definition__mdt good = AJOTestFactory.runnable('OK1');
        AJO_Job_Definition__mdt bad = AJOTestFactory.runnable('BAD1');
        bad.AJO_CronExpression__c = 'nonsense';
        Map<String, AJO_Job_Definition__mdt> all = defs(good);
        all.put(bad.DeveloperName, bad);
        Map<String, List<String>> problems = AJODefinitionValidator.validateAll(all);
        System.assertEquals(new Set<String>{ 'BAD1' }, problems.keySet());
    }

    // ---------------------------------------------------------------- helpers

    private static Map<String, AJO_Job_Definition__mdt> defs(AJO_Job_Definition__mdt d) {
        return new Map<String, AJO_Job_Definition__mdt>{ d.DeveloperName => d };
    }

    private static void assertValid(AJO_Job_Definition__mdt d) {
        List<String> p = AJODefinitionValidator.validate(d, defs(d));
        System.assert(p.isEmpty(), d.DeveloperName + ' should be valid: ' + String.join(p, ' | '));
    }

    private static void assertProblem(AJO_Job_Definition__mdt d, String fragment) {
        String joined = String.join(AJODefinitionValidator.validate(d, defs(d)), ' | ');
        System.assert(joined.containsIgnoreCase(fragment),
            d.DeveloperName + ' should report "' + fragment + '" but reported: ' + joined);
    }
}
