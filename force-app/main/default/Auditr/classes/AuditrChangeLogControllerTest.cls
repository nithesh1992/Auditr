/**
 * @description Unit test suite for AuditrChangeLogController Audit Mode state, backlog queries, and packaging actions.
 */
@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs,PMD.MethodNamingConventions')
private class AuditrChangeLogControllerTest {
    @TestSetup
    private static void setupTestData() {
        AuditrTestDataFactory.assignAdminPermissionSet();
        List<Auditr_Entry__c> entries = AuditrTestDataFactory.insertEntries(4);
        Auditr_Change_Log__c changeLog = AuditrTestDataFactory.insertChangeLog();
        AuditrTestDataFactory.insertChangeLogItems(changeLog.Id, new List<Auditr_Entry__c>{ entries[0] });
    }

    @IsTest
    private static void shouldReturnStateAndBacklog_WhenQueried() {
        AuditrChangeLogController.AuditModeStateDTO state;
        List<AuditrChangeLogController.UnassignedEntryDTO> allRows;
        List<AuditrChangeLogController.UnassignedEntryDTO> actorRows;
        List<AuditrChangeLogController.UnassignedEntryDTO> packagedActorRows;

        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            state = AuditrChangeLogController.getAuditModeState(null, null, null);
            allRows = AuditrChangeLogController.getUnassignedEntries(null, null, null);
            actorRows = AuditrChangeLogController.getUnassignedEntries(null, null, 'delegate.admin.2@example.com');
            packagedActorRows = AuditrChangeLogController.getUnassignedEntries(null, null, 'delegate.admin.0@example.com');
            Test.stopTest();
        }

        Assert.areEqual(1, state.changeLogs.size(), 'State should include the seeded change log');
        Assert.areEqual(3, state.backlogCount, 'Backlog count should exclude the 1 packaged entry');
        Assert.areEqual(3, allRows.size(), 'Unassigned listing should exclude the packaged entry');
        Assert.areEqual(1, actorRows.size(), 'Actor filter should return the 1 unassigned entry for that delegate');
        Assert.areEqual(0, packagedActorRows.size(), 'Entries already packaged must never appear in the backlog');
        Assert.areEqual('PROJ-0001', state.changeLogs[0].changeRequestId, 'Change log row should expose the Change Request Id');
        Assert.isFalse(state.changeLogs[0].isPackagingInFlight, 'No packaging job should be in flight');
    }

    @IsTest
    private static void shouldCreateChangeLog_WhenValidRequest() {
        Id changeLogId;

        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            changeLogId = AuditrChangeLogController.createChangeLog('PROJ-9876', System.now().addDays(3), 'Q4 release bundle');
            Test.stopTest();
        }

        Auditr_Change_Log__c inserted = [
            SELECT Status__c, Change_Request_Id__c, Description__c
            FROM Auditr_Change_Log__c WHERE Id = :changeLogId WITH SYSTEM_MODE
        ];
        Assert.areEqual('Draft', inserted.Status__c, 'New change log should start in Draft');
        Assert.areEqual('PROJ-9876', inserted.Change_Request_Id__c, 'Change Request Id should be stored trimmed');
        Assert.areEqual('Q4 release bundle', inserted.Description__c, 'Description should be stored');
    }

    @IsTest
    private static void shouldRejectInvalidChangeRequest_WhenCreating() {
        AuraHandledException blankError;
        AuraHandledException formatError;

        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            try {
                AuditrChangeLogController.createChangeLog('  ', null, null);
            } catch (AuraHandledException caught) {
                blankError = caught;
            }
            try {
                AuditrChangeLogController.createChangeLog('not a ticket!', null, null);
            } catch (AuraHandledException caught) {
                formatError = caught;
            }
            Test.stopTest();
        }

        Assert.isNotNull(blankError, 'Blank Change Request Id should raise AuraHandledException');
        Assert.isNotNull(formatError, 'Invalid Change Request Id format should raise AuraHandledException');
        Assert.isTrue(
            formatError.getMessage().contains('Change Request Id'),
            'Format error should reference the Change Request Id requirement'
        );
    }

    @IsTest
    private static void shouldQueueSelectionPackaging_WhenEntriesSelected() {
        Auditr_Change_Log__c changeLog = [SELECT Id FROM Auditr_Change_Log__c WITH SYSTEM_MODE LIMIT 1];
        List<Auditr_Entry__c> entries = [SELECT Id FROM Auditr_Entry__c WITH SYSTEM_MODE ORDER BY Name ASC LIMIT 4];
        Id jobId;

        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            jobId = AuditrChangeLogController.packageEntries(changeLog.Id, new List<Id>{ entries[1].Id, entries[2].Id });
            Test.stopTest();
        }

        Assert.isNotNull(jobId, 'packageEntries should return a batch job Id');
        Assert.areEqual(
            3,
            [SELECT COUNT() FROM Auditr_Change_Log_Item__c WHERE Change_Log__c = :changeLog.Id WITH SYSTEM_MODE],
            'Selected entries plus the seeded citation should yield 3 packaged items'
        );
        Assert.isNull(
            [SELECT Packaging_Job_Id__c FROM Auditr_Change_Log__c WHERE Id = :changeLog.Id WITH SYSTEM_MODE].Packaging_Job_Id__c,
            'Packaging_Job_Id__c should be cleared when the batch finishes'
        );
    }

    @IsTest
    private static void shouldQueueFilteredPackaging_WhenWindowGiven() {
        Auditr_Change_Log__c changeLog = [SELECT Id FROM Auditr_Change_Log__c WITH SYSTEM_MODE LIMIT 1];
        Id jobId;

        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            jobId = AuditrChangeLogController.packageFilteredEntries(changeLog.Id, null, null, null);
            Test.stopTest();
        }

        Assert.isNotNull(jobId, 'packageFilteredEntries should return a batch job Id');
        Assert.areEqual(
            4,
            [SELECT COUNT() FROM Auditr_Change_Log_Item__c WHERE Change_Log__c = :changeLog.Id WITH SYSTEM_MODE],
            'Filter packaging should cite every remaining unassigned entry exactly once'
        );
        Auditr_Change_Log__c refreshed = [SELECT Target_Actor__c, Window_Start__c, Window_End__c FROM Auditr_Change_Log__c WHERE Id = :changeLog.Id WITH SYSTEM_MODE];
        Assert.isNull(refreshed.Target_Actor__c, 'Filter packaging with no actor should clear the stored actor filter');
        Assert.isNotNull(refreshed.Window_Start__c, 'Filter packaging should store the resolved window start on the change log');
        Assert.isNotNull(refreshed.Window_End__c, 'Filter packaging should store the resolved window end on the change log');
    }

    @IsTest
    private static void shouldRejectPackaging_WhenTargetIsSealedOrMissing() {
        Auditr_Change_Log__c changeLog = [SELECT Id, Status__c FROM Auditr_Change_Log__c WITH SYSTEM_MODE LIMIT 1];
        changeLog.Status__c = 'Sealed';
        Database.update(changeLog, AccessLevel.SYSTEM_MODE);
        List<Auditr_Entry__c> entries = [SELECT Id FROM Auditr_Entry__c WITH SYSTEM_MODE ORDER BY Name ASC LIMIT 1];

        AuraHandledException sealedError;
        AuraHandledException missingError;
        AuraHandledException emptySelectionError;

        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            try {
                AuditrChangeLogController.packageEntries(changeLog.Id, new List<Id>{ entries[0].Id });
            } catch (AuraHandledException caught) {
                sealedError = caught;
            }
            try {
                AuditrChangeLogController.packageEntries(null, new List<Id>{ entries[0].Id });
            } catch (AuraHandledException caught) {
                missingError = caught;
            }
            try {
                AuditrChangeLogController.packageEntries(changeLog.Id, new List<Id>());
            } catch (AuraHandledException caught) {
                emptySelectionError = caught;
            }
            Test.stopTest();
        }

        Assert.isNotNull(sealedError, 'Packaging into a sealed change log should raise AuraHandledException');
        Assert.isNotNull(missingError, 'Packaging without a change log should raise AuraHandledException');
        Assert.isNotNull(emptySelectionError, 'Packaging without selected entries should raise AuraHandledException');
    }
}
