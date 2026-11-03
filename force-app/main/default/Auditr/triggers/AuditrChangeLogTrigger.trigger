/**
 * @description Logicless trigger on Auditr_Change_Log__c delegating all execution to AuditrChangeLogTriggerHandler.
 */
trigger AuditrChangeLogTrigger on Auditr_Change_Log__c(before insert, before update, before delete) {
    AuditrChangeLogTriggerHandler.run();
}
