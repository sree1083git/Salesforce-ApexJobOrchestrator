/**
 * Demonstrates (and lets tests prove) the executor's savepoint: this Runnable
 * writes a record and then fails. The executor rolls the write back before it
 * records the failure, so a failed run never leaves half its work behind.
 * Its parameter "marker" names the AJO_JobKey__c of the record it writes.
 */
public with sharing class AJODemoPartialFailJob implements AJORunnable {

    public class PartialFailureException extends Exception {}

    public void run(AJOContext ctx) {
        insert new AJOJob__c(
            Name                  = 'Partial work that must be rolled back',
            AJO_JobKey__c         = ctx.getString('marker', 'PARTIAL_FAIL_MARKER'),
            AJO_ApexClassName__c  = 'AJODemoRunnable',
            AJO_ExecutionType__c  = 'Runnable',
            AJO_CronExpression__c = '0 0 0 * * ?',
            AJO_Enabled__c        = false);
        throw new PartialFailureException('Failed after writing; the write must not survive.');
    }
}
