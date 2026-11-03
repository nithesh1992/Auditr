/**
 * @description Stamps the compound uniqueness key on Auditr_Change_Log_Item__c and blocks citation
 * changes once the parent Auditr Change Log is sealed.
 */
public with sharing class AuditrChangeLogItemTriggerHandler {
    public static final String SEALED_LOG_ERROR = 'Entries cannot be added to or removed from a sealed Auditr Change Log.';

    /**
     * @description Routes Auditr_Change_Log_Item__c trigger execution by Trigger.operationType.
     */
    public static void run() {
        switch on Trigger.operationType {
            when BEFORE_INSERT, BEFORE_UPDATE {
                beforeSave((List<Auditr_Change_Log_Item__c>) Trigger.new);
            }
            when BEFORE_DELETE {
                beforeDelete((List<Auditr_Change_Log_Item__c>) Trigger.old);
            }
        }
    }

    private static void beforeSave(List<Auditr_Change_Log_Item__c> newItems) {
        Map<Id, Auditr_Change_Log__c> parentLogsById = queryParentLogs(collectChangeLogIds(newItems));
        for (Auditr_Change_Log_Item__c item : newItems) {
            item.Compound_Key__c = String.valueOf(item.Change_Log__c) + '-' + String.valueOf(item.Entry__c);
            if (parentLogsById.get(item.Change_Log__c)?.Status__c == AuditrChangeLogTriggerHandler.STATUS_SEALED) {
                item.addError(SEALED_LOG_ERROR);
            }
        }
    }

    private static void beforeDelete(List<Auditr_Change_Log_Item__c> oldItems) {
        Map<Id, Auditr_Change_Log__c> parentLogsById = queryParentLogs(collectChangeLogIds(oldItems));
        for (Auditr_Change_Log_Item__c item : oldItems) {
            if (parentLogsById.get(item.Change_Log__c)?.Status__c == AuditrChangeLogTriggerHandler.STATUS_SEALED) {
                item.addError(SEALED_LOG_ERROR);
            }
        }
    }

    private static Set<Id> collectChangeLogIds(List<Auditr_Change_Log_Item__c> items) {
        Set<Id> changeLogIds = new Set<Id>();
        for (Auditr_Change_Log_Item__c item : items) {
            if (item.Change_Log__c != null) {
                changeLogIds.add(item.Change_Log__c);
            }
        }
        return changeLogIds;
    }

    private static Map<Id, Auditr_Change_Log__c> queryParentLogs(Set<Id> changeLogIds) {
        if (changeLogIds.isEmpty()) {
            return new Map<Id, Auditr_Change_Log__c>();
        }
        return new Map<Id, Auditr_Change_Log__c>([
            SELECT Id, Status__c FROM Auditr_Change_Log__c WHERE Id IN :changeLogIds WITH SYSTEM_MODE
        ]);
    }
}
