import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { NavigationMixin } from 'lightning/navigation';
import getAtAGlanceMetrics from '@salesforce/apex/AuditrController.getAtAGlanceMetrics';

const WINDOW_OPTIONS = [
    { label: 'Last 24 Hours', value: '1' },
    { label: 'Last 7 Days', value: '7' },
    { label: 'Last 30 Days', value: '30' },
    { label: 'Last 90 Days', value: '90' },
    { label: 'Last 1 Year', value: '365' }
];

const TOTAL_COUNT_CAP = 25000;
const KPI_COUNT_CAP = 5000;

function formatCappedMetric(value, cap) {
    const num = Number(value) || 0;
    const formatted =
        Math.abs(num) >= 10000
            ? `${(num / 1000).toFixed(1).replace(/\.0$/, '')}K`
            : new Intl.NumberFormat().format(num);
    return num >= cap ? `${formatted}+` : formatted;
}

export default class AuditrAtAGlance extends NavigationMixin(LightningElement) {
    selectedWindow = '7';
    windowOptions = WINDOW_OPTIONS;

    metrics = {
        totalEntries: 0,
        criticalAndHighCount: 0,
        securityAndAccessCount: 0,
        automationAndMetadataCount: 0,
        impersonatedCount: 0,
        unclassifiedCount: 0,
        unassignedChangeCount: 0,
        lastSyncedOccurredAt: null
    };
    errorMessage = '';
    wiredMetricsResult;

    get windowDaysNumber() {
        return parseInt(this.selectedWindow, 10);
    }

    get selectedWindowLabel() {
        const match = this.windowOptions.find((opt) => opt.value === this.selectedWindow);
        return match ? match.label : 'Last 7 Days';
    }

    get formattedTotalEntries() {
        return formatCappedMetric(this.metrics.totalEntries, TOTAL_COUNT_CAP);
    }

    get formattedCriticalAndHighCount() {
        return formatCappedMetric(this.metrics.criticalAndHighCount, KPI_COUNT_CAP);
    }

    get formattedSecurityAndAccessCount() {
        return formatCappedMetric(this.metrics.securityAndAccessCount, KPI_COUNT_CAP);
    }

    get formattedAutomationAndMetadataCount() {
        return formatCappedMetric(this.metrics.automationAndMetadataCount, KPI_COUNT_CAP);
    }

    get formattedImpersonatedCount() {
        return formatCappedMetric(this.metrics.impersonatedCount, KPI_COUNT_CAP);
    }

    get formattedUnclassifiedCount() {
        return formatCappedMetric(this.metrics.unclassifiedCount, KPI_COUNT_CAP);
    }

    get formattedUnassignedChangeCount() {
        return formatCappedMetric(this.metrics.unassignedChangeCount, KPI_COUNT_CAP);
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
    }

    handleOpenAuditMode() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'Auditr_Audit_Mode' }
        });
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
