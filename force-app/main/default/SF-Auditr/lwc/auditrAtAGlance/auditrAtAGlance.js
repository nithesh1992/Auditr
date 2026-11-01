import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getAtAGlanceMetrics from '@salesforce/apex/AuditrController.getAtAGlanceMetrics';
import getIncidentTimeline from '@salesforce/apex/AuditrController.getIncidentTimeline';

const WINDOW_OPTIONS = [
    { label: 'Last 24 Hours', value: '1' },
    { label: 'Last 7 Days', value: '7' },
    { label: 'Last 30 Days', value: '30' },
    { label: 'Last 90 Days', value: '90' },
    { label: 'Last 1 Year', value: '365' }
];

const TOTAL_COUNT_CAP = 25000;
const KPI_COUNT_CAP = 5000;

const RADIUS_OPTIONS = [
    { label: '± 15 Minutes', value: '15' },
    { label: '± 30 Minutes', value: '30' },
    { label: '± 1 Hour', value: '60' },
    { label: '± 4 Hours', value: '240' },
    { label: '± 12 Hours', value: '720' }
];

const INCIDENT_COLUMNS = [
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
    { label: 'Delegate', fieldName: 'delegateUser', type: 'text', initialWidth: 160 },
    { label: 'Display Summary', fieldName: 'displayText', type: 'text', wrapText: true }
];

export default class AuditrAtAGlance extends LightningElement {
    selectedWindow = '7';
    windowOptions = WINDOW_OPTIONS;
    radiusOptions = RADIUS_OPTIONS;
    incidentColumns = INCIDENT_COLUMNS;

    metrics = {
        totalEntries: 0,
        criticalAndHighCount: 0,
        securityAndAccessCount: 0,
        automationAndMetadataCount: 0,
        impersonatedCount: 0,
        unclassifiedCount: 0,
        lastSyncedOccurredAt: null
    };
    errorMessage = '';
    wiredMetricsResult;

    isIncidentModeOpen = false;
    incidentTimestamp = new Date().toISOString();
    incidentRadius = '60';
    highRiskOnly = false;
    isLoadingIncident = false;
    incidentRows = [];

    get windowDaysNumber() {
        return parseInt(this.selectedWindow, 10);
    }

    get selectedWindowLabel() {
        const match = this.windowOptions.find((opt) => opt.value === this.selectedWindow);
        return match ? match.label : 'Last 7 Days';
    }

    get totalEntriesSuffix() {
        return (this.metrics.totalEntries || 0) >= TOTAL_COUNT_CAP ? '+' : '';
    }

    get criticalAndHighSuffix() {
        return (this.metrics.criticalAndHighCount || 0) >= KPI_COUNT_CAP ? '+' : '';
    }

    get securityAndAccessSuffix() {
        return (this.metrics.securityAndAccessCount || 0) >= KPI_COUNT_CAP ? '+' : '';
    }

    get automationAndMetadataSuffix() {
        return (this.metrics.automationAndMetadataCount || 0) >= KPI_COUNT_CAP ? '+' : '';
    }

    get impersonatedSuffix() {
        return (this.metrics.impersonatedCount || 0) >= KPI_COUNT_CAP ? '+' : '';
    }

    get unclassifiedSuffix() {
        return (this.metrics.unclassifiedCount || 0) >= KPI_COUNT_CAP ? '+' : '';
    }

    get incidentButtonLabel() {
        return this.isIncidentModeOpen ? 'Close Incident Mode' : 'Incident Mode';
    }

    get incidentButtonVariant() {
        return this.isIncidentModeOpen ? 'brand' : 'neutral';
    }

    get hasIncidentRows() {
        return Array.isArray(this.incidentRows) && this.incidentRows.length > 0;
    }

    @wire(getAtAGlanceMetrics, { windowDays: '$windowDaysNumber' })
    wiredMetrics(result) {
        this.wiredMetricsResult = result;
        const { data, error } = result;
        if (data) {
            this.metrics = { ...data };
            this.errorMessage = '';
        } else if (error) {
            this.errorMessage = this.extractError(error);
        }
    }

    handleWindowChange(event) {
        this.selectedWindow = event.detail.value;
    }

    async handleRefresh() {
        if (this.wiredMetricsResult) {
            await refreshApex(this.wiredMetricsResult);
        }
        if (this.isIncidentModeOpen) {
            await this.loadIncidentTimeline();
        }
    }

    async handleToggleIncidentMode() {
        this.isIncidentModeOpen = !this.isIncidentModeOpen;
        if (this.isIncidentModeOpen && this.incidentRows.length === 0) {
            if (this.metrics.lastSyncedOccurredAt) {
                this.incidentTimestamp = this.metrics.lastSyncedOccurredAt;
            }
            await this.loadIncidentTimeline();
        }
    }

    handleIncidentTimeChange(event) {
        this.incidentTimestamp = event.detail.value;
    }

    handleRadiusChange(event) {
        this.incidentRadius = event.detail.value;
    }

    handleHighRiskToggle(event) {
        this.highRiskOnly = event.target.checked;
    }

    async handleRunIncidentSearch() {
        await this.loadIncidentTimeline();
    }

    async loadIncidentTimeline() {
        this.isLoadingIncident = true;
        this.errorMessage = '';
        try {
            const rows = await getIncidentTimeline({
                incidentTime: this.incidentTimestamp || new Date().toISOString(),
                windowMinutes: parseInt(this.incidentRadius, 10),
                highRiskOnly: this.highRiskOnly
            });
            this.incidentRows = (rows || []).map((row) => ({
                ...row,
                recordUrl: `/${row.recordId}`
            }));
        } catch (error) {
            this.errorMessage = this.extractError(error);
        } finally {
            this.isLoadingIncident = false;
        }
    }

    extractError(error) {
        if (error?.body?.message) {
            return error.body.message;
        }
        if (error?.message) {
            return error.message;
        }
        return 'Unable to load Auditr metrics.';
    }
}
