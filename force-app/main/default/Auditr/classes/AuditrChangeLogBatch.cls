/**
 * @description Asynchronous packaging engine that cites Auditr_Entry__c rows inside an Auditr_Change_Log__c
 * via Auditr_Change_Log_Item__c junction records. Scopes by explicit entry selection or by the
 * target log's stored window/actor filter (unassigned entries only), and deduplicates against existing citations.
 * Designed for 10,000+ entry release windows.
 */
public with sharing class AuditrChangeLogBatch implements Database.Batchable<SObject> {
    private final Id changeLogId;
    private final Set<Id> selectedEntryIds;

    /**
     * @description Filter-driven packaging: scope is resolved from the target log's Window_Start__c, Window_End__c, and Target_Actor__c.
     * @param changeLogId Draft Auditr_Change_Log__c to package entries into.
     */
    public AuditrChangeLogBatch(Id changeLogId) {
        this(changeLogId, null);
    }

    /**
     * @description Selection-driven packaging: scope is an explicit set of Auditr_Entry__c Ids.
     * @param changeLogId Draft Auditr_Change_Log__c to package entries into.
     * @param selectedEntryIds Explicit Auditr_Entry__c Ids to cite (null resolves the stored filter).
     */
    public AuditrChangeLogBatch(Id changeLogId, Set<Id> selectedEntryIds) {
        this.changeLogId = changeLogId;
        this.selectedEntryIds = selectedEntryIds;
    }

    /**
     * @description Builds the entry scope: explicit Ids or the target log's stored window/actor filter.
     * @param context BatchableContext provided by the platform.
     * @return Database.QueryLocator over Auditr_Entry__c ordered chronologically.
     */
    public Database.QueryLocator start(Database.BatchableContext context) {
        if (selectedEntryIds != null && !selectedEntryIds.isEmpty()) {
            return Database.getQueryLocator([
                SELECT Id FROM Auditr_Entry__c WHERE Id IN :selectedEntryIds WITH SYSTEM_MODE ORDER BY Occurred_At__c ASC
            ]);
        }

        Auditr_Change_Log__c targetLog = queryChangeLog();
        String actor = String.isBlank(targetLog.Target_Actor__c) ? null : targetLog.Target_Actor__c;
        DateTime windowStart = targetLog.Window_Start__c;
        DateTime windowEnd = targetLog.Window_End__c;
        if (actor == null) {
            return Database.getQueryLocator([
                SELECT Id FROM Auditr_Entry__c
                WHERE Occurred_At__c >= :windowStart AND Occurred_At__c <= :windowEnd
                    AND Id NOT IN (SELECT Entry__c FROM Auditr_Change_Log_Item__c WHERE Entry__c != NULL)
                WITH SYSTEM_MODE ORDER BY Occurred_At__c ASC
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id FROM Auditr_Entry__c
            WHERE Occurred_At__c >= :windowStart AND Occurred_At__c <= :windowEnd
                AND Responsible_Username__c = :actor
                AND Id NOT IN (SELECT Entry__c FROM Auditr_Change_Log_Item__c WHERE Entry__c != NULL)
            WITH SYSTEM_MODE ORDER BY Occurred_At__c ASC
        ]);
    }

    /**
     * @description Inserts deduplicated change log items for each chunk with partial-success DML and error logging.
     * @param context BatchableContext provided by the platform.
     * @param scope Chunk of Auditr_Entry__c records.
     */
    public void execute(Database.BatchableContext context, List<SObject> scope) {
        Auditr_Change_Log__c targetLog = queryChangeLog();
        if (targetLog.Status__c == AuditrChangeLogTriggerHandler.STATUS_SEALED) {
            System.debug(LoggingLevel.WARN, 'AuditrChangeLogBatch skipping chunk: target change log ' + changeLogId + ' is already sealed.');
            return;
        }

        Set<Id> scopeEntryIds = new Map<Id, SObject>(scope).keySet();
        Set<Id> alreadyCited = queryAlreadyCited(scopeEntryIds);

        List<Auditr_Change_Log_Item__c> newItems = new List<Auditr_Change_Log_Item__c>();
        for (SObject entry : scope) {
            if (!alreadyCited.contains(entry.Id)) {
                newItems.add(new Auditr_Change_Log_Item__c(Change_Log__c = changeLogId, Entry__c = entry.Id));
            }
        }
        if (newItems.isEmpty()) {
            return;
        }
        Database.SaveResult[] saveResults = Database.insert(newItems, false, AccessLevel.SYSTEM_MODE);
        for (Integer i = 0; i < saveResults.size(); i++) {
            Database.SaveResult sr = saveResults[i];
            if (!sr.isSuccess()) {
                for (Database.Error err : sr.getErrors()) {
                    System.debug(
                        LoggingLevel.ERROR,
                        'AuditrChangeLogBatch failed to cite entry ' + newItems[i].Entry__c + ': ' + err.getMessage()
                    );
                }
            }
        }
    }

    /**
     * @description Clears the in-flight Packaging_Job_Id__c on Draft logs when batch execution completes.
     * @param context BatchableContext provided by the platform.
     */
    public void finish(Database.BatchableContext context) {
        Auditr_Change_Log__c targetLog = queryChangeLog();
        if (targetLog.Status__c == AuditrChangeLogTriggerHandler.STATUS_DRAFT) {
            Database.update(
                new Auditr_Change_Log__c(Id = changeLogId, Packaging_Job_Id__c = null),
                false,
                AccessLevel.SYSTEM_MODE
            );
        }
    }

    private Auditr_Change_Log__c queryChangeLog() {
        List<Auditr_Change_Log__c> logs = [
            SELECT Id, Status__c, Target_Actor__c, Window_Start__c, Window_End__c
            FROM Auditr_Change_Log__c WHERE Id = :changeLogId WITH SYSTEM_MODE LIMIT 1
        ];
        return logs.isEmpty() ? new Auditr_Change_Log__c() : logs[0];
    }

    private Set<Id> queryAlreadyCited(Set<Id> scopeEntryIds) {
        Set<Id> cited = new Set<Id>();
        for (Auditr_Change_Log_Item__c existing : [
            SELECT Entry__c FROM Auditr_Change_Log_Item__c
            WHERE Change_Log__c = :changeLogId AND Entry__c IN :scopeEntryIds
            WITH SYSTEM_MODE
        ]) {
            cited.add(existing.Entry__c);
        }
        return cited;
    }
}
