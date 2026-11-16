/**
 * @description Re-evaluates Auditr_Entry__c records against active Auditr_Rule__mdt rules and updates Category__c / Risk_Level__c.
 */
public with sharing class AuditrReclassifyBatch implements Database.Batchable<SObject>, Database.Stateful {
    private final Boolean onlyUnclassified;

    @TestVisible private Integer totalUpdated = 0;
    @TestVisible private Integer totalFailed = 0;
    @TestVisible private String firstErrorMessage;

    public class AuditrReclassifyException extends Exception {}

    /**
     * @description Default constructor that re-evaluates only Unclassified Auditr_Entry__c records.
     */
    public AuditrReclassifyBatch() {
        this(true);
    }

    /**
     * @description Constructs a reclassification batch job.
     * @param onlyUnclassified True to query only Unclassified entries; false to re-evaluate all entries.
     */
    @SuppressWarnings('PMD.AvoidBooleanMethodParameters')
    public AuditrReclassifyBatch(Boolean onlyUnclassified) {
        this.onlyUnclassified = (onlyUnclassified != false);
    }

    /**
     * @description Queries Auditr_Entry__c records to reclassify.
     * @param context BatchableContext provided by the platform.
     * @return Database.QueryLocator for target Auditr_Entry__c rows.
     */
    public Database.QueryLocator start(Database.BatchableContext context) {
        if (this.onlyUnclassified) {
            return Database.getQueryLocator([
                SELECT Id, Source__c, Target_Object__c, Payload__c, Action_Code__c, Section__c, Namespace_Prefix__c, Delegate_User__c, Category__c, Risk_Level__c
                FROM Auditr_Entry__c
                WHERE Category__c = :AuditrUtil.DEFAULT_CATEGORY
                WITH SYSTEM_MODE
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id, Source__c, Target_Object__c, Payload__c, Action_Code__c, Section__c, Namespace_Prefix__c, Delegate_User__c, Category__c, Risk_Level__c
            FROM Auditr_Entry__c
            WHERE Source__c != NULL
            WITH SYSTEM_MODE
        ]);
    }

    /**
     * @description Re-evaluates classification rules and updates only rows whose Category__c or Risk_Level__c changed.
     * @param context BatchableContext provided by the platform.
     * @param scope Chunk of Auditr_Entry__c records.
     */
    public void execute(Database.BatchableContext context, List<SObject> scope) {
        List<Auditr_Entry__c> entriesToUpdate = new List<Auditr_Entry__c>();
        for (Auditr_Entry__c entry : (List<Auditr_Entry__c>) scope) {
            AuditrUtil.ClassificationResult result = classifyEntry(entry);
            if (entry.Category__c != result.category || entry.Risk_Level__c != result.riskLevel) {
                entry.Category__c = result.category;
                entry.Risk_Level__c = result.riskLevel;
                entriesToUpdate.add(entry);
            }
        }
        if (!entriesToUpdate.isEmpty()) {
            recordUpdateResults(entriesToUpdate, Database.update(entriesToUpdate, false, AccessLevel.SYSTEM_MODE));
        }
    }

    private static AuditrUtil.ClassificationResult classifyEntry(Auditr_Entry__c entry) {
        if (entry.Source__c == AuditrUtil.DATA_CHANGE_SOURCE) {
            AuditrUtil.ClassificationResult defaults = AuditrWatchedObjectSource.getDefaultsForObject(entry.Target_Object__c);
            return AuditrUtil.classifyWatchedObject(
                entry.Target_Object__c,
                extractChangedFields(entry.Payload__c),
                entry.Action_Code__c,
                entry.Section__c,
                entry.Delegate_User__c,
                defaults.category,
                defaults.riskLevel
            );
        }
        return AuditrUtil.classify(
            entry.Source__c,
            entry.Action_Code__c,
            entry.Section__c,
            entry.Namespace_Prefix__c,
            entry.Delegate_User__c
        );
    }

    private void recordUpdateResults(List<Auditr_Entry__c> entriesToUpdate, Database.SaveResult[] saveResults) {
        for (Integer i = 0; i < saveResults.size(); i++) {
            Database.SaveResult sr = saveResults[i];
            if (sr.isSuccess()) {
                totalUpdated++;
            } else {
                totalFailed++;
                logUpdateErrors(entriesToUpdate[i].Id, sr.getErrors());
            }
        }
    }

    private void logUpdateErrors(Id entryId, List<Database.Error> errors) {
        for (Database.Error err : errors) {
            if (firstErrorMessage == null) {
                firstErrorMessage = err.getMessage();
            }
            System.debug(
                LoggingLevel.ERROR,
                'AuditrReclassifyBatch failed to update entry ' + entryId + ': ' + err.getMessage()
            );
        }
    }

    /**
     * @description Post-processing hook after reclassification completes.
     * Throws AuditrReclassifyException if row-level update failures occurred.
     * @param context BatchableContext provided by the platform.
     */
    public void finish(Database.BatchableContext context) {
        if (totalFailed > 0) {
            throw new AuditrReclassifyException(
                'AuditrReclassifyBatch encountered ' + totalFailed +
                ' failed record updates. First error: ' + firstErrorMessage
            );
        }
    }

    private static List<String> extractChangedFields(String payloadJson) {
        List<String> fields = new List<String>();
        if (String.isBlank(payloadJson)) {
            return fields;
        }
        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);
            Object rawList = (parsed != null) ? parsed.get('fields') : null;
            if (rawList instanceof List<Object>) {
                for (Object item : (List<Object>) rawList) {
                    if (item != null) {
                        fields.add(String.valueOf(item));
                    }
                }
            }
        } catch (Exception ex) {
            return fields;
        }
        return fields;
    }
}