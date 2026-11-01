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
        AuditrController.ControlCenterStatusDTO scheduledStatus;
        Id syncJobId;
        Id reclassifyJobId;

        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            scheduledId = AuditrController.scheduleDailySync(3);
            scheduledStatus = AuditrController.getControlCenterStatus();
            AuditrController.unscheduleDailySync();
            syncJobId = AuditrController.runSyncNow();
            reclassifyJobId = AuditrController.runReclassify(true);
            Test.stopTest();
        }

        Assert.isNotNull(scheduledId, 'scheduleDailySync should return a CronTrigger Id');
        Assert.isTrue(scheduledStatus.isScheduled, 'Control Center status should reflect active schedule');
        Assert.isNotNull(syncJobId, 'runSyncNow should return a batch job Id');
        Assert.isNotNull(reclassifyJobId, 'runReclassify should return a batch job Id');
    }
}
