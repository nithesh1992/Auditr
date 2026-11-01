/**
 * @description Opt-in retention purge batch and schedulable job for Auditr_Entry__c.
 * Deletes records older than Retention_Days__c only when Enable_Purge__c is explicitly true.
 */
public with sharing class AuditrPurgeBatch implements Database.Batchable<SObject>, Schedulable {
    /**
     * @description Scheduled entry point that launches AuditrPurgeBatch when Enable_Purge__c is active and Retention_Days__c > 0.
     * @param context SchedulableContext provided by the platform.
     */
    public void execute(SchedulableContext context) {
        Auditr_Setting__mdt setting = AuditrUtil.getSetting();
        if (setting.Enable_Purge__c != true || setting.Retention_Days__c == null || setting.Retention_Days__c <= 0) {
            return;
        }
        Database.executeBatch(new AuditrPurgeBatch(), AuditrUtil.getBatchSize());
    }

    /**
     * @description Queries expired Auditr_Entry__c rows when Enable_Purge__c is true and Retention_Days__c > 0.
     * @param context BatchableContext provided by the platform.
     * @return Database.QueryLocator for expired Auditr_Entry__c rows (or an empty locator when purge is disabled).
     */
    public Database.QueryLocator start(Database.BatchableContext context) {
        Auditr_Setting__mdt setting = AuditrUtil.getSetting();
        if (setting.Enable_Purge__c != true || setting.Retention_Days__c == null || setting.Retention_Days__c <= 0) {
            return Database.getQueryLocator([SELECT Id FROM Auditr_Entry__c WHERE Id = NULL WITH SYSTEM_MODE]);
        }

        DateTime cutoffDate = System.now().addDays(-Integer.valueOf(setting.Retention_Days__c));
        return Database.getQueryLocator([
            SELECT Id
            FROM Auditr_Entry__c
            WHERE Occurred_At__c < :cutoffDate
            WITH SYSTEM_MODE
        ]);
    }

    /**
     * @description Temporarily unlocks AuditrEntryTriggerHandler.allowPurgeDelete to delete expired audit rows.
     * @param context BatchableContext provided by the platform.
     * @param scope Chunk of expired Auditr_Entry__c records.
     */
    public void execute(Database.BatchableContext context, List<SObject> scope) {
        AuditrEntryTriggerHandler.allowPurgeDelete = true;
        try {
            Database.delete(scope, false, AccessLevel.SYSTEM_MODE);
        } finally {
            AuditrEntryTriggerHandler.allowPurgeDelete = false;
        }
    }

    /**
     * @description Post-processing hook after retention purge completes.
     * @param context BatchableContext provided by the platform.
     */
    @SuppressWarnings('PMD.EmptyStatementBlock')
    public void finish(Database.BatchableContext context) {
    }
}