# Operations runbook

## Install

1. Deploy the engine and the org's configuration — see [DEPLOYMENT.md](DEPLOYMENT.md).
2. Create or pick a **dedicated, active integration user**; assign `AJOJobOrchestrationAdmin`.
   Scheduled Apex runs as the user who scheduled it, and every job inherits that user's access.
3. Log in as that user → **Apex Job Orchestration** app → **Apex Job Console** → **Setup** → **Install**.
   This seeds `AJOSetting__c` and schedules 6 heartbeats + the hourly supervisor.
4. Set `AJOSetting__c.AJO_DigestEmail__c` and subscribe to `AJO_Alert__e` (see Alerts).
5. Point an external monitor at the health endpoint (see Monitoring).

Deployment setting: `org-config/main/default/settings/Deployment.settings-meta.xml` enables *Allow deployments of components when
corresponding Apex jobs are pending or in progress*, so releases do not require uninstalling.

## Release a job change

1. Edit or add `org-config/main/default/customMetadata/AJO_Job_Definition.<NAME>.md-meta.xml`.
2. Deploy with `AJODefinitionValidationTest` in the test level.
3. Within ten minutes the next check syncs it; or press **Setup → Sync definitions now**.
4. New jobs: first release in Dry Run, check the **Activity** tab for a cycle, then release with Dry
   Run off.

Removing a definition retires its state (`Retired`, history kept). Deactivating keeps it visible
but idle.

## Day-to-day (no release needed)

| Need | Console action | Effect |
| --- | --- | --- |
| Stop one job now | Jobs → Pause | `AJO_OpsPaused__c` = true; survives syncs; queued run stands down |
| Resume it | Jobs → Resume | Recomputes Next Run (refused if the definition is inactive) |
| Run it now | Jobs → Run it now | Executor in its own transaction, **as you**; refused while the job is Queued/Running (unless overlap policy is Allow); stands down if the job is paused |
| Run it as the scheduler | Jobs → Run at next check | Due now; the next check runs it as the scheduling user |
| Retry a failure | Errors → Run it again | Same as Run it now |
| Stop everything | Header → Pause all jobs | Kill switch; nothing launches; queued runs stand down; heartbeats keep stamping |
| Housekeeping now | Setup → Run maintenance now | The supervisor sweep on demand |
| Apply a release now | Setup → Sync definitions now | Definition sync on demand |

## Monitoring

**Alerts** — `AJO_Alert__e` (`Severity__c`, `Code__c`, `JobKey__c`, `Message__c`). Route with a
platform-event-triggered Flow or Apex trigger, or subscribe over the Pub/Sub API from your
observability stack. WARNING/ERROR are also emailed to `AJO_DigestEmail__c` and the job's Notify
Emails.

| Code | Severity | Act on it |
| --- | --- | --- |
| `HEARTBEAT_STALE` | ERROR | No check ran for 3 intervals. Check the scheduling user is active and has the Admin set; reinstall. |
| `JOB_SUSPENDED` | ERROR | Circuit breaker opened. Fix the cause, then Resume. |
| `DEFINITION_INVALID` | ERROR | A deployed definition fails validation. Fix it in the next release. |
| `SYNC_FAILED` | ERROR | Sync rolled back (often a failed takeover abort). Read the message; jobs keep previous state. |
| `CUTOVER_FAILED` | ERROR | A takeover was refused (e.g. names a framework schedule). |
| `MAINTENANCE_FAILED` | ERROR | A supervisor step rolled back; the others ran. |
| `JOB_FAILED` | WARNING | One failure; breaker not yet open. |
| `SLOTS_REARMED` | WARNING | A missing slot was re-created. Find out who removed it. |
| `LAUNCH_BACKLOG` | WARNING | More jobs due than one check launches. Spread schedules or raise the cap carefully. |
| `RECONCILE_FAILED` | WARNING | Closing finished runs failed; retried next check. |
| `CUTOVER_DONE`, `DEFINITION_RETIRED` | INFO | Audit trail. `CUTOVER_DONE` is sent only after the Setup job was aborted, which happens only once the definition is out of Dry Run. |

**External health check** — `GET /services/apexrest/ajo/health` (integration user with the Viewer
set). 200 + `healthy:true`, or 503 with `problems`. Alert on 503 or on failure to connect. This is
the only signal that survives a total in-org outage (e.g. a deactivated scheduling user).

**Console header** — one sentence: running normally / paused / checks stopped / invalid definitions /
failures in 24h / suspended jobs.

## Troubleshooting

| Symptom | Look at | Likely cause |
| --- | --- | --- |
| "Already running" on Run now | Job status, Activity | A run is Queued/Running and the overlap policy forbids a second one; wait, or use Run at next check |
| Job never runs | Next up tab verdict | Inactive or invalid definition, ops pause, outside window, dependency unmet, Dry Run |
| Run stuck in Running | Activity, Apex Jobs | Long batch (reaped after Max Runtime, async job aborted); executor died (closed as Failed at next check) |
| "Throttled" repeatedly | Setup diagnostics: batches in flight, flex queue | Five active batches or flex queue at cap; another process is hogging batch capacity |
| Job started late | Run's Scheduled For vs Started At | Launch budget exceeded (`LAUNCH_BACKLOG`), or deferral disabled |
| Field not visible errors | Permission set assignment | `AJOJobOrchestrationAdmin` not assigned |
| Edits to a job keep reverting | Definition | Working as designed: change the definition by release |

## Settings (`AJOSetting__c`, org default)

| Field | Default | Meaning |
| --- | --- | --- |
| `AJO_KillSwitch__c` | false | Pause all jobs |
| `AJO_HeartbeatMinutes__c` | 10 | Check interval; keep ≤ 10 (queueable delay cap) |
| `AJO_EnableDeferral__c` | true | Look ahead and hold jobs to their minute; off = due jobs only (late, never early) |
| `AJO_MaxLaunchesPerCheck__c` | 40 | Launch cap per check (also capped by queueable headroom) |
| `AJO_MaxConcurrentBatches__c` | 5 | Active-batch ceiling for framework batches |
| `AJO_FlexQueueCap__c` | 90 | Hold batches while the flex queue holds this many |
| `AJO_DefaultTimeZone__c` | org zone | Cron zone when a definition names none |
| `AJO_StaleHeartbeatMinutes__c` | 3 × interval | Watchdog threshold |
| `AJO_RetentionDaysSuccess__c` / `...Failure__c` | 14 / 90 | Log retention |
| `AJO_DigestEmail__c` | — | Alert email recipients |
| `AJO_AllowUnmanagedJobs__c` | false | Migration only: lets `AJOJob__c` rows without a definition run |

## Uninstall

Setup → Uninstall (aborts the seven slots; healing does not undo it). Jobs stop. Definitions and
history remain. Reinstall to resume.
