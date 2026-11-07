/**
 * DEPRECATED — superseded by AJOJobExecutor. Kept only so that queueables of
 * this class already waiting in the platform queue at deployment time can
 * still deserialize and run. Nothing in the framework enqueues it any more.
 *
 * It delegates to the executor with no pre-opened run, which keeps the old
 * semantics: every re-check (pause, window, suspension, ownership of the
 * occurrence) happens first, and a run record is opened only if the job
 * really starts. Safe to delete one release after the upgrade, once no
 * AJODeferredRunner jobs remain in AsyncApexJob.
 */
public without sharing class AJODeferredRunner implements Queueable {

    private final Id jobId;
    private final Datetime dueAt;

    public AJODeferredRunner(Id jobId, Datetime dueAt) {
        this.jobId = jobId;
        this.dueAt = dueAt;
    }

    public void execute(QueueableContext qc) {
        new AJOJobExecutor(jobId, null, dueAt).execute(qc);
    }
}
