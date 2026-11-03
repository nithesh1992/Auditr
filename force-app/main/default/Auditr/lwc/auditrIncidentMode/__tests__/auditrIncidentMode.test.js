import { createElement } from 'lwc';
import AuditrIncidentMode from 'c/auditrIncidentMode';
import getIncidentTimeline from '@salesforce/apex/AuditrController.getIncidentTimeline';
import getLatestSyncedOccurredAt from '@salesforce/apex/AuditrController.getLatestSyncedOccurredAt';

jest.mock(
    '@salesforce/apex/AuditrController.getLatestSyncedOccurredAt',
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

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-auditr-incident-mode', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('anchors to the latest watermark and renders the incident timeline', async () => {
        getIncidentTimeline.mockResolvedValue([
            {
                recordId: 'a01000000000001AAA',
                name: 'AUD-0000001',
                occurredAt: '2026-10-31T15:00:00.000Z',
                riskLevel: 'High',
                category: 'Security & Access',
                section: 'Manage Users',
                responsibleUsername: 'admin@example.com',
                delegateUser: null,
                displayText: 'Changed profile System Administrator.'
            }
        ]);

        const element = createElement('c-auditr-incident-mode', { is: AuditrIncidentMode });
        document.body.appendChild(element);

        getLatestSyncedOccurredAt.emit('2026-10-31T15:00:00.000Z');
        await flushPromises();

        expect(getIncidentTimeline).toHaveBeenCalledTimes(1);
        const datatable = element.shadowRoot.querySelector('lightning-datatable');
        expect(datatable).not.toBeNull();
        expect(datatable.data.length).toBe(1);
    });
});
