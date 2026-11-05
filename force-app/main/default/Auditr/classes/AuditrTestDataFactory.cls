/**
 * @description Test data factory for Auditr unit and bulk tests.
 */
@IsTest
public with sharing class AuditrTestDataFactory {
    /**
     * @description Builds a single Auditr_Entry__c record with deterministic defaults.
     * @param index Numerical suffix for generating a unique 18-character Source_Record_Id__c.
     * @param delegateUser Optional Delegate_User__c value to simulate Login-As/Support sessions.
     * @return Uninserted Auditr_Entry__c record.
     */
    public static Auditr_Entry__c buildEntry(Integer index, String delegateUser) {
        return new Auditr_Entry__c(
            Source__c = 'SetupAuditTrail',
            Source_Record_Id__c = '0Ym' + String.valueOf(index).leftPad(15, '0'),
            Occurred_At__c = System.now().addMinutes(-index),
            Actor__c = UserInfo.getUserId(),
            Actor_Username__c = 'acted.as.' + index + '@example.com',
            Delegate_User__c = delegateUser,
            Actor_Context__c = 'InternalUser',
            Action_Code__c = 'changedprofile',
            Section__c = 'Manage Users',
            Category__c = 'Security & Access',
            Risk_Level__c = 'High',
            Display__c = 'Changed profile System Administrator permission Modify All Data.'
        );
    }

    /**
     * @description Builds an uninserted list of Auditr_Entry__c records.
     * @param count Number of records to build.
     * @return List of uninserted Auditr_Entry__c records.
     */
    public static List<Auditr_Entry__c> buildEntries(Integer count) {
        List<Auditr_Entry__c> entries = new List<Auditr_Entry__c>();
        for (Integer index = 0; index < count; index++) {
            String delegateUser = (Math.mod(index, 2) == 0) ? 'delegate.admin.' + index + '@example.com' : null;
            entries.add(buildEntry(index, delegateUser));
        }
        return entries;
    }

    /**
     * @description Builds and inserts a list of Auditr_Entry__c records in SYSTEM_MODE.
     * @param count Number of records to create and insert (e.g., 251 for bulk trigger testing).
     * @return List of inserted Auditr_Entry__c records.
     */
    public static List<Auditr_Entry__c> insertEntries(Integer count) {
        List<Auditr_Entry__c> entries = buildEntries(count);
        if (!entries.isEmpty()) {
            Database.insert(entries, AccessLevel.SYSTEM_MODE);
        }
        return entries;
    }

    /**
     * @description Builds and inserts a Draft Auditr_Change_Log__c with a deterministic Change Request Id.
     * @return Inserted Auditr_Change_Log__c record.
     */
    public static Auditr_Change_Log__c insertChangeLog() {
        Auditr_Change_Log__c changeLog = new Auditr_Change_Log__c(
            Change_Request_Id__c = 'PROJ-0001',
            Status__c = 'Draft',
            Deployment_Date__c = System.now().addDays(2),
            Description__c = 'Factory change log'
        );
        Database.insert(changeLog, AccessLevel.SYSTEM_MODE);
        return changeLog;
    }

    /**
     * @description Builds and inserts Auditr_Change_Log_Item__c citations for the given entries.
     * @param changeLogId Parent Auditr_Change_Log__c Id.
     * @param entries Auditr_Entry__c records to cite.
     * @return Inserted Auditr_Change_Log_Item__c records.
     */
    public static List<Auditr_Change_Log_Item__c> insertChangeLogItems(Id changeLogId, List<Auditr_Entry__c> entries) {
        List<Auditr_Change_Log_Item__c> items = new List<Auditr_Change_Log_Item__c>();
        for (Auditr_Entry__c entry : entries) {
            items.add(new Auditr_Change_Log_Item__c(Change_Log__c = changeLogId, Entry__c = entry.Id));
        }
        if (!items.isEmpty()) {
            Database.insert(items, AccessLevel.SYSTEM_MODE);
        }
        return items;
    }

    /**
     * @description Assigns the Auditr_Admin permission set to the running user for USER_MODE test queries.
     */
    public static void assignAdminPermissionSet() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            List<PermissionSet> permSets = [SELECT Id FROM PermissionSet WHERE Name = 'Auditr_Admin' WITH SYSTEM_MODE LIMIT 1];
            if (permSets.isEmpty()) {
                return;
            }
            List<PermissionSetAssignment> existing = [
                SELECT Id FROM PermissionSetAssignment
                WHERE AssigneeId = :UserInfo.getUserId() AND PermissionSetId = :permSets[0].Id
                WITH SYSTEM_MODE LIMIT 1
            ];
            if (existing.isEmpty()) {
                Database.insert(new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = permSets[0].Id), AccessLevel.SYSTEM_MODE);
            }
        }
    }

    /**
     * @description Constructs an in-memory SetupAuditTrail record via JSON deserialization
     * so unit tests can run deterministically without querying live org history.
     * @param index Numeric index for deterministic Id and attributes.
     * @param action SetupAuditTrail Action string.
     * @param section SetupAuditTrail Section string.
     * @param display SetupAuditTrail Display string.
     * @return Deserialized mock SetupAuditTrail instance.
     */
    public static SetupAuditTrail buildMockSetupAuditTrail(Integer index, String action, String section, String display) {
        String fakeId = '0Aa' + String.valueOf(index).leftPad(15, '0');
        Map<String, Object> data = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'SetupAuditTrail' },
            'Id' => fakeId,
            'Action' => String.isNotBlank(action) ? action : 'suorgadminadd',
            'Section' => String.isNotBlank(section) ? section : 'Manage Users',
            'Display' => String.isNotBlank(display) ? display : 'Test audit action ' + index,
            'CreatedDate' => System.now().addMinutes(-index).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\''),
            'CreatedById' => UserInfo.getUserId(),
            'CreatedBy' => new Map<String, Object>{ 'Username' => 'admin.' + index + '@example.com' },
            'DelegateUser' => (Math.mod(index, 2) == 0) ? 'delegate.' + index + '@example.com' : null,
            'ResponsibleNamespacePrefix' => null,
            'CreatedByContext' => 'InternalUser'
        };
        return (SetupAuditTrail) JSON.deserialize(JSON.serialize(data), SetupAuditTrail.class);
    }

    /**
     * @description Builds a list of in-memory SetupAuditTrail records for deterministic batch testing.
     * @param count Number of mock SetupAuditTrail records to construct.
     * @return List of mock SetupAuditTrail instances.
     */
    public static List<SetupAuditTrail> buildMockSetupAuditTrails(Integer count) {
        List<SetupAuditTrail> rows = new List<SetupAuditTrail>();
        for (Integer i = 1; i <= count; i++) {
            rows.add(buildMockSetupAuditTrail(i, 'suorgadminadd', 'Manage Users', 'Added user test' + i));
        }
        return rows;
    }
}