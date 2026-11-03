import { createElement } from 'lwc';
import AuditrAuditMode from 'c/auditrAuditMode';
import getAuditModeState from '@salesforce/apex/AuditrChangeLogController.getAuditModeState';
import getUnassignedEntries from '@salesforce/apex/AuditrChangeLogController.getUnassignedEntries';
import packageEntries from '@salesforce/apex/AuditrChangeLogController.packageEntries';

jest.mock(
    '@salesforce/apex/AuditrChangeLogController.getAuditModeState',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/AuditrChangeLogController.getUnassignedEntries',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/AuditrChangeLogController.createChangeLog',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/AuditrChangeLogController.packageEntries',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/AuditrChangeLogController.packageFilteredEntries',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

const DRAFT_LOG = {
    recordId: 'a02000000000001AAA',
    name: 'CLG-000001',
    changeRequestId: 'PROJ-0001',
    status: 'Draft',
    targetActor: null,
    windowStart: null,
    windowEnd: null,
    deploymentDate: null,
    totalEntries: 0,
    signedOffAt: null,
    isPackagingInFlight: false
};

const UNASSIGNED_ROW = {
    recordId: 'a01000000000001AAA',
    name: 'AUD-0000001',
    occurredAt: '2026-10-31T15:00:00.000Z',
    riskLevel: 'High',
    category: 'Security & Access',
    section: 'Manage Users',
    actionCode: 'changedprofile',
    responsibleUsername: 'admin@example.com',
    displayText: 'Changed profile System Administrator.'
};

function emitWorkspaceData() {
    getAuditModeState.emit({ changeLogs: [DRAFT_LOG], backlogCount: 1 });
    getUnassignedEntries.emit([UNASSIGNED_ROW]);
}

describe('c-auditr-audit-mode', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders change logs and the unassigned backlog from wired state', async () => {
        const element = createElement('c-auditr-audit-mode', { is: AuditrAuditMode });
        document.body.appendChild(element);
        emitWorkspaceData();
        await flushPromises();

        const datatables = element.shadowRoot.querySelectorAll('lightning-datatable');
        expect(datatables.length).toBe(2);
        expect(datatables[0].data.length).toBe(1);
        expect(datatables[1].data.length).toBe(1);
    });

    it('queues selection packaging once a log and entries are selected', async () => {
        packageEntries.mockResolvedValue('707000000000001AAA');

        const element = createElement('c-auditr-audit-mode', { is: AuditrAuditMode });
        document.body.appendChild(element);
        emitWorkspaceData();
        await flushPromises();

        const datatables = element.shadowRoot.querySelectorAll('lightning-datatable');
        datatables[0].dispatchEvent(new CustomEvent('rowselection', { detail: { selectedRows: [DRAFT_LOG] } }));
        datatables[1].dispatchEvent(new CustomEvent('rowselection', { detail: { selectedRows: [{ ...UNASSIGNED_ROW, recordUrl: `/${UNASSIGNED_ROW.recordId}` }] } }));
        await flushPromises();

        const packageButton = [...element.shadowRoot.querySelectorAll('lightning-button')].find((btn) =>
            btn.label.startsWith('Package Selected')
        );
        expect(packageButton.label).toBe('Package Selected (1)');
        expect(packageButton.disabled).toBe(false);

        packageButton.click();
        await flushPromises();

        expect(packageEntries).toHaveBeenCalledWith({
            changeLogId: DRAFT_LOG.recordId,
            entryIds: [UNASSIGNED_ROW.recordId]
        });
    });
});
