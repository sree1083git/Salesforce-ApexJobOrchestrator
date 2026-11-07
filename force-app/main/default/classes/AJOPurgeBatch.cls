/**
 * Log retention. Deletes run records older than the retention windows
 * (AJO_RetentionDaysSuccess__c for successes and refusals, default 14 days;
 * AJO_RetentionDaysFailure__c for failures and time-outs, default 90) and
 * empties them from the recycle bin so they stop counting against storage.
 *
 * A batch rather than an inline delete: each chunk deletes at most SCOPE rows
 * and empties the same rows, 2 × SCOPE DML rows per transaction — far under the
 * 10,000-row limit — however large the backlog. Started by AJOSupervisor.
 */
public without sharing class AJOPurgeBatch implements Database.Batchable<SObject> {

    public static final Integer SCOPE = 2000;

    public Database.QueryLocator start(Database.BatchableContext bc) {
        Datetime okCutoff   = Datetime.now().addDays(-AJOConfig.retentionSuccessDays());
        Datetime failCutoff = Datetime.now().addDays(-AJOConfig.retentionFailureDays());
        return Database.getQueryLocator([
            SELECT Id
            FROM   AJOJobRun__c
            WHERE  (AJO_Status__c IN ('Success', 'Skipped', 'Dry Run', 'Throttled')
                        AND CreatedDate < :okCutoff)
               OR  (AJO_Status__c IN ('Failed', 'Stuck') AND CreatedDate < :failCutoff)
        ]);
    }

    public void execute(Database.BatchableContext bc, List<AJOJobRun__c> scope) {
        delete scope;
        Database.emptyRecycleBin(scope);
    }

    public void finish(Database.BatchableContext bc) {
        // Nothing to report; the console's health view shows the log size.
    }
}
