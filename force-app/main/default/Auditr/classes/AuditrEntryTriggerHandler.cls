/**
 * @description Enforces attribution stamping and blocks edits/deletes of source fields through normal use on Auditr_Entry__c.
 */
public with sharing class AuditrEntryTriggerHandler {
    public static final String IMMUTABLE_SOURCE_ERROR = 'Auditr Entry source and attribution fields cannot be modified after creation. Only Category and Risk Level may be reclassified.';
    public static final String DELETE_BLOCKED_ERROR = 'Auditr Entry records cannot be deleted outside an authorized retention purge.';

    private static Boolean allowPurgeDelete = false;

    private static final List<Schema.SObjectField> IMMUTABLE_FIELDS = new List<Schema.SObjectField>{
        Auditr_Entry__c.Source__c,
        Auditr_Entry__c.Source_Record_Id__c,
        Auditr_Entry__c.Occurred_At__c,
        Auditr_Entry__c.Actor__c,
        Auditr_Entry__c.Actor_Username__c,
        Auditr_Entry__c.Delegate_User__c,
        Auditr_Entry__c.Responsible_Username__c,
        Auditr_Entry__c.Actor_Context__c,
        Auditr_Entry__c.Action_Code__c,
        Auditr_Entry__c.Section__c,
        Auditr_Entry__c.Namespace_Prefix__c,
        Auditr_Entry__c.Display__c
    };

    /**
     * @description Routes Auditr_Entry__c trigger execution by Trigger.operationType.
     */
    public static void run() {
        switch on Trigger.operationType {
            when BEFORE_INSERT {
                beforeInsert((List<Auditr_Entry__c>) Trigger.new);
            }
            when BEFORE_UPDATE {
                beforeUpdate((List<Auditr_Entry__c>) Trigger.new, (Map<Id, Auditr_Entry__c>) Trigger.oldMap);
            }
            when BEFORE_DELETE {
                beforeDelete((List<Auditr_Entry__c>) Trigger.old);
            }
        }
    }

    /**
     * @description Deletes expired audit records only when AuditrPurgeBatch.execute is on the call stack.
     * Stack inspection happens prior to DML because Apex truncates getStackTraceString() at the Trigger boundary.
     * @param scope Expired Auditr_Entry__c records to delete.
     */
    public static void deleteFromPurgeBatch(List<SObject> scope) {
        if (scope == null || scope.isEmpty()) {
            return;
        }
        allowPurgeDelete = new DmlException().getStackTraceString().contains('AuditrPurgeBatch.execute');
        try {
            Database.delete(scope, false, AccessLevel.SYSTEM_MODE);
        } finally {
            allowPurgeDelete = false;
        }
    }

    private static void beforeInsert(List<Auditr_Entry__c> newEntries) {
        for (Auditr_Entry__c entry : newEntries) {
            entry.Responsible_Username__c = String.isNotBlank(entry.Delegate_User__c) ? entry.Delegate_User__c : entry.Actor_Username__c;
        }
    }

    private static void beforeUpdate(List<Auditr_Entry__c> newEntries, Map<Id, Auditr_Entry__c> oldMap) {
        for (Auditr_Entry__c entry : newEntries) {
            if (isSourceModified(entry, oldMap.get(entry.Id))) {
                entry.addError(IMMUTABLE_SOURCE_ERROR);
            }
        }
    }

    private static void beforeDelete(List<Auditr_Entry__c> oldEntries) {
        if (allowPurgeDelete) {
            return;
        }
        for (Auditr_Entry__c entry : oldEntries) {
            entry.addError(DELETE_BLOCKED_ERROR);
        }
    }

    private static Boolean isSourceModified(Auditr_Entry__c current, Auditr_Entry__c previous) {
        for (Schema.SObjectField field : IMMUTABLE_FIELDS) {
            if (current.get(field) != previous.get(field)) {
                return true;
            }
        }
        return false;
    }
}