/**
 * Validates job definitions. Used in two places, deliberately the same code:
 *
 *   1. AJODefinitionSync refuses an invalid definition at runtime (the state
 *      record goes to 'Invalid' with the reasons, and an alert is raised), so
 *      a bad row can never launch.
 *   2. AJODefinitionValidationTest runs it over every DEPLOYED record, so a
 *      typo — a misspelt class, a cron that never fires, a dependency on a job
 *      that does not exist — fails the deployment instead of failing silently
 *      at 2 a.m. That is the main reason definitions live in custom metadata.
 */
public inherited sharing class AJODefinitionValidator {

    public static final Set<String> EXECUTION_TYPES =
        new Set<String>{ 'Runnable', 'Batch', 'Queueable', 'Legacy Schedulable' };
    public static final Set<String> OVERLAP_POLICIES =
        new Set<String>{ 'Skip', 'Queue', 'Allow' };

    /** DeveloperName -> problems. A definition absent from the map is valid. */
    public static Map<String, List<String>> validateAll(Map<String, AJO_Job_Definition__mdt> defs) {
        Map<String, List<String>> out = new Map<String, List<String>>();
        for (AJO_Job_Definition__mdt d : defs.values()) {
            List<String> problems = validate(d, defs);
            if (!problems.isEmpty()) { out.put(d.DeveloperName, problems); }
        }
        return out;
    }

    /** Every reason this definition cannot run. Empty means valid. */
    public static List<String> validate(AJO_Job_Definition__mdt d,
                                        Map<String, AJO_Job_Definition__mdt> all) {
        List<String> p = new List<String>();

        // ---- what runs --------------------------------------------------
        if (!EXECUTION_TYPES.contains(d.AJO_ExecutionType__c)) {
            p.add('Execution Type "' + d.AJO_ExecutionType__c + '" is not one of '
                + String.join(new List<String>(EXECUTION_TYPES), ', ') + '.');
        }
        String classProblem = checkClass(d.AJO_ApexClass__c, d.AJO_ExecutionType__c);
        if (classProblem != null) { p.add(classProblem); }

        // ---- when it runs -------------------------------------------------
        String tz = String.isBlank(d.AJO_TimeZone__c) ? AJOConfig.defaultTimeZone() : d.AJO_TimeZone__c;
        if (!isValidTimeZone(tz)) {
            p.add('Time Zone "' + tz + '" is not a recognised time zone id.');
        }
        try {
            AJOCron.parse(d.AJO_CronExpression__c);
            if (isValidTimeZone(tz)
                && AJOCron.next(d.AJO_CronExpression__c, Datetime.now(), tz) == null) {
                p.add('Cron Expression "' + d.AJO_CronExpression__c
                    + '" never fires within the evaluation horizon.');
            }
        } catch (Exception e) {
            p.add('Cron Expression is not valid: ' + e.getMessage());
        }
        if (d.AJO_StartDate__c != null && d.AJO_EndDate__c != null
            && d.AJO_EndDate__c < d.AJO_StartDate__c) {
            p.add('End Date ' + d.AJO_EndDate__c + ' is before Start Date ' + d.AJO_StartDate__c + '.');
        }

        // ---- how it runs ------------------------------------------------
        if (String.isNotBlank(d.AJO_OverlapPolicy__c) && !OVERLAP_POLICIES.contains(d.AJO_OverlapPolicy__c)) {
            p.add('Overlap Policy "' + d.AJO_OverlapPolicy__c + '" is not Skip, Queue or Allow.');
        }
        if (d.AJO_BatchSize__c != null && (d.AJO_BatchSize__c < 1 || d.AJO_BatchSize__c > 2000)) {
            p.add('Batch Size must be between 1 and 2000.');
        }
        if (d.AJO_MaxRuntimeMinutes__c != null && d.AJO_MaxRuntimeMinutes__c <= 0) {
            p.add('Max Runtime Minutes must be positive.');
        }
        if (d.AJO_MaxConsecutiveFailures__c != null && d.AJO_MaxConsecutiveFailures__c < 0) {
            p.add('Max Consecutive Failures cannot be negative.');
        }
        if (String.isNotBlank(d.AJO_Parameters__c)) {
            try {
                if (!(JSON.deserializeUntyped(d.AJO_Parameters__c) instanceof Map<String, Object>)) {
                    p.add('Parameters must be a JSON object, e.g. {"key":"value"}.');
                }
            } catch (Exception e) {
                p.add('Parameters are not valid JSON: ' + e.getMessage());
            }
        }
        if (d.AJO_AllowsCallouts__c == true && d.AJO_ExecutionType__c != 'Runnable') {
            p.add('Allows Callouts applies to Runnable jobs only; a Batch or Queueable declares '
                + 'Database.AllowsCallouts on its own class.');
        }
        for (String email : splitEmails(d.AJO_NotifyEmails__c)) {
            if (!Pattern.matches('^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$', email)) {
                p.add('Notify Emails contains an invalid address: ' + email);
            }
        }

        // ---- dependencies -------------------------------------------------
        if (String.isNotBlank(d.AJO_DependsOn__c)) {
            if (d.AJO_DependsOn__c == d.DeveloperName) {
                p.add('A job cannot depend on itself.');
            } else if (all == null || !all.containsKey(d.AJO_DependsOn__c)) {
                p.add('Depends On "' + d.AJO_DependsOn__c + '" is not a deployed definition.');
            } else if (hasCycle(d.DeveloperName, all)) {
                p.add('Depends On forms a cycle: ' + describeChain(d.DeveloperName, all) + '.');
            }
        } else if (d.AJO_RunAfterDependency__c == true) {
            p.add('Run After Dependency is set but Depends On is blank.');
        }
        return p;
    }

    /**
     * Null when the class exists, can be constructed, and implements what the
     * execution type needs; otherwise the reason. Public so the console can
     * reuse it when it previews a generated definition.
     */
    public static String checkClass(String className, String executionType) {
        if (String.isBlank(className)) { return 'Apex Class is blank.'; }
        Object o;
        try {
            o = AJOLegacyAdapter.instantiate(className);
        } catch (Exception e) {
            return e.getMessage();
        }
        Boolean ok;
        switch on executionType {
            when 'Runnable'  { ok = o instanceof AJORunnable; }
            when 'Batch'     { ok = o instanceof Database.Batchable<SObject>; }
            when 'Queueable' { ok = o instanceof Queueable; }
            when 'Legacy Schedulable' {
                ok = o instanceof Schedulable || o instanceof Database.Batchable<SObject>
                     || o instanceof Queueable;
            }
            when else { return null; } // the execution type error is reported separately
        }
        return ok ? null
            : 'Apex class "' + className + '" does not implement what Execution Type "'
              + executionType + '" needs.';
    }

    /** TimeZone.getTimeZone falls back to GMT for an unknown id instead of failing. */
    public static Boolean isValidTimeZone(String tzId) {
        if (String.isBlank(tzId)) { return false; }
        TimeZone t = TimeZone.getTimeZone(tzId);
        return t != null && t.getID() == tzId;
    }

    public static List<String> splitEmails(String raw) {
        List<String> out = new List<String>();
        if (String.isBlank(raw)) { return out; }
        for (String s : raw.split('[,;\\s]+')) {
            if (String.isNotBlank(s)) { out.add(s.trim()); }
        }
        return out;
    }

    private static Boolean hasCycle(String start, Map<String, AJO_Job_Definition__mdt> all) {
        Set<String> seen = new Set<String>{ start };
        String cur = all.get(start).AJO_DependsOn__c;
        while (String.isNotBlank(cur) && all.containsKey(cur)) {
            if (seen.contains(cur)) { return true; }
            seen.add(cur);
            cur = all.get(cur).AJO_DependsOn__c;
        }
        return false;
    }

    private static String describeChain(String start, Map<String, AJO_Job_Definition__mdt> all) {
        List<String> chain = new List<String>{ start };
        Set<String> seen = new Set<String>{ start };
        String cur = all.get(start).AJO_DependsOn__c;
        while (String.isNotBlank(cur) && all.containsKey(cur) && chain.size() < 20) {
            chain.add(cur);
            if (seen.contains(cur)) { break; }
            seen.add(cur);
            cur = all.get(cur).AJO_DependsOn__c;
        }
        return String.join(chain, ' -> ');
    }
}
