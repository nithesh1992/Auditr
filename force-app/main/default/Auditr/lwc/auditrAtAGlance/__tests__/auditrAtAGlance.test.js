import { createElement } from 'lwc';
import AuditrAtAGlance from 'c/auditrAtAGlance';
import getAtAGlanceMetrics from '@salesforce/apex/AuditrController.getAtAGlanceMetrics';

jest.mock(
    '@salesforce/apex/AuditrController.getAtAGlanceMetrics',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const flushPromises = () => Promise.resolve();

describe('c-auditr-at-a-glance', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders all 7 KPI cards including unassigned changes from wired metrics', async () => {
        const element = createElement('c-auditr-at-a-glance', { is: AuditrAtAGlance });
        document.body.appendChild(element);

        getAtAGlanceMetrics.emit({
            totalEntries: 42,
            criticalAndHighCount: 7,
            securityAndAccessCount: 15,
            automationAndMetadataCount: 12,
            impersonatedCount: 3,
            unclassifiedCount: 2,
            unassignedChangeCount: 31,
            lastSyncedOccurredAt: '2026-10-31T15:00:00.000Z'
        });

        await flushPromises();

        const kpiValues = element.shadowRoot.querySelectorAll('.kpi-value');
        expect(kpiValues.length).toBe(7);
        expect(kpiValues[0].textContent.trim()).toBe('42');
        expect(kpiValues[1].textContent.trim()).toBe('7');
        expect(kpiValues[6].textContent.trim()).toBe('31');
    });
});
