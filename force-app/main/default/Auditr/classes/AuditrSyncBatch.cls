/**
 * @description Schedulable dispatcher and generic Batchable ingestion engine for Auditr sources.
 * The scheduled entry point enqueues one independent batch per active Auditr_Source__mdt adapter, so a failure
 * in one source never blocks another. Each batch applies the adapter's watermark and overlap window, removes
 * duplicates by Source_Record_Id__c, inserts with partial-success DML, and fails the job in finish() when any
 * row could not be inserted. The class name is kept for compatibility with existing scheduled jobs and
 * Control Center job monitoring.
 */
public with sharing class AuditrSyncBatch implements Database.Batchable<SObject>, Database.Stateful, Schedulable {
    private final AuditrSource source;

    @TestVisible private Integer totalSourceProcessed = 0;
    @TestVisible private Integer totalSuccessfullyInserted = 0;
    @TestVisible private Integer totalFailedInserts = 0;
    @TestVisible private String firstInsertErrorMessage;

    public class AuditrSyncException extends Exception {}

    /** @description Structured result of an ingestion slice. */
    public class IngestResult {
        public Integer successCount = 0;
        public Integer failedCount = 0;
        public String firstErrorMessage;
    }

    /**
     * @description Default constructor ingesting Setup Audit Trail (backward compatible).
     */
    public AuditrSyncBatch() {
        this(AuditrSource.defaultSource());
    }

    /**
     * @description Constructs an ingestion batch for a specific source adapter.
     * @param source Configured AuditrSource adapter.
     */
    public AuditrSyncBatch(AuditrSource source) {
        this.source = (source != null) ? source : AuditrSource.defaultSource();
    }

    /**
     * @description Schedulable entry point; dispatches every active source when Auditr_Setting__mdt.Is_Active__c is true.
     * @param context SchedulableContext provided by the platform.
     */
    public void execute(SchedulableContext context) {
        if (AuditrUtil.getSetting().Is_Active__c == true) {
            dispatchActiveSources();
        }
    }

    /**
     * @description Enqueues one AuditrSyncBatch per active Auditr_Source__mdt adapter.
     * @return Async job Ids, in registry order.
     */
    public static List<Id> dispatchActiveSources() {
        List<Id> jobIds = new List<Id>();
        for (AuditrSource adapter : AuditrSource.loadActiveSources()) {
            try {
                jobIds.add(Database.executeBatch(new AuditrSyncBatch(adapter), adapter.batchSize()));
            } catch (Exception ex) {
                System.debug(LoggingLevel.ERROR, 'Auditr source dispatch failed: ' + ex.getMessage());
            }
        }
        return jobIds;
    }

    /**
     * @description Returns the adapter's query from its resolved watermark cutoff.
     * @param context BatchableContext provided by the platform.
     * @return Database.QueryLocator over the source object.
     */
    public Database.QueryLocator start(Database.BatchableContext context) {
        return source.getQueryLocator(source.resolveCutoff());
    }

    /**
     * @description Maps a chunk through the adapter, then deduplicates and inserts new Auditr_Entry__c rows.
     * @param context BatchableContext provided by the platform.
     * @param scope Chunk of source rows.
     */
    public void execute(Database.BatchableContext context, List<SObject> scope) {
        totalSourceProcessed += scope.size();
        List<Auditr_Entry__c> entries = source.toEntries(scope);
        entries.addAll(source.flush());
        accumulate(insertNewEntries(entries, source.sourceKey()));
    }

    /**
     * @description Fails the job when any row failed, and chains
     * AuditrPurgeBatch after a successful Setup Audit Trail run when retention purging is enabled.
     * @param context BatchableContext provided by the platform.
     */
    public void finish(Database.BatchableContext context) {
        if (totalFailedInserts > 0) {
            throw new AuditrSyncException(
                'AuditrSyncBatch [' + source.sourceKey() + '] encountered ' + totalFailedInserts +
                ' failed record inserts during ingestion. First error: ' + firstInsertErrorMessage
            );
        }
        Auditr_Setting__mdt setting = AuditrUtil.getSetting();
        if (!Test.isRunningTest() && source.sourceKey() == AuditrUtil.DEFAULT_SOURCE
            && setting.Enable_Purge__c == true && setting.Retention_Days__c != null && setting.Retention_Days__c > 0) {
            Database.executeBatch(new AuditrPurgeBatch(), AuditrUtil.getBatchSize());
        }
    }

    /**
     * @description Deduplicates and inserts Setup Audit Trail rows (backward-compatible helper).
     * @param auditRecords SetupAuditTrail rows.
     * @return IngestResult with successCount, failedCount, and firstErrorMessage.
     */
    public static IngestResult processAuditRecordsWithResult(List<SetupAuditTrail> auditRecords) {
        return insertNewEntries(new AuditrSetupAuditTrailSource().toEntries(auditRecords), AuditrUtil.DEFAULT_SOURCE);
    }

    /**
     * @description Backward-compatible helper returning the successfully inserted count.
     * @param auditRecords SetupAuditTrail rows.
     * @return Number of new Auditr_Entry__c records inserted.
     */
    public static Integer processAuditRecords(List<SetupAuditTrail> auditRecords) {
        return processAuditRecordsWithResult(auditRecords).successCount;
    }

    /**
     * @description Removes entries whose Source_Record_Id__c already exists (in the database or earlier in the list),
     * inserts the rest with partial-success DML, and records row-level failures.
     * @param candidates Unsaved entries built by an adapter.
     * @param sourceKey Source key used in error logging.
     * @return IngestResult with success/failure counts.
     */
    public static IngestResult insertNewEntries(List<Auditr_Entry__c> candidates, String sourceKey) {
        IngestResult result = new IngestResult();
        List<Auditr_Entry__c> newEntries = filterNewEntries(candidates);
        if (newEntries.isEmpty()) {
            return result;
        }

        Database.SaveResult[] saveResults = Database.insert(newEntries, false, AccessLevel.SYSTEM_MODE);
        for (Integer i = 0; i < saveResults.size(); i++) {
            recordInsertResult(result, saveResults[i], newEntries[i].Source_Record_Id__c, sourceKey);
        }
        return result;
    }

    private static List<Auditr_Entry__c> filterNewEntries(List<Auditr_Entry__c> candidates) {
        List<Auditr_Entry__c> newEntries = new List<Auditr_Entry__c>();
        if (candidates == null || candidates.isEmpty()) {
            return newEntries;
        }
        Set<String> candidateSourceIds = new Set<String>();
        for (Auditr_Entry__c entry : candidates) {
            if (String.isNotBlank(entry.Source_Record_Id__c)) {
                candidateSourceIds.add(entry.Source_Record_Id__c);
            }
        }
        Set<String> seenSourceIds = queryExistingSourceIds(candidateSourceIds);
        for (Auditr_Entry__c entry : candidates) {
            if (String.isNotBlank(entry.Source_Record_Id__c) && seenSourceIds.add(entry.Source_Record_Id__c)) {
                newEntries.add(entry);
            }
        }
        return newEntries;
    }

    @SuppressWarnings('PMD.ExcessiveParameterList')
    private static void recordInsertResult(
        IngestResult result,
        Database.SaveResult sr,
        String sourceRecordId,
        String sourceKey
    ) {
        if (sr.isSuccess()) {
            result.successCount++;
            return;
        }
        result.failedCount++;
        for (Database.Error err : sr.getErrors()) {
            if (result.firstErrorMessage == null) {
                result.firstErrorMessage = err.getMessage();
            }
            System.debug(
                LoggingLevel.ERROR,
                'AuditrSyncBatch [' + sourceKey + '] failed to insert row for sourceId ' +
                sourceRecordId + ': ' + err.getMessage()
            );
        }
    }

    /**
     * @description Resolves the Setup Audit Trail watermark cutoff (backward-compatible test hook).
     * @return Cutoff DateTime.
     */
    @TestVisible
    private static DateTime resolveCutoffTimestamp() {
        return AuditrSource.defaultSource().resolveCutoff();
    }

    private void accumulate(IngestResult result) {
        totalSuccessfullyInserted += result.successCount;
        totalFailedInserts += result.failedCount;
        if (firstInsertErrorMessage == null && result.firstErrorMessage != null) {
            firstInsertErrorMessage = result.firstErrorMessage;
        }
    }

    private static Set<String> queryExistingSourceIds(Set<String> candidateSourceIds) {
        Set<String> existingIds = new Set<String>();
        if (candidateSourceIds.isEmpty()) {
            return existingIds;
        }
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
