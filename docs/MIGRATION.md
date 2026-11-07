# Migration

Two sources move onto definitions: **Setup scheduled jobs** (each holding a slot) and **existing
`AJOJob__c` configurations** created before the hybrid model.

## Upgrading an org already running AJO

1. Deploy this version. `AJO_AllowUnmanagedJobs__c` defaults to **false**, which would stop every
   existing `AJOJob__c` configuration at the next check. Before deploying, set it to **true** so
   existing jobs keep running during the migration.
2. Reinstall from the console (moves the supervisor from daily to hourly; heartbeats are kept).
3. For each existing job: **Jobs → Export as definition** → commit the file. The file's key matches
   the record's `AJO_JobKey__c`, so the sync **adopts** the existing record (history, failure count
   and Next Run kept) instead of creating a duplicate.
4. Deploy the definitions. Confirm each job shows *Defined in custom metadata* in the console.
5. When no unmanaged jobs remain (the Next up tab lists none with "Not backed by a deployed
   definition"), set `AJO_AllowUnmanagedJobs__c` back to **false**.
6. Optional: remove the deprecated `AJO_Pinned__c` field with `manifest/retire-pinned`. Pinned jobs
   never ran; the flag is now ignored.

Queueables of the old `AJODeferredRunner` class already waiting at deployment still run (the class
is kept as a shim). Delete it one release later.

## Taking over Setup scheduled jobs

The takeover must never leave a job running twice or not at all. AJO makes it atomic:

1. Console → open the **convert** dialog (existing Setup schedules), select the schedules, press convert. In
   release-only mode this produces definition files instead of changing anything. Each file is
   **active**, in **Dry Run**, with `AJO_ReplacesCronJobName__c` set to the Setup job's name. The
   original time zone is copied, never assumed.
2. Commit and deploy them.
3. At the next check, the sync creates each job's state and, **in the same transaction, last**,
   aborts the named Setup job. If the abort fails, the savepoint rolls back the state too and the
   Setup job keeps running (alert `SYNC_FAILED`). The takeover happens once (`AJO_CutoverAt__c`).
4. Watch two cycles in Dry Run on the Activity tab. Values passed to the class when it was
   scheduled cannot be recovered from the platform, so confirm the class's defaults are right.
5. Release Dry Run off.

Start with a low-risk job you own; the first takeover is a test of the process.

### Rollback

Console → Jobs → **Restore to Setup** on a taken-over job. It pauses the orchestrated job
operationally (so syncs do not re-enable it) and recreates the Setup schedule as the last statement.
`System.schedule` uses the running user's time zone; the restore plan shows both sets of fire times
and refuses a silent shift unless you accept it. Then remove or deactivate the definition in the
next release.

## What cannot be migrated

- Managed-package schedulers that cannot be launched by class name keep their own slots.
- Classes without a public no-argument constructor (validation reports them).
- Cron expressions using `L`, `W` or `#` (rewrite them, or keep the Setup schedule).
