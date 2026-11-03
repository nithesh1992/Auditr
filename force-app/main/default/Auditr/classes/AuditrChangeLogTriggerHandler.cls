/**
 * @description Enforces the Change Log compliance lifecycle on Auditr_Change_Log__c: Draft by default,
 * sealed logs become fully immutable, sealing stamps auditor sign-off and requires packaged entries.
 */
public with sharing class AuditrChangeLogTriggerHandler {
    public static final String STATUS_DRAFT = 'Draft';
    public static final String STATUS_SEALED = 'Sealed';
    public static final String SEALED_IMMUTABLE_ERROR = 'Sealed Auditr Change Logs are immutable. Create a new change log instead of modifying a sealed one.';
    public static final String SEALED_DELETE_ERROR = 'Sealed Auditr Change Logs cannot be deleted; they are permanent compliance evidence.';
    public static final String SEAL_REQUIRES_ENTRIES_ERROR = 'A change log must contain at least one packaged entry before it can be sealed.';

    /**
     * @description Routes Auditr_Change_Log__c trigger execution by Trigger.operationType.
     */
    public static void run() {
        switch on Trigger.operationType {
            when BEFORE_INSERT {
                beforeInsert((List<Auditr_Change_Log__c>) Trigger.new);
            }
            when BEFORE_UPDATE {
                beforeUpdate((List<Auditr_Change_Log__c>) Trigger.new, (Map<Id, Auditr_Change_Log__c>) Trigger.oldMap);
            }
            when BEFORE_DELETE {
                beforeDelete((List<Auditr_Change_Log__c>) Trigger.old);
            }
        }
    }

    private static void beforeInsert(List<Auditr_Change_Log__c> newLogs) {
        for (Auditr_Change_Log__c changeLog : newLogs) {
            if (String.isBlank(changeLog.Status__c)) {
                changeLog.Status__c = STATUS_DRAFT;
            }
        }
    }

    private static void beforeUpdate(List<Auditr_Change_Log__c> newLogs, Map<Id, Auditr_Change_Log__c> oldMap) {
        for (Auditr_Change_Log__c changeLog : newLogs) {
            Auditr_Change_Log__c previous = oldMap.get(changeLog.Id);
            if (previous.Status__c == STATUS_SEALED) {
                changeLog.addError(SEALED_IMMUTABLE_ERROR);
            } else if (changeLog.Status__c == STATUS_SEALED && previous.Status__c != STATUS_SEALED) {
                if ((changeLog.Total_Entries__c ?? 0) <= 0) {
                    changeLog.addError(SEAL_REQUIRES_ENTRIES_ERROR);
                } else {
                    changeLog.Signed_Off_By__c = UserInfo.getUserId();
                    changeLog.Signed_Off_At__c = System.now();
                }
            }
        }
    }

    private static void beforeDelete(List<Auditr_Change_Log__c> oldLogs) {
        for (Auditr_Change_Log__c changeLog : oldLogs) {
            if (changeLog.Status__c == STATUS_SEALED) {
                changeLog.addError(SEALED_DELETE_ERROR);
            }
        }
    }
}
