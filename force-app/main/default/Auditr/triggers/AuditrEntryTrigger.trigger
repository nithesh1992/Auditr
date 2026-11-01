/**
 * @description Logicless trigger on Auditr_Entry__c delegating all execution to AuditrEntryTriggerHandler.
 */
trigger AuditrEntryTrigger on Auditr_Entry__c(before insert, before update, before delete) {
    AuditrEntryTriggerHandler.run();
}