import { createElement } from 'lwc';
import AuditrAtAGlance from 'c/auditrAtAGlance';
import getAtAGlanceMetrics from '@salesforce/apex/AuditrController.getAtAGlanceMetrics';
import getIncidentTimeline from '@salesforce/apex/AuditrController.getIncidentTimeline';

jest.mock(
    '@salesforce/apex/AuditrController.getAtAGlanceMetrics',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/AuditrController.getIncidentTimeline',
    () => ({ default: jest.fn() }),
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

    it('renders KPI counts from wired metrics and toggles Incident Mode', async () => {
        getIncidentTimeline.mockResolvedValue([
            {
                recordId: 'a01000000000001AAA',
                name: 'AUD-0000001',
                occurredAt: '2026-10-31T15:00:00.000Z',
                riskLevel: 'High',
                category: 'Security & Access',
                section: 'Manage Users',
                actionCode: 'changedprofile',
                responsibleUsername: 'admin@example.com',
                delegateUser: null,
                displayText: 'Changed profile System Administrator.'
            }
        ]);

        const element = createElement('c-auditr-at-a-glance', { is: AuditrAtAGlance });
        document.body.appendChild(element);

        getAtAGlanceMetrics.emit({
            totalEntries: 42,
            criticalAndHighCount: 7,
            securityAndAccessCount: 15,
            automationAndMetadataCount: 12,
            impersonatedCount: 3,
            unclassifiedCount: 2,
            lastSyncedOccurredAt: '2026-10-31T15:00:00.000Z'
        });

        await flushPromises();

        const numbers = element.shadowRoot.querySelectorAll('lightning-formatted-number');
        expect(numbers.length).toBe(6);
        expect(numbers[0].value).toBe(42);
        expect(numbers[1].value).toBe(7);

        const incidentBtn = element.shadowRoot.querySelector('lightning-button');
        incidentBtn.click();
        await flushPromises();

        expect(getIncidentTimeline).toHaveBeenCalledTimes(1);
        const datatable = element.shadowRoot.querySelector('lightning-datatable');
        expect(datatable).not.toBeNull();
        expect(datatable.data.length).toBe(1);
    });
});
