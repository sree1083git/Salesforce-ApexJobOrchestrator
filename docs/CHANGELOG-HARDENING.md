# Hardening changelog

The design review compared this repository with the *Scheduled Job Dispatcher* pattern (Shrikant
Bagal, LinkedIn, Nov 2026) and listed fifteen gaps. Each is fixed below, with where the fix lives
and the test that proves it. The reviewed recommendation — job definitions in Custom Metadata,
runtime state in a custom object — is implemented as the hybrid model described in
[ARCHITECTURE.md](ARCHITECTURE.md).

## Critical

| # | Gap | Fix | Where | Test |
| --- | --- | --- | --- | --- |
| 1 | Two DML per job in the check; ~70 due jobs hit the 150-DML limit, rolled back the whole check (launches, logs, Next Run) and re-selected the same jobs forever | Run records inserted, patched and job rows updated in bulk: a fixed handful of DML statements per check | `AJOLauncher.launch`, `enqueuePlanned` | `AJOEngineHardeningTest.aLargeCheckStaysWithinItsBudgetAndHoldsTheRest` |
| 2 | Runnable and Legacy Schedulable jobs ran inline in the check; one governor-limit exception rolled back every job's launch and log, and no failure was recorded | The check only dispatches. Every job runs in its own `AJOJobExecutor` queueable with full async limits; an executor killed by a limit is reconciled as Failed and counted by the breaker | `AJOJobExecutor`, `AJORunLogger.reconcile` | `aCheckDispatchesEveryJobToItsOwnExecutor`, `anExecutorThatDiedIsReconciledAsAFailure` |
| 3 | No savepoint: a Runnable that wrote and then threw left partial data. Callouts impossible (run record inserted before the job) | Savepoint around the job, rolled back before the failure is recorded. The executor does no DML before the job and implements `Database.AllowsCallouts`; definitions declare `Allows Callouts` to skip the savepoint | `AJOLauncher.execute`, `AJOJobExecutor` | `aFailedJobLeavesNoPartialWork` |

## High

| # | Gap | Fix | Where | Test |
| --- | --- | --- | --- | --- |
| 4 | Jobs started up to 10 minutes early when deferrals exceeded 40 or deferral was off | No fall-through to an immediate run. Over budget: Next Run untouched (next check). Deferral off: the check only selects jobs already due | `AJOLauncher.launch`, `AJODispatcher.selectDue` | `withDeferralOffNothingStartsEarly`, `aJobDueLaterInTheWindowIsHeldToItsMinute` |
| 5 | Queueable limit not budgeted; deferrals + legacy queueables could exceed 50 (uncatchable) | Launch budget = min(`AJO_MaxLaunchesPerCheck__c`, queueable headroom − 2); `LAUNCH_BACKLOG` alert | `AJOLauncher.launchBudget` | `aLargeCheckStaysWithinItsBudgetAndHoldsTheRest` |
| 6 | Anyone with Edit on `AJOJob__c` (OWD ReadWrite) could make the scheduler user run any class | Definitions in Custom Metadata (release-only). Projected fields read-only in both permission sets and on the layout; OWD now Read; sync overwrites direct edits; executor reads class/type/params from the definition; unmanaged rows refused unless the migration switch is on | `AJODefinitionSync`, `AJOLauncher.applyDefinition`, `mayRun`, permission sets | `editingTheStateRecordDirectlyIsUndone`, `theDefinitionDecidesWhatRunsEvenIfTheRecordWasEdited`, `unmanagedJobsAreIgnoredByDefault` |
| 7 | No stale-heartbeat alert; Notify/Digest email fields unused; missing heartbeats healed only daily; nothing restored a deleted supervisor | Every check stamps a heartbeat and heals missing slots (including the supervisor); supervisor hourly with a watchdog; `AJO_Alert__e` + email (digest and per-job); REST health endpoint for external monitoring | `AJODispatcher`, `AJOInstaller.healSafely`, `AJOSupervisor.checkHeartbeat`, `AJOAlerts`, `AJOHealthResource` | `aMissingHeartbeatIsRecreatedByTheNextCheck`, `aStaleHeartbeatRaisesAnAlert`, `healthIs*`, `alertsAreDedupedAndPublished` |

## Medium

| # | Gap | Fix | Where | Test |
| --- | --- | --- | --- | --- |
| 8 | Reaper freed the job but left the batch running, so the next run overlapped it | Reaper aborts the run's async job if still alive, and says so on the run | `AJOSupervisor.reapStuck` | `anOverrunningRunIsTimedOutAndItsJobFreed` |
| 9 | Throttle counted flex-queue (`Holding`) batches against the 5-active cap (starvation); deferred batches were never re-checked at start | Active and flex-queue limits counted separately (`AJO_FlexQueueCap__c`); the executor re-claims capacity and hands the occurrence back if full | `AJOThrottle`, `AJOJobExecutor` | `theThrottleOnlyGovernsBatches`, `batchCapacitySettingsAreBounded` |
| 10 | Supervisor was one transaction; inline purge (9k deletes + recycle bin) could breach the DML-row limit; re-arm ran last and was skipped on any failure | Steps isolated with savepoints; heal first; purge moved to `AJOPurgeBatch` (2,000-row chunks) | `AJOSupervisor`, `AJOPurgeBatch` | `theSweepRunsEveryStepAndReportsEach`, `retentionRunsAsABatchAndKeepsRecentRows` |
| 11 | Dependency = "parent succeeded today" (midnight-blind, one success fed many runs); no chaining | Parent's latest finished run must be a success after the child last ran; `Run After Dependency` makes the child due when the parent succeeds; cycles refused at deploy | `AJOLauncher.dependencySatisfied`, `AJORunLogger.chainDependents`, validator | `aDependencyMustHaveSucceededSinceTheChildLastRan`, `aParentsSuccessMakesItsChainedChildDue`, `dependenciesMustExistAndNotLoop` |
| 12 | `AJO_Pinned__c` jobs were skipped by every check and never ran | Flag ignored and deprecated; retirement manifest provided | `AJODispatcher`, `manifest/retire-pinned` | `AJOConsoleTest.everyEnabledJobIsListedWithAReason` |
| 13 | Hard-coded `Asia/Kolkata` fallback and source-org assumptions | Fallback is the setting, else the org's default time zone; org-specific comments removed | `AJOConfig.defaultTimeZone`, `AJOCron` | `AJOCronTest` (explicit zones) |
| 14 | Run now executed synchronously as the clicking user, inside the UI request's limits | Run now opens the run and enqueues an executor (own transaction, callouts allowed); **Run at next check** runs it as the scheduling user | `AJOAdminController.runNowById`, `runAtNextCheck` | `managedJobsAreOperatedButNotEdited`, `AJOFrameworkTest.consoleReadsJobsRunsAndHealth` |
| 15 | No deploy-time validation of job configuration | `AJODefinitionValidationTest.deployedDefinitionsAreAllValid` validates every deployed definition; the same validator guards the sync at runtime | `AJODefinitionValidator` | `AJODefinitionValidationTest` |

## Behaviour changes to note

- `AJO_AllowUnmanagedJobs__c` defaults to false: set it to true **before** upgrading an org that has
  `AJOJob__c` configurations, then migrate them (MIGRATION.md).
- Console **Save** becomes **Generate definition** and **convert** produces takeover definition files
  while unmanaged jobs are off. Pause/resume is an operational pause on managed jobs.
- Run now returns `Queued`; the outcome appears on the run record when the executor finishes.
- The supervisor runs hourly at :05 (reinstall moves an existing daily one automatically).
- `AJODeferredRunner` is a deprecated shim; `AJOCron.DEFAULT_TZ` is no longer used as a fallback.
- Pre-existing tests run in migration mode (`AJO_AllowUnmanagedJobs__c = true`) as engine
  regression coverage; four assertions were updated for the asynchronous Run now, the executor
  model and the retired pinned trap.
