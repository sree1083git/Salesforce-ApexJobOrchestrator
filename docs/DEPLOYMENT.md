# Deployment and reuse across orgs

The repository has two parts, and they deploy differently:

| Folder | What | Same in every org? | Ships as |
| --- | --- | --- | --- |
| `force-app/` | **The engine**: classes, objects, console, permission sets, demo jobs, tests | Yes | Source deploy, or the unlocked package *Apex Job Orchestrator* |
| `org-config/` | **One org's configuration**: job definitions (`AJO_Job_Definition__mdt` records) and `Deployment.settings` | No | Source deploy only (never packaged) |

Nothing in the engine is org-specific: the cron fallback is the org's own default time zone, all
limits live in `AJOSetting__c`, and the test suite ignores the definitions deployed in the org it runs
in (except `AJODefinitionValidationTest`, which exists to check them). So the same engine can be
deployed unchanged to any org.

## Choose a route

| Situation | Route |
| --- | --- |
| One org, or trying it out | **A. Source deploy** |
| Several orgs (different companies, business units or clients) that should run the same, versioned engine | **B. Unlocked package** for the engine, plus a small config repo per org |

## 0. Make it your own repository

Merge the pull request first, then copy the repository with its history into a new one:

```bash
git clone https://github.com/sree1083git/Salesforce-ApexJobOrchestrator.git apex-job-orchestrator
cd apex-job-orchestrator
# create an empty repository on GitHub first (no README), then:
git remote set-url origin https://github.com/<you>/apex-job-orchestrator.git
git push -u origin main
```

Prerequisites: [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf`), Node
for the LWC lint/Jest scripts (`npm install`), and an API version 67.0 org or newer.

## A. Source deploy to one org

```bash
sf org login web --alias myorg               # add --instance-url https://test.salesforce.com for a sandbox

# 1. Validate first: compiles and runs the tests, changes nothing
sf project deploy validate --source-dir force-app --target-org myorg \
  --test-level RunSpecifiedTests --tests AJODefinitionValidationTest AJODefinitionSyncTest \
  AJOEngineHardeningTest AJOOperationsTest AJOFrameworkTest AJOWindowTest AJOCronTest \
  AJOConsoleTest AJOConvertTest AJOSampleTest

# 2. Deploy the engine (same command with "deploy start")
sf project deploy start --source-dir force-app --target-org myorg \
  --test-level RunSpecifiedTests --tests AJODefinitionValidationTest AJODefinitionSyncTest \
  AJOEngineHardeningTest AJOOperationsTest AJOFrameworkTest AJOWindowTest AJOCronTest \
  AJOConsoleTest AJOConvertTest AJOSampleTest

# 3. Deploy this org's configuration (definitions + deployment setting)
sf project deploy start --source-dir org-config --target-org myorg \
  --test-level RunSpecifiedTests --tests AJODefinitionValidationTest
```

Then follow [Post-deployment](#post-deployment-every-org). Upgrading later is the same two deploys.

## B. Unlocked package for many orgs

Build the engine once as a versioned package, install the same version everywhere, and keep each
org's definitions in that org's own repository.

### Build (once per release, from a Dev Hub)

```bash
sf org login web --alias devhub --set-default-dev-hub     # a production org with Dev Hub enabled

# First time only: registers the package and writes its alias into sfdx-project.json
sf package create --name "Apex Job Orchestrator" --package-type Unlocked \
  --path force-app --no-namespace --target-dev-hub devhub

# Every release: build a version (runs the tests, needs 75% coverage to promote)
sf package version create --package "Apex Job Orchestrator" --installation-key-bypass \
  --code-coverage --wait 30 --target-dev-hub devhub
sf package version promote --package "Apex Job Orchestrator@1.0.0-1" --target-dev-hub devhub
```

Commit the updated `sfdx-project.json` (it now holds the package and version aliases). Bump
`versionNumber` in `sfdx-project.json` for each release.

`--no-namespace` keeps every API name identical to a source deploy (`AJOJob__c`, not
`ns__AJOJob__c`), so definitions, docs and code work the same either way, and orgs that were
source-deployed can move onto the package: a no-namespace unlocked package adopts matching
unpackaged components when it is installed. Try that adoption in a sandbox first.

### Install (each org, sandbox first)

```bash
sf package install --package "Apex Job Orchestrator@1.0.0-1" --target-org otherorg \
  --security-type AdminsOnly --wait 30
```

Upgrading is installing the newer version over it. Field history, runs, state and settings are kept.

### Per-org configuration repository

Each org keeps only its own configuration and its own job classes:

```
<org>-ajo-config/
  sfdx-project.json            one packageDirectory: "config"
  config/main/default/
    customMetadata/            AJO_Job_Definition.<NAME>.md-meta.xml  (this org's jobs)
    settings/                  Deployment.settings-meta.xml
    classes/                   (optional) this org's job classes, if they are not deployed elsewhere
```

Start it by copying `org-config/` from this repository and deleting the `DEMO_*` records you do not
want. Deploy it with the validation gate, which runs the packaged test against this org's
definitions:

```bash
sf project deploy start --source-dir config --target-org otherorg \
  --test-level RunSpecifiedTests --tests AJODefinitionValidationTest
```

## Post-deployment (every org)

1. **Integration user.** Create or pick a dedicated, active user. Scheduled Apex runs as the user who
   scheduled it, so every job inherits this user's access. Assign `AJOJobOrchestrationAdmin`:
   `sf org assign permset --name AJOJobOrchestrationAdmin --target-org myorg --on-behalf-of <username>`.
   Assign `AJOJobOrchestrationViewer` to people who only watch.
2. **Install the slots.** Log in as that user → **Apex Job Orchestration** app → **Apex Job
   Console** → **Setup** → **Install**. This seeds `AJOSetting__c` and schedules six heartbeats plus
   the hourly supervisor (7 of the org's 100 scheduled-job slots).
3. **Settings.** Review `AJOSetting__c` (org default): `AJO_DefaultTimeZone__c` (blank = the org's
   time zone), `AJO_DigestEmail__c`, limits. See [OPERATIONS.md](OPERATIONS.md#settings-ajosetting__c-org-default).
4. **Alerts.** Route `AJO_Alert__e` (Flow, trigger or Pub/Sub API) and point an external monitor at
   `GET /services/apexrest/ajo/health`.
5. **Org already running an older AJO?** Set `AJO_AllowUnmanagedJobs__c = true` **before** deploying,
   then follow [MIGRATION.md](MIGRATION.md).
6. **Existing Setup scheduled jobs?** Take them over in two releases: [MIGRATION.md](MIGRATION.md).

## What differs between orgs

| Differs | Where it lives |
| --- | --- |
| Which jobs run, when, in which time zone | `org-config` / the org's config repo (definitions) |
| Limits, kill switch, alert email, retention | `AJOSetting__c` in the org |
| Running user and its access | The integration user and its permission sets |
| Setup schedules to migrate | That org's Setup → Scheduled Jobs |

Everything else is the engine and is identical.

## Checklist before the first production deployment

- [ ] Full test run green in a sandbox of that org (validate command above).
- [ ] Integration user exists, is active and will not be frozen by offboarding processes.
- [ ] Definitions start in **Dry Run**; turn it off in a later release.
- [ ] Health endpoint monitored from outside Salesforce.
- [ ] Fewer than 93 scheduled jobs in use before installing (the framework needs 7).
