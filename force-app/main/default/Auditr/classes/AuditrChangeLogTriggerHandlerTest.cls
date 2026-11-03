/**
 * @description Unit test suite for AuditrChangeLogTriggerHandler compliance lifecycle enforcement.
 */
@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs,PMD.MethodNamingConventions')
private class AuditrChangeLogTriggerHandlerTest {
    @TestSetup
    private static void setupTestData() {
        AuditrTestDataFactory.insertEntries(2);
    }

    @IsTest
    private static void shouldDefaultToDraft_WhenStatusOmitted() {
        Auditr_Change_Log__c changeLog = new Auditr_Change_Log__c(Change_Request_Id__c = 'PROJ-1000');

        Test.startTest();
        Database.insert(changeLog, AccessLevel.SYSTEM_MODE);
        Test.stopTest();

        Auditr_Change_Log__c inserted = [SELECT Status__c FROM Auditr_Change_Log__c WHERE Id = :changeLog.Id WITH SYSTEM_MODE];
        Assert.areEqual('Draft', inserted.Status__c, 'Status should default to Draft when omitted');
    }

    @IsTest
    private static void shouldBlockSeal_WhenNoPackagedEntries() {
        Auditr_Change_Log__c changeLog = AuditrTestDataFactory.insertChangeLog();
        changeLog.Status__c = 'Sealed';

        Test.startTest();
        DmlException sealError;
        try {
            Database.update(changeLog, AccessLevel.SYSTEM_MODE);
        } catch (DmlException caught) {
            sealError = caught;
        }
        Test.stopTest();

        Assert.isNotNull(sealError, 'Sealing an empty change log should raise a DmlException');
        Assert.isTrue(
            sealError.getMessage().contains(AuditrChangeLogTriggerHandler.SEAL_REQUIRES_ENTRIES_ERROR),
            'Error should require at least one packaged entry before sealing'
        );
    }

    @IsTest
    private static void shouldStampSignOffAndEnforceImmutability_WhenSealed() {
        Auditr_Change_Log__c changeLog = AuditrTestDataFactory.insertChangeLog();
        List<Auditr_Entry__c> entries = [SELECT Id FROM Auditr_Entry__c WITH SYSTEM_MODE ORDER BY Name ASC LIMIT 2];
        AuditrTestDataFactory.insertChangeLogItems(changeLog.Id, entries);

        changeLog = [SELECT Id, Status__c, Total_Entries__c FROM Auditr_Change_Log__c WHERE Id = :changeLog.Id WITH SYSTEM_MODE];
        Assert.areEqual(2, Integer.valueOf(changeLog.Total_Entries__c), 'Roll-up should reflect 2 packaged entries');

        changeLog.Status__c = 'Sealed';

        Test.startTest();
        Database.update(changeLog, AccessLevel.SYSTEM_MODE);

        DmlException updateError;
        try {
            Database.update(new Auditr_Change_Log__c(Id = changeLog.Id, Description__c = 'Tampered'), AccessLevel.SYSTEM_MODE);
        } catch (DmlException caught) {
            updateError = caught;
        }
        DmlException deleteError;
        try {
            Database.delete(changeLog.Id, AccessLevel.SYSTEM_MODE);
        } catch (DmlException caught) {
            deleteError = caught;
        }
        Test.stopTest();

        Auditr_Change_Log__c sealed = [SELECT Status__c, Signed_Off_By__c, Signed_Off_At__c FROM Auditr_Change_Log__c WHERE Id = :changeLog.Id WITH SYSTEM_MODE];
        Assert.areEqual('Sealed', sealed.Status__c, 'Status should transition to Sealed');
        Assert.areEqual(UserInfo.getUserId(), sealed.Signed_Off_By__c, 'Sealing should stamp the current user');
        Assert.isNotNull(sealed.Signed_Off_At__c, 'Sealing should stamp the sign-off timestamp');
        Assert.isNotNull(updateError, 'Updating a sealed change log should raise a DmlException');
        Assert.isTrue(
            updateError.getMessage().contains(AuditrChangeLogTriggerHandler.SEALED_IMMUTABLE_ERROR),
            'Update error should state sealed change logs are immutable'
        );
        Assert.isNotNull(deleteError, 'Deleting a sealed change log should raise a DmlException');
        Assert.isTrue(
            deleteError.getMessage().contains(AuditrChangeLogTriggerHandler.SEALED_DELETE_ERROR),
            'Delete error should state sealed change logs cannot be deleted'
        );
    }
}
