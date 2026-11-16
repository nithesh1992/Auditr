/**
 * @description Unit tests for the AuditrSource adapter framework: registry loading, adapter defaults,
 * source-scoped classification, generic batch ingestion with flush(), and per-source failure surfacing.
 */
@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs,PMD.MethodNamingConventions,PMD.AvoidHardcodingId')
private class AuditrSourceTest {
    private static final String FAKE_SOURCE = 'LoginHistory';

    /** @description Test adapter whose configure() method throws to verify fault isolation. */
    public class BrokenConfigSource extends AuditrSource {
        public override void configure(Auditr_Source__mdt config) {
            throw new AuditrSyncBatch.AuditrSyncException('Invalid adapter configuration');
        }
        public override String sourceKey() {
            return FAKE_SOURCE;
        }
        public override Database.QueryLocator getQueryLocator(DateTime cutoff) {
            return Database.getQueryLocator([SELECT Id FROM User WHERE Id = NULL WITH SYSTEM_MODE]);
        }
        public override List<Auditr_Entry__c> toEntries(List<SObject> rows) {
            return new List<Auditr_Entry__c>();
        }
    }

    /** @description Test adapter emitting one entry per row and one trailing entry from flush(). */
    private class FakeSource extends AuditrSource {
        private final String flushActionCode;
        private Boolean flushed = false;

        FakeSource(String flushActionCode) {
            this.flushActionCode = flushActionCode;
        }

        public override String sourceKey() {
            return FAKE_SOURCE;
        }

        public override Database.QueryLocator getQueryLocator(DateTime cutoff) {
            Id currentUserId = UserInfo.getUserId();
            return Database.getQueryLocator([SELECT Id FROM User WHERE Id = :currentUserId WITH SYSTEM_MODE]);
        }

        public override List<Auditr_Entry__c> toEntries(List<SObject> rows) {
            List<Auditr_Entry__c> entries = new List<Auditr_Entry__c>();
            for (SObject row : rows) {
                entries.add(buildFakeEntry(String.valueOf(row.Id), 'fakelogin'));
            }
            return entries;
        }

        public override List<Auditr_Entry__c> flush() {
            if (flushed) {
                return new List<Auditr_Entry__c>();
            }
            flushed = true;
            return new List<Auditr_Entry__c>{ buildFakeEntry('FAKE-FLUSH', flushActionCode) };
        }
    }

    private static Auditr_Entry__c buildFakeEntry(String sourceId, String actionCode) {
        return new Auditr_Entry__c(
            Source__c = FAKE_SOURCE,
            Source_Record_Id__c = sourceId,
            Occurred_At__c = System.now(),
            Actor__c = UserInfo.getUserId(),
            Actor_Username__c = UserInfo.getUserName(),
            Responsible_Username__c = UserInfo.getUserName(),
            Action_Code__c = actionCode,
            Section__c = 'Login',
            Category__c = AuditrUtil.DEFAULT_CATEGORY,
            Risk_Level__c = AuditrUtil.DEFAULT_RISK_LEVEL
        );
    }

    private static Auditr_Source__mdt buildRegistryRecord(String developerName, String adapterClass, Boolean isActive) {
        return new Auditr_Source__mdt(
            DeveloperName = developerName,
            MasterLabel = developerName,
            Adapter_Class__c = adapterClass,
            Is_Active__c = isActive,
            Overlap_Hours__c = 12,
            Batch_Size__c = 500
        );
    }

    @IsTest
    private static void shouldLoadOnlyActiveValidAdapters_WhenRegistryContainsMixedRecords() {
        AuditrSource.testSourcesOverride = new List<Auditr_Source__mdt>{
            buildRegistryRecord('A_Setup', 'AuditrSetupAuditTrailSource', true),
            buildRegistryRecord('B_Inactive', 'AuditrSetupAuditTrailSource', false),
            buildRegistryRecord('C_Missing', 'NoSuchAuditrAdapter', true),
            buildRegistryRecord('D_WrongType', 'AuditrUtil', true)
        };

        Test.startTest();
        List<AuditrSource> adapters = AuditrSource.loadActiveSources();
        AuditrSource blank = AuditrSource.instantiate(new Auditr_Source__mdt(DeveloperName = 'Blank'));
        Test.stopTest();

        Assert.areEqual(1, adapters.size(), 'Only the active record with a valid AuditrSource class should load');
        Assert.areEqual(AuditrUtil.DEFAULT_SOURCE, adapters[0].sourceKey(), 'Loaded adapter should be Setup Audit Trail');
        Assert.areEqual(12, adapters[0].overlapHours(), 'Overlap should come from the registry record');
        Assert.areEqual(500, adapters[0].batchSize(), 'Batch size should come from the registry record');
        Assert.isNull(blank, 'A record without an adapter class should not instantiate');
    }

    @IsTest
    private static void shouldApplyDefaults_WhenAdapterHasNoRegistryRecord() {
        AuditrSource.testSourcesOverride = new List<Auditr_Source__mdt>();

        Test.startTest();
        AuditrSource adapter = AuditrSource.defaultSource();
        Test.stopTest();

        Assert.areEqual(AuditrSource.DEFAULT_OVERLAP_HOURS, adapter.overlapHours(), 'Overlap should default to 48 hours');
        Assert.areEqual(AuditrUtil.getBatchSize(), adapter.batchSize(), 'Batch size should fall back to Auditr Setting');
        Assert.isTrue(adapter.flush().isEmpty(), 'Default flush() should emit nothing');
        Assert.isTrue(adapter.toEntries(null).isEmpty(), 'Null rows should map to no entries');
    }

    @IsTest
    private static void shouldKeepHealthyAdapters_WhenConfigurationThrows() {
        Auditr_Source__mdt broken = buildRegistryRecord('A_Broken', 'AuditrSourceTest.BrokenConfigSource', true);
        AuditrSource.testSourcesOverride = new List<Auditr_Source__mdt>{
            broken, buildRegistryRecord('B_Healthy', 'AuditrSetupAuditTrailSource', true)
        };
        AuditrWatchedObjectSource.testWatchedObjectsOverride = new List<Auditr_Watched_Object__mdt>();
        Test.startTest();
        try {
            AuditrSource.instantiate(broken);
            Assert.fail('The fixture must exercise a throwing configure method');
        } catch (AuditrSyncBatch.AuditrSyncException ex) {
            Assert.isTrue(ex.getMessage().contains('Invalid adapter'), 'Expected the fixture configuration error');
        }
        List<AuditrSource> adapters = AuditrSource.loadActiveSources();
        Test.stopTest();
        Assert.areEqual(1, adapters.size(), 'The healthy adapter must still load after the broken one');
        Assert.areEqual(AuditrUtil.DEFAULT_SOURCE, adapters[0].sourceKey(), 'Remaining source must be Setup Audit Trail');
        Assert.isNotNull(AuditrWatchedObjectSource.queryWatchedRegistry(), 'Watched object SOQL registry query should execute cleanly');
    }

    @IsTest
    private static void shouldResolveWatermarkPerSource_WhenEntriesExistForThatSource() {
        DateTime lastOccurred = System.now().addHours(-10);
        Auditr_Entry__c existing = buildFakeEntry('FAKE-EXISTING', 'fakelogin');
        existing.Occurred_At__c = lastOccurred;
        Database.insert(existing, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        DateTime fakeCutoff = new FakeSource('fakelogin').resolveCutoff();
        DateTime setupCutoff = AuditrSource.defaultSource().resolveCutoff();
        Test.stopTest();

        Assert.areEqual(lastOccurred.addHours(-48), fakeCutoff, 'Cutoff should be the source watermark minus the overlap');
        Assert.isTrue(setupCutoff < System.now().addDays(-30), 'Setup Audit Trail has no entries, so it should use the backfill window');
    }

    @IsTest
    private static void shouldScopeRulesBySource_WhenClassifying() {
        AuditrUtil.testRulesOverride = new List<Auditr_Rule__mdt>{
            new Auditr_Rule__mdt(
                DeveloperName = 'Login_Rule', Is_Active__c = true, Priority__c = 1, Source__c = FAKE_SOURCE,
                Match_Target__c = 'Action', Match_Operator__c = 'Equals', Match_Value__c = 'sharedaction',
                Category__c = 'Users & Sessions', Risk_Level__c = 'High'
            ),
            new Auditr_Rule__mdt(
                DeveloperName = 'Setup_Rule', Is_Active__c = true, Priority__c = 2,
                Match_Target__c = 'Action', Match_Operator__c = 'Equals', Match_Value__c = 'sharedaction',
                Category__c = 'Security & Access', Risk_Level__c = 'Medium'
            )
        };

        Test.startTest();
        AuditrUtil.ClassificationResult loginResult = AuditrUtil.classify(FAKE_SOURCE, 'sharedaction', null, null, null);
        AuditrUtil.ClassificationResult setupResult = AuditrUtil.classify('sharedaction', null, null, null);
        AuditrUtil.ClassificationResult otherResult = AuditrUtil.classify('DataChange', 'sharedaction', null, null, null);
        Test.stopTest();

        Assert.areEqual('Users & Sessions', loginResult.category, 'LoginHistory entries should match only LoginHistory rules');
        Assert.areEqual('Security & Access', setupResult.category, 'Rules with blank Source should apply to SetupAuditTrail');
        Assert.areEqual(AuditrUtil.DEFAULT_CATEGORY, otherResult.category, 'Sources without rules should stay Unclassified');
    }

    @IsTest
    private static void shouldIngestRowsAndFlushedEntriesWithDedupe_WhenCustomAdapterRuns() {
        Test.startTest();
        AuditrSyncBatch firstRun = new AuditrSyncBatch(new FakeSource('fakelogin'));
        Database.QueryLocator locator = firstRun.start(null);
        firstRun.execute(null, [SELECT Id FROM User WHERE Id = :UserInfo.getUserId() WITH SYSTEM_MODE]);
        firstRun.finish(null);

        AuditrSyncBatch replay = new AuditrSyncBatch(new FakeSource('fakelogin'));
        replay.execute(null, [SELECT Id FROM User WHERE Id = :UserInfo.getUserId() WITH SYSTEM_MODE]);
        replay.finish(null);
        Test.stopTest();

        Assert.isNotNull(locator, 'Adapter query locator should be returned by start()');
        Assert.areEqual(2, firstRun.totalSuccessfullyInserted, 'Row entry and flushed entry should both be inserted');
        Assert.areEqual(0, replay.totalSuccessfullyInserted, 'Replay should skip entries already ingested');
        Assert.areEqual(
            2,
            [SELECT COUNT() FROM Auditr_Entry__c WHERE Source__c = :FAKE_SOURCE WITH SYSTEM_MODE],
            'Exactly two LoginHistory entries should exist'
        );
    }

    @IsTest
    private static void shouldFailWithSourceKey_WhenFlushedEntryCannotBeInserted() {
        AuditrSyncBatch batch = new AuditrSyncBatch(new FakeSource('a'.repeat(200)));

        Test.startTest();
        batch.execute(null, [SELECT Id FROM User WHERE Id = :UserInfo.getUserId() WITH SYSTEM_MODE]);
        AuditrSyncBatch.AuditrSyncException caughtEx;
        try {
            batch.finish(null);
        } catch (AuditrSyncBatch.AuditrSyncException ex) {
            caughtEx = ex;
        }
        Test.stopTest();

        Assert.isNotNull(caughtEx, 'finish() must fail the job when a flushed entry fails to insert');
        Assert.isTrue(caughtEx.getMessage().contains('[' + FAKE_SOURCE + ']'), 'Failure message should name the source');
    }

    @IsTest
    private static void shouldCommitFlushedEntry_WhenPriorChunkFailed() {
        AuditrSyncBatch batch = new AuditrSyncBatch(new FakeSource('fakelogin'));
        batch.totalFailedInserts = 1;
        batch.firstInsertErrorMessage = 'Prior chunk failed';
        Test.startTest();
        batch.execute(null, [SELECT Id FROM User WHERE Id = :UserInfo.getUserId() WITH SYSTEM_MODE]);
        Assert.areEqual(1, [SELECT COUNT() FROM Auditr_Entry__c WHERE Source_Record_Id__c = 'FAKE-FLUSH' WITH SYSTEM_MODE],
            'The trailing entry must be written during execute, not finish');
        Savepoint beforeFinish = Database.setSavepoint();
        try {
            batch.finish(null);
            Assert.fail('The job must still report the earlier failure');
        } catch (AuditrSyncBatch.AuditrSyncException ex) {
            Database.rollback(beforeFinish);
        }
        Test.stopTest();
        Assert.areEqual(1, [SELECT COUNT() FROM Auditr_Entry__c WHERE Source_Record_Id__c = 'FAKE-FLUSH' WITH SYSTEM_MODE],
            'Rolling back finish must not discard the execute flush');
    }

    @IsTest
    private static void shouldDispatchOneJobPerActiveSource_WhenScheduled() {
        Auditr_Entry__c recent = AuditrTestDataFactory.buildEntry(1, null);
        recent.Occurred_At__c = System.now();
        Database.insert(recent, AccessLevel.SYSTEM_MODE);
        Auditr_Source__mdt setupRecord = buildRegistryRecord('Setup_Audit_Trail', 'AuditrSetupAuditTrailSource', true);
        setupRecord.Overlap_Hours__c = 1;
        setupRecord.Batch_Size__c = 2000;
        AuditrSource.testSourcesOverride = new List<Auditr_Source__mdt>{
            setupRecord,
            buildRegistryRecord('Login_History', 'AuditrSetupAuditTrailSource', false)
        };

        Test.startTest();
        List<Id> jobIds = AuditrSyncBatch.dispatchActiveSources();
        Test.stopTest();

        Assert.areEqual(1, jobIds.size(), 'One batch should be enqueued per active source');
    }

    @IsTest
    private static void shouldGroupConsecutiveSameSaveRowsAndSplitOnInterruption_WhenWatchedObjectProcessesHistory() {
        Auditr_Watched_Object__mdt config = new Auditr_Watched_Object__mdt(
            DeveloperName = 'Account_Watch',
            MasterLabel = 'Account Watch',
            Object_API_Name__c = 'Account',
            Is_Active__c = true,
            Watched_Fields__c = 'OwnerId,Rating,Type',
            Default_Risk_Level__c = 'Medium',
            Category__c = 'Data & Schema',
            Overlap_Hours__c = 24,
            Batch_Size__c = 400
        );
        AuditrWatchedObjectSource adapter = new AuditrWatchedObjectSource(config);
        Id userA = UserInfo.getUserId();
        Id userB = Id.valueOf('005000000000001AAA');
        DateTime t1 = DateTime.newInstanceGmt(2026, 11, 9, 12, 0, 0);
        DateTime t2 = t1.addSeconds(1);

        List<AuditrWatchedObjectSource.HistoryRowInput> chunk1 = new List<AuditrWatchedObjectSource.HistoryRowInput>{
            // Continuous save 1 by userA on 001A at t1 (OwnerId + Rating + ignored BillingCity)
            new AuditrWatchedObjectSource.HistoryRowInput('017000000000001AAA', '001000000000001AAA', 'OwnerId', userA, 'alice@example.com', t1),
            new AuditrWatchedObjectSource.HistoryRowInput('017000000000002AAA', '001000000000001AAA', 'BillingCity', userA, 'alice@example.com', t1),
            new AuditrWatchedObjectSource.HistoryRowInput('017000000000003AAA', '001000000000001AAA', 'Rating', userA, 'alice@example.com', t1),
            new AuditrWatchedObjectSource.HistoryRowInput('017000000000004AAA', '001000000000001AAA', 'Rating', userA, 'alice@example.com', t1),
            // Interruption at exact same timestamp t1 by userB on 001A
            new AuditrWatchedObjectSource.HistoryRowInput('017000000000005AAA', '001000000000001AAA', 'Type', userB, 'bob@example.com', t1),
            // Non-continuous row by userA on 001A at t1 after userB interruption -> must NOT merge with first group
            new AuditrWatchedObjectSource.HistoryRowInput('017000000000006AAA', '001000000000001AAA', 'Type', userA, 'alice@example.com', t1),
            // Different timestamp t2 by userA on 001A (spans into chunk2)
            new AuditrWatchedObjectSource.HistoryRowInput('017000000000007AAA', '001000000000001AAA', 'OwnerId', userA, 'alice@example.com', t2)
        };
        List<AuditrWatchedObjectSource.HistoryRowInput> chunk2 = new List<AuditrWatchedObjectSource.HistoryRowInput>{
            // Continues the t2 save across the chunk boundary
            new AuditrWatchedObjectSource.HistoryRowInput('017000000000008AAA', '001000000000001AAA', 'Rating', userA, 'alice@example.com', t2),
            // Record creation event on 001B
            new AuditrWatchedObjectSource.HistoryRowInput('017000000000009AAA', '001000000000002AAA', 'created', userA, 'alice@example.com', t2)
        };

        Test.startTest();
        List<Auditr_Entry__c> emitted = new List<Auditr_Entry__c>();
        emitted.addAll(adapter.processHistoryInputs(chunk1));
        emitted.addAll(adapter.flush());
        emitted.addAll(adapter.processHistoryInputs(chunk2));
        emitted.addAll(adapter.flush());
        Test.stopTest();

        Assert.areEqual(6, emitted.size(), 'A save crossing a chunk boundary is emitted as two groups');
        Assert.areEqual('017000000000001AAA', emitted[0].Source_Record_Id__c, 'First group should use first history row Id');
        Assert.areEqual('fields_changed:2', emitted[0].Action_Code__c, 'Duplicate Rating and unwatched BillingCity should leave 2 watched fields');
        Assert.isTrue(emitted[0].Display__c.contains('Changed OwnerId, Rating on Account'), 'Display should list watched fields only');
        Assert.areEqual('017000000000005AAA', emitted[1].Source_Record_Id__c, 'Second entry should be userB interruption');
        Assert.areEqual('017000000000006AAA', emitted[2].Source_Record_Id__c, 'Third entry should be userA post-interruption (not merged with first)');
        Assert.areEqual('field_changed:Type', emitted[2].Action_Code__c, 'Single field change should use field_changed:<field>');
        Assert.areEqual('017000000000007AAA', emitted[3].Source_Record_Id__c, 'First chunk anchors its final group');
        Assert.areEqual('field_changed:OwnerId', emitted[3].Action_Code__c, 'Only the first field is in chunk one');
        Assert.areEqual('017000000000008AAA', emitted[4].Source_Record_Id__c, 'Next chunk starts a new group');
        Assert.areEqual('field_changed:Rating', emitted[4].Action_Code__c, 'The second field must not be dropped');
        Assert.areEqual('record_created', emitted[5].Action_Code__c, 'created field should produce record_created action');
        Assert.areEqual(24, adapter.overlapHours(), 'Watched object overlap override should be respected');
        Assert.areEqual(400, adapter.batchSize(), 'Watched object batch size override should be respected');
    }

    @IsTest
    private static void shouldClassifyAndReclassifyWatchedObjectEntries_WhenFieldAndObjectRulesExist() {
        AuditrWatchedObjectSource.testWatchedObjectsOverride = new List<Auditr_Watched_Object__mdt>{
            new Auditr_Watched_Object__mdt(
                DeveloperName = 'Account_Watch',
                MasterLabel = 'Account Watch',
                Object_API_Name__c = 'Account',
                Is_Active__c = true,
                Default_Risk_Level__c = 'Medium',
                Category__c = 'Data & Schema'
            )
        };
        AuditrUtil.testRulesOverride = new List<Auditr_Rule__mdt>{
            new Auditr_Rule__mdt(
                DeveloperName = 'Critical_Owner_Change', Is_Active__c = true, Priority__c = 1,
                Source__c = AuditrUtil.DATA_CHANGE_SOURCE,
                Match_Target__c = 'ChangedField', Match_Operator__c = 'Equals', Match_Value__c = 'OwnerId',
                Category__c = 'Security & Access', Risk_Level__c = 'Critical'
            ),
            new Auditr_Rule__mdt(
                DeveloperName = 'High_Opportunity_Target', Is_Active__c = true, Priority__c = 2,
                Source__c = AuditrUtil.DATA_CHANGE_SOURCE,
                Match_Target__c = 'TargetObject', Match_Operator__c = 'Equals', Match_Value__c = 'Opportunity',
                Category__c = 'Data & Schema', Risk_Level__c = 'High'
            )
        };

        Auditr_Entry__c watchedEntry = new Auditr_Entry__c(
            RecordTypeId = AuditrUtil.getDataChangeRecordTypeId(),
            Source__c = AuditrUtil.DATA_CHANGE_SOURCE,
            Source_Record_Id__c = '017000000000099AAA',
            Target_Object__c = 'Account',
            Target_Record_Id__c = '001000000000001AAA',
            Occurred_At__c = System.now(),
            Actor__c = UserInfo.getUserId(),
            Actor_Username__c = UserInfo.getUserName(),
            Responsible_Username__c = UserInfo.getUserName(),
            Action_Code__c = 'fields_changed:2',
            Section__c = 'Watched Object: Account',
            Category__c = 'Unclassified',
            Risk_Level__c = 'Low',
            Display__c = 'Changed Rating, OwnerId on Account (001000000000001AAA)',
            Payload__c = '{"object":"Account","recordId":"001000000000001AAA","fieldCount":2,"fields":["Rating","OwnerId"]}'
        );
        Database.insert(watchedEntry, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        AuditrUtil.ClassificationResult oppResult = AuditrUtil.classifyWatchedObject(
            'Opportunity', new List<String>{ 'StageName' }, 'field_changed:StageName', 'Watched Object: Opportunity', 'Data & Schema', 'Low'
        );
        AuditrUtil.ClassificationResult fallbackResult = AuditrUtil.classifyWatchedObject(
            'Account', new List<String>{ 'Rating' }, 'field_changed:Rating', 'Watched Object: Account', 'Data & Schema', 'Medium'
        );
        AuditrReclassifyBatch reclassify = new AuditrReclassifyBatch(false);
        reclassify.execute(null, [
            SELECT Id, Source__c, Target_Object__c, Payload__c, Action_Code__c, Section__c, Namespace_Prefix__c, Delegate_User__c, Category__c, Risk_Level__c
            FROM Auditr_Entry__c
            WHERE Id = :watchedEntry.Id
            WITH SYSTEM_MODE
        ]);
        reclassify.finish(null);
        Test.stopTest();

        Auditr_Entry__c updated = [SELECT Category__c, Risk_Level__c FROM Auditr_Entry__c WHERE Id = :watchedEntry.Id WITH SYSTEM_MODE];
        Assert.areEqual('Security & Access', updated.Category__c, 'Reclassify should match ChangedField = OwnerId in Payload__c');
        Assert.areEqual('Critical', updated.Risk_Level__c, 'ChangedField = OwnerId should elevate Risk_Level__c to Critical');
        Assert.areEqual('High', oppResult.riskLevel, 'TargetObject = Opportunity rule should match');
        Assert.areEqual('Medium', fallbackResult.riskLevel, 'Unmatched field should fall back to watched object default');
    }

    @IsTest
    private static void shouldResolveHistoryTableAndReadiness_WhenWatchedObjectInspected() {
        AuditrWatchedObjectSource.testWatchedObjectsOverride = new List<Auditr_Watched_Object__mdt>{
            new Auditr_Watched_Object__mdt(
                DeveloperName = 'A_ChangeLog_Valid',
                MasterLabel = 'Change Log Valid',
                Object_API_Name__c = 'Auditr_Change_Log__c',
                Is_Active__c = true,
                Watched_Fields__c = 'Status__c,Description__c',
                Default_Risk_Level__c = 'High',
                Category__c = 'Security & Access'
            ),
            new Auditr_Watched_Object__mdt(
                DeveloperName = 'B_ChangeLog_BadField',
                MasterLabel = 'Change Log Bad Field',
                Object_API_Name__c = 'Auditr_Change_Log__c',
                Is_Active__c = false,
                Watched_Fields__c = 'No_Such_Field__c'
            ),
            new Auditr_Watched_Object__mdt(
                DeveloperName = 'C_Invalid_Object',
                MasterLabel = 'Invalid Object',
                Object_API_Name__c = 'No_Such_Object__c',
                Is_Active__c = true
            )
        };
        AuditrSource.testSourcesOverride = new List<Auditr_Source__mdt>();
        AuditrWatchedObjectSource.testTrackedFieldsOverride = new Map<String, Set<String>>{
            'auditr_change_log__c' => new Set<String>{ 'status__c', 'description__c' }
        };

        Auditr_Change_Log__History syntheticHistory = (Auditr_Change_Log__History) JSON.deserialize(
            '{"attributes":{"type":"Auditr_Change_Log__History"},' +
            '"Id":"017000000000055AAA",' +
            '"ParentId":"a00000000000001AAA",' +
            '"Field":"Status__c",' +
            '"CreatedById":"' + UserInfo.getUserId() + '",' +
            '"CreatedDate":"2026-11-09T12:00:00.000+0000"}',
            Auditr_Change_Log__History.class
        );

        Test.startTest();
        List<AuditrWatchedObjectSource.WatchedObjectReadiness> readiness = AuditrController.getWatchedObjectReadiness();
        List<AuditrSource> activeSources = AuditrSource.loadActiveSources();
        AuditrSource watchedAdapter = activeSources[0];
        Database.QueryLocator locator = watchedAdapter.getQueryLocator(watchedAdapter.resolveCutoff());
        List<Auditr_Entry__c> chunkEntries = watchedAdapter.toEntries(new List<SObject>{ syntheticHistory });
        List<Auditr_Entry__c> flushedEntries = watchedAdapter.flush();
        Test.stopTest();

        Assert.areEqual(3, readiness.size(), 'Readiness should report all 3 configured watched objects');
        Assert.isTrue(readiness[0].isReady, 'Auditr_Change_Log__c with valid fields and history enabled should be ready');
        Assert.areEqual('Auditr_Change_Log__History', readiness[0].historyObjectName, 'Custom object history name should resolve to __History');
        Assert.isFalse(readiness[1].isReady, 'Unknown watched field should mark readiness false');
        Assert.areEqual(1, readiness[1].missingFields.size(), 'Unknown field should be reported in missingFields');
        Assert.isFalse(readiness[2].isObjectValid, 'Non-existent object should be flagged as invalid');
        Assert.areEqual(1, activeSources.size(), 'Only the valid active watched object should load as an active source');
        Assert.isNotNull(locator, 'Watched object getQueryLocator should return a valid QueryLocator');
        Assert.areEqual(0, chunkEntries.size(), 'Single history row stays buffered in pendingGroup until flush');
        Assert.areEqual(1, flushedEntries.size(), 'flush() should emit the buffered history entry');
        Assert.areEqual('Auditr_Change_Log__c', flushedEntries[0].Target_Object__c, 'Target_Object__c should be stamped');
        Assert.areEqual('a00000000000001AAA', flushedEntries[0].Target_Record_Id__c, 'Target_Record_Id__c should be stamped');
        AuditrWatchedObjectSource.testTrackedFieldsOverride = null;
    }

    @IsTest
    private static void shouldInferDelegateUserDuringLoginAsWindow_WhenWatchedObjectChangedDuringImpersonation() {
        Id impersonatedUserId = UserInfo.getUserId();
        String impersonatedUsername = UserInfo.getUserName();
        String adminDelegate = 'security.admin@example.com';
        DateTime loginTime = DateTime.newInstanceGmt(2026, 11, 9, 14, 0, 0);
        DateTime insideWindowTime = loginTime.addMinutes(10);
        DateTime logoutTime = loginTime.addMinutes(20);
        DateTime afterLogoutTime = loginTime.addMinutes(25);

        Database.insert(new List<Auditr_Entry__c>{
            new Auditr_Entry__c(
                RecordTypeId = AuditrUtil.getSetupAuditTrailRecordTypeId(),
                Source__c = AuditrUtil.DEFAULT_SOURCE,
                Source_Record_Id__c = '0Ym000000000001AAA',
                Occurred_At__c = loginTime,
                Actor__c = impersonatedUserId,
                Actor_Username__c = impersonatedUsername,
                Delegate_User__c = adminDelegate,
                Responsible_Username__c = adminDelegate,
                Action_Code__c = 'suOrgAdminLogin',
                Section__c = 'Manage Users',
                Category__c = 'Users & Sessions',
                Risk_Level__c = 'Critical',
                Display__c = 'Logged in using Login-As access for ' + impersonatedUsername
            ),
            new Auditr_Entry__c(
                RecordTypeId = AuditrUtil.getSetupAuditTrailRecordTypeId(),
                Source__c = AuditrUtil.DEFAULT_SOURCE,
                Source_Record_Id__c = '0Ym000000000002AAA',
                Occurred_At__c = logoutTime,
                Actor__c = impersonatedUserId,
                Actor_Username__c = impersonatedUsername,
                Delegate_User__c = adminDelegate,
                Responsible_Username__c = adminDelegate,
                Action_Code__c = 'suOrgAdminLogout',
                Section__c = 'Manage Users',
                Category__c = 'Users & Sessions',
                Risk_Level__c = 'Low',
                Display__c = 'Logged out using Login-As access for ' + impersonatedUsername
            )
        }, AccessLevel.SYSTEM_MODE);

        AuditrUtil.testRulesOverride = new List<Auditr_Rule__mdt>{
            new Auditr_Rule__mdt(
                DeveloperName = 'Watched_Object_Delegated_Impersonation',
                Is_Active__c = true,
                Priority__c = 5,
                Source__c = AuditrUtil.DATA_CHANGE_SOURCE,
                Match_Target__c = 'DelegateUser',
                Match_Operator__c = 'NotBlank',
                Category__c = 'Users & Sessions',
                Risk_Level__c = 'Critical'
            )
        };

        AuditrWatchedObjectSource adapter = new AuditrWatchedObjectSource(
            new Auditr_Watched_Object__mdt(
                DeveloperName = 'Case_Watch',
                MasterLabel = 'Case Watch',
                Object_API_Name__c = 'Case',
                Is_Active__c = true,
                Watched_Fields__c = 'Status,Priority',
                Default_Risk_Level__c = 'Medium',
                Category__c = 'Data & Schema'
            )
        );

        List<AuditrWatchedObjectSource.HistoryRowInput> inputs = new List<AuditrWatchedObjectSource.HistoryRowInput>{
            new AuditrWatchedObjectSource.HistoryRowInput(
                '017000000000101AAA', '500000000000001AAA', 'Status', impersonatedUserId, impersonatedUsername, insideWindowTime
            ),
            new AuditrWatchedObjectSource.HistoryRowInput(
                '017000000000102AAA', '500000000000001AAA', 'Priority', impersonatedUserId, impersonatedUsername, afterLogoutTime
            )
        };

        Test.startTest();
        List<Auditr_Entry__c> emitted = new List<Auditr_Entry__c>();
        emitted.addAll(adapter.processHistoryInputs(inputs));
        emitted.addAll(adapter.flush());
        Test.stopTest();

        Assert.areEqual(2, emitted.size(), 'Should emit one entry during Login-As window and one after logout');
        Assert.areEqual(adminDelegate, emitted[0].Delegate_User__c, 'Change inside Login-As window should infer Delegate_User__c');
        Assert.areEqual(adminDelegate, emitted[0].Responsible_Username__c, 'Responsible_Username__c should be the inferred delegate');
        Assert.areEqual('Critical', emitted[0].Risk_Level__c, 'DelegateUser NotBlank rule should elevate risk to Critical');
        Assert.isTrue(emitted[0].Payload__c.contains('"delegateInferredFromLoginAs":true'), 'Payload should flag inferred Login-As delegation');
        Assert.isNull(emitted[1].Delegate_User__c, 'Change after suOrgAdminLogout should not infer a Delegate_User__c');
        Assert.areEqual(impersonatedUsername, emitted[1].Responsible_Username__c, 'Change after logout should attribute to the actor directly');
        Assert.areEqual('Medium', emitted[1].Risk_Level__c, 'Change after logout should use the watched object default risk');
    }

    @IsTest
    private static void shouldCorrelateDisplayTargetLoginAsAndNormalizeSpecialHistoryTokens_WhenProcessed() {
        Id impersonatedUserId = UserInfo.getUserId();
        String impersonatedUsername = UserInfo.getUserName();
        String impersonatedDisplayName = UserInfo.getName();
        String adminActorUsername = 'org.admin@example.com';
        DateTime loginTime = DateTime.newInstanceGmt(2026, 11, 10, 9, 0, 0);
        DateTime saveTime = loginTime.addMinutes(5);
        DateTime lifecycleTime = loginTime.addMinutes(8);

        // Display-target representation: Actor_Username__c is the admin, Delegate_User__c is null,
        // and Display__c names the impersonated user by Name
        Database.insert(new Auditr_Entry__c(
            RecordTypeId = AuditrUtil.getSetupAuditTrailRecordTypeId(),
            Source__c = AuditrUtil.DEFAULT_SOURCE,
            Source_Record_Id__c = '0Ym000000000010AAA',
            Occurred_At__c = loginTime,
            Actor_Username__c = adminActorUsername,
            Responsible_Username__c = adminActorUsername,
            Action_Code__c = 'suloginaccessused',
            Section__c = 'Manage Users',
            Category__c = 'Users & Sessions',
            Risk_Level__c = 'Critical',
            Display__c = 'Logged in using Login-As access for ' + impersonatedDisplayName + '.'
        ), AccessLevel.SYSTEM_MODE);

        AuditrWatchedObjectSource adapter = new AuditrWatchedObjectSource(
            new Auditr_Watched_Object__mdt(
                DeveloperName = 'Account_Special_Watch',
                MasterLabel = 'Account Special Watch',
                Object_API_Name__c = 'Account',
                Is_Active__c = true,
                Watched_Fields__c = 'Name,OwnerId',
                Default_Risk_Level__c = 'Medium',
                Category__c = 'Data & Schema'
            )
        );

        List<AuditrWatchedObjectSource.HistoryRowInput> inputs = new List<AuditrWatchedObjectSource.HistoryRowInput>{
            // Save run starts with an unwatched field (BillingCity at 201), followed by ignored noise (feedEvent at 202),
            // TextName (normalized to Name at 203), and Owner (normalized to OwnerId at 204)
            new AuditrWatchedObjectSource.HistoryRowInput(
                '017000000000201AAA', '001000000000010AAA', 'BillingCity', impersonatedUserId, impersonatedUsername, saveTime
            ),
            new AuditrWatchedObjectSource.HistoryRowInput(
                '017000000000202AAA', '001000000000010AAA', 'feedEvent', impersonatedUserId, impersonatedUsername, saveTime
            ),
            new AuditrWatchedObjectSource.HistoryRowInput(
                '017000000000203AAA', '001000000000010AAA', 'TextName', impersonatedUserId, impersonatedUsername, saveTime
            ),
            new AuditrWatchedObjectSource.HistoryRowInput(
                '017000000000204AAA', '001000000000010AAA', 'Owner', impersonatedUserId, impersonatedUsername, saveTime
            ),
            // Isolated lifecycle tokens: accountMerged, locked, unlocked
            new AuditrWatchedObjectSource.HistoryRowInput(
                '017000000000205AAA', '001000000000010AAA', 'accountMerged', impersonatedUserId, impersonatedUsername, lifecycleTime
            ),
            new AuditrWatchedObjectSource.HistoryRowInput(
                '017000000000206AAA', '001000000000010AAA', 'locked', impersonatedUserId, impersonatedUsername, lifecycleTime
            ),
            new AuditrWatchedObjectSource.HistoryRowInput(
                '017000000000207AAA', '001000000000010AAA', 'unlocked', impersonatedUserId, impersonatedUsername, lifecycleTime
            )
        };

        Test.startTest();
        List<Auditr_Entry__c> emitted = new List<Auditr_Entry__c>();
        emitted.addAll(adapter.processHistoryInputs(inputs));
        emitted.addAll(adapter.flush());
        Test.stopTest();

        Assert.areEqual(4, emitted.size(), 'Should emit 1 grouped field save + 3 isolated lifecycle events');
        Assert.areEqual('017000000000201AAA', emitted[0].Source_Record_Id__c, 'Source_Record_Id__c should anchor to the first row of the save run even when unwatched');
        Assert.areEqual('fields_changed:2', emitted[0].Action_Code__c, 'TextName->Name and Owner->OwnerId should merge into 2 watched fields while skipping feedEvent');
        Assert.isTrue(emitted[0].Display__c.contains('Changed Name, OwnerId on Account'), 'TextName and Owner should normalize to Name and OwnerId');
        Assert.areEqual(adminActorUsername, emitted[0].Delegate_User__c, 'Display-target Login-As entry should resolve impersonated user by Name and attribute admin as delegate');
        Assert.areEqual('record_merged', emitted[1].Action_Code__c, 'accountMerged should map to record_merged');
        Assert.areEqual('record_locked', emitted[2].Action_Code__c, 'locked should map to record_locked');
        Assert.areEqual('record_unlocked', emitted[3].Action_Code__c, 'unlocked should map to record_unlocked');
    }
}
