/**
 * Operator alerts. Every condition a person must act on is raised here:
 *
 *   JOB_FAILED           a run failed (only emailed when the job has Notify Emails)
 *   JOB_SUSPENDED        the circuit breaker switched a job off
 *   DEFINITION_INVALID   a deployed definition failed validation and cannot run
 *   DEFINITION_RETIRED   a definition was removed; its state was retired
 *   CUTOVER_DONE         a Setup schedule was aborted and its job taken over
 *   CUTOVER_FAILED       the takeover could not complete; nothing changed
 *   HEARTBEAT_STALE      no scheduled check has run for too long
 *   SLOTS_REARMED        a missing heartbeat or the supervisor was re-created
 *   SYNC_FAILED          definition sync threw and was rolled back
 *   MAINTENANCE_FAILED   a supervisor step threw
 *
 * Alerts go out two ways:
 *   - an AJO_Alert__e platform event (publish-immediately, so it survives a
 *     rollback of the transaction that raised it). Subscribe from Flow, a
 *     trigger, or the Pub/Sub API to route into Slack, Datadog, PagerDuty.
 *   - an email for WARNING/ERROR to the framework digest address and to the
 *     job's Notify Emails, when either is set.
 *
 * Alerts are buffered and sent once per transaction by flush(), so a check
 * that raises twenty alerts spends one publish and at most one email call.
 */
public without sharing class AJOAlerts {

    public static final String INFO = 'INFO';
    public static final String WARNING = 'WARNING';
    public static final String ERROR = 'ERROR';

    public class Alert {
        public String severity;
        public String code;
        public String jobKey;
        public String message;
        public List<String> recipients = new List<String>();
    }

    @TestVisible
    private static List<Alert> pending = new List<Alert>();
    /** What flush() actually sent in this transaction; tests assert on it. */
    @TestVisible
    private static List<Alert> sent = new List<Alert>();
    private static Set<String> seen = new Set<String>();

    /** Queues an alert. Duplicate code+job pairs in one transaction are dropped. */
    public static void raise(String severity, String code, String jobKey, String message,
                             String notifyEmails) {
        String dedupe = code + '|' + jobKey;
        if (seen.contains(dedupe)) { return; }
        seen.add(dedupe);

        Alert a = new Alert();
        a.severity = severity;
        a.code     = code;
        a.jobKey   = jobKey;
        a.message  = message == null ? '' : message.abbreviate(32000);
        a.recipients.addAll(AJODefinitionValidator.splitEmails(notifyEmails));
        pending.add(a);
    }

    public static void raise(String severity, String code, String jobKey, String message) {
        raise(severity, code, jobKey, message, null);
    }

    /**
     * Sends everything queued. Safe to call repeatedly and never throws: an
     * alert that cannot be delivered must not fail the work that raised it.
     */
    public static void flush() {
        if (pending.isEmpty()) { return; }
        List<Alert> batch = pending;
        pending = new List<Alert>();

        try {
            List<AJO_Alert__e> events = new List<AJO_Alert__e>();
            for (Alert a : batch) {
                events.add(new AJO_Alert__e(
                    Severity__c = a.severity,
                    Code__c     = a.code,
                    JobKey__c   = a.jobKey == null ? null : a.jobKey.left(80),
                    Message__c  = a.message));
            }
            EventBus.publish(events);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AJO could not publish alerts: ' + e.getMessage());
        }

        try {
            sendEmails(batch);
        } catch (Exception e) {
            // Daily single-email limits, deliverability settings, invalid addresses.
            System.debug(LoggingLevel.ERROR, 'AJO could not email alerts: ' + e.getMessage());
        }
        sent.addAll(batch);
    }

    private static void sendEmails(List<Alert> batch) {
        List<String> digest = AJODefinitionValidator.splitEmails(AJOConfig.digestEmail());
        List<Messaging.SingleEmailMessage> mails = new List<Messaging.SingleEmailMessage>();
        for (Alert a : batch) {
            if (a.severity == INFO) { continue; }
            Set<String> to = new Set<String>(digest);
            to.addAll(a.recipients);
            if (to.isEmpty()) { continue; }
            Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
            m.setToAddresses(new List<String>(to));
            m.setSubject('[AJO ' + a.severity + '] ' + a.code
                + (String.isBlank(a.jobKey) ? '' : ' - ' + a.jobKey));
            m.setPlainTextBody(a.message + '\n\nOrg: ' + UserInfo.getOrganizationName()
                + ' (' + UserInfo.getOrganizationId() + ')');
            m.setSaveAsActivity(false);
            mails.add(m);
        }
        if (mails.isEmpty()) { return; }
        Messaging.reserveSingleEmailCapacity(mails.size());
        Messaging.sendEmail(mails, false);
    }
}
