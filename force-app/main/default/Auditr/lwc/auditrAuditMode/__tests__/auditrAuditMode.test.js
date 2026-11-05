import { createElement } from 'lwc';
import AuditrAuditMode from 'c/auditrAuditMode';
import getAuditEntries from '@salesforce/apex/AuditrChangeLogController.getAuditEntries';
import searchDraftChangeLogs from '@salesforce/apex/AuditrChangeLogController.searchDraftChangeLogs';
import createChangeLog from '@salesforce/apex/AuditrChangeLogController.createChangeLog';
import packageEntries from '@salesforce/apex/AuditrChangeLogController.packageEntries';
import resolveUser from '@salesforce/apex/AuditrChangeLogController.resolveUser';

jest.mock(
    '@salesforce/apex/AuditrChangeLogController.getAuditEntries',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/AuditrController.getLatestSyncedOccurredAt',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/AuditrChangeLogController.searchDraftChangeLogs',
    () => ({ default: jest.fn() }),
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

jest.mock(
    '@salesforce/apex/AuditrChangeLogController.resolveUser',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

const ENTRY_ONE = {
    recordId: 'a01000000000001AAA',
    name: 'AUD-0000001',
    occurredAt: '2026-10-31T15:00:00.000Z',
    riskLevel: 'High',
    category: 'Security & Access',
    section: 'Manage Users',
    actionCode: 'changedprofile',
    responsibleUsername: 'admin@example.com',
    delegateUser: null,
    displayText: 'Changed profile System Administrator.',
    isPackaged: false,
    changeRequestId: null,
    changeLogName: null,
    changeLogId: null
};

const ENTRY_TWO = {
    recordId: 'a01000000000002AAA',
    name: 'AUD-0000002',
    occurredAt: '2026-10-31T15:01:00.000Z',
    riskLevel: 'Critical',
    category: 'Security & Access',
    section: 'Manage Users',
    actionCode: 'assignedpermset',
    responsibleUsername: 'admin@example.com',
    delegateUser: null,
    displayText: 'Assigned permission set Modify All Data.',
    isPackaged: true,
    changeRequestId: 'CR-1001',
    changeLogName: 'CLG-000001',
    changeLogId: 'a02000000000001AAA'
};

const DRAFT_LOG = {
    recordId: 'a02000000000001AAA',
    name: 'CLG-000001',
    changeRequestId: 'PROJ-0001',
    status: 'Draft',
    totalEntries: 5
};

describe('c-auditr-audit-mode', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders audit entries with stats and flat datatable by default', async () => {
        const element = createElement('c-auditr-audit-mode', { is: AuditrAuditMode });
        document.body.appendChild(element);
        getAuditEntries.emit([ENTRY_ONE, ENTRY_TWO]);
        await flushPromises();

        const badge = element.shadowRoot.querySelector('.stats-badge');
        expect(badge.textContent).toContain('2 event(s) found');

        const datatable = element.shadowRoot.querySelector('lightning-datatable');
        expect(datatable).not.toBeNull();
        expect(datatable.data.length).toBe(2);
    });

    it('resolves actor username when selecting and clearing a user in the record picker', async () => {
        resolveUser.mockResolvedValue({
            userId: '005000000000001AAA',
            name: 'Audit Manager',
            username: 'auditor@example.com'
        });

        const element = createElement('c-auditr-audit-mode', { is: AuditrAuditMode });
        document.body.appendChild(element);
        getAuditEntries.emit([ENTRY_ONE]);
        await flushPromises();

        const picker = element.shadowRoot.querySelector('lightning-record-picker');
        picker.dispatchEvent(new CustomEvent('change', { detail: { recordId: '005000000000001AAA' } }));
        await flushPromises();

        expect(resolveUser).toHaveBeenCalledWith({ userId: '005000000000001AAA', username: null });

        const actorHint = element.shadowRoot.querySelector('.actor-hint');
        expect(actorHint).not.toBeNull();
        expect(actorHint.textContent).toContain('auditor@example.com');

        picker.dispatchEvent(new CustomEvent('change', { detail: { recordId: null } }));
        await flushPromises();

        expect(element.shadowRoot.querySelector('.actor-hint')).toBeNull();
    });

    it('groups actor bursts into a tree grid and cascades selection to all burst child entries', async () => {
        const element = createElement('c-auditr-audit-mode', { is: AuditrAuditMode });
        document.body.appendChild(element);
        getAuditEntries.emit([ENTRY_ONE, ENTRY_TWO]); // both same actor: admin@example.com
        await flushPromises();

        // Toggle Group Actor Bursts
        const burstToggle = element.shadowRoot.querySelector('.burst-toggle-input');
        expect(burstToggle).not.toBeNull();
        burstToggle.checked = true;
        burstToggle.dispatchEvent(new CustomEvent('change', { target: { checked: true } }));
        await flushPromises();

        const treeGrid = element.shadowRoot.querySelector('lightning-tree-grid');
        expect(treeGrid).not.toBeNull();
        expect(treeGrid.data.length).toBe(1); // 1 burst parent
        expect(treeGrid.data[0]._children.length).toBe(2); // 2 children

        // Select the parent burst row
        treeGrid.dispatchEvent(new CustomEvent('rowselection', {
            detail: {
                selectedRows: [treeGrid.data[0]]
            }
        }));
        await flushPromises();

        const packageBtn = [...element.shadowRoot.querySelectorAll('lightning-button')].find((btn) =>
            btn.label.startsWith('Package Selected')
        );
        expect(packageBtn.label).toBe('Package Selected (2)');
        expect(packageBtn.disabled).toBe(false);
    });

    it('opens packaging modal, searches draft logs, and packages entries into existing change log', async () => {
        searchDraftChangeLogs.mockResolvedValue([DRAFT_LOG]);
        packageEntries.mockResolvedValue('707000000000001AAA');

        const element = createElement('c-auditr-audit-mode', { is: AuditrAuditMode });
        document.body.appendChild(element);
        getAuditEntries.emit([ENTRY_ONE]);
        await flushPromises();

        // Select row in flat datatable
        const datatable = element.shadowRoot.querySelector('lightning-datatable');
        datatable.dispatchEvent(new CustomEvent('rowselection', {
            detail: { selectedRows: [ENTRY_ONE] }
        }));
        await flushPromises();

        const packageBtn = [...element.shadowRoot.querySelectorAll('lightning-button')].find((btn) =>
            btn.label.startsWith('Package Selected')
        );
        packageBtn.click();
        await flushPromises();

        expect(searchDraftChangeLogs).toHaveBeenCalled();
        expect(element.shadowRoot.querySelector('section.slds-modal')).not.toBeNull();

        // Confirm packaging
        const confirmBtn = [...element.shadowRoot.querySelectorAll('lightning-button')].find((btn) =>
            btn.label === 'Confirm & Package'
        );
        confirmBtn.click();
        await flushPromises();

        expect(packageEntries).toHaveBeenCalledWith({
            changeLogId: DRAFT_LOG.recordId,
            entryIds: [ENTRY_ONE.recordId]
        });
    });

    it('allows creating a new change log inside modal before packaging', async () => {
        searchDraftChangeLogs.mockResolvedValue([]);
        createChangeLog.mockResolvedValue('a02000000000002AAA');
        packageEntries.mockResolvedValue('707000000000002AAA');

        const element = createElement('c-auditr-audit-mode', { is: AuditrAuditMode });
        document.body.appendChild(element);
        getAuditEntries.emit([ENTRY_ONE]);
        await flushPromises();

        const datatable = element.shadowRoot.querySelector('lightning-datatable');
        datatable.dispatchEvent(new CustomEvent('rowselection', {
            detail: { selectedRows: [ENTRY_ONE] }
        }));
        await flushPromises();

        const packageBtn = [...element.shadowRoot.querySelectorAll('lightning-button')].find((btn) =>
            btn.label.startsWith('Package Selected')
        );
        packageBtn.click();
        await flushPromises();
        await flushPromises();
        await flushPromises();

        // When no draft logs exist, defaults to 'create' target mode
        const crInput = element.shadowRoot.querySelector('.modal-cr-input');
        expect(crInput).not.toBeNull();
        crInput.value = 'CR-9999';
        crInput.dispatchEvent(new CustomEvent('change', { detail: { value: 'CR-9999' } }));
        await flushPromises();

        const confirmBtn = [...element.shadowRoot.querySelectorAll('lightning-button')].find((btn) =>
            btn.label === 'Confirm & Package'
        );
        expect(confirmBtn.disabled).toBe(false);

        confirmBtn.click();
        await flushPromises();

        expect(createChangeLog).toHaveBeenCalledWith({
            changeRequestId: 'CR-9999',
            deploymentDate: null,
            description: ''
        });
        expect(packageEntries).toHaveBeenCalledWith({
            changeLogId: 'a02000000000002AAA',
            entryIds: [ENTRY_ONE.recordId]
        });
    });

    it('handles envelope response and displays warning badge when scope exceeds table limit', async () => {
        const element = createElement('c-auditr-audit-mode', { is: AuditrAuditMode });
        document.body.appendChild(element);
        getAuditEntries.emit({
            entries: [ENTRY_ONE],
            totalMatchingCount: 500,
            totalUnassignedCount: 450,
            totalPackagedCount: 50,
            isCapped: false,
            queryLimit: 200
        });
        await flushPromises();

        const warningBadge = element.shadowRoot.querySelector('.slds-theme_warning');
        expect(warningBadge).not.toBeNull();
        expect(warningBadge.textContent).toContain('Showing first 1 of 500 events');

        const packageAllBtn = [...element.shadowRoot.querySelectorAll('lightning-button')].find((btn) =>
            btn.label.startsWith('Package All Unassigned')
        );
        expect(packageAllBtn.label).toContain('(450)');
    });
});
