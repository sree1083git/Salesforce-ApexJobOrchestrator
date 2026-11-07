/**
 * Batch capacity guard.
 *
 * Two different platform limits matter and the old version conflated them:
 *
 *   - ACTIVE batches (Queued, Preparing, Processing): the platform runs five
 *     at a time. The framework holds its own batches back once that many are
 *     active (AJO_MaxConcurrentBatches__c), rather than piling more in.
 *   - The FLEX QUEUE (status Holding) holds up to 100 waiting batches; once it
 *     is full, Database.executeBatch throws. The framework holds back while it
 *     is at or over AJO_FlexQueueCap__c (default 90).
 *
 * Counting Holding batches against the five-active ceiling — as before — let
 * a managed package parking batches in the flex queue starve every framework
 * batch indefinitely, re-logging "Throttled" every ten minutes.
 *
 * Only Batch jobs consume capacity. A Legacy Schedulable that starts a batch
 * internally is invisible here; register the batch class directly to have it
 * governed.
 */
public inherited sharing class AJOThrottle {

    private Integer batchBudget;

    public AJOThrottle() {
        this.batchBudget = availableBatchSlots();
    }

    /** Batches competing for the platform's five active slots. */
    public static Integer inFlightBatches() {
        return [
            SELECT COUNT()
            FROM   AsyncApexJob
            WHERE  JobType = 'BatchApex'
              AND  Status IN ('Queued', 'Preparing', 'Processing')
        ];
    }

    /** Batches waiting in the Apex flex queue. */
    public static Integer flexQueueDepth() {
        return [
            SELECT COUNT()
            FROM   AsyncApexJob
            WHERE  JobType = 'BatchApex' AND Status = 'Holding'
        ];
    }

    /** How many more framework batches may start now. */
    public static Integer availableBatchSlots() {
        if (flexQueueDepth() >= AJOConfig.flexQueueCap()) { return 0; }
        return Math.max(0, AJOConfig.maxConcurrentBatches() - inFlightBatches());
    }

    /** True when this job may start now. Consumes budget for batch work only. */
    public Boolean claim(AJOJob__c job) {
        if (job.AJO_ExecutionType__c != 'Batch') { return true; }
        if (batchBudget <= 0) { return false; }
        batchBudget--;
        return true;
    }

    public Integer remaining() { return batchBudget; }
}
