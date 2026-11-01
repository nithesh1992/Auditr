import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class AuditrRecordDetail extends LightningElement {
    @api recordId;

    isEditingClassification = false;
    isSaving = false;

    handleEditClassification() {
        this.isEditingClassification = true;
    }

    handleCancelClassification() {
        this.isEditingClassification = false;
        this.isSaving = false;
    }

    handleSaveClassification() {
        const submitBtn = this.template.querySelector('[data-id="hiddenSubmitBtn"]');
        if (submitBtn) {
            this.isSaving = true;
            submitBtn.click();
        }
    }

    handleClassificationSuccess() {
        this.isSaving = false;
        this.isEditingClassification = false;
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Classification Updated',
                message: 'Risk Level and Category have been updated.',
                variant: 'success'
            })
        );
    }

    handleClassificationError(event) {
        this.isSaving = false;
        const detailMessage = event?.detail?.detail || event?.detail?.message || 'Unable to update classification.';
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Error Updating Classification',
                message: detailMessage,
                variant: 'error'
            })
        );
    }
}
