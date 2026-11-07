# Defining jobs

Every job is one `AJO_Job_Definition__mdt` record, stored in the repository at
`force-app/main/default/customMetadata/AJO_Job_Definition.<DeveloperName>.md-meta.xml`.
The `DeveloperName` is the job's permanent key (`AJOJob__c.AJO_JobKey__c`); renaming it creates a
new job and retires the old one.

## Fields

| Field | Required | Meaning |
| --- | --- | --- |
| Label (`MasterLabel`) | yes | Display name in the console (max 40). |
| `AJO_Active__c` | yes | Master switch. Inactive definitions keep their state but never run. |
| `AJO_ApexClass__c` | yes | Class to run; `ns.ClassName` for a namespaced class. Needs a public no-argument constructor. |
| `AJO_ExecutionType__c` | yes | `Runnable` (implements `AJORunnable`), `Batch`, `Queueable`, or `Legacy Schedulable`. |
| `AJO_CronExpression__c` | yes | `Seconds Minutes Hours Day-of-month Month Day-of-week [Year]`. `* ? , - /` and `JAN..DEC` / `SUN..SAT` supported; `L W #` are not. Minute precision (seconds are ignored). |
| `AJO_TimeZone__c` | no | IANA id, e.g. `America/New_York`. Blank = `AJOSetting__c.AJO_DefaultTimeZone__c`, else the org's default zone. |
| `AJO_BatchSize__c` | no | Scope for `Batch` (1–2000). Blank = 200. A Legacy Schedulable chooses its own. |
| `AJO_Parameters__c` | no | JSON object passed to a `Runnable` as `ctx.params`. |
| `AJO_OverlapPolicy__c` | no | When the previous occurrence is still queued/running: `Skip` (default) this occurrence, `Queue` (retry at next check), or `Allow` (run anyway). |
| `AJO_Priority__c` | no | Lower first when a check has more due jobs than it launches. |
| `AJO_MaxRuntimeMinutes__c` | no | After this a run is timed out and its async job aborted. Blank = 240. |
| `AJO_MaxConsecutiveFailures__c` | no | Circuit breaker threshold. Blank/0 = never suspend. |
| `AJO_DependsOn__c` | no | `DeveloperName` of a job that must have succeeded since this job last ran. |
| `AJO_RunAfterDependency__c` | no | Start this job at the check after its dependency succeeds, instead of waiting for its own cron. |
| `AJO_StartDate__c` / `AJO_EndDate__c` | no | Activation window, inclusive. A ten-day data fix: start today, end today + 9. |
| `AJO_DryRun__c` | no | Records what would run, launches nothing. Use for every new job's first release. |
| `AJO_AllowsCallouts__c` | no | `Runnable` makes HTTP callouts; the executor skips its savepoint. |
| `AJO_NotifyEmails__c` | no | Addresses alerted when this job fails or is suspended. |
| `AJO_ReplacesCronJobName__c` | no | Name of a Setup scheduled job this definition takes over (see MIGRATION.md). |
| `AJO_Description__c` | no | What it does and who owns it. |

## Example

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata"
                xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <label>Nightly opportunity closer</label>
    <protected>false</protected>
    <values><field>AJO_Active__c</field><value xsi:type="xsd:boolean">true</value></values>
    <values><field>AJO_ApexClass__c</field><value xsi:type="xsd:string">OpportunityCloserBatch</value></values>
    <values><field>AJO_ExecutionType__c</field><value xsi:type="xsd:string">Batch</value></values>
    <values><field>AJO_CronExpression__c</field><value xsi:type="xsd:string">0 30 2 * * ?</value></values>
    <values><field>AJO_TimeZone__c</field><value xsi:type="xsd:string">America/New_York</value></values>
    <values><field>AJO_BatchSize__c</field><value xsi:type="xsd:double">200</value></values>
    <values><field>AJO_MaxConsecutiveFailures__c</field><value xsi:type="xsd:double">3</value></values>
    <values><field>AJO_NotifyEmails__c</field><value xsi:type="xsd:string">crm-oncall@example.com</value></values>
    <values><field>AJO_DryRun__c</field><value xsi:type="xsd:boolean">false</value></values>
</CustomMetadata>
```

Omitted fields are blank. The console's **Generate definition** produces a complete file.

## Writing a Runnable

```apex
public with sharing class OpportunityCloser implements AJORunnable {
    public void run(AJOContext ctx) {
        Integer days = ctx.getInteger('olderThanDays', 30);
        // ... do the work ...
        ctx.itemsProcessed = 120;
        ctx.itemsFailed    = 0;
        ctx.message        = 'Closed 120 opportunities older than ' + days + ' days.';

        // Starting a batch? Hand its id back and the run stays open until it finishes:
        // ctx.asyncJobId = Database.executeBatch(new CloserBatch(days), ctx.configuredBatchSize);
    }
}
```

- Throwing marks the run Failed and rolls back the job's writes (unless `Allows Callouts`).
- `ctx.jobKey`, `ctx.scheduledFor`, `ctx.triggeredBy` describe the run; `ctx.params` is the parsed JSON.
- A batch can close its run with real record counts from `finish()`:
  `AJORunLogger.report(bc.getJobId(), processed, failed, 'summary');`

## Validation

`AJODefinitionValidator` checks: execution type; class exists, constructs, and implements what the
type needs; cron parses and fires within the horizon; time zone is real; window ordered; batch size
1–2000; positive runtime; non-negative failure limit; parameters are a JSON object; callouts only on
Runnable; email format; dependency exists, is not itself, and forms no cycle; Run After Dependency
has a dependency.

The same rules run in `AJODefinitionValidationTest.deployedDefinitionsAreAllValid` (fails the
deployment) and in the sync (an invalid definition's state goes to `Invalid` with the reasons, never
runs, and raises `DEFINITION_INVALID`).
