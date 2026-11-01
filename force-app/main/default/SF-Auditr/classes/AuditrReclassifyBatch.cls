/**
 * @description Re-evaluates Auditr_Entry__c records against active Auditr_Rule__mdt rules and updates Category__c / Risk_Level__c.
 */
public with sharing class AuditrReclassifyBatch implements Database.Batchable<SObject> {
    private final Boolean onlyUnclassified;

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
                SELECT Id, Action_Code__c, Section__c, Namespace_Prefix__c, Delegate_User__c, Category__c, Risk_Level__c
                FROM Auditr_Entry__c
                WHERE Category__c = :AuditrUtil.DEFAULT_CATEGORY
                WITH SYSTEM_MODE
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id, Action_Code__c, Section__c, Namespace_Prefix__c, Delegate_User__c, Category__c, Risk_Level__c
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
            AuditrUtil.ClassificationResult result = AuditrUtil.classify(
                entry.Action_Code__c,
                entry.Section__c,
                entry.Namespace_Prefix__c,
                entry.Delegate_User__c
            );
            if (entry.Category__c != result.category || entry.Risk_Level__c != result.riskLevel) {
                entry.Category__c = result.category;
                entry.Risk_Level__c = result.riskLevel;
                entriesToUpdate.add(entry);
            }
        }
        if (!entriesToUpdate.isEmpty()) {
            Database.update(entriesToUpdate, false, AccessLevel.SYSTEM_MODE);
        }
    }

    /**
     * @description Post-processing hook after reclassification completes.
     * @param context BatchableContext provided by the platform.
     */
    @SuppressWarnings('PMD.EmptyStatementBlock')
    public void finish(Database.BatchableContext context) {
    }
}
