/**
 * Turns a job into the custom metadata record file that defines it, ready to
 * commit under force-app/main/default/customMetadata/ and deploy.
 *
 * This is how work that used to be a click in production now becomes a
 * release: the console generates the file (for a new job, an existing
 * unmanaged AJOJob__c being migrated, or a Setup schedule being taken over),
 * a developer commits it, the release deploys it, and the next heartbeat's
 * sync picks it up. Nothing here writes to the org.
 */
public inherited sharing class AJODefinitionExporter {

    public class DefinitionFile {
        @AuraEnabled public String developerName;
        @AuraEnabled public String fileName;
        @AuraEnabled public String xml;
        /** Validation problems against the current org; empty means deployable. */
        @AuraEnabled public List<String> problems;
    }

    /** A definition file from an existing AJOJob__c (used to migrate unmanaged jobs). */
    public static DefinitionFile fromJob(AJOJob__c j) {
        AJO_Job_Definition__mdt d = new AJO_Job_Definition__mdt(
            DeveloperName                 = developerName(j.AJO_JobKey__c, j.Name),
            MasterLabel                   = String.isBlank(j.Name) ? j.AJO_JobKey__c : j.Name.left(40),
            AJO_Active__c                 = j.AJO_Enabled__c == true,
            AJO_ApexClass__c              = j.AJO_ApexClassName__c,
            AJO_ExecutionType__c          = j.AJO_ExecutionType__c,
            AJO_CronExpression__c         = j.AJO_CronExpression__c,
            AJO_TimeZone__c               = j.AJO_TimeZoneSidKey__c,
            AJO_BatchSize__c              = j.AJO_BatchSize__c,
            AJO_Parameters__c             = j.AJO_Parameters__c,
            AJO_OverlapPolicy__c          = j.AJO_OverlapPolicy__c,
            AJO_Priority__c               = j.AJO_Priority__c,
            AJO_MaxRuntimeMinutes__c      = j.AJO_MaxRuntimeMinutes__c,
            AJO_MaxConsecutiveFailures__c = j.AJO_MaxConsecutiveFailures__c,
            AJO_StartDate__c              = j.AJO_StartDate__c,
            AJO_EndDate__c                = j.AJO_EndDate__c,
            AJO_DryRun__c                 = j.AJO_DryRun__c == true,
            AJO_AllowsCallouts__c         = false,
            AJO_RunAfterDependency__c     = false,
            AJO_NotifyEmails__c           = j.AJO_NotifyEmails__c,
            AJO_Description__c            = j.AJO_Description__c);
        return toFile(d);
    }

    /**
     * A definition file that takes over a Setup scheduled job. It ships in Dry
     * Run with Replaces Setup Job set: once deployed and active, the first sync
     * aborts the Setup job in the same transaction that creates the state, so
     * the job never runs twice or not at all. Turn Dry Run off in a later
     * release once a cycle looks right.
     */
    public static DefinitionFile fromSetupSchedule(String setupName, String className,
                                                   String executionType, String cron,
                                                   String timeZone) {
        AJO_Job_Definition__mdt d = new AJO_Job_Definition__mdt(
            DeveloperName                 = developerName(null, setupName),
            MasterLabel                   = setupName.left(40),
            AJO_Active__c                 = true,
            AJO_ApexClass__c              = className,
            AJO_ExecutionType__c          = executionType,
            AJO_CronExpression__c         = cron,
            AJO_TimeZone__c               = timeZone,
            AJO_OverlapPolicy__c          = 'Skip',
            AJO_Priority__c               = 5,
            AJO_MaxRuntimeMinutes__c      = 60,
            AJO_MaxConsecutiveFailures__c = 3,
            AJO_DryRun__c                 = true,
            AJO_AllowsCallouts__c         = false,
            AJO_RunAfterDependency__c     = false,
            AJO_ReplacesCronJobName__c    = setupName,
            AJO_Description__c            = 'Takes over the Setup scheduled job "' + setupName
                + '". Generated ' + Date.today().format() + '. Values passed to the class when it '
                + 'was scheduled cannot be recovered, so it runs with its own defaults; it ships in '
                + 'Dry Run for that reason.');
        return toFile(d);
    }

    /** Validates a definition and renders it as a CustomMetadata record file. */
    public static DefinitionFile toFile(AJO_Job_Definition__mdt d) {
        Map<String, AJO_Job_Definition__mdt> all = new Map<String, AJO_Job_Definition__mdt>(AJODefinitions.all());
        all.put(d.DeveloperName, d);

        DefinitionFile f = new DefinitionFile();
        f.developerName = d.DeveloperName;
        f.fileName      = 'AJO_Job_Definition.' + d.DeveloperName + '.md-meta.xml';
        f.problems      = AJODefinitionValidator.validate(d, all);

        List<String> v = new List<String>();
        v.add(val('AJO_Active__c', d.AJO_Active__c == true));
        v.add(val('AJO_AllowsCallouts__c', d.AJO_AllowsCallouts__c == true));
        v.add(val('AJO_ApexClass__c', d.AJO_ApexClass__c));
        v.add(val('AJO_BatchSize__c', d.AJO_BatchSize__c));
        v.add(val('AJO_CronExpression__c', d.AJO_CronExpression__c));
        v.add(val('AJO_DependsOn__c', d.AJO_DependsOn__c));
        v.add(val('AJO_Description__c', d.AJO_Description__c));
        v.add(val('AJO_DryRun__c', d.AJO_DryRun__c == true));
        v.add(val('AJO_EndDate__c', d.AJO_EndDate__c));
        v.add(val('AJO_ExecutionType__c', d.AJO_ExecutionType__c));
        v.add(val('AJO_MaxConsecutiveFailures__c', d.AJO_MaxConsecutiveFailures__c));
        v.add(val('AJO_MaxRuntimeMinutes__c', d.AJO_MaxRuntimeMinutes__c));
        v.add(val('AJO_NotifyEmails__c', d.AJO_NotifyEmails__c));
        v.add(val('AJO_OverlapPolicy__c', String.isBlank(d.AJO_OverlapPolicy__c) ? 'Skip' : d.AJO_OverlapPolicy__c));
        v.add(val('AJO_Parameters__c', d.AJO_Parameters__c));
        v.add(val('AJO_Priority__c', d.AJO_Priority__c));
        v.add(val('AJO_ReplacesCronJobName__c', d.AJO_ReplacesCronJobName__c));
        v.add(val('AJO_RunAfterDependency__c', d.AJO_RunAfterDependency__c == true));
        v.add(val('AJO_StartDate__c', d.AJO_StartDate__c));
        v.add(val('AJO_TimeZone__c', d.AJO_TimeZone__c));

        f.xml = '<?xml version="1.0" encoding="UTF-8"?>\n'
            + '<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata" '
            + 'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
            + 'xmlns:xsd="http://www.w3.org/2001/XMLSchema">\n'
            + '    <label>' + esc(d.MasterLabel) + '</label>\n'
            + '    <protected>false</protected>\n'
            + String.join(v, '\n') + '\n'
            + '</CustomMetadata>\n';
        return f;
    }

    /**
     * A valid custom metadata DeveloperName: letters, digits and single
     * underscores, starting with a letter, at most 40 characters.
     */
    public static String developerName(String key, String fallback) {
        String base = String.isNotBlank(key) ? key : (fallback == null ? 'JOB' : fallback);
        base = base.replaceAll('[^A-Za-z0-9]+', '_').replaceAll('_+', '_').replaceAll('^_|_$', '');
        if (String.isBlank(base)) { base = 'JOB'; }
        if (!Pattern.matches('^[A-Za-z].*', base)) { base = 'J_' + base; }
        base = base.left(40).replaceAll('_$', '');
        return base;
    }

    private static String val(String field, Object value) {
        if (value == null || (value instanceof String && String.isBlank((String) value))) {
            return '    <values>\n        <field>' + field + '</field>\n'
                + '        <value xsi:nil="true"/>\n    </values>';
        }
        String type = value instanceof Boolean ? 'xsd:boolean'
            : (value instanceof Decimal || value instanceof Integer) ? 'xsd:double'
            : value instanceof Date ? 'xsd:date' : 'xsd:string';
        String text = value instanceof Date ? String.valueOf((Date) value).left(10) : String.valueOf(value);
        return '    <values>\n        <field>' + field + '</field>\n'
            + '        <value xsi:type="' + type + '">' + esc(text) + '</value>\n    </values>';
    }

    private static String esc(String s) {
        return s == null ? '' : s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
            .replace('"', '&quot;');
    }
}
