/**
 * @description Unit test suite for AuditrChangeLogItemTriggerHandler compound key stamping and sealed-log protection.
 */
@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs,PMD.MethodNamingConventions')
private class AuditrChangeLogItemTriggerHandlerTest {
    @TestSetup
    private static void setupTestData() {
        AuditrTestDataFactory.insertEntries(3);
        AuditrTestDataFactory.insertChangeLog();
    }

    @IsTest
    private static void shouldStampCompoundKey_WhenItemInserted() {
        Auditr_Change_Log__c changeLog = [SELECT Id FROM Auditr_Change_Log__c WITH SYSTEM_MODE LIMIT 1];
        Auditr_Entry__c entry = [SELECT Id FROM Auditr_Entry__c WITH SYSTEM_MODE ORDER BY Name ASC LIMIT 1];

        Test.startTest();
        Auditr_Change_Log_Item__c item = new Auditr_Change_Log_Item__c(Change_Log__c = changeLog.Id, Entry__c = entry.Id);
        Database.insert(item, AccessLevel.SYSTEM_MODE);
        Test.stopTest();

        Auditr_Change_Log_Item__c inserted = [SELECT Compound_Key__c FROM Auditr_Change_Log_Item__c WHERE Id = :item.Id WITH SYSTEM_MODE];
        Assert.areEqual(
            String.valueOf(changeLog.Id) + '-' + String.valueOf(entry.Id),
            inserted.Compound_Key__c,
            'Compound key should be stamped as ChangeLogId-EntryId'
        );
    }

    @IsTest
    private static void shouldBlockDuplicateCitation_WhenSameLogAndEntry() {
        Auditr_Change_Log__c changeLog = [SELECT Id FROM Auditr_Change_Log__c WITH SYSTEM_MODE LIMIT 1];
        Auditr_Entry__c entry = [SELECT Id FROM Auditr_Entry__c WITH SYSTEM_MODE ORDER BY Name ASC LIMIT 1];

        Test.startTest();
        Database.insert(new Auditr_Change_Log_Item__c(Change_Log__c = changeLog.Id, Entry__c = entry.Id), AccessLevel.SYSTEM_MODE);
        DmlException duplicateError;
        try {
            Database.insert(new Auditr_Change_Log_Item__c(Change_Log__c = changeLog.Id, Entry__c = entry.Id), AccessLevel.SYSTEM_MODE);
        } catch (DmlException caught) {
            duplicateError = caught;
        }
        Test.stopTest();

        Assert.isNotNull(duplicateError, 'Duplicate citation within the same change log should raise a DmlException');
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Auditr_Change_Log_Item__c WHERE Change_Log__c = :changeLog.Id WITH SYSTEM_MODE],
            'Only one citation should exist for the same change log and entry'
        );
    }

    @IsTest
    private static void shouldAllowSameEntry_WhenCitedByDifferentLogs() {
        Auditr_Change_Log__c firstLog = [SELECT Id FROM Auditr_Change_Log__c WITH SYSTEM_MODE LIMIT 1];
        Auditr_Entry__c entry = [SELECT Id FROM Auditr_Entry__c WITH SYSTEM_MODE ORDER BY Name ASC LIMIT 1];
        Auditr_Change_Log__c secondLog = new Auditr_Change_Log__c(Change_Request_Id__c = 'PROJ-0002', Status__c = 'Draft');
        Database.insert(secondLog, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        Database.insert(new Auditr_Change_Log_Item__c(Change_Log__c = firstLog.Id, Entry__c = entry.Id), AccessLevel.SYSTEM_MODE);
        Database.insert(new Auditr_Change_Log_Item__c(Change_Log__c = secondLog.Id, Entry__c = entry.Id), AccessLevel.SYSTEM_MODE);
        Test.stopTest();

        Assert.areEqual(
            2,
            [SELECT COUNT() FROM Auditr_Change_Log_Item__c WHERE Entry__c = :entry.Id WITH SYSTEM_MODE],
            'Multi-audit citation should allow the same entry in two distinct change logs'
        );
    }

    @IsTest
    private static void shouldBlockAddAndRemove_WhenParentSealed() {
        Auditr_Change_Log__c changeLog = [SELECT Id FROM Auditr_Change_Log__c WITH SYSTEM_MODE LIMIT 1];
        List<Auditr_Entry__c> entries = [SELECT Id FROM Auditr_Entry__c WITH SYSTEM_MODE ORDER BY Name ASC LIMIT 3];
        List<Auditr_Change_Log_Item__c> items = AuditrTestDataFactory.insertChangeLogItems(changeLog.Id, new List<Auditr_Entry__c>{ entries[0] });
        Database.update(new Auditr_Change_Log__c(Id = changeLog.Id, Status__c = 'Sealed'), AccessLevel.SYSTEM_MODE);

        Test.startTest();
        DmlException addError;
        try {
            Database.insert(new Auditr_Change_Log_Item__c(Change_Log__c = changeLog.Id, Entry__c = entries[1].Id), AccessLevel.SYSTEM_MODE);
        } catch (DmlException caught) {
            addError = caught;
        }
        DmlException removeError;
        try {
            Database.delete(items[0].Id, AccessLevel.SYSTEM_MODE);
        } catch (DmlException caught) {
            removeError = caught;
        }
        Test.stopTest();

        Assert.isNotNull(addError, 'Adding an entry to a sealed change log should raise a DmlException');
        Assert.isTrue(
            addError.getMessage().contains(AuditrChangeLogItemTriggerHandler.SEALED_LOG_ERROR),
            'Add error should state the change log is sealed'
        );
        Assert.isNotNull(removeError, 'Removing an entry from a sealed change log should raise a DmlException');
        Assert.isTrue(
            removeError.getMessage().contains(AuditrChangeLogItemTriggerHandler.SEALED_LOG_ERROR),
            'Remove error should state the change log is sealed'
        );
    }
}
