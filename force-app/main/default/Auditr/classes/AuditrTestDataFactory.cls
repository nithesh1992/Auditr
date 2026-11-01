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
}
