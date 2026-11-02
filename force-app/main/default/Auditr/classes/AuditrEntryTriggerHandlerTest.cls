/**
 * @description Unit and 251-record bulk test suite for AuditrEntryTrigger and AuditrEntryTriggerHandler.
 */
@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs,PMD.MethodNamingConventions')
private class AuditrEntryTriggerHandlerTest {
    @TestSetup
    private static void setupTestData() {
        AuditrTestDataFactory.insertEntries(251);
    }

    @IsTest
    private static void shouldStampResponsibleUsername_WhenBulk251Inserted() {
        List<Auditr_Entry__c> insertedEntries = [
            SELECT Id, Source_Record_Id__c, Actor_Username__c, Delegate_User__c, Responsible_Username__c
            FROM Auditr_Entry__c
            WITH SYSTEM_MODE
            ORDER BY Source_Record_Id__c ASC
        ];

        Assert.areEqual(251, insertedEntries.size(), 'All 251 bulk Auditr Entry records should be inserted');
        Assert.areEqual('delegate.admin.0@example.com', insertedEntries[0].Responsible_Username__c, 'Even index with Delegate_User__c should stamp Delegate_User__c');
        Assert.areEqual('acted.as.1@example.com', insertedEntries[1].Responsible_Username__c, 'Odd index without Delegate_User__c should fall back to Actor_Username__c');
    }

    @IsTest
    private static void shouldAllowReclassificationUpdate_WhenOnlyCategoryAndRiskLevelChange() {
        Auditr_Entry__c existingEntry = [SELECT Id, Category__c, Risk_Level__c FROM Auditr_Entry__c WITH SYSTEM_MODE LIMIT 1];
        existingEntry.Category__c = 'Users & Sessions';
        existingEntry.Risk_Level__c = 'Critical';

        Test.startTest();
        Database.update(existingEntry, AccessLevel.SYSTEM_MODE);
        Test.stopTest();

        Auditr_Entry__c updatedEntry = [SELECT Category__c, Risk_Level__c FROM Auditr_Entry__c WHERE Id = :existingEntry.Id WITH SYSTEM_MODE];
        Assert.areEqual('Users & Sessions', updatedEntry.Category__c, 'Category__c update should be permitted for reclassification');
        Assert.areEqual('Critical', updatedEntry.Risk_Level__c, 'Risk_Level__c update should be permitted for reclassification');
    }

    @IsTest
    private static void shouldBlockUpdate_WhenImmutableSourceFieldModified() {
        Auditr_Entry__c existingEntry = [SELECT Id, Display__c FROM Auditr_Entry__c WITH SYSTEM_MODE LIMIT 1];
        existingEntry.Display__c = 'Tampered display text';

        Test.startTest();
        try {
            Database.update(existingEntry, AccessLevel.SYSTEM_MODE);
            Assert.fail('Expected DmlException when modifying immutable Display__c field');
        } catch (DmlException expectedException) {
            Assert.isTrue(expectedException.getMessage().contains(AuditrEntryTriggerHandler.IMMUTABLE_SOURCE_ERROR), 'DML error should include IMMUTABLE_SOURCE_ERROR');
        }
        Test.stopTest();
    }

    private class UnauthorizedDeleteCaller {
        public void attemptDirectDelete(Auditr_Entry__c targetEntry) {
            Database.delete(targetEntry, AccessLevel.SYSTEM_MODE);
        }

        public void attemptHelperDelete(Auditr_Entry__c targetEntry) {
            AuditrEntryTriggerHandler.deleteFromPurgeBatch(new List<SObject>{ targetEntry });
        }
    }

    @IsTest
    private static void shouldBlockDelete_WhenCalledFromAnotherClass() {
        Auditr_Entry__c existingEntry = [SELECT Id FROM Auditr_Entry__c WITH SYSTEM_MODE LIMIT 1];
        UnauthorizedDeleteCaller caller = new UnauthorizedDeleteCaller();

        Test.startTest();
        try {
            caller.attemptDirectDelete(existingEntry);
            Assert.fail('Expected DmlException when deleting Auditr_Entry__c from a class other than AuditrPurgeBatch');
        } catch (DmlException expectedException) {
            Assert.isTrue(expectedException.getMessage().contains(AuditrEntryTriggerHandler.DELETE_BLOCKED_ERROR), 'DML error should include DELETE_BLOCKED_ERROR');
        }
        caller.attemptHelperDelete(existingEntry);
        Test.stopTest();

        Integer remainingCount = [SELECT COUNT() FROM Auditr_Entry__c WHERE Id = :existingEntry.Id WITH SYSTEM_MODE];
        Assert.areEqual(1, remainingCount, 'Record should remain when deleteFromPurgeBatch is called outside AuditrPurgeBatch.execute');
    }

    @IsTest
    private static void shouldAllowDelete_WhenCalledFromAuditrPurgeBatchExecute() {
        Auditr_Entry__c existingEntry = [SELECT Id FROM Auditr_Entry__c WITH SYSTEM_MODE LIMIT 1];

        Test.startTest();
        new AuditrPurgeBatch().execute(null, new List<SObject>{ existingEntry });
        Test.stopTest();

        Integer remainingCount = [SELECT COUNT() FROM Auditr_Entry__c WHERE Id = :existingEntry.Id WITH SYSTEM_MODE];
        Assert.areEqual(0, remainingCount, 'Record should be deleted when invoked via AuditrPurgeBatch.execute');
    }
}