/**
 * Framework-wide settings, read from the AJOSetting__c hierarchy custom
 * setting with safe defaults, so a missing or half-filled setting never breaks
 * a run. Per-job configuration does not live here: it lives in
 * AJO_Job_Definition__mdt (see AJODefinitions).
 */
public inherited sharing class AJOConfig {

    public static final Integer DEFAULT_HEARTBEAT_MINUTES = 10;
    public static final Integer DEFAULT_MAX_BATCHES       = 5;
    /** Platform cap on AsyncOptions.MinimumQueueableDelayInMinutes. */
    public static final Integer PLATFORM_DELAY_CAP        = 10;
    /** Org-wide limit on scheduled Apex jobs; the number this framework exists to protect. */
    public static final Integer SLOT_LIMIT                = 100;
    public static final Integer DEFAULT_MAX_LAUNCHES      = 40;
    /** The Apex flex queue holds at most 100 batches; leave room for others. */
    public static final Integer DEFAULT_FLEX_QUEUE_CAP    = 90;

    private static AJOSetting__c cached;
    private static String orgTimeZoneCache;

    public static AJOSetting__c get() {
        if (cached == null) {
            cached = AJOSetting__c.getOrgDefaults();
            if (cached == null) { cached = new AJOSetting__c(); }
        }
        return cached;
    }

    /** Lets a test substitute settings without DML. */
    @TestVisible
    private static void applyOverride(AJOSetting__c s) { cached = s; }

    /** "Pause all jobs": nothing launches and queued runs stand down. */
    public static Boolean killSwitch() {
        return get().AJO_KillSwitch__c == true;
    }

    public static Integer heartbeatMinutes() {
        Decimal v = get().AJO_HeartbeatMinutes__c;
        return (v == null || v <= 0) ? DEFAULT_HEARTBEAT_MINUTES : v.intValue();
    }

    /** Concurrent batch ceiling (the platform allows five active batches). */
    public static Integer maxConcurrentBatches() {
        Decimal v = get().AJO_MaxConcurrentBatches__c;
        return (v == null || v <= 0) ? DEFAULT_MAX_BATCHES : v.intValue();
    }

    /**
     * When on (default), a check also takes jobs due later in its window and
     * holds each in a delayed queueable until its exact minute. When off, a
     * check only takes jobs already due: they start late, never early.
     */
    public static Boolean deferralEnabled() {
        return get().AJO_EnableDeferral__c != false;
    }

    /** Most launches one check makes; the rest wait for the next check. */
    public static Integer maxLaunchesPerCheck() {
        Decimal v = get().AJO_MaxLaunchesPerCheck__c;
        return (v == null || v <= 0) ? DEFAULT_MAX_LAUNCHES : v.intValue();
    }

    /** Batches are held back while the flex queue holds at least this many. */
    public static Integer flexQueueCap() {
        Decimal v = get().AJO_FlexQueueCap__c;
        return (v == null || v <= 0) ? DEFAULT_FLEX_QUEUE_CAP : Math.min(v.intValue(), 100);
    }

    /**
     * Transition switch. Off by default: only jobs backed by a deployed
     * AJO_Job_Definition__mdt record can run, so editing a record in production
     * can never make the framework run an arbitrary class.
     */
    public static Boolean allowUnmanagedJobs() {
        return get().AJO_AllowUnmanagedJobs__c == true;
    }

    /** The watchdog's threshold: three missed checks by default. */
    public static Integer staleHeartbeatMinutes() {
        Decimal v = get().AJO_StaleHeartbeatMinutes__c;
        return (v == null || v <= 0) ? heartbeatMinutes() * 3 : v.intValue();
    }

    public static Integer retentionSuccessDays() {
        Decimal v = get().AJO_RetentionDaysSuccess__c;
        return (v == null || v <= 0) ? 14 : v.intValue();
    }

    public static Integer retentionFailureDays() {
        Decimal v = get().AJO_RetentionDaysFailure__c;
        return (v == null || v <= 0) ? 90 : v.intValue();
    }

    /**
     * The zone a job's cron is evaluated in when its definition names none:
     * the setting if filled, otherwise the org's own default time zone. The
     * previous hard-coded fallback belonged to one specific org.
     */
    public static String defaultTimeZone() {
        String v = get().AJO_DefaultTimeZone__c;
        return String.isBlank(v) ? orgTimeZone() : v;
    }

    /** The org's default time zone (Company Information), cached per transaction. */
    public static String orgTimeZone() {
        if (orgTimeZoneCache == null) {
            List<Organization> o = [SELECT TimeZoneSidKey FROM Organization LIMIT 1];
            orgTimeZoneCache = (o.isEmpty() || String.isBlank(o[0].TimeZoneSidKey))
                ? UserInfo.getTimeZone().getID() : o[0].TimeZoneSidKey;
        }
        return orgTimeZoneCache;
    }

    /** Framework-wide alert recipient(s); comma-separated. */
    public static String digestEmail() { return get().AJO_DigestEmail__c; }

    public static Datetime lastHeartbeatAt() { return get().AJO_LastHeartbeatAt__c; }

    /**
     * Records that a scheduled check ran, for the watchdog. Writes the org
     * default row only; one DML per check. Never throws: a failed stamp must
     * not stop the check it describes.
     */
    public static void stampHeartbeat() {
        try {
            AJOSetting__c s = AJOSetting__c.getOrgDefaults();
            if (s == null || s.Id == null) { return; } // not installed; ensureSettings creates it
            s.AJO_LastHeartbeatAt__c = Datetime.now();
            update s;
            if (cached != null) { cached.AJO_LastHeartbeatAt__c = s.AJO_LastHeartbeatAt__c; }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AJO could not stamp the heartbeat: ' + e.getMessage());
        }
    }
}
