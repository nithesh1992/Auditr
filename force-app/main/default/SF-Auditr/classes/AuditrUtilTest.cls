/**
 * @description Unit test suite for AuditrUtil configuration loading, rule priority evaluation, and entry mapping.
 */
@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs,PMD.MethodNamingConventions')
private class AuditrUtilTest {
    @IsTest
    private static void shouldLoadDefaultAndOverrideSettings_WhenGetSettingAndBatchSizeCalled() {
        Test.startTest();
        Auditr_Setting__mdt defaultSetting = AuditrUtil.getSetting();
        Integer defaultBatchSize = AuditrUtil.getBatchSize();

        AuditrUtil.testSettingOverride = new Auditr_Setting__mdt(
            DeveloperName = 'CustomOverride',
            Is_Active__c = false,
            Backfill_Days__c = 30,
            Enable_Purge__c = true,
            Retention_Days__c = 90,
            Batch_Size__c = 5000,
            Preferred_Sync_Hour__c = 4
        );
        Integer clampedBatchSize = AuditrUtil.getBatchSize();

        AuditrUtil.testSettingOverride.Batch_Size__c = 250;
        Integer validCustomBatchSize = AuditrUtil.getBatchSize();
        AuditrUtil.testSettingOverride = null;
        Test.stopTest();

        Assert.isNotNull(defaultSetting, 'Default setting should never be null');
        Assert.areEqual(2000, defaultBatchSize, 'Default batch size should be 2000');
        Assert.areEqual(2000, clampedBatchSize, 'Out-of-bounds batch size (>2000) should clamp to 2000');
        Assert.areEqual(250, validCustomBatchSize, 'Valid custom batch size should be returned');
    }

    @IsTest
    private static void shouldEvaluateRulesInPriorityOrderAcrossAllTargetsAndOperators() {
        AuditrUtil.testRulesOverride = new List<Auditr_Rule__mdt>{
            new Auditr_Rule__mdt(
                DeveloperName = 'Rule_B_Section_Contains',
                Is_Active__c = true,
                Priority__c = 20,
                Match_Target__c = 'Section',
                Match_Operator__c = 'Contains',
                Match_Value__c = 'Users',
                Category__c = 'Users & Sessions',
                Risk_Level__c = 'Medium'
            ),
            new Auditr_Rule__mdt(
                DeveloperName = 'Rule_A_Delegate_NotBlank',
                Is_Active__c = true,
                Priority__c = 10,
                Match_Target__c = 'DelegateUser',
                Match_Operator__c = 'NotBlank',
                Category__c = 'Security & Access',
                Risk_Level__c = 'Critical'
            ),
            new Auditr_Rule__mdt(
                DeveloperName = 'Rule_C_Action_StartsWith',
                Is_Active__c = true,
                Priority__c = 20,
                Match_Target__c = 'Action',
                Match_Operator__c = 'StartsWith',
                Match_Value__c = 'created',
                Category__c = 'Code & Automation',
                Risk_Level__c = 'High'
            ),
            new Auditr_Rule__mdt(
                DeveloperName = 'Rule_D_Namespace_Equals',
                Is_Active__c = true,
                Priority__c = 30,
                Match_Target__c = 'NamespacePrefix',
                Match_Operator__c = 'Equals',
                Match_Value__c = 'pkgns',
                Category__c = 'Packages & Integrations',
                Risk_Level__c = 'Medium'
            ),
            new Auditr_Rule__mdt(
                DeveloperName = 'Rule_Inactive',
                Is_Active__c = false,
                Priority__c = 1,
                Match_Target__c = 'Action',
                Match_Operator__c = 'Equals',
                Match_Value__c = 'unmatched',
                Category__c = 'Org Preferences',
                Risk_Level__c = 'Critical'
            )
        };

        Test.startTest();
        AuditrUtil.ClassificationResult delegateMatch = AuditrUtil.classify('changedprofile', 'Manage Users', null, 'admin@example.com');
        AuditrUtil.ClassificationResult sectionMatch = AuditrUtil.classify('changedprofile', 'Manage Users', null, null);
        AuditrUtil.ClassificationResult startsWithMatch = AuditrUtil.classify('createdinteractiondefinition', 'Flows', null, null);
        AuditrUtil.ClassificationResult namespaceMatch = AuditrUtil.classify('customaction', 'Custom', 'PKGNS', null);
        AuditrUtil.ClassificationResult unmatchedResult = AuditrUtil.classify('unmatched', 'Other', null, null);
        AuditrUtil.testRulesOverride = null;
        Test.stopTest();

        Assert.areEqual('Critical', delegateMatch.riskLevel, 'Priority 10 DelegateUser NotBlank rule should win');
        Assert.areEqual('Users & Sessions', sectionMatch.category, 'Section Contains rule should match Manage Users');
        Assert.areEqual('Code & Automation', startsWithMatch.category, 'Action StartsWith rule should match createdinteractiondefinition');
        Assert.areEqual('Packages & Integrations', namespaceMatch.category, 'NamespacePrefix Equals rule should match case-insensitively');
        Assert.areEqual('Unclassified', unmatchedResult.category, 'Unmatched event should default to Unclassified');
    }

    @IsTest
    private static void shouldMapSetupAuditTrailToAuditrEntry_WhenBuildEntryCalled() {
        List<SetupAuditTrail> liveRows = [
            SELECT Id, Action, Section, CreatedDate, CreatedById, CreatedBy.Username,
                   Display, DelegateUser, ResponsibleNamespacePrefix, CreatedByContext, CreatedByIssuer
            FROM SetupAuditTrail
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        Assert.isFalse(liveRows.isEmpty(), 'Org should contain at least one SetupAuditTrail record');

        Test.startTest();
        Auditr_Entry__c mappedEntry = AuditrUtil.buildEntryFromAuditTrail(liveRows[0]);
        Test.stopTest();

        Assert.areEqual(String.valueOf(liveRows[0].Id), mappedEntry.Source_Record_Id__c, 'Source_Record_Id__c should match SetupAuditTrail.Id');
        Assert.areEqual(liveRows[0].Display, mappedEntry.Display__c, 'Display__c should map 1:1 from SetupAuditTrail.Display');
        Assert.isNotNull(mappedEntry.Responsible_Username__c, 'Responsible_Username__c should be populated');
    }
}
