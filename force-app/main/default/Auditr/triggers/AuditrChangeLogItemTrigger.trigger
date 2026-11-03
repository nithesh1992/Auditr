/**
 * @description Logicless trigger on Auditr_Change_Log_Item__c delegating all execution to AuditrChangeLogItemTriggerHandler.
 */
trigger AuditrChangeLogItemTrigger on Auditr_Change_Log_Item__c(before insert, before update, before delete) {
    AuditrChangeLogItemTriggerHandler.run();
}
