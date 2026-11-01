import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import SECTION_FIELD from '@salesforce/schema/Auditr_Entry__c.Section__c';
import ACTION_CODE_FIELD from '@salesforce/schema/Auditr_Entry__c.Action_Code__c';
import DISPLAY_FIELD from '@salesforce/schema/Auditr_Entry__c.Display__c';
import OCCURRED_AT_FIELD from '@salesforce/schema/Auditr_Entry__c.Occurred_At__c';
import RESPONSIBLE_USERNAME_FIELD from '@salesforce/schema/Auditr_Entry__c.Responsible_Username__c';
import ACTOR_USERNAME_FIELD from '@salesforce/schema/Auditr_Entry__c.Actor_Username__c';
import DELEGATE_USER_FIELD from '@salesforce/schema/Auditr_Entry__c.Delegate_User__c';
import ACTOR_CONTEXT_FIELD from '@salesforce/schema/Auditr_Entry__c.Actor_Context__c';
import NAMESPACE_PREFIX_FIELD from '@salesforce/schema/Auditr_Entry__c.Namespace_Prefix__c';
import SOURCE_FIELD from '@salesforce/schema/Auditr_Entry__c.Source__c';
import SOURCE_RECORD_ID_FIELD from '@salesforce/schema/Auditr_Entry__c.Source_Record_Id__c';

const FIELDS = [
    SECTION_FIELD,
    ACTION_CODE_FIELD,
    DISPLAY_FIELD,
    OCCURRED_AT_FIELD,
    RESPONSIBLE_USERNAME_FIELD,
    ACTOR_USERNAME_FIELD,
    DELEGATE_USER_FIELD,
    ACTOR_CONTEXT_FIELD,
    NAMESPACE_PREFIX_FIELD,
    SOURCE_FIELD,
    SOURCE_RECORD_ID_FIELD
];

export default class AuditrRecordDetail extends LightningElement {
    @api recordId;

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    entryRecord;

    isEditingClassification = false;
    isSaving = false;

    get section() {
        return getFieldValue(this.entryRecord?.data, SECTION_FIELD) || 'General';
    }

    get actionCode() {
        return getFieldValue(this.entryRecord?.data, ACTION_CODE_FIELD) || '—';
    }

    get displayText() {
        return getFieldValue(this.entryRecord?.data, DISPLAY_FIELD) || '—';
    }

    get occurredAt() {
        return getFieldValue(this.entryRecord?.data, OCCURRED_AT_FIELD);
    }

    get responsibleUsername() {
        return getFieldValue(this.entryRecord?.data, RESPONSIBLE_USERNAME_FIELD) || '—';
    }

    get actorUsername() {
        return getFieldValue(this.entryRecord?.data, ACTOR_USERNAME_FIELD) || '—';
    }

    get delegateUser() {
        return getFieldValue(this.entryRecord?.data, DELEGATE_USER_FIELD) || '—';
    }

    get actorContext() {
        return getFieldValue(this.entryRecord?.data, ACTOR_CONTEXT_FIELD) || '—';
    }

    get namespacePrefix() {
        return getFieldValue(this.entryRecord?.data, NAMESPACE_PREFIX_FIELD) || '—';
    }

    get source() {
        return getFieldValue(this.entryRecord?.data, SOURCE_FIELD) || 'SetupAuditTrail';
    }

    get sourceRecordId() {
        return getFieldValue(this.entryRecord?.data, SOURCE_RECORD_ID_FIELD) || '—';
    }

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

    async handleClassificationSuccess() {
        this.isSaving = false;
        this.isEditingClassification = false;
        if (this.recordId) {
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        }
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
