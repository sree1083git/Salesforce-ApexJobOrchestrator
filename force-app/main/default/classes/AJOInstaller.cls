/**
 * Arms, disarms and heals the framework's permanent scheduled-Apex slots:
 * six heartbeats plus one supervisor — seven registrations, whatever the job
 * count.
 *
 * Self-healing: every heartbeat and the supervisor call healSafely(), which
 * re-creates any of the seven that went missing (aborted by hand, lost in a
 * sandbox refresh, removed by a deployment). The checks therefore heal each
 * other every ten minutes; a lone survivor rebuilds the rest. Healing only
 * happens while the framework is installed (at least one registration still
 * exists), so a deliberate uninstall stays uninstalled.
 *
 * Runs without sharing: framework infrastructure.
 */
public without sharing class AJOInstaller {

    public static final String HEARTBEAT_PREFIX = 'AJO Heartbeat ';
    public static final String SUPERVISOR_NAME  = 'AJO Supervisor';
    /**
     * Hourly at :05. Was daily at 02:05, which meant a total heartbeat outage
     * could go unhealed and unreported for up to a day.
     */
    public static final String SUPERVISOR_CRON  = '0 5 * * * ?';

    public static List<Integer> slots() {
        List<Integer> out = new List<Integer>();
        Integer step = AJOConfig.heartbeatMinutes();
        for (Integer m = 0; m < 60; m += step) { out.add(m); }
        return out;
    }

    public static String heartbeatName(Integer minute) {
        return HEARTBEAT_PREFIX + (minute < 10 ? '0' : '') + minute;
    }

    /** Schedules every heartbeat plus the supervisor. Idempotent. */
    public static List<String> arm() {
        List<String> armed = new List<String>();
        Map<String, CronTrigger> existing = scheduledByName();

        for (Integer m : slots()) {
            String nm = heartbeatName(m);
            if (existing.containsKey(nm)) { continue; }
            System.schedule(nm, '0 ' + m + ' * * * ?', new AJODispatcher(m));
            armed.add(nm);
        }
        CronTrigger sup = existing.get(SUPERVISOR_NAME);
        if (sup != null && sup.CronExpression != SUPERVISOR_CRON) {
            // An install from before the supervisor went hourly: move it.
            System.abortJob(sup.Id);
            sup = null;
        }
        if (sup == null) {
            System.schedule(SUPERVISOR_NAME, SUPERVISOR_CRON, new AJOSupervisor());
            armed.add(SUPERVISOR_NAME);
        }
        return armed;
    }

    /**
     * Re-creates whatever is missing, if the framework is installed at all.
     * Returns how many registrations were created (0 when nothing was missing,
     * -1 when healing failed). Never throws, and alerts when it acted.
     */
    public static Integer healSafely() {
        try {
            Map<String, CronTrigger> existing = scheduledByName();
            if (existing.isEmpty()) { return 0; } // uninstalled on purpose
            Integer expected = slots().size() + 1;
            Boolean supervisorCurrent = existing.containsKey(SUPERVISOR_NAME)
                && existing.get(SUPERVISOR_NAME).CronExpression == SUPERVISOR_CRON;
            if (existing.size() >= expected && supervisorCurrent) { return 0; }

            List<String> armed = arm();
            if (!armed.isEmpty()) {
                AJOAlerts.raise(AJOAlerts.WARNING, 'SLOTS_REARMED', null,
                    'Re-created missing scheduled checks: ' + String.join(armed, ', ') + '.');
            }
            return armed.size();
        } catch (Exception e) {
            AJOAlerts.raise(AJOAlerts.ERROR, 'SLOTS_REARMED', null,
                'Could not re-create missing scheduled checks: ' + e.getMessage());
            return -1;
        }
    }

    /** Kept for callers of the previous API. */
    public static Integer rearmMissing() {
        try { return arm().size(); } catch (Exception e) { return -1; }
    }

    public static List<String> disarm() {
        List<String> removed = new List<String>();
        for (CronTrigger ct : ownTriggers()) {
            System.abortJob(ct.Id);
            removed.add(ct.CronJobDetail.Name);
        }
        return removed;
    }

    public static List<CronTrigger> ownTriggers() {
        String pattern = HEARTBEAT_PREFIX + '%';
        String supervisor = SUPERVISOR_NAME;
        return [
            SELECT Id, CronExpression, State, NextFireTime, PreviousFireTime,
                   TimesTriggered, CronJobDetail.Name
            FROM   CronTrigger
            WHERE  CronJobDetail.JobType = '7'
              AND  (CronJobDetail.Name LIKE :pattern
                    OR CronJobDetail.Name = :supervisor)
            ORDER BY CronJobDetail.Name
        ];
    }

    private static Map<String, CronTrigger> scheduledByName() {
        Map<String, CronTrigger> m = new Map<String, CronTrigger>();
        for (CronTrigger ct : ownTriggers()) {
            m.put(ct.CronJobDetail.Name, ct);
        }
        return m;
    }

    /** The number this whole project exists to reduce. */
    public static Integer scheduledApexSlotsUsed() {
        return [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.JobType = '7'];
    }

    /** Seeds sensible defaults so a fresh org works without Setup clicks. */
    public static AJOSetting__c ensureSettings() {
        AJOSetting__c s = AJOSetting__c.getOrgDefaults();
        Boolean isNew = (s == null || s.Id == null);
        if (s == null) { s = new AJOSetting__c(); }
        if (s.AJO_HeartbeatMinutes__c == null)      { s.AJO_HeartbeatMinutes__c = 10; }
        if (s.AJO_MaxConcurrentBatches__c == null)  { s.AJO_MaxConcurrentBatches__c = 5; }
        if (s.AJO_RetentionDaysSuccess__c == null)  { s.AJO_RetentionDaysSuccess__c = 14; }
        if (s.AJO_RetentionDaysFailure__c == null)  { s.AJO_RetentionDaysFailure__c = 90; }
        if (String.isBlank(s.AJO_DefaultTimeZone__c)) { s.AJO_DefaultTimeZone__c = AJOConfig.orgTimeZone(); }
        if (s.AJO_EnableDeferral__c == null)        { s.AJO_EnableDeferral__c = true; }
        if (s.AJO_KillSwitch__c == null)            { s.AJO_KillSwitch__c = false; }
        if (s.AJO_MaxLaunchesPerCheck__c == null)   { s.AJO_MaxLaunchesPerCheck__c = AJOConfig.DEFAULT_MAX_LAUNCHES; }
        if (s.AJO_FlexQueueCap__c == null)          { s.AJO_FlexQueueCap__c = AJOConfig.DEFAULT_FLEX_QUEUE_CAP; }
        if (isNew) { insert s; } else { update s; }
        return s;
    }
}
