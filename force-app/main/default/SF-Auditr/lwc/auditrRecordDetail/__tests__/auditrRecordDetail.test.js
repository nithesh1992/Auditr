import { createElement } from 'lwc';
import AuditrRecordDetail from 'c/auditrRecordDetail';

describe('c-auditr-record-detail', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('renders read-only output fields by default and toggles classification edit mode', async () => {
        const element = createElement('c-auditr-record-detail', {
            is: AuditrRecordDetail
        });
        element.recordId = 'a00000000000001AAA';
        document.body.appendChild(element);

        const outputFields = element.shadowRoot.querySelectorAll('lightning-output-field');
        expect(outputFields.length).toBe(15);
        expect(element.shadowRoot.querySelectorAll('lightning-input-field').length).toBe(0);

        const editButton = element.shadowRoot.querySelector('lightning-button');
        editButton.click();
        await Promise.resolve();

        const inputFields = element.shadowRoot.querySelectorAll('lightning-input-field');
        expect(inputFields.length).toBe(2);
    });
});
