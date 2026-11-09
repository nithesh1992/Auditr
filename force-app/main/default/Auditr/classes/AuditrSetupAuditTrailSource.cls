/**
 * @description Auditr ingestion adapter for SetupAuditTrail (Setup changes, 180-day platform retention).
 */
public with sharing class AuditrSetupAuditTrailSource extends AuditrSource {
    /**
     * @description Source key for Setup Audit Trail entries.
     * @return 'SetupAuditTrail'.
     */
    public override String sourceKey() {
        return AuditrUtil.DEFAULT_SOURCE;
    }

    /**
     * @description Queries SetupAuditTrail from the cutoff, oldest first.
     * @param cutoff Earliest CreatedDate to read.
     * @return Database.QueryLocator over SetupAuditTrail.
     */
    public override Database.QueryLocator getQueryLocator(DateTime cutoff) {
        return Database.getQueryLocator([
            SELECT Id, Action, Section, CreatedDate, CreatedById, CreatedBy.Username,
                   Display, DelegateUser, ResponsibleNamespacePrefix, CreatedByContext
            FROM SetupAuditTrail
            WHERE CreatedDate >= :cutoff
            WITH SYSTEM_MODE
            ORDER BY CreatedDate ASC
        ]);
    }

    /**
     * @description Maps SetupAuditTrail rows to classified Auditr_Entry__c records (one entry per row).
     * @param rows SetupAuditTrail rows.
     * @return Unsaved Auditr_Entry__c records.
     */
    public override List<Auditr_Entry__c> toEntries(List<SObject> rows) {
        List<Auditr_Entry__c> entries = new List<Auditr_Entry__c>();
        if (rows == null) {
            return entries;
        }
        for (SObject row : rows) {
            entries.add(AuditrUtil.buildEntryFromAuditTrail((SetupAuditTrail) row));
        }
        return entries;
    }
}
