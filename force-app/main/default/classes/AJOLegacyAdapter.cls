/**
 * Runs an existing Apex class without changing it.
 *
 * Interface order matters. In the source production org ten classes implement BOTH
 * Schedulable and Database.Batchable, and their execute(SchedulableContext)
 * chooses its own scope size. Testing Batchable first would silently override
 * that choice, so Schedulable is checked first — exactly reproducing what the
 * platform's CronTrigger did.
 *
 * Passing null as the SchedulableContext is safe here: all 89 Schedulable
 * implementations in the source org were checked and none dereferences it.
 */
public inherited sharing class AJOLegacyAdapter {

    public class UnsupportedJobException extends Exception {}

    public class Outcome {
        public Id asyncJobId;
        public String mode;
        /**
          * The scope genuinely passed to Database.executeBatch, which is not the
          * same thing as the job's configured Records Per Batch: a legacy
          * Schedulable chooses its own and the configured value is ignored.
          * Null when this launch started no batch at all.
          */
        public Integer scopeUsed;

        public Outcome(Id asyncJobId, String mode) {
            this(asyncJobId, mode, null);
        }
        public Outcome(Id asyncJobId, String mode, Integer scopeUsed) {
            this.asyncJobId = asyncJobId;
            this.mode = mode;
            this.scopeUsed = scopeUsed;
        }
    }

    /** The scope a batch launch will really use: the configured value, or 200. */
    public static Integer effectiveScope(Integer scope) {
        return (scope == null || scope <= 0) ? 200 : scope;
    }

    public static Outcome run(String className, String executionType, Integer scope) {
        Object instance = instantiate(className);

        if (executionType == 'Runnable') {
            throw new UnsupportedJobException(
                'Runnable jobs are launched by AJOLauncher, not the legacy adapter.');
        }

        if (executionType == 'Batch') {
            if (!(instance instanceof Database.Batchable<SObject>)) {
                throw new UnsupportedJobException(
                    className + ' is configured as Batch but does not implement '
                    + 'Database.Batchable<SObject>.');
            }
            Integer used = effectiveScope(scope);
            Id jid = Database.executeBatch((Database.Batchable<SObject>) instance, used);
            return new Outcome(jid, 'Batch', used);
        }

        if (executionType == 'Queueable') {
            if (!(instance instanceof Queueable)) {
                throw new UnsupportedJobException(
                    className + ' is configured as Queueable but does not implement Queueable.');
            }
            return new Outcome(System.enqueueJob((Queueable) instance), 'Queueable');
        }

        // 'Legacy Schedulable' — and the fallback when nothing was specified.
        if (instance instanceof Schedulable) {
            ((Schedulable) instance).execute(null);
            return new Outcome(null, 'Schedulable');
        }
        if (instance instanceof Database.Batchable<SObject>) {
            Integer used = effectiveScope(scope);
            Id jid = Database.executeBatch((Database.Batchable<SObject>) instance, used);
            return new Outcome(jid, 'Batch', used);
        }
        if (instance instanceof Queueable) {
            return new Outcome(System.enqueueJob((Queueable) instance), 'Queueable');
        }
        throw new UnsupportedJobException(
            className + ' implements none of Schedulable, Batchable or Queueable.');
    }

    public static Object instantiate(String className) {
        if (String.isBlank(className)) {
            throw new UnsupportedJobException('No Apex class configured on this job.');
        }
        Type t = Type.forName(className);
        if (t == null && className.contains('.')) {
            List<String> parts = className.split('\\.');
            t = Type.forName(parts[0], parts[1]);
        }
        if (t == null) {
            throw new UnsupportedJobException('Apex class not found: ' + className);
        }
        try {
            return t.newInstance();
        } catch (Exception e) {
            throw new UnsupportedJobException(
                'Cannot instantiate ' + className
                + '. It needs a public no-argument constructor. ' + e.getMessage());
        }
    }

    /** Used by the console to validate a class name before the record is saved. */
    public static String classify(String className) {
        Object o;
        try {
            o = instantiate(className);
        } catch (Exception e) {
            return null;
        }
        if (o instanceof AJORunnable)               { return 'Runnable'; }
        if (o instanceof Schedulable)               { return 'Legacy Schedulable'; }
        if (o instanceof Database.Batchable<SObject>) { return 'Batch'; }
        if (o instanceof Queueable)                 { return 'Queueable'; }
        return null;
    }
}