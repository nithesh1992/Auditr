import { LightningElement, wire } from 'lwc';
import getIncidentTimeline from '@salesforce/apex/AuditrController.getIncidentTimeline';
import getLatestSyncedOccurredAt from '@salesforce/apex/AuditrController.getLatestSyncedOccurredAt';

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

export default class AuditrIncidentMode extends LightningElement {
    radiusOptions = RADIUS_OPTIONS;
    incidentColumns = INCIDENT_COLUMNS;

    lastSyncedOccurredAt = null;
    incidentTimestamp = new Date().toISOString();
    incidentRadius = '60';
    highRiskOnly = false;
    isLoading = false;
    incidentRows = [];
    errorMessage = '';
    hasSearched = false;

    get hasIncidentRows() {
        return Array.isArray(this.incidentRows) && this.incidentRows.length > 0;
    }

    get showEmptyState() {
        return this.hasSearched && !this.isLoading && !this.hasIncidentRows;
    }

    @wire(getLatestSyncedOccurredAt)
    wiredWatermark({ data, error }) {
        if (data) {
            this.lastSyncedOccurredAt = data;
            if (!this.hasSearched) {
                this.incidentTimestamp = data;
                this.loadIncidentTimeline();
            }
        } else if (error) {
            this.errorMessage = this.extractError(error);
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
        this.isLoading = true;
        this.hasSearched = true;
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
            this.incidentRows = [];
        } finally {
            this.isLoading = false;
        }
    }

    extractError(error) {
        if (error?.body?.message) {
            return error.body.message;
        }
        if (error?.message) {
            return error.message;
        }
        return 'Unable to load the incident timeline.';
    }
}
