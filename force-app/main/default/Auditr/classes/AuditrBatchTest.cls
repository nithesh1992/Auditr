/**
 * @description Unit test suite for AuditrSyncBatch, AuditrReclassifyBatch, and AuditrPurgeBatch.
 */
@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs,PMD.MethodNamingConventions')
private class AuditrBatchTest {
    @IsTest
    private static void shouldIngestAndDeduplicateSetupAuditTrail_WhenAuditrSyncBatchRuns() {
        List<SetupAuditTrail> sampleAuditRows = [
            SELECT Id, Action, Section, CreatedDate, CreatedById, CreatedBy.Username,
                   Display, DelegateUser, ResponsibleNamespacePrefix, CreatedByContext
            FROM SetupAuditTrail
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 5
        ];

        Test.startTest();
        Integer firstInsertCount = AuditrSyncBatch.processAuditRecords(sampleAuditRows);
        Integer duplicateInsertCount = AuditrSyncBatch.processAuditRecords(sampleAuditRows);
        DateTime watermarkCutoff = AuditrSyncBatch.resolveCutoffTimestamp();
        AuditrSyncBatch syncBatch = new AuditrSyncBatch();
        Database.QueryLocator locator = syncBatch.start(null);
        syncBatch.execute(null, sampleAuditRows);
        syncBatch.finish(null);
        Test.stopTest();

        Assert.areEqual(sampleAuditRows.size(), firstInsertCount, 'First sync pass should insert all sampled SetupAuditTrail records');
        Assert.areEqual(0, duplicateInsertCount, 'Second sync pass on identical records should skip all duplicates');
        Assert.isNotNull(watermarkCutoff, 'Watermark cutoff should be resolved from existing Auditr_Entry__c records');
        Assert.isNotNull(locator, 'QueryLocator should be returned by start()');
    }

    @IsTest
    private static void shouldRespectIsActiveFlag_WhenScheduledSyncExecutes() {
        AuditrUtil.testSettingOverride = new Auditr_Setting__mdt(
            DeveloperName = 'InactiveSetting',
            Is_Active__c = false,
            Backfill_Days__c = 10,
            Batch_Size__c = 200
        );

        Test.startTest();
        DateTime initialBackfillCutoff = AuditrSyncBatch.resolveCutoffTimestamp();
        new AuditrSyncBatch().execute((SchedulableContext) null);
        AuditrUtil.testSettingOverride = null;
        Test.stopTest();

        Assert.isNotNull(initialBackfillCutoff, 'Initial backfill cutoff should resolve when no Auditr_Entry__c records exist');
        Assert.areEqual(0, [SELECT COUNT() FROM Auditr_Entry__c WITH SYSTEM_MODE], 'Inactive setting should skip batch execution when scheduled');
    }

    @IsTest
    private static void shouldReclassifyEntries_WhenAuditrReclassifyBatchExecutes() {
        Auditr_Entry__c unclassifiedEntry = AuditrTestDataFactory.buildEntry(500, null);
        unclassifiedEntry.Action_Code__c = 'suorgadminlogin';
        unclassifiedEntry.Category__c = 'Unclassified';
        unclassifiedEntry.Risk_Level__c = 'Low';
        Database.insert(unclassifiedEntry, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        Database.executeBatch(new AuditrReclassifyBatch(), 200);
        new AuditrReclassifyBatch(false).start(null);
        Test.stopTest();

        Auditr_Entry__c reclassified = [SELECT Category__c, Risk_Level__c FROM Auditr_Entry__c WHERE Id = :unclassifiedEntry.Id WITH SYSTEM_MODE];
        Assert.areEqual('Users & Sessions', reclassified.Category__c, 'suorgadminlogin should be reclassified to Users & Sessions');
        Assert.areEqual('Critical', reclassified.Risk_Level__c, 'suorgadminlogin should be reclassified to Critical risk');
    }

    @IsTest
    private static void shouldPurgeExpiredEntriesOnlyWhenEnabled_WhenAuditrPurgeBatchExecutes() {
        Auditr_Entry__c expiredEntry = AuditrTestDataFactory.buildEntry(600, null);
        expiredEntry.Occurred_At__c = System.now().addDays(-400);
        Database.insert(expiredEntry, AccessLevel.SYSTEM_MODE);

        AuditrUtil.testSettingOverride = new Auditr_Setting__mdt(
            DeveloperName = 'PurgeDisabled',
            Is_Active__c = true,
            Enable_Purge__c = false,
            Retention_Days__c = 0
        );
        new AuditrPurgeBatch().start(null);
        new AuditrPurgeBatch().execute((SchedulableContext) null);

        AuditrUtil.testSettingOverride = new Auditr_Setting__mdt(
            DeveloperName = 'PurgeEnabled',
            Is_Active__c = true,
            Enable_Purge__c = true,
            Retention_Days__c = 365,
            Batch_Size__c = 200
        );

        Test.startTest();
        new AuditrPurgeBatch().execute((SchedulableContext) null);
        Test.stopTest();
        AuditrUtil.testSettingOverride = null;

        Integer remainingCount = [SELECT COUNT() FROM Auditr_Entry__c WHERE Id = :expiredEntry.Id WITH SYSTEM_MODE];
        Assert.areEqual(0, remainingCount, 'Expired Auditr_Entry__c older than 365 days should be purged when Enable_Purge__c is true');
    }
}