/**
 * @description Unit test suite for AuditrChangeLogBatch asynchronous packaging (selection- and filter-driven).
 */
@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs,PMD.MethodNamingConventions')
private class AuditrChangeLogBatchTest {
    @TestSetup
    private static void setupTestData() {
        AuditrTestDataFactory.insertEntries(6);
    }

    @IsTest
    private static void shouldPackageSelectedEntries_WhenExplicitIdsGiven() {
        Auditr_Change_Log__c changeLog = AuditrTestDataFactory.insertChangeLog();
        List<Auditr_Entry__c> entries = [SELECT Id FROM Auditr_Entry__c WITH SYSTEM_MODE ORDER BY Name ASC LIMIT 3];

        Test.startTest();
        Id jobId = Database.executeBatch(new AuditrChangeLogBatch(changeLog.Id, new Map<Id, Auditr_Entry__c>(entries).keySet()), 200);
        Test.stopTest();

        Assert.isNotNull(jobId, 'executeBatch should return a job Id');
        Assert.areEqual(
            3,
            [SELECT COUNT() FROM Auditr_Change_Log_Item__c WHERE Change_Log__c = :changeLog.Id WITH SYSTEM_MODE],
            'All 3 selected entries should be packaged'
        );
        Assert.areEqual(
            3.0,
            [SELECT Total_Entries__c FROM Auditr_Change_Log__c WHERE Id = :changeLog.Id WITH SYSTEM_MODE].Total_Entries__c,
            'Roll-up should reflect 3 packaged entries'
        );
    }

    @IsTest
    private static void shouldSkipDuplicates_WhenBatchRerunsOnSameEntries() {
        Auditr_Change_Log__c changeLog = AuditrTestDataFactory.insertChangeLog();
        List<Auditr_Entry__c> entries = [SELECT Id FROM Auditr_Entry__c WITH SYSTEM_MODE ORDER BY Name ASC LIMIT 2];
        Set<Id> entryIds = new Map<Id, Auditr_Entry__c>(entries).keySet();

        Test.startTest();
        Database.executeBatch(new AuditrChangeLogBatch(changeLog.Id, entryIds), 200);
        Database.executeBatch(new AuditrChangeLogBatch(changeLog.Id, entryIds), 200);
        Test.stopTest();

        Assert.areEqual(
            2,
            [SELECT COUNT() FROM Auditr_Change_Log_Item__c WHERE Change_Log__c = :changeLog.Id WITH SYSTEM_MODE],
            'Rerunning the batch on the same entries should keep exactly 2 citations'
        );
    }

    @IsTest
    private static void shouldPackageByStoredFilter_WhenIdsNotGiven() {
        Auditr_Change_Log__c changeLog = AuditrTestDataFactory.insertChangeLog();
        changeLog.Window_Start__c = System.now().addHours(-1);
        changeLog.Window_End__c = System.now().addHours(1);
        changeLog.Target_Actor__c = 'acted.as.1@example.com';
        Database.update(changeLog, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        Database.executeBatch(new AuditrChangeLogBatch(changeLog.Id), 200);
        Test.stopTest();

        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Auditr_Change_Log_Item__c WHERE Change_Log__c = :changeLog.Id WITH SYSTEM_MODE],
            'Only the entry matching the stored actor filter should be packaged'
        );
    }

    @IsTest
    private static void shouldExcludeEntriesCitedElsewhere_WhenPackagingByFilter() {
        Auditr_Change_Log__c otherLog = AuditrTestDataFactory.insertChangeLog();
        Auditr_Entry__c cited = [SELECT Id FROM Auditr_Entry__c WITH SYSTEM_MODE ORDER BY Name ASC LIMIT 1];
        AuditrTestDataFactory.insertChangeLogItems(otherLog.Id, new List<Auditr_Entry__c>{ cited });

        Auditr_Change_Log__c changeLog = AuditrTestDataFactory.insertChangeLog();
        changeLog.Window_Start__c = System.now().addHours(-1);
        changeLog.Window_End__c = System.now().addHours(1);
        Database.update(changeLog, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        Database.executeBatch(new AuditrChangeLogBatch(changeLog.Id), 200);
        Test.stopTest();

        Assert.areEqual(
            5,
            [SELECT COUNT() FROM Auditr_Change_Log_Item__c WHERE Change_Log__c = :changeLog.Id WITH SYSTEM_MODE],
            'Filter packaging should cite only unassigned entries, skipping the one already cited by another log'
        );
    }

    @IsTest
    private static void shouldSkipChunk_WhenTargetChangeLogIsSealed() {
        Auditr_Change_Log__c changeLog = AuditrTestDataFactory.insertChangeLog();
        List<Auditr_Entry__c> entries = [SELECT Id FROM Auditr_Entry__c WITH SYSTEM_MODE ORDER BY Name ASC LIMIT 2];
        AuditrTestDataFactory.insertChangeLogItems(changeLog.Id, new List<Auditr_Entry__c>{ entries[0] });

        changeLog.Status__c = 'Sealed';
        Database.update(changeLog, AccessLevel.SYSTEM_MODE);

        AuditrChangeLogBatch batch = new AuditrChangeLogBatch(changeLog.Id, new Set<Id>{ entries[1].Id });

        Test.startTest();
        batch.execute(null, new List<Auditr_Entry__c>{ entries[1] });
        batch.finish(null);
        Test.stopTest();

        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Auditr_Change_Log_Item__c WHERE Change_Log__c = :changeLog.Id WITH SYSTEM_MODE],
            'Sealed change log should reject in-flight execution chunk'
        );
    }
}
