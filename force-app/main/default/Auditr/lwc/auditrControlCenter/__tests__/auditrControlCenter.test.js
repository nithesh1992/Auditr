import { createElement } from 'lwc';
import AuditrControlCenter from 'c/auditrControlCenter';
import getControlCenterStatus from '@salesforce/apex/AuditrController.getControlCenterStatus';
import runSyncNow from '@salesforce/apex/AuditrController.runSyncNow';

jest.mock(
    '@salesforce/apex/AuditrController.getControlCenterStatus',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/AuditrController.runSyncNow',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/AuditrController.runReclassify',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/AuditrController.runPurgeNow',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/AuditrController.scheduleDailySync',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/AuditrController.unscheduleDailySync',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/AuditrController.scheduleDailyPurge',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/AuditrController.unscheduleDailyPurge',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const flushPromises = () => Promise.resolve();

describe('c-auditr-control-center', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders operational status, active rules, and triggers Sync Now', async () => {
        runSyncNow.mockResolvedValue('707000000000001AAA');

        const element = createElement('c-auditr-control-center', { is: AuditrControlCenter });
        document.body.appendChild(element);

        getControlCenterStatus.emit({
            isActive: true,
            backfillDays: 180,
            batchSize: 200,
            enablePurge: false,
            retentionDays: 365,
            preferredSyncHour: 2,
            totalEntries: 120,
            unclassifiedEntries: 4,
            lastSyncedOccurredAt: '2026-10-31T15:00:00.000Z',
            isScheduled: true,
            nextFireTime: '2026-11-01T02:00:00.000Z',
            scheduleOwnerUsername: 'admin@example.com',
            isScheduleOwnerActive: true,
            isStaleSync: false,
            healthWarning: null,
            recentJobs: [],
            activeRules: [
                {
                    developerName: 'Profile_Changes',
                    label: 'Profile Changes',
                    priority: 100,
                    matchTarget: 'Action_Code__c',
                    matchOperator: 'CONTAINS',
                    matchValue: 'profile',
                    category: 'Security & Access',
                    riskLevel: 'High'
                }
            ],
            topUnclassifiedActions: [
                { actionCode: 'customaction', section: 'Custom Setup', entryCount: 4 }
            ]
        });

        await flushPromises();

        const buttons = element.shadowRoot.querySelectorAll('lightning-button');
        expect(buttons[0].label).toBe('Sync Now');
        buttons[0].click();
        await flushPromises();

        expect(runSyncNow).toHaveBeenCalledTimes(1);

        const purgeBox = element.shadowRoot.querySelector('.schedule-box-purge');
        expect(purgeBox).toBeNull();
    });

    it('renders purge schedule controls when retention policy is enabled and configured', async () => {
        const element = createElement('c-auditr-control-center', { is: AuditrControlCenter });
        document.body.appendChild(element);

        getControlCenterStatus.emit({
            isActive: true,
            backfillDays: 180,
            batchSize: 200,
            enablePurge: true,
            retentionDays: 365,
            preferredSyncHour: 2,
            totalEntries: 120,
            unclassifiedEntries: 0,
            lastSyncedOccurredAt: '2026-10-31T15:00:00.000Z',
            isScheduled: false,
            isPurgeScheduled: false,
            scheduledPurgeHour: 3,
            recentJobs: [],
            activeRules: [],
            topUnclassifiedActions: []
        });

        await flushPromises();

        const purgeBox = element.shadowRoot.querySelector('.schedule-box-purge');
        expect(purgeBox).not.toBeNull();
    });
});
