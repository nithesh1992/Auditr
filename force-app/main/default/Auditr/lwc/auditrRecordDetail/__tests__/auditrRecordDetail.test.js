import { createElement } from 'lwc';
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

        const editButton = element.shadowRoot.querySelector('lightning-button');
        editButton.click();
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('lightning-input-field').length).toBe(2);
    });
});
