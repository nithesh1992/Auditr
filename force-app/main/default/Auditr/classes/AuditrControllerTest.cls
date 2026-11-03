/**
 * @description Unit test suite for AuditrController At-a-Glance KPIs, Control Center status, and admin actions.
 */
@IsTest
@SuppressWarnings('PMD.MethodNamingConventions')
private class AuditrControllerTest {
    @TestSetup
    private static void setupTestData() {
        AuditrTestDataFactory.assignAdminPermissionSet();
        List<Auditr_Entry__c> entries = AuditrTestDataFactory.buildEntries(4);
        entries[0].Category__c = 'Unclassified';
        entries[0].Risk_Level__c = 'Low';
        entries[0].Action_Code__c = 'customunknownaction';
        Database.insert(entries, AccessLevel.SYSTEM_MODE);
    }

    @IsTest
    private static void shouldReturnAtAGlanceMetricsAndControlCenterStatus_WhenQueried() {
        AuditrController.AtAGlanceDTO sevenDayMetrics;
        AuditrController.AtAGlanceDTO allTimeMetrics;
        AuditrController.ControlCenterStatusDTO status;
        List<AuditrController.IncidentEntryDTO> incidentEvents;

        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            sevenDayMetrics = AuditrController.getAtAGlanceMetrics(7);
            allTimeMetrics = AuditrController.getAtAGlanceMetrics(365);
            status = AuditrController.getControlCenterStatus();
            incidentEvents = AuditrController.getIncidentTimeline(System.now(), 60, true);
            Test.stopTest();
        }

        Assert.areEqual(4, sevenDayMetrics.totalEntries, '7-day window should include all 4 seeded entries');
        Assert.areEqual(3, sevenDayMetrics.criticalAndHighCount, '3 entries should be Critical or High risk');
        Assert.areEqual(3, sevenDayMetrics.securityAndAccessCount, '3 entries should be Security & Access');
        Assert.areEqual(0, sevenDayMetrics.automationAndMetadataCount, '0 entries should be Automation & Metadata');
        Assert.areEqual(2, sevenDayMetrics.impersonatedCount, '2 entries have Delegate_User__c populated');
        Assert.areEqual(1, sevenDayMetrics.unclassifiedCount, '1 entry is Unclassified');
        Assert.areEqual(4, sevenDayMetrics.unassignedChangeCount, 'All 4 entries are unassigned when no change log cites them');
        Assert.areEqual(4, allTimeMetrics.totalEntries, 'All-time window should include all 4 entries');
        Assert.areEqual(3, incidentEvents.size(), 'Incident timeline with highRiskOnly=true should return 3 events');

        Assert.areEqual(4, status.totalEntries, 'Control Center should report 4 total entries');
        Assert.areEqual(1, status.unclassifiedEntries, 'Control Center should report 1 unclassified entry');
        Assert.isFalse(status.activeRules.isEmpty(), 'Active rules list should be populated');
        Assert.areEqual(1, status.topUnclassifiedActions.size(), 'Top unclassified actions should contain 1 group');
    }

    @IsTest
    private static void shouldScheduleUnscheduleAndRunBatches_WhenAdminActionsInvoked() {
        Id scheduledId;
        Id scheduledPurgeId;
        AuditrController.ControlCenterStatusDTO scheduledStatus;
        Id syncJobId;
        Id reclassifyJobId;
        Id purgeJobId;

        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            scheduledId = AuditrController.scheduleDailySync(3);
            scheduledPurgeId = AuditrController.scheduleDailyPurge(4);
            scheduledStatus = AuditrController.getControlCenterStatus();
            AuditrController.unscheduleDailySync();
            AuditrController.unscheduleDailyPurge();
            syncJobId = AuditrController.runSyncNow();
            reclassifyJobId = AuditrController.runReclassify(true);
            purgeJobId = AuditrController.runPurgeNow();
            Test.stopTest();
        }

        Assert.isNotNull(scheduledId, 'scheduleDailySync should return a CronTrigger Id');
        Assert.isNotNull(scheduledPurgeId, 'scheduleDailyPurge should return a CronTrigger Id');
        Assert.isTrue(scheduledStatus.isScheduled, 'Control Center status should reflect active sync schedule');
        Assert.areEqual(3, scheduledStatus.scheduledSyncHour, 'Scheduled sync hour should be parsed from CronExpression');
        Assert.isTrue(scheduledStatus.isPurgeScheduled, 'Control Center status should reflect active purge schedule');
        Assert.areEqual(4, scheduledStatus.scheduledPurgeHour, 'Scheduled purge hour should be parsed from CronExpression');
        Assert.isNotNull(syncJobId, 'runSyncNow should return a batch job Id');
        Assert.isNotNull(reclassifyJobId, 'runReclassify should return a batch job Id');
        Assert.isNotNull(purgeJobId, 'runPurgeNow should return a batch job Id');
    }

    @IsTest
    private static void shouldDiscountPackagedEntries_WhenBacklogKpiQueried() {
        List<Auditr_Entry__c> entries = [SELECT Id FROM Auditr_Entry__c WITH SYSTEM_MODE ORDER BY Name ASC LIMIT 1];
        Auditr_Change_Log__c changeLog = AuditrTestDataFactory.insertChangeLog();
        AuditrTestDataFactory.insertChangeLogItems(changeLog.Id, entries);
        AuditrController.AtAGlanceDTO metrics;
        DateTime watermark;

        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            metrics = AuditrController.getAtAGlanceMetrics(7);
            watermark = AuditrController.getLatestSyncedOccurredAt();
            Test.stopTest();
        }

        Assert.areEqual(3, metrics.unassignedChangeCount, 'Backlog KPI should exclude the 1 entry cited by a change log');
        Assert.isNotNull(watermark, 'Latest synced watermark should be returned for lightweight LWC consumers');
    }
}