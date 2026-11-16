/**
 * @description Regression coverage for chronological signal merging and chunk-local Login-As windows.
 */
@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs,PMD.MethodNamingConventions,PMD.AvoidHardcodingId')
private class AuditrLoginAsCorrelatorTest {
    private static AuditrLoginAsCorrelator.RawSignal signal(String action, DateTime occurredAt, String sourceId) {
        AuditrLoginAsCorrelator.RawSignal value = new AuditrLoginAsCorrelator.RawSignal();
        value.sourceId = sourceId;
        value.actionCode = action;
        value.occurredAt = occurredAt;
        value.createdById = UserInfo.getUserId();
        value.createdByUsername = UserInfo.getUserName();
        value.delegateUser = 'correlation.admin@example.com';
        return value;
    }

    @IsTest
    private static void shouldCloseSession_WhenArchivedLogoutPrecedesRawLoginInInput() {
        DateTime login = DateTime.newInstanceGmt(2020, 1, 1, 12, 0, 0);
        List<AuditrLoginAsCorrelator.RawSignal> signals = new List<AuditrLoginAsCorrelator.RawSignal>{
            signal('suOrgAdminLogout', login.addMinutes(20), 'archived-logout'),
            signal('suOrgAdminLogin', login, 'raw-login')
        };
        Test.startTest();
        List<AuditrLoginAsCorrelator.LoginAsWindow> windows =
            AuditrLoginAsCorrelator.buildWindowsFromSignals(signals, new Map<String, User>());
        Test.stopTest();
        Assert.areEqual(1, windows.size(), 'Interleaved streams must produce one closed session');
        Assert.areEqual(login, windows[0].startAt, 'Start must be the raw login');
        Assert.areEqual(login.addMinutes(20), windows[0].endAt, 'Archived logout must close the session');
        Assert.isNull(AuditrLoginAsCorrelator.resolveDelegateUser(windows, UserInfo.getUserId(), UserInfo.getUserName(), login.addMinutes(25)),
            'No delegation may be inferred after the known logout');
    }

    @IsTest
    private static void shouldOrderLoginBeforeLogout_WhenTimestampsTie() {
        DateTime timestamp = DateTime.newInstanceGmt(2020, 1, 1, 12, 0, 0);
        List<AuditrLoginAsCorrelator.RawSignal> signals = new List<AuditrLoginAsCorrelator.RawSignal>{
            signal('suOrgAdminLogout', timestamp, 'a'),
            signal('suOrgAdminLogin', timestamp, 'z')
        };
        Test.startTest();
        List<AuditrLoginAsCorrelator.LoginAsWindow> windows =
            AuditrLoginAsCorrelator.buildWindowsFromSignals(signals, new Map<String, User>());
        Test.stopTest();
        Assert.areEqual(1, windows.size(), 'Tied logout must close the tied login');
        Assert.areEqual(timestamp, windows[0].endAt, 'No two-hour open window may remain');
    }

    private static Auditr_Entry__c archivedSignal(Integer index, DateTime timestamp, String action) {
        Auditr_Entry__c entry = AuditrTestDataFactory.buildEntry(index, 'correlation.admin@example.com');
        entry.Actor_Username__c = UserInfo.getUserName();
        entry.Occurred_At__c = timestamp;
        entry.Action_Code__c = action;
        return entry;
    }

    @IsTest
    private static void shouldIncludeLogoutOnlyWindow_WhenSignalIsMoreThanFiveMinutesLater() {
        DateTime eventTime = DateTime.newInstanceGmt(2020, 1, 1, 12, 0, 0);
        Database.insert(archivedSignal(1, eventTime.addMinutes(60), 'suOrgAdminLogout'), AccessLevel.SYSTEM_MODE);
        Test.startTest();
        List<AuditrLoginAsCorrelator.LoginAsWindow> windows =
            AuditrLoginAsCorrelator.loadWindowsForRange(eventTime, eventTime);
        Test.stopTest();
        Assert.areEqual('correlation.admin@example.com',
            AuditrLoginAsCorrelator.resolveDelegateUser(windows, UserInfo.getUserId(), UserInfo.getUserName(), eventTime),
            'A logout-only signal can reach 120 minutes backwards');
    }

    @IsTest
    private static void shouldReloadWindows_WhenNextChunkCoversAnotherDay() {
        DateTime first = DateTime.newInstanceGmt(2020, 1, 1, 12, 0, 0);
        DateTime second = first.addDays(2);
        Database.insert(new List<Auditr_Entry__c>{
            archivedSignal(1, first.addMinutes(-5), 'suOrgAdminLogin'),
            archivedSignal(2, first.addMinutes(5), 'suOrgAdminLogout'),
            archivedSignal(3, second.addMinutes(-5), 'suOrgAdminLogin'),
            archivedSignal(4, second.addMinutes(5), 'suOrgAdminLogout')
        }, AccessLevel.SYSTEM_MODE);
        AuditrWatchedObjectSource source = new AuditrWatchedObjectSource(new Auditr_Watched_Object__mdt(
            Object_API_Name__c = 'Account', Watched_Fields__c = 'Rating'
        ));
        Test.startTest();
        source.processHistoryInputs(historyChunk(first, '017000000000001AAA'));
        List<Auditr_Entry__c> firstFlush = source.flush();
        source.processHistoryInputs(historyChunk(second, '017000000000002AAA'));
        List<Auditr_Entry__c> secondFlush = source.flush();
        Test.stopTest();
        Assert.areEqual('correlation.admin@example.com', firstFlush[0].Delegate_User__c, 'First chunk must correlate');
        Assert.areEqual('correlation.admin@example.com', secondFlush[0].Delegate_User__c, 'Later chunk must not reuse the first time window');
        Assert.isTrue(source.flush().isEmpty(), 'Each chunk must leave no pending group');
    }

    private static List<AuditrWatchedObjectSource.HistoryRowInput> historyChunk(DateTime timestamp, String historyId) {
        return new List<AuditrWatchedObjectSource.HistoryRowInput>{
            new AuditrWatchedObjectSource.HistoryRowInput(
                historyId, '001000000000001AAA', 'Rating', UserInfo.getUserId(), UserInfo.getUserName(), timestamp
            )
        };
    }
}
