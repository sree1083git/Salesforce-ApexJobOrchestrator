/**
 * GET /services/apexrest/ajo/health
 *
 * A machine-readable health check for EXTERNAL monitoring. In-org alerting
 * cannot report its own total failure: if the scheduling user is deactivated,
 * no heartbeat and no supervisor run, so nothing in the org raises an alert.
 * Point a synthetic check (Datadog, Pingdom, a MuleSoft poller) at this
 * endpoint with an integration user holding the Viewer permission set, and
 * alert when "healthy" is false or the call fails.
 *
 * Returns HTTP 200 with healthy=true, or HTTP 503 with healthy=false and the
 * reasons, so a plain status-code monitor works without parsing the body.
 */
@RestResource(urlMapping='/ajo/health')
global with sharing class AJOHealthResource {

    global class Health {
        global Boolean healthy;
        global List<String> problems;
        global Datetime lastHeartbeatAt;
        global Integer staleAfterMinutes;
        global Integer heartbeatsExpected;
        global Integer heartbeatsArmed;
        global Boolean supervisorArmed;
        global Boolean paused;
        global Integer jobsSuspended;
        global Integer jobsInvalid;
        global Integer failuresLast24h;
        global Integer scheduledApexSlotsUsed;
    }

    @HttpGet
    global static Health get() {
        Health h = evaluate(Datetime.now());
        RestResponse res = RestContext.response;
        if (res != null) { res.statusCode = h.healthy ? 200 : 503; }
        return h;
    }

    /** The evaluation, separate from the HTTP plumbing so tests can call it. */
    public static Health evaluate(Datetime now) {
        Health h = new Health();
        h.problems = new List<String>();
        h.lastHeartbeatAt    = AJOConfig.lastHeartbeatAt();
        h.staleAfterMinutes  = AJOConfig.staleHeartbeatMinutes();
        h.heartbeatsExpected = AJOInstaller.slots().size();
        h.paused             = AJOConfig.killSwitch();
        h.heartbeatsArmed    = 0;
        h.supervisorArmed    = false;
        for (CronTrigger ct : AJOInstaller.ownTriggers()) {
            if (ct.CronJobDetail.Name == AJOInstaller.SUPERVISOR_NAME) { h.supervisorArmed = true; }
            else { h.heartbeatsArmed++; }
        }
        h.jobsSuspended   = [SELECT COUNT() FROM AJOJob__c WHERE AJO_Status__c = 'Suspended'];
        h.jobsInvalid     = [SELECT COUNT() FROM AJOJob__c WHERE AJO_Status__c = 'Invalid'];
        h.failuresLast24h = [
            SELECT COUNT() FROM AJOJobRun__c
            WHERE  AJO_StartedAt__c = LAST_N_DAYS:1 AND AJO_Status__c IN ('Failed', 'Stuck')
        ];
        h.scheduledApexSlotsUsed = AJOInstaller.scheduledApexSlotsUsed();

        if (h.heartbeatsArmed < h.heartbeatsExpected) {
            h.problems.add(h.heartbeatsArmed + ' of ' + h.heartbeatsExpected + ' heartbeats are scheduled.');
        }
        if (!h.supervisorArmed) { h.problems.add('The supervisor is not scheduled.'); }
        if (!h.paused && (h.lastHeartbeatAt == null
                          || h.lastHeartbeatAt.addMinutes(h.staleAfterMinutes) < now)) {
            h.problems.add('No heartbeat in the last ' + h.staleAfterMinutes + ' minutes.');
        }
        if (h.jobsInvalid > 0) { h.problems.add(h.jobsInvalid + ' definition(s) are invalid.'); }
        // Suspended jobs and failures are reported but do not make the scheduler
        // unhealthy: they are per-job problems, already alerted individually.
        h.healthy = h.problems.isEmpty();
        return h;
    }
}
