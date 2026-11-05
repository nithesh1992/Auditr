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

    @IsTest
    private static void shouldResolveUser_WhenIdOrUsernameGiven() {
        User currentUser = [SELECT Id, Name, Username FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        AuditrChangeLogController.UserLookupDTO byId;
        AuditrChangeLogController.UserLookupDTO byUsername;
        AuditrChangeLogController.UserLookupDTO notFound;

        System.runAs(currentUser) {
            Test.startTest();
            byId = AuditrChangeLogController.resolveUser(currentUser.Id, null);
            byUsername = AuditrChangeLogController.resolveUser(null, currentUser.Username);
            notFound = AuditrChangeLogController.resolveUser(null, 'nonexistent.user.12345@example.com');
            Test.stopTest();
        }

        Assert.isNotNull(byId, 'Should resolve user by Id');
        Assert.areEqual(currentUser.Username, byId.username, 'Resolved username should match');
        Assert.isNotNull(byUsername, 'Should resolve user by username');
        Assert.areEqual(currentUser.Id, byUsername.userId, 'Resolved userId should match');
        Assert.isNull(notFound, 'Nonexistent user should return null');
    }

    @IsTest
    private static void shouldReturnAuditEntries_WithPackagedStateAndRiskFilters() {
        User currentUser = [SELECT Id, Username FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        AuditrChangeLogController.AuditEntriesEnvelopeDTO allEnvelope;
        AuditrChangeLogController.AuditEntriesEnvelopeDTO highRiskEnvelope;
        AuditrChangeLogController.AuditEntriesEnvelopeDTO actorEnvelope;
        AuditrChangeLogController.AuditEntriesEnvelopeDTO actorHighRiskEnvelope;

        System.runAs(currentUser) {
            Test.startTest();
            allEnvelope = AuditrChangeLogController.getAuditEntries(System.now().addDays(-7), System.now().addDays(1), null, false);
            highRiskEnvelope = AuditrChangeLogController.getAuditEntries(System.now().addDays(-7), System.now().addDays(1), null, true);
            actorEnvelope = AuditrChangeLogController.getAuditEntries(System.now().addDays(-7), System.now().addDays(1), 'delegate.admin.0@example.com', false);
            actorHighRiskEnvelope = AuditrChangeLogController.getAuditEntries(System.now().addDays(-7), System.now().addDays(1), 'delegate.admin.0@example.com', true);
            AuditrChangeLogController.UserLookupDTO blankUser = AuditrChangeLogController.resolveUser(null, '   ');
            Assert.isFalse(actorHighRiskEnvelope.entries.isEmpty(), 'Actor with high risk filter should return records');
            Assert.isNull(blankUser, 'Blank user lookup should return null');
            Test.stopTest();
        }

        Assert.isFalse(allEnvelope.entries.isEmpty(), 'Should return audit entries');
        Assert.isTrue(allEnvelope.totalMatchingCount >= allEnvelope.entries.size(), 'Total count must equal or exceed slice size');
        Assert.isFalse(allEnvelope.isCapped, 'Test envelope must not be capped');
        Assert.areEqual(200, allEnvelope.queryLimit, 'Query limit must be 200');

        Boolean foundPackaged = false;
        Boolean foundUnassigned = false;
        for (AuditrChangeLogController.AuditEntryDTO row : allEnvelope.entries) {
            if (row.isPackaged) {
                foundPackaged = true;
                Assert.isNotNull(row.changeRequestId, 'Packaged entry must carry change request id');
            } else {
                foundUnassigned = true;
            }
        }
        Assert.isTrue(foundPackaged, 'Should detect packaged entry');
        Assert.isTrue(foundUnassigned, 'Should detect unassigned entry');
        Assert.isFalse(highRiskEnvelope.entries.isEmpty(), 'Should return high risk entries');
        for (AuditrChangeLogController.AuditEntryDTO row : highRiskEnvelope.entries) {
            Assert.isTrue(row.riskLevel == 'Critical' || row.riskLevel == 'High', 'High risk filter must only include Critical or High');
        }
        Assert.isFalse(actorEnvelope.entries.isEmpty(), 'Should filter by actor username');
    }

    @IsTest
    private static void shouldRejectAdminOperations_WhenUserLacksAdminPermission() {
        User currentUser = [SELECT Id, Username FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        Auditr_Change_Log__c draftLog = [SELECT Id FROM Auditr_Change_Log__c WHERE Status__c = 'Draft' LIMIT 1];
        Auditr_Entry__c testEntry = [SELECT Id FROM Auditr_Entry__c LIMIT 1];

        System.runAs(currentUser) {
            AuditrChangeLogController.testAdminAccessOverride = false;
            Test.startTest();

            try {
                AuditrChangeLogController.createChangeLog('CR-TEST-FAIL-01', System.now(), 'Unauthorized test');
                Assert.fail('createChangeLog should have thrown AuraHandledException when admin permission is absent');
            } catch (AuraHandledException auraEx) {
                Assert.isNotNull(auraEx.getMessage(), 'Exception message should not be null');
            }

            try {
                AuditrChangeLogController.packageEntries(draftLog.Id, new List<Id>{ testEntry.Id });
                Assert.fail('packageEntries should have thrown AuraHandledException when admin permission is absent');
            } catch (AuraHandledException auraEx) {
                Assert.isNotNull(auraEx.getMessage(), 'Exception message should not be null');
            }

            try {
                AuditrChangeLogController.packageFilteredEntries(draftLog.Id, System.now().addDays(-7), System.now(), null);
                Assert.fail('packageFilteredEntries should have thrown AuraHandledException when admin permission is absent');
            } catch (AuraHandledException auraEx) {
                Assert.isNotNull(auraEx.getMessage(), 'Exception message should not be null');
            }

            Test.stopTest();
            AuditrChangeLogController.testAdminAccessOverride = null;
        }
    }

    @IsTest
    private static void shouldSearchDraftChangeLogs_WhenSearchTermProvided() {
        User currentUser = [SELECT Id, Username FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        List<AuditrChangeLogController.ChangeLogDTO> allDrafts;
        List<AuditrChangeLogController.ChangeLogDTO> matchedDrafts;
        List<AuditrChangeLogController.ChangeLogDTO> unmatchedDrafts;

        System.runAs(currentUser) {
            Test.startTest();
            allDrafts = AuditrChangeLogController.searchDraftChangeLogs(null);
            matchedDrafts = AuditrChangeLogController.searchDraftChangeLogs('PROJ-');
            unmatchedDrafts = AuditrChangeLogController.searchDraftChangeLogs('NONEXISTENT-XYZ-999');
            Test.stopTest();
        }

        Assert.isFalse(allDrafts.isEmpty(), 'Search with null should return recent draft change logs');
        Assert.isFalse(matchedDrafts.isEmpty(), 'Search with matching prefix should return matched draft change logs');
        Assert.isTrue(unmatchedDrafts.isEmpty(), 'Search with nonexistent term should return empty list');
    }

    @IsTest
    private static void shouldComputeAggregateCounts_WhenSliceMatchesQueryLimit() {
        User currentUser = [SELECT Id, Username FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        AuditrChangeLogController.AuditEntriesEnvelopeDTO allEnvelope;
        AuditrChangeLogController.AuditEntriesEnvelopeDTO actorEnvelope;
        AuditrChangeLogController.AuditEntriesEnvelopeDTO highRiskEnvelope;
        AuditrChangeLogController.AuditEntriesEnvelopeDTO actorHighRiskEnvelope;

        System.runAs(currentUser) {
            AuditrChangeLogController.entryQueryLimit = 2;
            Test.startTest();
            allEnvelope = AuditrChangeLogController.getAuditEntries(System.now().addDays(-7), System.now().addDays(1), null, false);
            actorEnvelope = AuditrChangeLogController.getAuditEntries(System.now().addDays(-7), System.now().addDays(1), 'delegate.admin.0@example.com', false);
            highRiskEnvelope = AuditrChangeLogController.getAuditEntries(System.now().addDays(-7), System.now().addDays(1), null, true);
            actorHighRiskEnvelope = AuditrChangeLogController.getAuditEntries(System.now().addDays(-7), System.now().addDays(1), 'delegate.admin.0@example.com', true);
            Test.stopTest();
            AuditrChangeLogController.entryQueryLimit = 200;
        }

        Assert.areEqual(2, allEnvelope.entries.size(), 'Slice size should match lowered query limit');
        Assert.isTrue(allEnvelope.totalMatchingCount >= 2, 'Total matching count must be computed via COUNT query');
        Assert.isNotNull(actorEnvelope.totalMatchingCount, 'Actor matching count must be computed');
        Assert.isNotNull(highRiskEnvelope.totalMatchingCount, 'High risk matching count must be computed');
        Assert.isNotNull(actorHighRiskEnvelope.totalMatchingCount, 'Actor high risk matching count must be computed');
    }
}
