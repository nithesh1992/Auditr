import { createElement } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';
import AuditrRecordDetail from 'c/auditrRecordDetail';

describe('c-auditr-record-detail', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('renders compact read-only metadata grid by default and toggles reclassify form', async () => {
        const element = createElement('c-auditr-record-detail', {
            is: AuditrRecordDetail
        });
        element.recordId = 'a00000000000001AAA';
        document.body.appendChild(element);

        expect(element.shadowRoot.querySelectorAll('.meta-item').length).toBe(10);
        expect(element.shadowRoot.querySelectorAll('lightning-input-field').length).toBe(0);
        expect(element.shadowRoot.querySelector('[data-id="inferredDelegateWarning"]')).toBeNull();

        const editButton = element.shadowRoot.querySelector('lightning-button');
        editButton.click();
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('lightning-input-field').length).toBe(2);
    });

    it('renders conditional warning banner when DataChange entry has an inferred Delegate User', async () => {
        const element = createElement('c-auditr-record-detail', {
            is: AuditrRecordDetail
        });
        element.recordId = 'a02000000000001AAA';
        document.body.appendChild(element);

        getRecord.emit({
            fields: {
                Source__c: { value: 'DataChange' },
                Actor_Username__c: { value: 'rep@example.com' },
                Delegate_User__c: { value: 'admin@example.com' },
                Responsible_Username__c: { value: 'admin@example.com' },
                Target_Object__c: { value: 'Case' },
                Target_Record_Id__c: { value: '500000000000001AAA' },
                Payload__c: { value: '{"fields":["Status","Priority"]}' }
            }
        });
        await Promise.resolve();

        const warning = element.shadowRoot.querySelector('[data-id="inferredDelegateWarning"]');
        expect(warning).not.toBeNull();
        expect(warning.textContent).toContain('admin@example.com');
        expect(warning.textContent).toContain('rep@example.com');
        expect(element.shadowRoot.querySelectorAll('.field-pill').length).toBe(2);
    });
});
