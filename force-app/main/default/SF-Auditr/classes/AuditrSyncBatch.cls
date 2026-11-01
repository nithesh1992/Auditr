/**
 * @description Schedulable and Batchable job that ingests new SetupAuditTrail rows into Auditr_Entry__c
 * using an indexed CreatedDate watermark with a 2-day overlap window and per-chunk deduplication.
 */
public with sharing class AuditrSyncBatch implements Database.Batchable<SObject>, Schedulable {
    private static final Integer OVERLAP_DAYS = 2;

    /**
     * @description Schedulable entry point; executes AuditrSyncBatch when Auditr_Setting__mdt.Is_Active__c is true.
     * @param context SchedulableContext provided by the platform.
     */
    public void execute(SchedulableContext context) {
        if (AuditrUtil.getSetting().Is_Active__c == true) {
            Database.executeBatch(new AuditrSyncBatch(), AuditrUtil.getBatchSize());
        }
    }

    /**
     * @description Queries SetupAuditTrail starting from the latest ingested watermark minus 2 days.
     * @param context BatchableContext provided by the platform.
     * @return Database.QueryLocator for SetupAuditTrail ordered by CreatedDate ASC.
     */
    public Database.QueryLocator start(Database.BatchableContext context) {
        DateTime cutoffTimestamp = resolveCutoffTimestamp();
        return Database.getQueryLocator([
            SELECT Id, Action, Section, CreatedDate, CreatedById, CreatedBy.Username,
                   Display, DelegateUser, ResponsibleNamespacePrefix, CreatedByContext, CreatedByIssuer
            FROM SetupAuditTrail
            WHERE CreatedDate >= :cutoffTimestamp
            WITH SYSTEM_MODE
            ORDER BY CreatedDate ASC
        ]);
    }

    /**
     * @description Deduplicates incoming SetupAuditTrail records and inserts new Auditr_Entry__c rows in SYSTEM_MODE.
     * @param context BatchableContext provided by the platform.
     * @param scope Chunk of SetupAuditTrail records.
     */
    public void execute(Database.BatchableContext context, List<SObject> scope) {
        processAuditRecords((List<SetupAuditTrail>) scope);
    }

    /**
     * @description Chains AuditrPurgeBatch when opt-in retention purging is enabled in Auditr_Setting__mdt.
     * @param context BatchableContext provided by the platform.
     */
    public void finish(Database.BatchableContext context) {
        Auditr_Setting__mdt setting = AuditrUtil.getSetting();
        if (!Test.isRunningTest() && setting.Enable_Purge__c == true && setting.Retention_Days__c != null && setting.Retention_Days__c > 0) {
            Database.executeBatch(new AuditrPurgeBatch(), AuditrUtil.getBatchSize());
        }
    }

    /**
     * @description Deduplicates and inserts new Auditr_Entry__c records from a list of SetupAuditTrail rows.
     * @param auditRecords List of SetupAuditTrail records to ingest.
     * @return Number of new Auditr_Entry__c records inserted.
     */
    public static Integer processAuditRecords(List<SetupAuditTrail> auditRecords) {
        if (auditRecords == null || auditRecords.isEmpty()) {
            return 0;
        }

        Set<String> candidateSourceIds = new Set<String>();
        for (SetupAuditTrail auditRow : auditRecords) {
            if (auditRow.Id != null) {
                candidateSourceIds.add(String.valueOf(auditRow.Id));
            }
        }

        Set<String> existingSourceIds = queryExistingSourceIds(candidateSourceIds);
        List<Auditr_Entry__c> newEntries = new List<Auditr_Entry__c>();

        for (SetupAuditTrail auditRow : auditRecords) {
            String sourceId = String.valueOf(auditRow.Id);
            if (!existingSourceIds.contains(sourceId)) {
                newEntries.add(AuditrUtil.buildEntryFromAuditTrail(auditRow));
                existingSourceIds.add(sourceId);
            }
        }

        if (!newEntries.isEmpty()) {
            Database.insert(newEntries, false, AccessLevel.SYSTEM_MODE);
        }
        return newEntries.size();
    }

    @TestVisible
    private static DateTime resolveCutoffTimestamp() {
        List<Auditr_Entry__c> latestEntries = [
            SELECT Occurred_At__c, CreatedDate
            FROM Auditr_Entry__c
            WHERE Source__c = :AuditrUtil.DEFAULT_SOURCE
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        DateTime twoDaysAgo = System.now().addDays(-OVERLAP_DAYS);
        if (!latestEntries.isEmpty() && latestEntries[0].Occurred_At__c != null) {
            DateTime watermarkOverlap = latestEntries[0].Occurred_At__c.addDays(-OVERLAP_DAYS);
            return (watermarkOverlap < twoDaysAgo) ? watermarkOverlap : twoDaysAgo;
        }

        Decimal configuredBackfill = AuditrUtil.getSetting().Backfill_Days__c;
        Integer backfillDays = (configuredBackfill != null && configuredBackfill > 0)
            ? Integer.valueOf(configuredBackfill)
            : AuditrUtil.DEFAULT_BACKFILL_DAYS;
        return System.now().addDays(-backfillDays);
    }

    private static Set<String> queryExistingSourceIds(Set<String> candidateSourceIds) {
        Set<String> existingIds = new Set<String>();
        for (Auditr_Entry__c existing : [
            SELECT Source_Record_Id__c
            FROM Auditr_Entry__c
            WHERE Source_Record_Id__c IN :candidateSourceIds
            WITH SYSTEM_MODE
        ]) {
            existingIds.add(existing.Source_Record_Id__c);
        }
        return existingIds;
    }
}
