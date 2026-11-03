import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAuditModeState from '@salesforce/apex/AuditrChangeLogController.getAuditModeState';
import getUnassignedEntries from '@salesforce/apex/AuditrChangeLogController.getUnassignedEntries';
import createChangeLog from '@salesforce/apex/AuditrChangeLogController.createChangeLog';
import packageEntries from '@salesforce/apex/AuditrChangeLogController.packageEntries';
import packageFilteredEntries from '@salesforce/apex/AuditrChangeLogController.packageFilteredEntries';

const BACKLOG_COUNT_CAP = 25000;
const DEFAULT_WINDOW_DAYS = 30;

const LOG_COLUMNS = [
    {
        label: 'Change Log',
        fieldName: 'recordUrl',
        type: 'url',
        initialWidth: 115,
        typeAttributes: { label: { fieldName: 'name' }, target: '_self' }
    },
    { label: 'Change Request', fieldName: 'changeRequestId', type: 'text', initialWidth: 140 },
    { label: 'Status', fieldName: 'status', type: 'text', initialWidth: 90 },
    { label: 'Entries', fieldName: 'totalEntries', type: 'number', initialWidth: 85 },
    { label: 'Target Actor', fieldName: 'targetActor', type: 'text', initialWidth: 175 },
    {
        label: 'Deployment',
        fieldName: 'deploymentDate',
        type: 'date',
        initialWidth: 160,
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
    },
    {
        label: 'Signed Off',
        fieldName: 'signedOffAt',
        type: 'date',
        initialWidth: 160,
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
    }
];

const BASE_ENTRY_COLUMNS = [
    {
        label: 'Entry',
        fieldName: 'recordUrl',
        type: 'url',
        initialWidth: 115,
        typeAttributes: { label: { fieldName: 'name' }, target: '_self' }
    },
    {
        label: 'Occurred At',
        fieldName: 'occurredAt',
        type: 'date',
        initialWidth: 175,
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
    },
    { label: 'Risk', fieldName: 'riskLevel', type: 'text', initialWidth: 95 },
    { label: 'Category', fieldName: 'category', type: 'text', initialWidth: 165 },
    { label: 'Section', fieldName: 'section', type: 'text', initialWidth: 150 },
    { label: 'Responsible Actor', fieldName: 'responsibleUsername', type: 'text', initialWidth: 190 },
    { label: 'Display Summary', fieldName: 'displayText', type: 'text', wrapText: true }
];

const BURST_COLUMN = { label: 'Burst', fieldName: 'burstCount', type: 'number', initialWidth: 75 };

function formatCompactNumber(value) {
    const num = Number(value) || 0;
    if (Math.abs(num) >= 10000) {
        return `${(num / 1000).toFixed(1).replace(/\.0$/, '')}K`;
    }
    return new Intl.NumberFormat().format(num);
}

export default class AuditrAuditMode extends LightningElement {
    logColumns = LOG_COLUMNS;

    // Applied (reactive wire) filters
    windowStart;
    windowEnd;
    actorUsername = '';
    // Staged filter inputs (applied on Apply Filters)
    windowStartInput;
    windowEndInput;
    actorInput = '';

    changeLogs = [];
    backlogCount = 0;
    entryRows = [];
    errorMessage = '';
    wiredStateResult;
    wiredEntriesResult;

    selectedChangeLogId = null;
    selectedEntryIds = [];
    groupBursts = false;
    isPackaging = false;
    isConfirmAllOpen = false;

    isCreateModalOpen = false;
    isSavingLog = false;
    newChangeRequestId = '';
    newDeploymentDate = null;
    newDescription = '';

    connectedCallback() {
        const now = new Date();
        this.windowEndInput = now.toISOString();
        this.windowStartInput = new Date(now.getTime() - DEFAULT_WINDOW_DAYS * 24 * 60 * 60 * 1000).toISOString();
        this.windowStart = this.windowStartInput;
        this.windowEnd = this.windowEndInput;
    }

    get hasChangeLogs() {
        return this.changeLogs.length > 0;
    }

    get hasEntryRows() {
        return this.entryRows.length > 0;
    }

    get selectedLog() {
        return this.changeLogs.find((log) => log.recordId === this.selectedChangeLogId) || null;
    }

    get selectedLogIsPackable() {
        return !!this.selectedLog && this.selectedLog.status === 'Draft' && !this.selectedLog.isPackagingInFlight;
    }

    get backlogCountSuffix() {
        return (this.backlogCount || 0) >= BACKLOG_COUNT_CAP ? '+' : '';
    }

    get formattedBacklogCount() {
        return `${formatCompactNumber(this.backlogCount)}${this.backlogCountSuffix}`;
    }

    get entryColumns() {
        return this.groupBursts ? [...BASE_ENTRY_COLUMNS, BURST_COLUMN] : BASE_ENTRY_COLUMNS;
    }

    get displayedRows() {
        if (!this.groupBursts) {
            return this.entryRows;
        }
        const groups = [];
        for (const row of this.entryRows) {
            const last = groups[groups.length - 1];
            if (last && last.responsibleUsername === row.responsibleUsername) {
                last._children = last._children || [];
                last._children.push(row);
                last.burstCount += 1;
            } else {
                groups.push({ ...row, burstCount: 1 });
            }
        }
        return groups;
    }

    get selectedLogLabel() {
        return this.selectedLog ? `${this.selectedLog.name} (${this.selectedLog.changeRequestId})` : 'No change log selected';
    }

    get packageSelectedLabel() {
        return `Package Selected (${this.selectedEntryIds.length})`;
    }

    get packageAllLabel() {
        return `Package All Matching (${this.formattedBacklogCount})`;
    }

    get canPackage() {
        return this.selectedLogIsPackable && !this.isPackaging;
    }

    get canPackageSelected() {
        return this.canPackage && this.selectedEntryIds.length > 0;
    }

    get packageSelectedDisabled() {
        return !this.canPackageSelected;
    }

    get packageAllDisabled() {
        return !this.canPackageAll;
    }

    get canPackageAll() {
        return this.canPackage && this.backlogCount > 0;
    }

    @wire(getAuditModeState, { windowStart: '$windowStart', windowEnd: '$windowEnd', actorUsername: '$actorUsername' })
    wiredState(result) {
        this.wiredStateResult = result;
        const { data, error } = result;
        if (data) {
            this.changeLogs = (data.changeLogs || []).map((log) => ({ ...log, recordUrl: `/${log.recordId}` }));
            this.backlogCount = data.backlogCount || 0;
            this.errorMessage = '';
        } else if (error) {
            this.errorMessage = this.extractError(error);
        }
    }

    @wire(getUnassignedEntries, { windowStart: '$windowStart', windowEnd: '$windowEnd', actorUsername: '$actorUsername' })
    wiredEntries(result) {
        this.wiredEntriesResult = result;
        const { data, error } = result;
        if (data) {
            this.entryRows = (data || []).map((row) => ({ ...row, recordUrl: `/${row.recordId}` }));
            this.errorMessage = '';
        } else if (error) {
            this.errorMessage = this.extractError(error);
        }
    }

    async refreshAll() {
        const refreshes = [];
        if (this.wiredStateResult) {
            refreshes.push(refreshApex(this.wiredStateResult));
        }
        if (this.wiredEntriesResult) {
            refreshes.push(refreshApex(this.wiredEntriesResult));
        }
        await Promise.all(refreshes);
    }

    handleLogSelection(event) {
        const selected = event.detail.selectedRows || [];
        this.selectedChangeLogId = selected.length > 0 ? selected[0].recordId : null;
    }

    handleEntrySelection(event) {
        const selected = event.detail.selectedRows || [];
        this.selectedEntryIds = selected.map((row) => row.recordId);
    }

    handleWindowStartChange(event) {
        this.windowStartInput = event.detail.value;
    }

    handleWindowEndChange(event) {
        this.windowEndInput = event.detail.value;
    }

    handleActorChange(event) {
        this.actorInput = event.detail.value;
    }

    handleApplyFilters() {
        this.selectedEntryIds = [];
        this.windowStart = this.windowStartInput;
        this.windowEnd = this.windowEndInput;
        this.actorUsername = this.actorInput;
    }

    handleBurstToggle(event) {
        this.groupBursts = event.target.checked;
        this.selectedEntryIds = [];
    }

    async handleRefresh() {
        await this.refreshAll();
    }

    async handlePackageSelected() {
        if (!this.canPackageSelected) {
            return;
        }
        await this.queuePackaging(() =>
            packageEntries({ changeLogId: this.selectedChangeLogId, entryIds: this.selectedEntryIds })
        );
        this.selectedEntryIds = [];
    }

    handleOpenConfirmAll() {
        if (this.canPackageAll) {
            this.isConfirmAllOpen = true;
        }
    }

    handleCancelConfirmAll() {
        this.isConfirmAllOpen = false;
    }

    async handleConfirmAll() {
        this.isConfirmAllOpen = false;
        await this.queuePackaging(() =>
            packageFilteredEntries({
                changeLogId: this.selectedChangeLogId,
                windowStart: this.windowStart,
                windowEnd: this.windowEnd,
                actorUsername: this.actorUsername
            })
        );
    }

    async queuePackaging(invokePackaging) {
        this.isPackaging = true;
        try {
            await invokePackaging();
            this.showToast(
                'Packaging Started',
                `Packaging is in progress for ${this.selectedLogLabel}. The batch process is running in the background and will finish shortly. Click Refresh to inspect status.`,
                'info'
            );
            await this.refreshAll();
        } catch (error) {
            this.showToast('Packaging Failed', this.extractError(error), 'error');
        } finally {
            this.isPackaging = false;
        }
    }

    handleOpenCreateModal() {
        this.newChangeRequestId = '';
        this.newDeploymentDate = null;
        this.newDescription = '';
        this.isCreateModalOpen = true;
    }

    handleCloseCreateModal() {
        this.isCreateModalOpen = false;
    }

    handleCrIdChange(event) {
        this.newChangeRequestId = event.detail.value;
    }

    handleDeploymentDateChange(event) {
        this.newDeploymentDate = event.detail.value;
    }

    handleDescriptionChange(event) {
        this.newDescription = event.detail.value;
    }

    async handleCreateSave() {
        this.isSavingLog = true;
        try {
            const newLogId = await createChangeLog({
                changeRequestId: this.newChangeRequestId,
                deploymentDate: this.newDeploymentDate || null,
                description: this.newDescription || null
            });
            this.isCreateModalOpen = false;
            this.selectedChangeLogId = newLogId;
            this.showToast('Change Log Created', 'Draft change log created. Select entries below to package into it.', 'success');
            await this.refreshAll();
        } catch (error) {
            this.showToast('Create Failed', this.extractError(error), 'error');
        } finally {
            this.isSavingLog = false;
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
        return 'Unable to load Audit Mode data.';
    }
}
