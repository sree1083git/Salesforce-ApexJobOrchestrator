# Apex Job Orchestration (AJO)

Run any number of scheduled Apex jobs from **seven** of the org's 100 scheduled-job slots.
Jobs are defined in **Custom Metadata** and released like code; the orchestrator wakes every
ten minutes, works out what is due, and starts each job in its **own transaction** on its exact
minute.

| | |
| --- | --- |
| Slots used | 6 heartbeats (`:00`, `:10` … `:50`) + 1 hourly supervisor = **7**, whatever the job count |
| Timing | To the minute: a check looks ten minutes ahead and holds each job in a delayed executor until its minute |
| Job definitions | `AJO_Job_Definition__mdt` — reviewed, versioned, deployed, validated by a test at deploy time |
| Runtime state | `AJOJob__c` — next run, status, failures, queued marker, operations pause |
| Run log | `AJOJobRun__c` — one row per run or refusal, with retention |
| Isolation | Every job runs in its own `AJOJobExecutor` queueable: own governor limits, callouts allowed, failures contained |
| Safety | Circuit breaker, overlap policy, batch throttle, activation windows, dry run, kill switch, savepoints |
| Operability | Self-healing slots, stale-heartbeat watchdog, alerts (platform event + email), REST health endpoint, console |

## Documentation

| Document | For |
| --- | --- |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How it works: the hybrid model, a check step by step, the executor, guarantees and limits |
| [docs/DEFINING-JOBS.md](docs/DEFINING-JOBS.md) | Writing a job definition: every field, examples, writing a `Runnable` |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Runbook: install, release, monitor, alerts, troubleshooting, settings |
| [docs/MIGRATION.md](docs/MIGRATION.md) | Moving Setup schedules and existing `AJOJob__c` configurations onto definitions |
| [docs/CHANGELOG-HARDENING.md](docs/CHANGELOG-HARDENING.md) | The design-review gaps and exactly how each was fixed |

## Quick start

```bash
# 1. Deploy (run the definition validation test as part of every deployment)
sf project deploy start -d force-app -o <alias> --test-level RunSpecifiedTests \
  --tests AJODefinitionValidationTest AJODefinitionSyncTest AJOEngineHardeningTest \
          AJOOperationsTest AJOFrameworkTest AJOWindowTest AJOCronTest AJOConsoleTest \
          AJOConvertTest AJOSampleTest

# 2. Grant access (not optional: a Metadata API deploy carries no field-level security)
sf org assign permset -n AJOJobOrchestrationAdmin -o <alias>

# 3. Install the seven slots: Apex Job Orchestration app → Apex Job Console → Setup → Install
```

Install as a **dedicated, active integration user** that holds `AJOJobOrchestrationAdmin`:
scheduled Apex runs as the user who scheduled it, so every job inherits that user's access.

## Adding a job

1. Create `force-app/main/default/customMetadata/AJO_Job_Definition.<NAME>.md-meta.xml`
   (or open the console's **Jobs → New job**, fill the form and press **Generate definition** to
   get the file).
2. Commit, review, deploy. `AJODefinitionValidationTest` fails the deployment if the class is
   missing, the cron never fires, the time zone is unknown or a dependency does not exist.
3. The next check (or **Setup → Sync definitions now**) creates the job's state. Start new jobs in
   **Dry Run**; turn it off in a later release once a cycle looks right.

Pause/resume and Run now work from the console without a release; *what* runs and *when* changes
only through a release.

## The moving parts

| Class | Does |
| --- | --- |
| `AJODispatcher` | The heartbeat. Stamps, heals, syncs, reconciles, selects what is due, dispatches. |
| `AJODefinitions` | Reads `AJO_Job_Definition__mdt` (one cached query; injectable in tests). |
| `AJODefinitionValidator` | Every validation rule; used by the sync at runtime and by the deploy-time test. |
| `AJODefinitionSync` | Projects definitions onto `AJOJob__c`; corrects tampering; retires removed jobs; performs atomic takeovers of Setup schedules. |
| `AJOLauncher` | Gates each due job and dispatches it to an executor. Bulk DML, bounded launches. Also the execution core. |
| `AJOJobExecutor` | Runs one job in its own transaction; re-checks before starting; savepoint; callouts. |
| `AJOLegacyAdapter` | Runs existing `Schedulable` / `Batchable` / `Queueable` classes unchanged. |
| `AJORunLogger` | Opens, closes and reconciles runs; circuit breaker; dependency chaining. |
| `AJOThrottle` | Batch capacity: five active batches and the flex-queue cap, counted separately. |
| `AJOSupervisor` | Hourly: heal, watchdog, sync, reconcile, reap (with abort), expire, unqueue, purge. Steps isolated. |
| `AJOPurgeBatch` | Log retention in chunks. |
| `AJOInstaller` | Arms, disarms and self-heals the seven slots. |
| `AJOAlerts` | `AJO_Alert__e` platform events and email for everything an operator must act on. |
| `AJOHealthResource` | `GET /services/apexrest/ajo/health` for external monitoring. |
| `AJODefinitionExporter` | Generates definition files (new job, migration, Setup takeover). |
| `AJOCron`, `AJOWindow`, `AJOContext`, `AJOConfig` | Cron evaluation, activation windows, the Runnable context, settings. |
| `AJOAdminController` + `ajoJobConsole` | The console. |
| `AJODeferredRunner` | Deprecated shim so queueables already in flight at upgrade still run. |

## Tests

| Test class | Covers |
| --- | --- |
| `AJODefinitionValidationTest` | **Deployment gate** over the real deployed definitions, plus every validation rule |
| `AJODefinitionSyncTest` | Projection, idempotency, tamper correction, rescheduling, invalid/retired, ops pause, dependencies, takeovers |
| `AJOEngineHardeningTest` | Dispatch-only checks, DML bound and launch budget, executor stand-downs, savepoint, unmanaged policy, early starts, throttle, dependencies and chaining, failure reconciliation, managed console |
| `AJOOperationsTest` | Self-healing, hourly supervisor, watchdog, reaping, batched retention, health endpoint, alerts, exporter |
| `AJOFrameworkTest`, `AJOWindowTest`, `AJOCronTest`, `AJOConsoleTest`, `AJOConvertTest`, `AJOSampleTest` | The original suite, run in migration mode (unmanaged jobs allowed) as engine regression coverage |

## Repository layout

```
force-app/main/default/
  classes/            engine, console controller, tests
  customMetadata/     job definitions (DEMO_* samples ship inactive)
  objects/            AJO_Job_Definition__mdt, AJOJob__c, AJOJobRun__c, AJOSetting__c, AJO_Alert__e
  lwc/ajoJobConsole/  the console
  permissionsets/     AJOJobOrchestrationAdmin, AJOJobOrchestrationViewer
manifest/             retire-ojo (old components), retire-pinned (deprecated field)
docs/                 architecture, definitions, operations, migration, changelog
```
