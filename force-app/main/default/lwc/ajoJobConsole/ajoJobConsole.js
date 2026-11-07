import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getJobsApex from '@salesforce/apex/AJOAdminController.getJobs';
import getActivityApex from '@salesforce/apex/AJOAdminController.getActivity';
import getUsedSlotsApex from '@salesforce/apex/AJOAdminController.getUsedSlots';
import getHealthApex from '@salesforce/apex/AJOAdminController.getHealth';
import getNextCheckApex from '@salesforce/apex/AJOAdminController.getNextCheck';
import preview from '@salesforce/apex/AJOAdminController.preview';
import describeCronApex from '@salesforce/apex/AJOAdminController.describeSchedule';
import classifyClass from '@salesforce/apex/AJOAdminController.classifyClass';
import runNowByIdApex from '@salesforce/apex/AJOAdminController.runNowById';
import retryRunApex from '@salesforce/apex/AJOAdminController.retryRun';
import setEnabledApex from '@salesforce/apex/AJOAdminController.setEnabled';
import saveJobApex from '@salesforce/apex/AJOAdminController.saveJob';
import deleteJobApex from '@salesforce/apex/AJOAdminController.deleteJob';
import armFrameworkApex from '@salesforce/apex/AJOAdminController.armFramework';
import disarmFrameworkApex from '@salesforce/apex/AJOAdminController.disarmFramework';
import setKillSwitchApex from '@salesforce/apex/AJOAdminController.setKillSwitch';
import runSupervisorApex from '@salesforce/apex/AJOAdminController.runSupervisor';
import seedDemoJobsApex from '@salesforce/apex/AJOAdminController.seedDemoJobs';
import listConvertibleApex from '@salesforce/apex/AJOAdminController.listConvertible';
import convertApex from '@salesforce/apex/AJOAdminController.convert';
import convertManyApex from '@salesforce/apex/AJOAdminController.convertMany';
import planRestoreApex from '@salesforce/apex/AJOAdminController.planRestore';
import restoreApex from '@salesforce/apex/AJOAdminController.restore';
import runAtNextCheckApex from '@salesforce/apex/AJOAdminController.runAtNextCheck';
import syncNowApex from '@salesforce/apex/AJOAdminController.syncNow';
import generateDefinitionApex from '@salesforce/apex/AJOAdminController.generateDefinition';
import exportDefinitionApex from '@salesforce/apex/AJOAdminController.exportDefinition';
import generateConversionDefinitionsApex from '@salesforce/apex/AJOAdminController.generateConversionDefinitions';

const MS_PER_DAY = 86400000;

/** Four actions, not six. Deleting a job now lives inside the editor. */
const JOB_ACTIONS = [
    { label: 'Run it now', name: 'run' },
    { label: 'See its activity', name: 'history' },
    { label: 'Pause or resume', name: 'toggle' },
    { label: 'Edit', name: 'edit' }
];

/**
 * Restoring only means anything for a job that came from Setup, so the action
 * is offered per row rather than shown everywhere and then refused.
 */
function jobActionsFor(row, done) {
    // A job defined in custom metadata changes only through a release, so its
    // editor is replaced by "Show definition". An unmanaged job with a run
    // queued cannot be edited until it starts; the server refuses both too,
    // this just says so before anyone tries.
    let actions = JOB_ACTIONS;
    if (row.managed) {
        actions = JOB_ACTIONS.filter((a) => a.name !== 'edit')
            .concat([{ label: 'Show definition', name: 'export' }]);
    } else if (row.editLocked) {
        actions = JOB_ACTIONS.map((a) => (a.name === 'edit'
            ? { ...a, label: 'Edit (locked: run queued)', disabled: true }
            : a));
    }
    actions = actions.concat([{ label: 'Run at next check (as scheduler)', name: 'nextcheck' }]);
    if (!row.managed) {
        actions = actions.concat([{ label: 'Export as definition', name: 'export' }]);
    }
    done(row.converted
        ? actions.concat([{ label: 'Restore to Setup', name: 'restore' }])
        : actions);
}

const PROBLEM_ACTIONS = [
    { label: 'What went wrong', name: 'detail' },
    { label: 'Run it again', name: 'retry' }
];

/** yyyy-MM-dd, which is what lightning-input type=date and Apex both expect. */
function isoDate(d) {
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(
        d.getDate()
    ).padStart(2, '0')}`;
}

/** The detail modal shows these as text, where a raw ISO string reads badly. */
function when(value) {
    if (!value) { return '—'; }
    return new Date(value).toLocaleString();
}

/** ":20" reads as a clock time; "20" reads as an id. */
function slotLabel(slot) {
    if (slot === null || slot === undefined) { return '—'; }
    return ':' + String(slot).padStart(2, '0');
}

const DATE_COLUMN = {
    year: 'numeric', month: 'short', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit'
};

const EMPTY_DRAFT = {
    id: null,
    name: '',
    jobKey: '',
    apexClass: '',
    executionType: 'Legacy Schedulable',
    cronExpression: '0 0 * * * ?',
    timeZone: 'Asia/Kolkata',
    priority: 5,
    batchSize: 200,
    maxRuntimeMinutes: 60,
    maxConsecutiveFailures: 3,
    overlapPolicy: 'Skip',
    enabled: true,
    startDate: isoDate(new Date()),
    endDate: '',
    dryRun: false,
    pinned: false,
    parameters: '',
    description: ''
};

export default class AjoJobConsole extends LightningElement {
    @track jobs = [];
    @track activity = [];
    @track problems = [];
    @track nextCheck;
    @track health;
    @track draft = { ...EMPTY_DRAFT };
    @track detailRow;
    @track convertible = [];
    @track convertPick;
    @track convertPreview = [];
    @track convertResults = [];
    @track restorePlan;
    selectedIds = [];

    showEditor = false;
    showDetail = false;
    showConvert = false;
    converting = false;
    showRestore = false;
    restoring = false;
    acceptShift = false;
    showUninstall = false;
    // Definition files produced for a release (new job, export, takeover).
    @track definitionFiles = [];
    showDefinitions = false;
    uninstallConfirm = '';
    saving = false;
    busy = false;

    selectedJobId = null;
    selectedJobName = '';
    activityFilter = 'all';
    activitySlot = '';
    slotOptions = [{ label: 'Every scheduled check', value: '' }];

    previewText = 'Enter a schedule to see when it would run.';
    cronDescription = '';
    classHint = '';
    classHintOk = 'no';

    executionTypes = [
        { label: 'An existing Apex class, unchanged', value: 'Legacy Schedulable' },
        { label: 'Batch', value: 'Batch' },
        { label: 'Queueable', value: 'Queueable' },
        { label: 'Written for this framework', value: 'Runnable' }
    ];

    overlapPolicies = [
        { label: 'Skip this run', value: 'Skip' },
        { label: 'Try again at the next check', value: 'Queue' },
        { label: 'Start it anyway', value: 'Allow' }
    ];

    // ----------------------------------------------------------- 1. next up

    dueColumns = [
        { label: 'Job', fieldName: 'name', wrapText: true },
        { label: 'What it runs', fieldName: 'apexClass', initialWidth: 200 },
        { label: 'Due at', fieldName: 'dueAtLocal', initialWidth: 160 },
        { label: 'Will it run?', fieldName: 'verdict', initialWidth: 140,
          cellAttributes: { class: { fieldName: 'verdictClass' } } },
        { label: 'Why', fieldName: 'verdictReason', wrapText: true }
    ];

    // ---------------------------------------------------------- 2. activity

    activityColumns = [
        { label: 'When', fieldName: 'startedAt', type: 'date', initialWidth: 180,
          typeAttributes: DATE_COLUMN },
        { label: 'Job', fieldName: 'jobName', initialWidth: 190, wrapText: true },
        { label: 'Result', fieldName: 'statusLabel', initialWidth: 130,
          cellAttributes: { class: { fieldName: 'statusClass' } } },
        { label: 'Check', fieldName: 'slotLabel', initialWidth: 80 },
        { label: 'Started by', fieldName: 'triggeredBy', initialWidth: 110 },
        { label: 'Seconds', fieldName: 'durationSec', type: 'number', initialWidth: 90,
          typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
        { label: 'Items', fieldName: 'itemsProcessed', type: 'number', initialWidth: 80,
          cellAttributes: { alignment: 'right' } },
        { label: 'Detail', fieldName: 'detail', wrapText: true }
    ];

    // ---------------------------------------------------------- 3. problems

    problemColumns = [
        { label: 'When', fieldName: 'startedAt', type: 'date', initialWidth: 180,
          typeAttributes: DATE_COLUMN },
        { label: 'Job', fieldName: 'jobName', initialWidth: 190, wrapText: true },
        { label: 'Result', fieldName: 'statusLabel', initialWidth: 120,
          cellAttributes: { class: { fieldName: 'statusClass' } } },
        { label: 'What went wrong', fieldName: 'errorMessage', wrapText: true },
        { type: 'action', typeAttributes: { rowActions: PROBLEM_ACTIONS } }
    ];

    // ------------------------------------------------------------- 4. jobs

    jobColumns = [
        { label: 'Job', fieldName: 'name', wrapText: true,
          cellAttributes: { class: { fieldName: 'nameClass' } } },
        { label: 'Runs', fieldName: 'schedule', initialWidth: 190 },
        { label: 'Next run', fieldName: 'nextRunLocal', initialWidth: 170 },
        { label: 'Last result', fieldName: 'lastOutcome', initialWidth: 130,
          cellAttributes: { class: { fieldName: 'lastOutcomeClass' } } },
        { label: 'State', fieldName: 'stateLabel', initialWidth: 175, wrapText: true,
          cellAttributes: { class: { fieldName: 'stateClass' } } },
        { type: 'action', typeAttributes: { rowActions: jobActionsFor } }
    ];

    connectedCallback() {
        this.loadAll();
    }

    // ------------------------------------------------------------- loading

    async loadAll() {
        await Promise.all([
            this.loadJobs(),
            this.loadActivity(),
            this.loadProblems(),
            this.loadNextCheck(),
            this.loadHealth(),
            this.loadSlots()
        ]);
    }

    async loadJobs() {
        try {
            const rows = await getJobsApex();
            this.jobs = rows.map((j) => ({
                ...j,
                lastOutcome: this.lastOutcome(j),
                lastOutcomeClass: this.outcomeClass(j.lastRunStatus),
                stateLabel: this.stateLabel(j),
                stateClass: this.stateClass(j),
                nameClass: j.isActive ? '' : 'slds-text-color_weak'
            }));
        } catch (e) {
            this.toastError('Could not load the jobs', e);
        }
    }

    async loadActivity() {
        try {
            const rows = await getActivityApex({
                jobId: this.selectedJobId,
                filter: this.activityFilter,
                slot: this.activitySlot === '' ? null : Number(this.activitySlot),
                limitSize: 200
            });
            this.activity = rows.map((r) => this.decorateRun(r));
        } catch (e) {
            this.toastError('Could not load the activity', e);
        }
    }

    async loadProblems() {
        try {
            const rows = await getActivityApex({
                jobId: null, filter: 'failures', slot: null, limitSize: 100
            });
            this.problems = rows.map((r) => ({
                ...this.decorateRun(r),
                errorMessage: r.errorMessage || r.message || 'No detail was recorded.'
            }));
        } catch (e) {
            this.toastError('Could not load the errors', e);
        }
    }

    async loadNextCheck() {
        try {
            this.nextCheck = await getNextCheckApex();
            if (this.nextCheck && this.nextCheck.due) {
                this.nextCheck = {
                    ...this.nextCheck,
                    due: this.nextCheck.due.map((d) => ({
                        ...d,
                        verdictClass: d.willRun
                            ? 'ok-text'
                            : (d.verdict === 'Never runs'
                               ? 'err-text'
                               : (d.verdict === 'Test mode' || d.verdict === 'Held back'
                                  ? 'warn-text'
                                  : 'slds-text-color_weak'))
                    }))
                };
            }
        } catch (e) {
            this.toastError('Could not work out what runs next', e);
        }
    }

    async loadHealth() {
        try {
            this.health = await getHealthApex();
        } catch (e) {
            this.toastError('Could not load the status', e);
        }
    }

    async loadSlots() {
        try {
            const slots = await getUsedSlotsApex();
            this.slotOptions = [{ label: 'Every scheduled check', value: '' }].concat(
                slots.map((s) => ({ label: `The ${slotLabel(s)} check`, value: String(s) }))
            );
        } catch (e) {
            this.slotOptions = [{ label: 'Every scheduled check', value: '' }];
        }
    }

    /** Plain words for the run statuses, and a colour that matches. */
    decorateRun(r) {
        const map = {
            Success: 'Succeeded',
            Failed: 'Failed',
            Stuck: 'Timed out',
            Skipped: 'Skipped',
            Throttled: 'Held back',
            'Dry Run': 'Test mode',
            Running: 'Still running'
        };
        return {
            ...r,
            statusLabel: map[r.status] || r.status || '—',
            statusClass: this.outcomeClass(r.status),
            slotLabel: slotLabel(r.heartbeatSlot),
            startedAtText: when(r.startedAt),
            finishedAtText: when(r.finishedAt),
            detail: r.errorMessage || r.message || ''
        };
    }

    outcomeClass(status) {
        if (status === 'Failed' || status === 'Stuck') { return 'err-text'; }
        if (status === 'Success') { return 'ok-text'; }
        if (status === 'Skipped' || status === 'Throttled' || status === 'Dry Run') {
            return 'warn-text';
        }
        return '';
    }

    lastOutcome(j) {
        if (j.status === 'Running') { return 'Still running'; }
        const map = {
            Success: 'Succeeded', Failed: 'Failed', 'Dry Run': 'Test mode',
            Skipped: 'Skipped', Throttled: 'Held back', Stuck: 'Timed out'
        };
        return map[j.lastRunStatus] || j.lastRunStatus || 'Not run yet';
    }

    /** The same facts the old console showed, without the framework's words. */
    stateLabel(j) {
        if (j.status === 'Suspended') { return 'Switched off after failures'; }
        if (j.status === 'Expired') { return 'Finished — past its end date'; }
        if (!j.enabled) { return 'Paused'; }
        if (!j.isActive) {
            return j.startDate && new Date(j.startDate) > new Date()
                ? `Starts ${j.startDate}`
                : 'Past its end date';
        }
        if (j.dryRun) { return 'Test mode — runs nothing'; }
        if (j.daysRemaining !== null && j.daysRemaining !== undefined && j.daysRemaining <= 7) {
            return `Active, ${j.daysRemaining} day(s) left`;
        }
        if (j.pinned) { return 'Active, exact minute'; }
        return 'Active';
    }

    stateClass(j) {
        if (j.status === 'Suspended') { return 'err-text'; }
        if (!j.enabled || j.status === 'Expired' || !j.isActive) {
            return 'slds-text-color_weak';
        }
        if (j.dryRun) { return 'warn-text'; }
        if (j.daysRemaining !== null && j.daysRemaining !== undefined && j.daysRemaining <= 7) {
            return 'warn-text';
        }
        return '';
    }

    // ------------------------------------------------- convert from Setup

    async openConvert() {
        this.showConvert = true;
        this.convertPick = undefined;
        this.convertPreview = [];
        this.convertible = [];
        this.convertResults = [];
        this.selectedIds = [];
        try {
            const rows = await listConvertibleApex();
            this.convertible = rows.map((r) => this.decorateConvertible(r));
        } catch (e) {
            this.toastError('Could not read the scheduled jobs in Setup', e);
        }
    }

    closeConvert() {
        this.showConvert = false;
        this.convertPick = undefined;
        this.convertPreview = [];
        this.convertResults = [];
        this.selectedIds = [];
    }

    handleConvertCheck(event) {
        const id = event.target.dataset.id;
        const on = event.target.checked;
        this.selectedIds = on
            ? this.selectedIds.concat([id])
            : this.selectedIds.filter((x) => x !== id);
        this.convertible = this.convertible.map((r) => ({
            ...r,
            picked: this.selectedIds.includes(r.cronTriggerId)
        }));
        if (this.selectedIds.length === 1) {
            this.pickForPreview(this.selectedIds[0]);
        } else {
            this.convertPick = undefined;
            this.convertPreview = [];
        }
    }

    selectAllConvertible() {
        this.selectedIds = this.convertible.filter((r) => r.selectable)
                                           .map((r) => r.cronTriggerId);
        this.convertible = this.convertible.map((r) => ({ ...r, picked: r.selectable }));
        this.convertPick = undefined;
        this.convertPreview = [];
    }

    clearSelection() {
        this.selectedIds = [];
        this.convertible = this.convertible.map((r) => ({ ...r, picked: false }));
        this.convertPick = undefined;
        this.convertPreview = [];
    }

    async convertSelected() {
        if (!this.selectedIds.length) { return; }
        this.converting = true;
        if (this.releaseOnly) {
            // Takeovers ship as definitions with Replaces Setup Job set; the
            // first sync after the release aborts the Setup schedule atomically.
            try {
                const files = await generateConversionDefinitionsApex({
                    cronTriggerIds: this.selectedIds
                });
                this.showConvert = false;
                this.openDefinitions(files);
            } catch (e) {
                this.toastError('Could not build the definitions', e);
            } finally {
                this.converting = false;
            }
            return;
        }
        try {
            const rows = await convertManyApex({
                cronTriggerIds: this.selectedIds, testMode: true
            });
            this.convertResults = rows.map((r) => ({
                ...r,
                resultClass: r.converted ? 'conv-res conv-res_ok' : 'conv-res conv-res_bad',
                verdict: r.converted ? 'Converted' : 'Not converted'
            }));
            const ok = rows.filter((r) => r.converted).length;
            this.toast(
                `Converted ${ok} of ${rows.length}`,
                ok === rows.length
                    ? 'All are in Test mode. Turn Test mode off once a cycle looks right.'
                    : 'Some could not be moved — each says why in the dialog.',
                ok === rows.length ? 'success' : 'warning'
            );
            this.selectedIds = [];
            await this.loadAll();
            const refreshed = await listConvertibleApex();
            this.convertible = refreshed.map((r) => this.decorateConvertible(r));
        } catch (e) {
            this.toastError('Could not convert', e);
        } finally {
            this.converting = false;
        }
    }

    /**
      * Selecting a row also asks the orchestrator when it thinks the job would
      * run. Shown beside the platform's own next run time, a mismatch here is
      * what catches a time zone or cron-dialect problem before anything is
      * deleted.
      */
    decorateConvertible(r) {
        return {
            ...r,
            rowClass: r.convertible ? 'conv' : 'conv conv_blocked',
            selectable: r.convertible,
            picked: false,
            lastRunText: r.lastFireLocal || 'never',
            nextRunText: r.nextFireLocal || '—',
            runsText: r.timesTriggered === null || r.timesTriggered === undefined
                ? '0' : String(r.timesTriggered),
            hasBlockers: r.blockers && r.blockers.length > 0,
            hasWarnings: r.warnings && r.warnings.length > 0,
            classText: r.className || 'unknown'
        };
    }

    async pickForPreview(id) {
        const row = this.convertible.find((r) => r.cronTriggerId === id);
        if (!row || !row.selectable) { return; }
        this.convertPick = {
            ...row,
            newName: row.name,
            newKey: row.suggestedKey,
            newBatchSize: null,
            newPriority: 5
        };
        this.convertPreview = ['Working it out…'];
        try {
            this.convertPreview = await preview({
                cronExpression: row.cronExpression,
                timeZone: row.timeZone
            });
        } catch (e) {
            this.convertPreview = ['Could not work out that schedule.'];
        }
    }

    handleConvertField(event) {
        this.convertPick = {
            ...this.convertPick,
            [event.target.dataset.field]: event.target.value
        };
    }

    async saveConvert() {
        if (this.selectedIds.length > 1) { return this.convertSelected(); }
        if (!this.convertPick) { return; }
        this.converting = true;
        try {
            const r = await convertApex({
                payload: JSON.stringify({
                    cronTriggerId: this.convertPick.cronTriggerId,
                    name: this.convertPick.newName,
                    jobKey: this.convertPick.newKey,
                    batchSize: this.convertPick.newBatchSize || null,
                    priority: this.convertPick.newPriority || null,
                    testMode: true
                })
            });
            this.showConvert = false;
            this.toast(`Converted ${r.jobName}`, r.summary, 'success');
            await this.loadAll();
        } catch (e) {
            this.toastError('Could not convert that job', e);
        } finally {
            this.converting = false;
        }
    }

    get convertibleCount() {
        return this.convertible.filter((r) => r.convertible).length;
    }

    get blockedCount() {
        return this.convertible.filter((r) => !r.convertible).length;
    }

    get convertHeadline() {
        if (!this.convertible.length) {
            return 'No scheduled Apex jobs in Setup, apart from this framework\'s own.';
        }
        const blocked = this.blockedCount;
        return `${this.convertibleCount} of ${this.convertible.length} scheduled job(s) can be `
            + `taken over.${blocked ? ` ${blocked} cannot — each says why below.` : ''}`;
    }

    get convertDisabled() {
        return this.converting || (!this.convertPick && this.selectedIds.length === 0);
    }

    get convertButtonLabel() {
        const n = this.selectedIds.length;
        return n > 1 ? `Convert ${n} and remove from Setup` : 'Convert and remove from Setup';
    }

    get hasSelection() { return this.selectedIds.length > 0; }
    get hasResults() { return this.convertResults.length > 0; }
    get showSinglePanel() { return !!this.convertPick && this.selectedIds.length <= 1; }
    get bulkNote() {
        return `${this.selectedIds.length} schedules will be moved, each in Test mode. `
            + 'Their Setup entries are removed one at a time; anything that cannot be '
            + 'removed leaves its job switched off rather than running twice.';
    }

    // ------------------------------------------------------------ restore

    async openRestore(row) {
        this.restoring = false;
        this.acceptShift = false;
        try {
            this.restorePlan = await planRestoreApex({ jobId: row.id });
            this.showRestore = true;
        } catch (e) {
            this.toastError('Could not work out what restoring would do', e);
        }
    }

    closeRestore() {
        this.showRestore = false;
        this.restorePlan = undefined;
    }

    handleAcceptShift(event) { this.acceptShift = event.target.checked; }

    async doRestore() {
        this.restoring = true;
        try {
            const msg = await restoreApex({
                jobId: this.restorePlan.jobId,
                acceptTimeZoneShift: this.acceptShift
            });
            this.showRestore = false;
            this.toast('Restored to Setup', msg, 'success');
            await this.loadAll();
        } catch (e) {
            this.toastError('Could not restore', e);
        } finally {
            this.restoring = false;
        }
    }

    get restoreBlocked() {
        if (!this.restorePlan) { return true; }
        if (this.restorePlan.blockers.length) { return true; }
        if (!this.restorePlan.timeZoneMatches && !this.acceptShift) { return true; }
        return this.restoring;
    }

    get restoreHasBlockers() {
        return !!(this.restorePlan && this.restorePlan.blockers.length);
    }

    get restoreZoneDiffers() {
        return !!(this.restorePlan && !this.restorePlan.timeZoneMatches);
    }

    get originalFireText() {
        return this.restorePlan ? this.restorePlan.originalFireTimes.join('\n') : '';
    }

    get restoredFireText() {
        return this.restorePlan ? this.restorePlan.restoredFireTimes.join('\n') : '';
    }

    get convertPreviewText() {
        return this.convertPreview.join('\n');
    }

    // ------------------------------------------------------------- header

    get bannerClass() {
        const tone = this.health ? this.health.statusTone : 'ok';
        return `banner banner_${tone || 'ok'}`;
    }

    get bannerIcon() {
        const tone = this.health ? this.health.statusTone : 'ok';
        if (tone === 'error') { return 'utility:error'; }
        if (tone === 'warning') { return 'utility:warning'; }
        return 'utility:success';
    }

    get bannerVariant() {
        const tone = this.health ? this.health.statusTone : 'ok';
        if (tone === 'error') { return 'error'; }
        if (tone === 'warning') { return 'warning'; }
        return 'success';
    }

    get pauseLabel() {
        return this.health && this.health.killSwitch ? 'Resume all jobs' : 'Pause all jobs';
    }

    get pauseVariant() {
        return this.health && this.health.killSwitch ? 'brand' : 'destructive-text';
    }

    get isAdmin() {
        return !!(this.health && this.health.canAdminister);
    }

    get failuresLabel() {
        if (!this.health) { return '—'; }
        return `${this.health.failures24h} of ${this.health.runs24h}`;
    }

    get nextCheckLabel() {
        if (!this.health) { return '—'; }
        return this.health.nextCheckLocal || 'not scheduled';
    }

    get dueTabLabel() {
        const n = this.nextCheck ? this.nextCheck.willRunCount : 0;
        return n ? `Next up (${n})` : 'Next up';
    }

    get problemsTabLabel() {
        return this.problems.length ? `Errors (${this.problems.length})` : 'Errors';
    }

    get nextCheckHeadline() {
        if (!this.nextCheck) { return ''; }
        if (!this.nextCheck.installed) {
            return 'The scheduler is not installed, so nothing is due.';
        }
        if (this.nextCheck.paused) {
            return 'Every job is paused, so nothing will start at the next check.';
        }
        const when = this.nextCheck.checkAtLocal || 'shortly';
        const blocked = this.nextCheck.due.filter((d) => d.verdict === 'Never runs').length;
        const tail = blocked
            ? ` ${blocked} job(s) below will never run as configured — check the Why column.`
            : '';
        return `${this.nextCheck.willRunCount} job(s) start at the next check, ${when}. `
            + `Every configured job is listed with what will happen to it. `
            + `Jobs are checked every ${this.nextCheck.everyMinutes} minutes.${tail}`;
    }

    get slotTileClass() {
        if (!this.health) { return 'tile'; }
        const pct = (this.health.slotsUsed / this.health.slotLimit) * 100;
        if (pct >= 85) { return 'tile hot'; }
        if (pct >= 60) { return 'tile warn'; }
        return 'tile ok';
    }

    get slotMeterClass() {
        if (!this.health) { return 'meter'; }
        const pct = (this.health.slotsUsed / this.health.slotLimit) * 100;
        return pct >= 85 ? 'meter hot' : 'meter';
    }

    get slotBarStyle() {
        if (!this.health) { return 'width:0%'; }
        const pct = Math.min(100, (this.health.slotsUsed / this.health.slotLimit) * 100);
        return `width:${pct}%`;
    }

    /**
      * The CronTrigger rows, dressed for a table: a plain-English purpose, a
      * readable fire time instead of an ISO string, and a colour for a state
      * that is not WAITING.
      */
    get registeredEntries() {
        if (!this.health || !this.health.triggers) { return []; }
        return this.health.triggers.map((t) => ({
            ...t,
            kind: t.name === 'AJO Supervisor'
                ? 'Nightly tidy-up'
                : 'Looks for due jobs',
            stateClass: t.state === 'WAITING' || t.state === 'ACQUIRED' ? '' : 'warn-text',
            nextFireText: when(t.nextFireTime)
        }));
    }

    get batchLabel() {
        if (!this.health) { return '—'; }
        return `${this.health.batchesInFlight} / ${this.health.maxConcurrentBatches}`;
    }

    /** Reads as a sentence, like every other tab's, and names the active filters. */
    get activityLede() {
        const base = {
            all: 'Everything that has run, newest first.',
            failures: 'Runs that failed or timed out.',
            today: 'Runs from the last 24 hours.'
        }[this.activityFilter] || 'Everything that has run, newest first.';

        const parts = [];
        if (this.selectedJobId) { parts.push(`${this.selectedJobName} only`); }
        if (this.activitySlot !== '') {
            const opt = this.slotOptions.find((o) => o.value === this.activitySlot);
            if (opt) { parts.push(`${opt.label.toLowerCase()} only`); }
        }
        return parts.length ? `${base} Showing ${parts.join(', ')}.` : base;
    }

    /**
      * A slot filter is only meaningful once more than one scheduled check has
      * run something — with a single slot it selects exactly what is already
      * on screen, so it is hidden rather than offered as a dead control.
      */
    get showSlotFilter() {
        return this.slotOptions.length > 2;
    }

    get filterAllVariant() { return this.activityFilter === 'all' ? 'brand' : 'neutral'; }
    get filterFailVariant() { return this.activityFilter === 'failures' ? 'brand' : 'neutral'; }
    get filterTodayVariant() { return this.activityFilter === 'today' ? 'brand' : 'neutral'; }

    get uninstallBlocked() {
        return this.uninstallConfirm.trim().toLowerCase() !== 'uninstall';
    }

    get editorTitle() {
        return this.draft.id ? `Edit ${this.draft.name || 'job'}` : 'New job';
    }

    get detailTitle() {
        return this.detailRow ? `${this.detailRow.jobName} — ${this.detailRow.name}` : '';
    }

    /** Plain-English echo of the dates, so the window is legible before saving. */
    get windowHint() {
        const { startDate, endDate } = this.draft;
        if (!endDate) {
            return startDate
                ? `Runs from ${startDate} onwards, with no end date.`
                : 'Runs indefinitely once switched on.';
        }
        const start = startDate ? new Date(startDate) : new Date();
        const end = new Date(endDate);
        if (end < start) { return 'The end date is before the start date.'; }
        const days = Math.round((end - start) / MS_PER_DAY) + 1;
        return `Runs for ${days} day(s), from ${startDate || 'today'} through ${endDate} `
            + 'inclusive, then stops on its own.';
    }

    // ------------------------------------------------------------ filters

    handleFilter(event) {
        this.activityFilter = event.target.dataset.filter;
        this.loadActivity();
    }

    handleSlotChange(event) {
        this.activitySlot = event.detail.value;
        this.loadActivity();
    }

    clearJobFilter() {
        this.selectedJobId = null;
        this.selectedJobName = '';
        this.loadActivity();
    }

    // ------------------------------------------------------------- actions

    async handleJobAction(event) {
        const action = event.detail.action.name;
        const row = event.detail.row;

        if (action === 'run') {
            await this.runOne(row.id, row.name);
        } else if (action === 'history') {
            this.selectedJobId = row.id;
            this.selectedJobName = row.name;
            this.activityFilter = 'all';
            this.activitySlot = '';
            await this.loadActivity();
            this.template.querySelector('lightning-tabset').activeTabValue = 'activity';
        } else if (action === 'toggle') {
            try {
                await setEnabledApex({ jobId: row.id, enabled: !row.enabled });
                this.toast(
                    row.enabled ? 'Paused' : 'Resumed',
                    row.enabled || row.isActive
                        ? row.name
                        : `${row.name} — still outside its dates: ${row.windowStatus}`,
                    'success'
                );
                await this.loadAll();
            } catch (e) {
                this.toastError('Could not change the job', e);
            }
        } else if (action === 'edit') {
            this.openEdit(row);
        } else if (action === 'restore') {
            await this.openRestore(row);
        } else if (action === 'nextcheck') {
            try {
                const msg = await runAtNextCheckApex({ jobId: row.id });
                this.toast(row.name, msg, 'success');
                await this.loadAll();
            } catch (e) {
                this.toastError('Could not schedule it', e);
            }
        } else if (action === 'export') {
            try {
                const file = await exportDefinitionApex({ jobId: row.id });
                this.openDefinitions([file]);
            } catch (e) {
                this.toastError('Could not build the definition', e);
            }
        }
    }

    async handleProblemAction(event) {
        const action = event.detail.action.name;
        const row = event.detail.row;
        if (action === 'detail') {
            this.detailRow = row;
            this.showDetail = true;
        } else if (action === 'retry') {
            try {
                const status = await retryRunApex({ runId: row.id });
                this.toast('Queued again', `${row.jobName} — ${status}. It runs in its own `
                    + 'transaction; refresh in a moment for the result.', 'success');
                await this.loadAll();
            } catch (e) {
                this.toastError('Could not run it again', e);
            }
        }
    }

    async runOne(jobId, jobName) {
        try {
            const status = await runNowByIdApex({ jobId });
            this.toast(`${jobName}: ${status}`,
                'It runs in its own transaction, as you. Refresh in a moment for the result.',
                'success');
            await this.loadAll();
        } catch (e) {
            this.toastError('The run failed', e);
        }
    }

    closeDetail() {
        this.showDetail = false;
        this.detailRow = undefined;
    }

    // -------------------------------------------------------------- editor

    openEdit(row) {
        if (row.editLocked) {
            this.toast('Cannot edit yet', row.editLockReason, 'warning');
            return;
        }
        this.draft = {
            ...EMPTY_DRAFT,
            id: row.id,
            name: row.name,
            jobKey: row.jobKey,
            apexClass: row.apexClass,
            executionType: row.executionType,
            cronExpression: row.cronExpression,
            timeZone: row.timeZone,
            priority: row.priority,
            overlapPolicy: row.overlapPolicy || 'Skip',
            enabled: row.enabled,
            startDate: row.startDate || '',
            endDate: row.endDate || '',
            dryRun: row.dryRun,
            pinned: row.pinned,
            description: row.description || ''
        };
        this.showEditor = true;
        this.refreshPreview();
        this.checkClass(row.apexClass);
    }

    openNew() {
        this.draft = { ...EMPTY_DRAFT };
        this.classHint = '';
        this.showEditor = true;
        this.refreshPreview();
    }

    closeEditor() {
        this.showEditor = false;
    }

    handleDraftChange(event) {
        this.draft = { ...this.draft, [event.target.dataset.field]: event.target.value };
    }

    handleDraftToggle(event) {
        this.draft = { ...this.draft, [event.target.dataset.field]: event.target.checked };
    }

    handleCronChange(event) {
        this.handleDraftChange(event);
        this.refreshPreview();
    }

    handleWindowChange(event) {
        this.handleDraftChange(event);
    }

    handleClassChange(event) {
        this.handleDraftChange(event);
        this.checkClass(event.target.value);
    }

    async checkClass(className) {
        if (!className) { this.classHint = ''; return; }
        try {
            const kind = await classifyClass({ className });
            if (kind) {
                this.classHint = `Found — implements ${kind}.`;
                this.classHintOk = 'yes';
                this.draft = { ...this.draft, executionType: kind };
            } else {
                this.classHint = 'No Apex class of that name was found, or it is not one this '
                    + 'framework can run.';
                this.classHintOk = 'no';
            }
        } catch (e) {
            this.classHint = '';
        }
    }

    async refreshPreview() {
        if (!this.draft.cronExpression) { return; }
        try {
            const [lines, desc] = await Promise.all([
                preview({ cronExpression: this.draft.cronExpression, timeZone: this.draft.timeZone }),
                describeCronApex({ cronExpression: this.draft.cronExpression })
            ]);
            this.previewText = lines.join('\n');
            this.cronDescription = desc;
        } catch (e) {
            this.previewText = 'Could not work out that schedule.';
            this.cronDescription = '';
        }
    }

    /** True while jobs are defined only in custom metadata (no unmanaged jobs). */
    get releaseOnly() {
        return !(this.health && this.health.unmanagedAllowed);
    }

    get saveLabel() {
        return this.releaseOnly ? 'Generate definition' : 'Save';
    }

    async saveDraft() {
        this.saving = true;
        if (this.releaseOnly) {
            // Jobs change through a release: produce the record file to commit.
            try {
                const file = await generateDefinitionApex({ payload: JSON.stringify(this.draft) });
                this.showEditor = false;
                this.openDefinitions([file]);
            } catch (e) {
                this.toastError('Could not build the definition', e);
            } finally {
                this.saving = false;
            }
            return;
        }
        try {
            await saveJobApex({ payload: JSON.stringify(this.draft) });
            this.toast('Saved', this.draft.name, 'success');
            this.showEditor = false;
            await this.loadAll();
        } catch (e) {
            this.toastError('Could not save', e);
        } finally {
            this.saving = false;
        }
    }

    async deleteDraft() {
        if (!this.draft.id) { return; }
        this.saving = true;
        try {
            await deleteJobApex({ jobId: this.draft.id });
            this.toast('Deleted', this.draft.name, 'success');
            if (this.selectedJobId === this.draft.id) { this.clearJobFilter(); }
            this.showEditor = false;
            await this.loadAll();
        } catch (e) {
            this.toastError('Could not delete the job', e);
        } finally {
            this.saving = false;
        }
    }

    // --------------------------------------------------------------- setup

    async install() {
        this.busy = true;
        try {
            const armed = await armFrameworkApex();
            this.toast('Scheduler installed',
                armed.length
                    ? `Created ${armed.length} scheduled entr(y/ies).`
                    : 'Everything was already in place.',
                'success');
            await this.loadAll();
        } catch (e) {
            this.toastError('Could not install the scheduler', e);
        } finally {
            this.busy = false;
        }
    }

    askUninstall() {
        this.uninstallConfirm = '';
        this.showUninstall = true;
    }

    closeUninstall() {
        this.showUninstall = false;
    }

    handleUninstallConfirm(event) {
        this.uninstallConfirm = event.target.value || '';
    }

    async uninstall() {
        this.busy = true;
        try {
            const removed = await disarmFrameworkApex();
            this.showUninstall = false;
            this.toast('Scheduler uninstalled',
                `${removed.length} entr(y/ies) removed. No job will run until you install again.`,
                'warning');
            await this.loadAll();
        } catch (e) {
            this.toastError('Could not uninstall', e);
        } finally {
            this.busy = false;
        }
    }

    async runMaintenance() {
        this.busy = true;
        try {
            const summary = await runSupervisorApex();
            this.toast('Maintenance finished', summary, 'success');
            await this.loadAll();
        } catch (e) {
            this.toastError('Maintenance failed', e);
        } finally {
            this.busy = false;
        }
    }

    async syncNow() {
        this.busy = true;
        try {
            const summary = await syncNowApex();
            this.toast('Definitions synced', summary, 'success');
            await this.loadAll();
        } catch (e) {
            this.toastError('Sync failed', e);
        } finally {
            this.busy = false;
        }
    }

    // ------------------------------------------------- definition file dialog

    openDefinitions(files) {
        this.definitionFiles = (files || []).map((f, i) => ({
            ...f,
            key: `${f.fileName}-${i}`,
            path: `force-app/main/default/customMetadata/${f.fileName}`,
            hasProblems: !!(f.problems && f.problems.length)
        }));
        this.showDefinitions = true;
    }

    closeDefinitions() {
        this.showDefinitions = false;
        this.definitionFiles = [];
    }

    async copyDefinition(event) {
        const file = this.definitionFiles.find((f) => f.key === event.target.dataset.key);
        if (!file) { return; }
        try {
            await navigator.clipboard.writeText(file.xml);
            this.toast('Copied', file.fileName, 'success');
        } catch (e) {
            this.toastError('Could not copy; select the text instead', e);
        }
    }

    async togglePause() {
        const pausing = !(this.health && this.health.killSwitch);
        try {
            await setKillSwitchApex({ enabled: pausing });
            await this.loadAll();
            this.toast(
                pausing ? 'All jobs paused' : 'All jobs resumed',
                pausing
                    ? 'Nothing will start until you resume. The schedule itself is untouched.'
                    : 'Jobs will start again at the next scheduled check.',
                pausing ? 'warning' : 'success'
            );
        } catch (e) {
            this.toastError('Could not change that', e);
        }
    }

    async seedDemo() {
        try {
            const n = await seedDemoJobsApex();
            this.toast('Demo jobs created', `${n} job(s) configured.`, 'success');
            await this.loadAll();
        } catch (e) {
            this.toastError('Could not create the demo jobs', e);
        }
    }

    // -------------------------------------------------------------- toasts

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    toastError(title, error) {
        const message =
            (error && error.body && error.body.message) ||
            (error && error.message) ||
            'Unexpected error.';
        this.dispatchEvent(new ShowToastEvent({ title, message, variant: 'error' }));
    }
}