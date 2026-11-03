import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAuditEntries from '@salesforce/apex/AuditrChangeLogController.getAuditEntries';
import searchDraftChangeLogs from '@salesforce/apex/AuditrChangeLogController.searchDraftChangeLogs';
import createChangeLog from '@salesforce/apex/AuditrChangeLogController.createChangeLog';
import packageEntries from '@salesforce/apex/AuditrChangeLogController.packageEntries';
import packageFilteredEntries from '@salesforce/apex/AuditrChangeLogController.packageFilteredEntries';
import resolveUser from '@salesforce/apex/AuditrChangeLogController.resolveUser';
import getLatestSyncedOccurredAt from '@salesforce/apex/AuditrController.getLatestSyncedOccurredAt';

const TIME_MODE_OPTIONS = [
    { label: 'Date Range (Window)', value: 'window' },
    { label: 'Incident (Time ± Radius)', value: 'incident' }
];

const RADIUS_OPTIONS = [
    { label: '± 15 Minutes', value: '15' },
    { label: '± 30 Minutes', value: '30' },
    { label: '± 1 Hour', value: '60' },
    { label: '± 4 Hours', value: '240' },
    { label: '± 12 Hours', value: '720' }
];

const PACKAGE_TARGET_OPTIONS = [
    { label: 'Link to Existing Change Log', value: 'existing' },
    { label: 'Create New Change Log', value: 'create' }
];

const FLAT_COLUMNS = [
    {
        label: 'Entry',
        fieldName: 'recordUrl',
        type: 'url',
        initialWidth: 120,
        typeAttributes: { label: { fieldName: 'name' }, target: '_blank' }
    },
    {
        label: 'Occurred At',
        fieldName: 'occurredAt',
        type: 'date',
        initialWidth: 175,
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
    },
    { label: 'Risk', fieldName: 'riskLevel', type: 'text', initialWidth: 90 },
    { label: 'Category', fieldName: 'category', type: 'text', initialWidth: 155 },
    { label: 'Section', fieldName: 'section', type: 'text', initialWidth: 140 },
    { label: 'Responsible Actor', fieldName: 'responsibleUsername', type: 'text', initialWidth: 180 },
    { label: 'Delegate', fieldName: 'delegateUser', type: 'text', initialWidth: 120 },
    { label: 'Display Summary', fieldName: 'displayText', type: 'text', wrapText: true },
    {
        label: 'Change Request',
        fieldName: 'changeRequestUrl',
        type: 'url',
        initialWidth: 140,
        typeAttributes: { label: { fieldName: 'changeRequestDisplay' }, target: '_blank' }
    }
];

const TREE_COLUMNS = [
    {
        label: 'Action / Entry',
        fieldName: 'displayName',
        type: 'text',
        initialWidth: 220
    },
    {
        label: 'Occurred At',
        fieldName: 'occurredAt',
        type: 'date',
        initialWidth: 175,
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
    },
    { label: 'Risk', fieldName: 'riskLevel', type: 'text', initialWidth: 90 },
    { label: 'Category', fieldName: 'category', type: 'text', initialWidth: 140 },
    { label: 'Section', fieldName: 'section', type: 'text', initialWidth: 130 },
    { label: 'Responsible Actor', fieldName: 'responsibleUsername', type: 'text', initialWidth: 170 },
    { label: 'Burst Size', fieldName: 'burstSizeLabel', type: 'text', initialWidth: 100 },
    { label: 'Display Summary', fieldName: 'displayText', type: 'text', wrapText: true },
    { label: 'Status', fieldName: 'changeRequestDisplay', type: 'text', initialWidth: 130 }
];

export default class AuditrAuditMode extends LightningElement {
    timeModeOptions = TIME_MODE_OPTIONS;
    radiusOptions = RADIUS_OPTIONS;
    packageTargetOptions = PACKAGE_TARGET_OPTIONS;
    flatColumns = FLAT_COLUMNS;
    treeColumns = TREE_COLUMNS;

    timeMode = 'window';
    windowStartInput;
    windowEndInput;
    incidentTimestampInput;
    incidentRadiusInput = '60';

    selectedUserId = null;
    actorInput = '';
    highRiskOnly = false;
    groupBursts = false;

    // Applied query parameters
    windowStart;
    windowEnd;
    actorUsername = '';
    appliedHighRiskOnly = false;

    userDisplayInfo = { additionalFields: ['Username'] };
    userMatchingInfo = {
        primaryField: { fieldPath: 'Name' },
        additionalFields: [{ fieldPath: 'Username' }]
    };

    entryRows = [];
    selectedEntryIds = [];
    gridSelectedRows = [];
    isLoading = false;
    errorMessage = '';
    wiredEntriesResult;

    // Modal state
    isPackageModalOpen = false;
    packageScope = 'selected'; // 'selected' or 'all'
    packageTargetMode = 'existing'; // 'existing' or 'create'
    changeLogSearchTerm = '';
    draftLogs = [];
    selectedModalChangeLogId = null;
    modalNewChangeRequestId = '';
    modalNewDeploymentDate = null;
    modalNewDescription = '';
    isPackaging = false;

    connectedCallback() {
        const now = new Date();
        this.windowEndInput = now.toISOString();
        this.windowStartInput = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000).toISOString();
        this.incidentTimestampInput = now.toISOString();
        this.applyResolvedFilters();
    }

    @wire(getLatestSyncedOccurredAt)
    wiredWatermark({ data }) {
        if (data && !this.windowStart) {
            this.incidentTimestampInput = data;
        }
    }

    @wire(getAuditEntries, {
        windowStart: '$windowStart',
        windowEnd: '$windowEnd',
        actorUsername: '$actorUsername',
        highRiskOnly: '$appliedHighRiskOnly'
    })
    wiredEntries(result) {
        this.wiredEntriesResult = result;
        const { data, error } = result;
        this.isLoading = false;
        if (data) {
            this.entryRows = data.map((row) => ({
                ...row,
                displayName: row.name,
                recordUrl: `/${row.recordId}`,
                changeRequestUrl: row.changeLogId ? `/${row.changeLogId}` : null,
                changeRequestDisplay: row.isPackaged ? (row.changeRequestId || row.changeLogName || 'Packaged') : 'Unassigned'
            }));
            this.errorMessage = '';
            this.syncGridSelectedRows();
        } else if (error) {
            this.errorMessage = this.extractError(error);
        }
    }

    get isWindowMode() {
        return this.timeMode === 'window';
    }

    get isIncidentMode() {
        return this.timeMode === 'incident';
    }

    get hasEntryRows() {
        return Array.isArray(this.entryRows) && this.entryRows.length > 0;
    }

    get displayedRows() {
        return this.entryRows;
    }

    get totalEventsCount() {
        return this.entryRows.length;
    }

    get unassignedCount() {
        return this.entryRows.filter((e) => !e.isPackaged).length;
    }

    get packagedCount() {
        return this.entryRows.filter((e) => e.isPackaged).length;
    }

    get formattedTotalCount() {
        return new Intl.NumberFormat().format(this.totalEventsCount);
    }

    get formattedUnassignedCount() {
        return new Intl.NumberFormat().format(this.unassignedCount);
    }

    get formattedPackagedCount() {
        return new Intl.NumberFormat().format(this.packagedCount);
    }

    get packageSelectedLabel() {
        return `Package Selected (${this.selectedEntryIds.length})`;
    }

    get packageAllLabel() {
        return `Package All Unassigned (${this.formattedUnassignedCount})`;
    }

    get packageSelectedDisabled() {
        return this.selectedEntryIds.length === 0 || this.isPackaging;
    }

    get packageAllDisabled() {
        return this.unassignedCount === 0 || this.isPackaging;
    }

    get treeData() {
        if (!this.groupBursts) {
            return [];
        }
        const bursts = [];
        let currentBurst = null;
        let burstIndex = 0;

        for (const entry of this.entryRows) {
            if (currentBurst && currentBurst.responsibleUsername === entry.responsibleUsername) {
                currentBurst._children.push({
                    ...entry,
                    burstSizeLabel: ''
                });
                currentBurst.burstCount += 1;
                currentBurst.childIds.push(entry.recordId);
            } else {
                currentBurst = {
                    recordId: `burst_${burstIndex++}`,
                    isBurst: true,
                    displayName: `Burst: ${entry.responsibleUsername}`,
                    name: `Burst: ${entry.responsibleUsername}`,
                    occurredAt: entry.occurredAt,
                    riskLevel: entry.riskLevel,
                    category: entry.category,
                    section: entry.section,
                    responsibleUsername: entry.responsibleUsername,
                    delegateUser: entry.delegateUser,
                    displayText: `Consecutive activity by ${entry.responsibleUsername}`,
                    burstSizeLabel: '1 event',
                    changeRequestDisplay: entry.changeRequestDisplay,
                    burstCount: 1,
                    childIds: [entry.recordId],
                    _children: [{
                        ...entry,
                        burstSizeLabel: ''
                    }]
                };
                bursts.push(currentBurst);
            }
            currentBurst.burstSizeLabel = `${currentBurst.burstCount} events`;
            currentBurst.displayName = `Burst (${currentBurst.burstCount} actions)`;
            currentBurst.displayText = `${currentBurst.burstCount} consecutive changes by ${currentBurst.responsibleUsername}`;
        }
        return bursts;
    }

    handleTimeModeChange(event) {
        this.timeMode = event.detail.value;
    }

    handleWindowStartChange(event) {
        this.windowStartInput = event.detail.value;
    }

    handleWindowEndChange(event) {
        this.windowEndInput = event.detail.value;
    }

    handleIncidentTimestampChange(event) {
        this.incidentTimestampInput = event.detail.value;
    }

    handleIncidentRadiusChange(event) {
        this.incidentRadiusInput = event.detail.value;
    }

    async handleUserChange(event) {
        const userId = event.detail.recordId;
        this.selectedUserId = userId;
        if (!userId) {
            this.actorInput = '';
            return;
        }
        try {
            const user = await resolveUser({ userId, username: null });
            this.actorInput = user?.username || '';
        } catch {
            this.actorInput = '';
        }
    }

    handleHighRiskToggle(event) {
        this.highRiskOnly = event.target.checked;
    }

    handleBurstToggle(event) {
        this.groupBursts = event.target.checked;
        this.syncGridSelectedRows();
    }

    handleApplyFilters() {
        this.isLoading = true;
        this.applyResolvedFilters();
    }

    applyResolvedFilters() {
        if (this.timeMode === 'incident') {
            const center = this.incidentTimestampInput ? new Date(this.incidentTimestampInput).getTime() : Date.now();
            const radiusMinutes = parseInt(this.incidentRadiusInput, 10) || 60;
            const radiusMs = radiusMinutes * 60 * 1000;
            this.windowStart = new Date(center - radiusMs).toISOString();
            this.windowEnd = new Date(center + radiusMs).toISOString();
        } else {
            this.windowStart = this.windowStartInput;
            this.windowEnd = this.windowEndInput;
        }
        this.actorUsername = this.actorInput;
        this.appliedHighRiskOnly = this.highRiskOnly;
        this.selectedEntryIds = [];
        this.gridSelectedRows = [];
    }

    handleFlatRowSelection(event) {
        const selected = event.detail.selectedRows || [];
        this.selectedEntryIds = selected.map((r) => r.recordId);
    }

    handleTreeRowSelection(event) {
        const selectedRows = event.detail.selectedRows || [];
        const newSelectedEntryIds = new Set();

        for (const row of selectedRows) {
            if (row.isBurst && Array.isArray(row.childIds)) {
                for (const id of row.childIds) {
                    newSelectedEntryIds.add(id);
                }
            } else if (row.recordId && !row.recordId.startsWith('burst_')) {
                newSelectedEntryIds.add(row.recordId);
            }
        }

        this.selectedEntryIds = Array.from(newSelectedEntryIds);
        this.syncGridSelectedRows();
    }

    syncGridSelectedRows() {
        const selectedSet = new Set(this.selectedEntryIds);
        const keys = [...this.selectedEntryIds];

        for (const burst of this.treeData) {
            const allChildrenSelected = burst.childIds.length > 0 && burst.childIds.every((id) => selectedSet.has(id));
            if (allChildrenSelected) {
                keys.push(burst.recordId);
            }
        }
        this.gridSelectedRows = keys;
    }

    async handleRefresh() {
        this.isLoading = true;
        if (this.wiredEntriesResult) {
            await refreshApex(this.wiredEntriesResult);
        }
        this.isLoading = false;
    }

    // Modal Workflow
    async handleOpenPackageSelectedModal() {
        if (this.selectedEntryIds.length === 0) {
            return;
        }
        this.packageScope = 'selected';
        await this.openPackageModal();
    }

    async handleOpenPackageAllModal() {
        if (this.unassignedCount === 0) {
            return;
        }
        this.packageScope = 'all';
        await this.openPackageModal();
    }

    async openPackageModal() {
        this.isPackageModalOpen = true;
        this.modalNewChangeRequestId = '';
        this.modalNewDeploymentDate = null;
        this.modalNewDescription = '';
        this.changeLogSearchTerm = '';
        await this.loadDraftLogs();
        if (this.draftLogs.length > 0) {
            this.packageTargetMode = 'existing';
            this.selectedModalChangeLogId = this.draftLogs[0].recordId;
        } else {
            this.packageTargetMode = 'create';
            this.selectedModalChangeLogId = null;
        }
    }

    handleClosePackageModal() {
        this.isPackageModalOpen = false;
    }

    handlePackageTargetModeChange(event) {
        this.packageTargetMode = event.detail.value;
    }

    async handleSearchTermChange(event) {
        this.changeLogSearchTerm = event.detail.value;
        await this.loadDraftLogs();
    }

    async loadDraftLogs() {
        try {
            const logs = await searchDraftChangeLogs({ searchTerm: this.changeLogSearchTerm });
            this.draftLogs = logs || [];
            if (this.draftLogs.length > 0 && !this.selectedModalChangeLogId) {
                this.selectedModalChangeLogId = this.draftLogs[0].recordId;
            }
        } catch (error) {
            this.draftLogs = [];
            this.errorMessage = this.extractError(error);
        }
    }

    handleSelectExistingChangeLog(event) {
        this.selectedModalChangeLogId = event.detail.value;
    }

    handleModalCrIdChange(event) {
        this.modalNewChangeRequestId = event.detail.value;
    }

    handleModalDeploymentDateChange(event) {
        this.modalNewDeploymentDate = event.detail.value;
    }

    handleModalDescriptionChange(event) {
        this.modalNewDescription = event.detail.value;
    }

    get isExistingTargetMode() {
        return this.packageTargetMode === 'existing';
    }

    get isCreateTargetMode() {
        return this.packageTargetMode === 'create';
    }

    get hasDraftLogs() {
        return this.draftLogs.length > 0;
    }

    get draftLogOptions() {
        return this.draftLogs.map((log) => ({
            label: `${log.changeRequestId} — ${log.name} (${log.totalEntries} entries)`,
            value: log.recordId
        }));
    }

    get packageScopeSummaryText() {
        if (this.packageScope === 'selected') {
            return `Packaging ${this.selectedEntryIds.length} selected audit change(s).`;
        }
        return `Packaging all ${this.formattedUnassignedCount} unassigned change(s) matching your current filter.`;
    }

    get confirmPackageDisabled() {
        if (this.isPackaging) {
            return true;
        }
        if (this.isExistingTargetMode) {
            return !this.selectedModalChangeLogId;
        }
        return !this.modalNewChangeRequestId || !this.modalNewChangeRequestId.trim();
    }

    async handleConfirmPackage() {
        this.isPackaging = true;
        try {
            let targetLogId = this.selectedModalChangeLogId;
            let crLabel = '';

            if (this.isCreateTargetMode) {
                targetLogId = await createChangeLog({
                    changeRequestId: this.modalNewChangeRequestId.trim(),
                    deploymentDate: this.modalNewDeploymentDate,
                    description: this.modalNewDescription
                });
                crLabel = this.modalNewChangeRequestId.trim();
            } else {
                const selectedLog = this.draftLogs.find((l) => l.recordId === targetLogId);
                crLabel = selectedLog?.changeRequestId || 'Change Log';
            }

            if (this.packageScope === 'selected') {
                await packageEntries({ changeLogId: targetLogId, entryIds: this.selectedEntryIds });
            } else {
                await packageFilteredEntries({
                    changeLogId: targetLogId,
                    windowStart: this.windowStart,
                    windowEnd: this.windowEnd,
                    actorUsername: this.actorUsername
                });
            }

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Packaging Queued',
                    message: `Background packaging started for ${crLabel}. Entries will be cited as compliance evidence.`,
                    variant: 'success'
                })
            );

            this.isPackageModalOpen = false;
            this.selectedEntryIds = [];
            this.gridSelectedRows = [];
            if (this.wiredEntriesResult) {
                await refreshApex(this.wiredEntriesResult);
            }
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Packaging Failed',
                    message: this.extractError(error),
                    variant: 'error'
                })
            );
        } finally {
            this.isPackaging = false;
        }
    }

    extractError(error) {
        if (!error) {
            return 'An unknown error occurred.';
        }
        if (error.body && error.body.message) {
            return error.body.message;
        }
        if (error.message) {
            return error.message;
        }
        return JSON.stringify(error);
    }
}
