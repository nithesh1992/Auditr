import { LightningElement, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getControlCenterStatus from '@salesforce/apex/AuditrController.getControlCenterStatus';
import runSyncNow from '@salesforce/apex/AuditrController.runSyncNow';
import runReclassify from '@salesforce/apex/AuditrController.runReclassify';
import runPurgeNow from '@salesforce/apex/AuditrController.runPurgeNow';
import scheduleDailySync from '@salesforce/apex/AuditrController.scheduleDailySync';
import unscheduleDailySync from '@salesforce/apex/AuditrController.unscheduleDailySync';
import scheduleDailyPurge from '@salesforce/apex/AuditrController.scheduleDailyPurge';
import unscheduleDailyPurge from '@salesforce/apex/AuditrController.unscheduleDailyPurge';

const HOUR_OPTIONS = Array.from({ length: 24 }, (_, hour) => ({
    label: `${String(hour).padStart(2, '0')}:00`,
    value: String(hour)
}));

const UNCLASSIFIED_COLUMNS = [
    { label: 'Action Code', fieldName: 'actionCode', type: 'text' },
    { label: 'Setup Section', fieldName: 'section', type: 'text' },
    { label: 'Entries', fieldName: 'entryCount', type: 'number', initialWidth: 100 }
];

const JOB_COLUMNS = [
    { label: 'Batch Class', fieldName: 'className', type: 'text' },
    { label: 'Status', fieldName: 'status', type: 'text', initialWidth: 115 },
    { label: 'Batches', fieldName: 'jobItemsProcessed', type: 'number', initialWidth: 95 },
    { label: 'Errors', fieldName: 'numberOfErrors', type: 'number', initialWidth: 85 },
    {
        label: 'Completed At',
        fieldName: 'completedDate',
        type: 'date',
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
    }
];

const RULE_COLUMNS = [
    { label: 'Priority', fieldName: 'priority', type: 'number', initialWidth: 95 },
    { label: 'Rule Label', fieldName: 'label', type: 'text' },
    { label: 'Target', fieldName: 'matchTarget', type: 'text', initialWidth: 135 },
    { label: 'Operator', fieldName: 'matchOperator', type: 'text', initialWidth: 120 },
    { label: 'Match Value', fieldName: 'matchValue', type: 'text' },
    { label: 'Category', fieldName: 'category', type: 'text' },
    { label: 'Risk Level', fieldName: 'riskLevel', type: 'text', initialWidth: 115 }
];

export default class AuditrControlCenter extends LightningElement {
    hourOptions = HOUR_OPTIONS;
    unclassifiedColumns = UNCLASSIFIED_COLUMNS;
    jobColumns = JOB_COLUMNS;
    ruleColumns = RULE_COLUMNS;

    status = {
        isActive: true,
        backfillDays: 180,
        batchSize: 200,
        enablePurge: false,
        retentionDays: 365,
        preferredSyncHour: 2,
        totalEntries: 0,
        unclassifiedEntries: 0,
        lastSyncedOccurredAt: null,
        lastSyncJobStatus: null,
        lastSyncJobCompletedAt: null,
        isScheduled: false,
        scheduledSyncHour: 2,
        nextFireTime: null,
        scheduleOwnerUsername: null,
        isScheduleOwnerActive: true,
        isPurgeScheduled: false,
        scheduledPurgeHour: 3,
        nextPurgeFireTime: null,
        purgeScheduleOwnerUsername: null,
        isPurgeScheduleOwnerActive: true,
        isStaleSync: false,
        healthWarning: null,
        recentJobs: [],
        activeRules: [],
        topUnclassifiedActions: []
    };

    selectedHour = '2';
    selectedPurgeHour = '3';
    ruleSearchTerm = '';
    isBusy = false;
    wiredStatusResult;

    get engineStatusLabel() {
        return this.status.isActive ? 'Active' : 'Paused';
    }

    get lastSyncJobLabel() {
        return this.status.lastSyncJobStatus || 'No Sync Run';
    }

    get newestEntryAgeLabel() {
        if (!this.status.lastSyncedOccurredAt) {
            return 'None';
        }
        const occurredMs = new Date(this.status.lastSyncedOccurredAt).getTime();
        if (Number.isNaN(occurredMs)) {
            return 'None';
        }
        const diffMinutes = Math.max(0, Math.floor((Date.now() - occurredMs) / 60000));
        if (diffMinutes < 60) {
            return `${diffMinutes}m ago`;
        }
        const diffHours = Math.floor(diffMinutes / 60);
        if (diffHours < 24) {
            return `${diffHours}h ${diffMinutes % 60}m ago`;
        }
        const diffDays = Math.floor(diffHours / 24);
        return `${diffDays}d ${diffHours % 24}h ago`;
    }

    get scheduleStatusLabel() {
        return this.status.isScheduled ? 'Scheduled' : 'Not Scheduled';
    }

    get retentionStatusLabel() {
        if (!this.status.enablePurge || !this.status.retentionDays || this.status.retentionDays <= 0) {
            return 'Retain Indefinitely (Purge Off)';
        }
        return this.status.isPurgeScheduled
            ? `Purge > ${this.status.retentionDays}d (Scheduled)`
            : `Purge > ${this.status.retentionDays}d (Not Scheduled)`;
    }

    get isPurgeConfigured() {
        return Boolean(this.status.enablePurge && this.status.retentionDays && this.status.retentionDays > 0);
    }

    get showPurgeSchedule() {
        return this.isPurgeConfigured || this.status.isPurgeScheduled;
    }

    get scheduleGridClass() {
        return this.showPurgeSchedule ? 'schedule-grid' : 'schedule-grid schedule-grid-single';
    }

    get showNextPurgeTime() {
        return Boolean(this.status.enablePurge && this.status.isPurgeScheduled && this.status.nextPurgeFireTime);
    }

    get hasUnclassifiedActions() {
        return Array.isArray(this.status.topUnclassifiedActions) && this.status.topUnclassifiedActions.length > 0;
    }

    get unclassifiedActionRows() {
        return (this.status.topUnclassifiedActions || []).map((row, index) => ({
            ...row,
            rowKey: `${row.actionCode || 'blank'}-${row.section || 'blank'}-${index}`
        }));
    }

    get hasRecentJobs() {
        return Array.isArray(this.status.recentJobs) && this.status.recentJobs.length > 0;
    }

    get filteredRules() {
        const rules = this.status.activeRules || [];
        const term = (this.ruleSearchTerm || '').trim().toLowerCase();
        if (!term) {
            return rules;
        }
        return rules.filter((rule) =>
            [rule.label, rule.matchTarget, rule.matchOperator, rule.matchValue, rule.category, rule.riskLevel]
                .filter(Boolean)
                .some((val) => val.toLowerCase().includes(term))
        );
    }

    get rulesCardTitle() {
        const total = (this.status.activeRules || []).length;
        return `Active Classification Rules (${this.filteredRules.length} of ${total})`;
    }

    @wire(getControlCenterStatus)
    wiredStatus(result) {
        this.wiredStatusResult = result;
        const { data, error } = result;
        if (data) {
            this.status = { ...data };
            const syncHour = data.scheduledSyncHour ?? data.preferredSyncHour;
            if (syncHour !== undefined && syncHour !== null) {
                this.selectedHour = String(syncHour);
            }
            if (data.scheduledPurgeHour !== undefined && data.scheduledPurgeHour !== null) {
                this.selectedPurgeHour = String(data.scheduledPurgeHour);
            }
        } else if (error) {
            this.showToast('Control Center Error', this.extractError(error), 'error');
        }
    }

    handleHourChange(event) {
        this.selectedHour = event.detail.value;
    }

    handlePurgeHourChange(event) {
        this.selectedPurgeHour = event.detail.value;
    }

    handleRuleSearchChange(event) {
        this.ruleSearchTerm = event.target.value;
    }

    async handleRefresh() {
        if (this.wiredStatusResult) {
            await refreshApex(this.wiredStatusResult);
        }
    }

    async handleSyncNow() {
        await this.executeAdminAction(
            () => runSyncNow(),
            'Sync Queued',
            'AuditrSyncBatch has been queued to ingest new SetupAuditTrail entries.'
        );
    }

    async handleReclassifyUnclassified() {
        await this.executeAdminAction(
            () => runReclassify({ onlyUnclassified: true }),
            'Reclassification Queued',
            'AuditrReclassifyBatch queued for Unclassified entries.'
        );
    }

    async handleReclassifyAll() {
        await this.executeAdminAction(
            () => runReclassify({ onlyUnclassified: false }),
            'Full Reclassification Queued',
            'AuditrReclassifyBatch queued across all stored Auditr entries.'
        );
    }

    async handlePurgeNow() {
        if (!this.status.enablePurge) {
            this.showToast(
                'Purge Disabled',
                'Retention purging is disabled (Enable_Purge__c = false). Enable it in Setup -> Custom Metadata Types -> Auditr Setting to purge expired records.',
                'warning'
            );
            return;
        }

        const retentionDays = this.status.retentionDays || 0;
        await this.executeAdminAction(
            () => runPurgeNow(),
            'Retention Purge Queued',
            `AuditrPurgeBatch queued to delete records older than ${retentionDays} days.`
        );
    }

    async handleScheduleSync() {
        const hour = parseInt(this.selectedHour, 10);
        await this.executeAdminAction(
            () => scheduleDailySync({ hourOfDay: hour }),
            'Daily Sync Scheduled',
            `Auditr_Daily_Sync scheduled for ${String(hour).padStart(2, '0')}:00 daily.`
        );
    }

    async handleUnscheduleSync() {
        await this.executeAdminAction(
            () => unscheduleDailySync(),
            'Daily Sync Unscheduled',
            'Auditr_Daily_Sync schedule has been removed.'
        );
    }

    async handleSchedulePurge() {
        if (!this.status.enablePurge || !this.status.retentionDays || this.status.retentionDays <= 0) {
            this.showToast(
                'Purge Disabled',
                'Enable "Enable Purge" and set "Retention Days" (> 0) in Setup -> Custom Metadata Types -> Auditr Setting before scheduling.',
                'warning'
            );
            return;
        }
        const hour = parseInt(this.selectedPurgeHour, 10);
        await this.executeAdminAction(
            () => scheduleDailyPurge({ hourOfDay: hour }),
            'Daily Purge Scheduled',
            `Auditr_Daily_Purge scheduled for ${String(hour).padStart(2, '0')}:00 daily (retaining ${this.status.retentionDays} days).`
        );
    }

    async handleUnschedulePurge() {
        await this.executeAdminAction(
            () => unscheduleDailyPurge(),
            'Daily Purge Unscheduled',
            'Auditr_Daily_Purge schedule has been removed.'
        );
    }

    async executeAdminAction(actionFn, successTitle, successMessage) {
        this.isBusy = true;
        try {
            await actionFn();
            this.showToast(successTitle, successMessage, 'success');
            if (this.wiredStatusResult) {
                await refreshApex(this.wiredStatusResult);
            }
        } catch (error) {
            this.showToast('Action Failed', this.extractError(error), 'error');
        } finally {
            this.isBusy = false;
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    extractError(error) {
        if (error?.body?.message) {
            return error.body.message;
        }
        if (error?.message) {
            return error.message;
        }
        return 'An unexpected error occurred.';
    }
}