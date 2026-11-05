/**
 * @description Unit test suite for AuditrSyncBatch, AuditrReclassifyBatch, and AuditrPurgeBatch.
 */
@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs,PMD.MethodNamingConventions')
private class AuditrBatchTest {
    @IsTest
    private static void shouldIngestAndDeduplicateSetupAuditTrail_WhenAuditrSyncBatchRuns() {
        List<SetupAuditTrail> sampleAuditRows = AuditrTestDataFactory.buildMockSetupAuditTrails(5);

        Test.startTest();
        Integer firstInsertCount = AuditrSyncBatch.processAuditRecords(sampleAuditRows);
        Integer duplicateInsertCount = AuditrSyncBatch.processAuditRecords(sampleAuditRows);
        DateTime watermarkCutoff = AuditrSyncBatch.resolveCutoffTimestamp();
        AuditrSyncBatch syncBatch = new AuditrSyncBatch();
        Database.QueryLocator locator = syncBatch.start(null);
        syncBatch.execute(null, sampleAuditRows);
        syncBatch.finish(null);
        Test.stopTest();

        Assert.areEqual(5, firstInsertCount, 'First sync pass should insert all 5 mock SetupAuditTrail records');
        Assert.areEqual(0, duplicateInsertCount, 'Second sync pass on identical records should skip all duplicates');
        Assert.isNotNull(watermarkCutoff, 'Watermark cutoff should be resolved from existing Auditr_Entry__c records');
        Assert.isNotNull(locator, 'QueryLocator should be returned by start()');
    }

    @IsTest
    private static void shouldHandlePartialDmlFailuresAndLogErrors_WhenIngestionEncountersInvalidRow() {
        List<SetupAuditTrail> mixedRows = new List<SetupAuditTrail>{
            AuditrTestDataFactory.buildMockSetupAuditTrail(801, 'suorgadminadd', 'Manage Users', 'Valid row 1'),
            AuditrTestDataFactory.buildMockSetupAuditTrail(802, 'a'.repeat(200), 'Manage Users', 'Invalid long action row')
        };

        Test.startTest();
        Integer insertedCount = AuditrSyncBatch.processAuditRecords(mixedRows);
        Test.stopTest();

        Assert.areEqual(1, insertedCount, 'Only the valid record should be counted as successfully inserted');
        String expectedSourceId = String.valueOf(mixedRows[0].Id);
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Auditr_Entry__c WHERE Source_Record_Id__c = :expectedSourceId WITH SYSTEM_MODE],
            'Valid record must exist in the database'
        );
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

    @IsTest
    private static void shouldExemptPackagedEntries_WhenAuditrPurgeBatchExecutes() {
        Auditr_Entry__c expiredUnassigned = AuditrTestDataFactory.buildEntry(700, null);
        expiredUnassigned.Occurred_At__c = System.now().addDays(-400);
        Auditr_Entry__c expiredPackaged = AuditrTestDataFactory.buildEntry(701, null);
        expiredPackaged.Occurred_At__c = System.now().addDays(-400);
        Database.insert(new List<Auditr_Entry__c>{ expiredUnassigned, expiredPackaged }, AccessLevel.SYSTEM_MODE);
        Auditr_Change_Log__c changeLog = AuditrTestDataFactory.insertChangeLog();
        AuditrTestDataFactory.insertChangeLogItems(changeLog.Id, new List<Auditr_Entry__c>{ expiredPackaged });

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

        Integer remainingUnassigned = [SELECT COUNT() FROM Auditr_Entry__c WHERE Id = :expiredUnassigned.Id WITH SYSTEM_MODE];
        Integer remainingPackaged = [SELECT COUNT() FROM Auditr_Entry__c WHERE Id = :expiredPackaged.Id WITH SYSTEM_MODE];
        Assert.areEqual(0, remainingUnassigned, 'Expired unassigned entry should be purged');
        Assert.areEqual(1, remainingPackaged, 'Entries cited by a change log must be exempt from retention purge');
    }

    @IsTest
    private static void shouldThrowSyncExceptionInFinish_WhenRowLevelErrorsRecorded() {
        AuditrSyncBatch syncBatch = new AuditrSyncBatch();
        syncBatch.totalFailedInserts = 3;
        syncBatch.firstInsertErrorMessage = 'Simulated DML failure';

        Test.startTest();
        AuditrSyncBatch.AuditrSyncException caughtEx;
        try {
            syncBatch.finish(null);
        } catch (AuditrSyncBatch.AuditrSyncException ex) {
            caughtEx = ex;
        }
        Test.stopTest();

        Assert.isNotNull(caughtEx, 'AuditrSyncException must be thrown when totalFailedInserts > 0');
        Assert.isTrue(caughtEx.getMessage().contains('Simulated DML failure'), 'Exception message should contain first error');
    }

    @IsTest
    private static void shouldThrowReclassifyExceptionInFinish_WhenUpdateErrorsRecorded() {
        AuditrReclassifyBatch reclassifyBatch = new AuditrReclassifyBatch();
        reclassifyBatch.totalFailed = 2;
        reclassifyBatch.firstErrorMessage = 'Simulated reclassify update failure';

        Test.startTest();
        AuditrReclassifyBatch.AuditrReclassifyException caughtEx;
        try {
            reclassifyBatch.finish(null);
        } catch (AuditrReclassifyBatch.AuditrReclassifyException ex) {
            caughtEx = ex;
        }
        Test.stopTest();

        Assert.isNotNull(caughtEx, 'AuditrReclassifyException must be thrown when totalFailed > 0');
        Assert.isTrue(caughtEx.getMessage().contains('Simulated reclassify update failure'), 'Exception message should contain first error');
    }
}