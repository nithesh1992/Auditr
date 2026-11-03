/**
 * @description AuraEnabled controller backing the Audit Mode workspace LWC: change log listing,
 * unassigned (unpackaged) backlog review, and asynchronous packaging requests.
 */
public with sharing class AuditrChangeLogController {
    private static final Integer CHANGE_LOG_LIMIT = 200;
    private static final Integer ENTRY_QUERY_LIMIT = 200;
    private static final Integer BACKLOG_COUNT_CAP = 25000;
    private static final Integer DEFAULT_WINDOW_DAYS = 30;
    private static final String ERROR_LOG_NOT_DRAFT = 'Only Draft change logs can accept packaged entries.';
    private static final String ERROR_PACKAGING_IN_FLIGHT = 'A packaging job is already running for this change log. Wait for it to finish.';
    private static final String ERROR_INSUFFICIENT_ACCESS = 'Insufficient permissions to package audit entries.';
    private static final Set<String> ACTIVE_JOB_STATUSES = new Set<String>{ 'Holding', 'Queued', 'Preparing', 'Processing' };

    /** @description Change Log summary row for the Audit Mode workspace. */
    public class ChangeLogDTO {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String name;
        @AuraEnabled public String changeRequestId;
        @AuraEnabled public String status;
        @AuraEnabled public String targetActor;
        @AuraEnabled public DateTime windowStart;
        @AuraEnabled public DateTime windowEnd;
        @AuraEnabled public DateTime deploymentDate;
        @AuraEnabled public Integer totalEntries;
        @AuraEnabled public DateTime signedOffAt;
        @AuraEnabled public Boolean isPackagingInFlight;
    }

    /** @description User summary for user lookup resolution in Audit Mode. */
    public class UserLookupDTO {
        @AuraEnabled public Id userId;
        @AuraEnabled public String name;
        @AuraEnabled public String username;
    }

    /** @description Audit entry row with packaging citation and risk metadata for Audit Mode. */
    public class AuditEntryDTO {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String name;
        @AuraEnabled public DateTime occurredAt;
        @AuraEnabled public String riskLevel;
        @AuraEnabled public String category;
        @AuraEnabled public String section;
        @AuraEnabled public String actionCode;
        @AuraEnabled public String responsibleUsername;
        @AuraEnabled public String delegateUser;
        @AuraEnabled public String displayText;
        @AuraEnabled public Boolean isPackaged;
        @AuraEnabled public String changeRequestId;
        @AuraEnabled public String changeLogName;
        @AuraEnabled public Id changeLogId;
    }

    /** @description Unassigned audit entry row eligible for packaging. */
    public class UnassignedEntryDTO {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String name;
        @AuraEnabled public DateTime occurredAt;
        @AuraEnabled public String riskLevel;
        @AuraEnabled public String category;
        @AuraEnabled public String section;
        @AuraEnabled public String actionCode;
        @AuraEnabled public String responsibleUsername;
        @AuraEnabled public String displayText;
    }

    /** @description Combined Audit Mode workspace snapshot: recent change logs plus filtered backlog count. */
    public class AuditModeStateDTO {
        @AuraEnabled public List<ChangeLogDTO> changeLogs;
        @AuraEnabled public Integer backlogCount;
    }

    /**
     * @description Returns recent change logs and the unassigned backlog count matching the backlog filter.
     * @param windowStart Inclusive Occurred_At__c lower bound (defaults to System.now() - 30 days).
     * @param windowEnd Inclusive Occurred_At__c upper bound (defaults to System.now()).
     * @param actorUsername Optional exact Responsible_Username__c filter (blank for all actors).
     * @return AuditModeStateDTO with change logs and capped backlog count.
     */
    @AuraEnabled(cacheable=true)
    public static AuditModeStateDTO getAuditModeState(DateTime windowStart, DateTime windowEnd, String actorUsername) {
        AuditModeStateDTO state = new AuditModeStateDTO();
        state.changeLogs = queryChangeLogs();
        state.backlogCount = queryBacklogCount(resolveWindowStart(windowStart), resolveWindowEnd(windowEnd), normalizeActor(actorUsername));
        return state;
    }

    /**
     * @description Returns unassigned audit entries (entries with no change log citation) matching the backlog filter.
     * @param windowStart Inclusive Occurred_At__c lower bound (defaults to System.now() - 30 days).
     * @param windowEnd Inclusive Occurred_At__c upper bound (defaults to System.now()).
     * @param actorUsername Optional exact Responsible_Username__c filter (blank for all actors).
     * @return Up to 200 UnassignedEntryDTO rows newest-first.
     */
    @AuraEnabled(cacheable=true)
    public static List<UnassignedEntryDTO> getUnassignedEntries(DateTime windowStart, DateTime windowEnd, String actorUsername) {
        DateTime effectiveStart = resolveWindowStart(windowStart);
        DateTime effectiveEnd = resolveWindowEnd(windowEnd);
        String actor = normalizeActor(actorUsername);

        List<Auditr_Entry__c> entries;
        if (actor == null) {
            entries = [
                SELECT Id, Name, Occurred_At__c, Risk_Level__c, Category__c, Section__c, Action_Code__c, Responsible_Username__c, Display__c
                FROM Auditr_Entry__c
                WHERE Occurred_At__c >= :effectiveStart AND Occurred_At__c <= :effectiveEnd
                    AND Id NOT IN (SELECT Entry__c FROM Auditr_Change_Log_Item__c WHERE Entry__c != NULL)
                WITH USER_MODE ORDER BY Occurred_At__c DESC LIMIT :ENTRY_QUERY_LIMIT
            ];
        } else {
            entries = [
                SELECT Id, Name, Occurred_At__c, Risk_Level__c, Category__c, Section__c, Action_Code__c, Responsible_Username__c, Display__c
                FROM Auditr_Entry__c
                WHERE Occurred_At__c >= :effectiveStart AND Occurred_At__c <= :effectiveEnd
                    AND Responsible_Username__c = :actor
                    AND Id NOT IN (SELECT Entry__c FROM Auditr_Change_Log_Item__c WHERE Entry__c != NULL)
                WITH USER_MODE ORDER BY Occurred_At__c DESC LIMIT :ENTRY_QUERY_LIMIT
            ];
        }

        List<UnassignedEntryDTO> rows = new List<UnassignedEntryDTO>();
        for (Auditr_Entry__c entry : entries) {
            UnassignedEntryDTO dto = new UnassignedEntryDTO();
            dto.recordId = entry.Id;
            dto.name = entry.Name;
            dto.occurredAt = entry.Occurred_At__c;
            dto.riskLevel = entry.Risk_Level__c;
            dto.category = entry.Category__c;
            dto.section = entry.Section__c;
            dto.actionCode = entry.Action_Code__c;
            dto.responsibleUsername = entry.Responsible_Username__c;
            dto.displayText = entry.Display__c;
            rows.add(dto);
        }
        return rows;
    }

    /**
     * @description Resolves user details by Id or Username for Audit Mode user lookup.
     * @param userId Optional User Id.
     * @param username Optional User Username.
     * @return UserLookupDTO with userId, name, and username, or null if not found.
     */
    @AuraEnabled(cacheable=true)
    public static UserLookupDTO resolveUser(Id userId, String username) {
        if (userId == null && String.isBlank(username)) {
            return null;
        }
        List<User> users;
        if (userId != null) {
            users = [SELECT Id, Name, Username FROM User WHERE Id = :userId WITH USER_MODE LIMIT 1];
        } else {
            String cleanUsername = username.trim();
            users = [SELECT Id, Name, Username FROM User WHERE Username = :cleanUsername WITH USER_MODE LIMIT 1];
        }
        if (users.isEmpty()) {
            return null;
        }
        UserLookupDTO dto = new UserLookupDTO();
        dto.userId = users[0].Id;
        dto.name = users[0].Name;
        dto.username = users[0].Username;
        return dto;
    }

    /**
     * @description Returns all audit entries matching the window, actor, and risk criteria, with packaging citations.
     * @param windowStart Inclusive Occurred_At__c lower bound (defaults to System.now() - 30 days).
     * @param windowEnd Inclusive Occurred_At__c upper bound (defaults to System.now()).
     * @param actorUsername Optional exact Responsible_Username__c filter.
     * @param highRiskOnly When true, filters to Critical and High risk entries only.
     * @return Up to 200 AuditEntryDTO rows newest-first.
     */
    @AuraEnabled(cacheable=true)
    public static List<AuditEntryDTO> getAuditEntries(DateTime windowStart, DateTime windowEnd, String actorUsername, Boolean highRiskOnly) {
        DateTime effectiveStart = resolveWindowStart(windowStart);
        DateTime effectiveEnd = resolveWindowEnd(windowEnd);
        String actor = normalizeActor(actorUsername);
        List<String> allowedRisks = (highRiskOnly == true) ? new List<String>{ 'Critical', 'High' } : null;

        List<Auditr_Entry__c> entries;
        if (actor == null && allowedRisks == null) {
            entries = [
                SELECT Id, Name, Occurred_At__c, Risk_Level__c, Category__c, Section__c, Action_Code__c, Responsible_Username__c, Delegate_User__c, Display__c,
                       (SELECT Id, Change_Log__c, Change_Log__r.Name, Change_Log__r.Change_Request_Id__c, Change_Log__r.Status__c FROM Auditr_Change_Log_Items__r ORDER BY CreatedDate DESC LIMIT 1)
                FROM Auditr_Entry__c
                WHERE Occurred_At__c >= :effectiveStart AND Occurred_At__c <= :effectiveEnd
                WITH USER_MODE ORDER BY Occurred_At__c DESC LIMIT :ENTRY_QUERY_LIMIT
            ];
        } else if (actor != null && allowedRisks == null) {
            entries = [
                SELECT Id, Name, Occurred_At__c, Risk_Level__c, Category__c, Section__c, Action_Code__c, Responsible_Username__c, Delegate_User__c, Display__c,
                       (SELECT Id, Change_Log__c, Change_Log__r.Name, Change_Log__r.Change_Request_Id__c, Change_Log__r.Status__c FROM Auditr_Change_Log_Items__r ORDER BY CreatedDate DESC LIMIT 1)
                FROM Auditr_Entry__c
                WHERE Occurred_At__c >= :effectiveStart AND Occurred_At__c <= :effectiveEnd
                  AND Responsible_Username__c = :actor
                WITH USER_MODE ORDER BY Occurred_At__c DESC LIMIT :ENTRY_QUERY_LIMIT
            ];
        } else if (actor == null && allowedRisks != null) {
            entries = [
                SELECT Id, Name, Occurred_At__c, Risk_Level__c, Category__c, Section__c, Action_Code__c, Responsible_Username__c, Delegate_User__c, Display__c,
                       (SELECT Id, Change_Log__c, Change_Log__r.Name, Change_Log__r.Change_Request_Id__c, Change_Log__r.Status__c FROM Auditr_Change_Log_Items__r ORDER BY CreatedDate DESC LIMIT 1)
                FROM Auditr_Entry__c
                WHERE Occurred_At__c >= :effectiveStart AND Occurred_At__c <= :effectiveEnd
                  AND Risk_Level__c IN :allowedRisks
                WITH USER_MODE ORDER BY Occurred_At__c DESC LIMIT :ENTRY_QUERY_LIMIT
            ];
        } else {
            entries = [
                SELECT Id, Name, Occurred_At__c, Risk_Level__c, Category__c, Section__c, Action_Code__c, Responsible_Username__c, Delegate_User__c, Display__c,
                       (SELECT Id, Change_Log__c, Change_Log__r.Name, Change_Log__r.Change_Request_Id__c, Change_Log__r.Status__c FROM Auditr_Change_Log_Items__r ORDER BY CreatedDate DESC LIMIT 1)
                FROM Auditr_Entry__c
                WHERE Occurred_At__c >= :effectiveStart AND Occurred_At__c <= :effectiveEnd
                  AND Responsible_Username__c = :actor
                  AND Risk_Level__c IN :allowedRisks
                WITH USER_MODE ORDER BY Occurred_At__c DESC LIMIT :ENTRY_QUERY_LIMIT
            ];
        }

        List<AuditEntryDTO> rows = new List<AuditEntryDTO>();
        for (Auditr_Entry__c entry : entries) {
            AuditEntryDTO dto = new AuditEntryDTO();
            dto.recordId = entry.Id;
            dto.name = entry.Name;
            dto.occurredAt = entry.Occurred_At__c;
            dto.riskLevel = entry.Risk_Level__c;
            dto.category = entry.Category__c;
            dto.section = entry.Section__c;
            dto.actionCode = entry.Action_Code__c;
            dto.responsibleUsername = entry.Responsible_Username__c;
            dto.delegateUser = entry.Delegate_User__c;
            dto.displayText = entry.Display__c;
            if (!entry.Auditr_Change_Log_Items__r.isEmpty()) {
                dto.isPackaged = true;
                dto.changeLogId = entry.Auditr_Change_Log_Items__r[0].Change_Log__c;
                dto.changeLogName = entry.Auditr_Change_Log_Items__r[0].Change_Log__r.Name;
                dto.changeRequestId = entry.Auditr_Change_Log_Items__r[0].Change_Log__r.Change_Request_Id__c;
            } else {
                dto.isPackaged = false;
                dto.changeLogId = null;
                dto.changeLogName = null;
                dto.changeRequestId = null;
            }
            rows.add(dto);
        }
        return rows;
    }

    /**
     * @description Searches open Draft change logs by Change Request Id or Name for the packaging modal.
     * @param searchTerm Optional substring search on Change_Request_Id__c or Name.
     * @return Up to 20 matching ChangeLogDTO records.
     */
    @AuraEnabled(cacheable=true)
    public static List<ChangeLogDTO> searchDraftChangeLogs(String searchTerm) {
        String clean = (searchTerm == null) ? '' : searchTerm.trim();
        List<Auditr_Change_Log__c> records;
        if (String.isBlank(clean)) {
            records = [
                SELECT Id, Name, Change_Request_Id__c, Status__c, Target_Actor__c, Window_Start__c, Window_End__c,
                       Deployment_Date__c, Total_Entries__c, Signed_Off_At__c, Packaging_Job_Id__c
                FROM Auditr_Change_Log__c
                WHERE Status__c = :AuditrChangeLogTriggerHandler.STATUS_DRAFT
                WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 20
            ];
        } else {
            String pattern = '%' + String.escapeSingleQuotes(clean) + '%';
            records = [
                SELECT Id, Name, Change_Request_Id__c, Status__c, Target_Actor__c, Window_Start__c, Window_End__c,
                       Deployment_Date__c, Total_Entries__c, Signed_Off_At__c, Packaging_Job_Id__c
                FROM Auditr_Change_Log__c
                WHERE Status__c = :AuditrChangeLogTriggerHandler.STATUS_DRAFT
                  AND (Name LIKE :pattern OR Change_Request_Id__c LIKE :pattern)
                WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 20
            ];
        }

        Set<String> candidateJobIds = new Set<String>();
        for (Auditr_Change_Log__c log : records) {
            if (String.isNotBlank(log.Packaging_Job_Id__c)) {
                candidateJobIds.add(log.Packaging_Job_Id__c);
            }
        }
        Set<String> runningJobIds = queryRunningJobIds(candidateJobIds);

        List<ChangeLogDTO> logs = new List<ChangeLogDTO>();
        for (Auditr_Change_Log__c log : records) {
            ChangeLogDTO dto = new ChangeLogDTO();
            dto.recordId = log.Id;
            dto.name = log.Name;
            dto.changeRequestId = log.Change_Request_Id__c;
            dto.status = log.Status__c;
            dto.targetActor = log.Target_Actor__c;
            dto.windowStart = log.Window_Start__c;
            dto.windowEnd = log.Window_End__c;
            dto.deploymentDate = log.Deployment_Date__c;
            dto.totalEntries = Integer.valueOf(log.Total_Entries__c ?? 0);
            dto.signedOffAt = log.Signed_Off_At__c;
            dto.isPackagingInFlight = String.isNotBlank(log.Packaging_Job_Id__c) && runningJobIds.contains(log.Packaging_Job_Id__c);
            logs.add(dto);
        }
        return logs;
    }

    /**
     * @description Creates a Draft change log tied to a mandatory external Change Request Id.
     * @param changeRequestId External CR/ticket number (validated by Change_Request_Id_Format rule).
     * @param deploymentDate Optional planned/actual deployment timestamp.
     * @param description Optional business summary of the change log scope.
     * @return Id of the inserted Auditr_Change_Log__c.
     */
    @AuraEnabled
    public static Id createChangeLog(String changeRequestId, DateTime deploymentDate, String description) {
        if (String.isBlank(changeRequestId)) {
            throw createAuraException('Change Request Id is required.');
        }
        Auditr_Change_Log__c changeLog = new Auditr_Change_Log__c(
            Change_Request_Id__c = changeRequestId.trim(),
            Status__c = AuditrChangeLogTriggerHandler.STATUS_DRAFT,
            Deployment_Date__c = deploymentDate,
            Description__c = String.isBlank(description) ? null : description.trim()
        );
        try {
            Database.insert(changeLog, true, AccessLevel.USER_MODE);
        } catch (DmlException dmlError) {
            throw createAuraException(dmlError.getDmlMessage(0));
        }
        return changeLog.Id;
    }

    /**
     * @description Queues asynchronous packaging of explicitly selected entries into a Draft change log.
     * @param changeLogId Target Draft Auditr_Change_Log__c.
     * @param entryIds Explicitly selected Auditr_Entry__c Ids (1..200; for larger scopes use packageFilteredEntries).
     * @return AsyncApexJob Id of the queued AuditrChangeLogBatch.
     */
    @AuraEnabled
    public static Id packageEntries(Id changeLogId, List<Id> entryIds) {
        if (entryIds == null || entryIds.isEmpty()) {
            throw createAuraException('Select at least one audit entry to package.');
        }
        Auditr_Change_Log__c targetLog = validatePackagingTarget(changeLogId);
        Id jobId = Database.executeBatch(new AuditrChangeLogBatch(targetLog.Id, new Set<Id>(entryIds)), AuditrUtil.getBatchSize());
        stampPackagingJob(targetLog.Id, jobId);
        return jobId;
    }

    /**
     * @description Queues asynchronous packaging of every unassigned entry matching a window/actor filter into a Draft change log.
     * Stores the filter on the change log for audit reproducibility, then delegates the scope to AuditrChangeLogBatch.
     * @param changeLogId Target Draft Auditr_Change_Log__c.
     * @param windowStart Inclusive Occurred_At__c lower bound (defaults to System.now() - 30 days).
     * @param windowEnd Inclusive Occurred_At__c upper bound (defaults to System.now()).
     * @param actorUsername Optional exact Responsible_Username__c filter (blank for all actors).
     * @return AsyncApexJob Id of the queued AuditrChangeLogBatch.
     */
    @AuraEnabled
    @SuppressWarnings('PMD.ExcessiveParameterList')
    public static Id packageFilteredEntries(Id changeLogId, DateTime windowStart, DateTime windowEnd, String actorUsername) {
        Auditr_Change_Log__c targetLog = validatePackagingTarget(changeLogId);
        targetLog.Window_Start__c = resolveWindowStart(windowStart);
        targetLog.Window_End__c = resolveWindowEnd(windowEnd);
        targetLog.Target_Actor__c = normalizeActor(actorUsername);
        try {
            Database.update(targetLog, true, AccessLevel.USER_MODE);
        } catch (DmlException dmlError) {
            throw createAuraException(dmlError.getDmlMessage(0));
        }
        Id jobId = Database.executeBatch(new AuditrChangeLogBatch(targetLog.Id), AuditrUtil.getBatchSize());
        stampPackagingJob(targetLog.Id, jobId);
        return jobId;
    }

    private static List<ChangeLogDTO> queryChangeLogs() {
        List<Auditr_Change_Log__c> records = [
            SELECT Id, Name, Change_Request_Id__c, Status__c, Target_Actor__c, Window_Start__c, Window_End__c,
                   Deployment_Date__c, Total_Entries__c, Signed_Off_At__c, Packaging_Job_Id__c
            FROM Auditr_Change_Log__c
            WITH USER_MODE ORDER BY CreatedDate DESC LIMIT :CHANGE_LOG_LIMIT
        ];
        Set<String> candidateJobIds = new Set<String>();
        for (Auditr_Change_Log__c record : records) {
            if (String.isNotBlank(record.Packaging_Job_Id__c)) {
                candidateJobIds.add(record.Packaging_Job_Id__c);
            }
        }
        Set<String> runningJobIds = queryRunningJobIds(candidateJobIds);

        List<ChangeLogDTO> logs = new List<ChangeLogDTO>();
        for (Auditr_Change_Log__c changeLog : records) {
            ChangeLogDTO dto = new ChangeLogDTO();
            dto.recordId = changeLog.Id;
            dto.name = changeLog.Name;
            dto.changeRequestId = changeLog.Change_Request_Id__c;
            dto.status = changeLog.Status__c;
            dto.targetActor = changeLog.Target_Actor__c;
            dto.windowStart = changeLog.Window_Start__c;
            dto.windowEnd = changeLog.Window_End__c;
            dto.deploymentDate = changeLog.Deployment_Date__c;
            dto.totalEntries = Integer.valueOf(changeLog.Total_Entries__c ?? 0);
            dto.signedOffAt = changeLog.Signed_Off_At__c;
            dto.isPackagingInFlight = String.isNotBlank(changeLog.Packaging_Job_Id__c) && runningJobIds.contains(changeLog.Packaging_Job_Id__c);
            logs.add(dto);
        }
        return logs;
    }

    private static Integer queryBacklogCount(DateTime effectiveStart, DateTime effectiveEnd, String actor) {
        if (actor == null) {
            return [
                SELECT COUNT() FROM Auditr_Entry__c
                WHERE Occurred_At__c >= :effectiveStart AND Occurred_At__c <= :effectiveEnd
                    AND Id NOT IN (SELECT Entry__c FROM Auditr_Change_Log_Item__c WHERE Entry__c != NULL)
                WITH USER_MODE LIMIT :BACKLOG_COUNT_CAP
            ];
        }
        return [
            SELECT COUNT() FROM Auditr_Entry__c
            WHERE Occurred_At__c >= :effectiveStart AND Occurred_At__c <= :effectiveEnd
                AND Responsible_Username__c = :actor
                AND Id NOT IN (SELECT Entry__c FROM Auditr_Change_Log_Item__c WHERE Entry__c != NULL)
            WITH USER_MODE LIMIT :BACKLOG_COUNT_CAP
        ];
    }

    private static Auditr_Change_Log__c validatePackagingTarget(Id changeLogId) {
        if (!Schema.sObjectType.Auditr_Change_Log__c.isUpdateable() || !Schema.sObjectType.Auditr_Change_Log_Item__c.isCreateable()) {
            throw createAuraException(ERROR_INSUFFICIENT_ACCESS);
        }
        if (changeLogId == null) {
            throw createAuraException('Select a change log to package into.');
        }
        List<Auditr_Change_Log__c> logs = [
            SELECT Id, Status__c, Packaging_Job_Id__c
            FROM Auditr_Change_Log__c WHERE Id = :changeLogId WITH USER_MODE LIMIT 1
        ];
        if (logs.isEmpty()) {
            throw createAuraException('Change log not found or not accessible.');
        }
        Auditr_Change_Log__c targetLog = logs[0];
        if (targetLog.Status__c != AuditrChangeLogTriggerHandler.STATUS_DRAFT) {
            throw createAuraException(ERROR_LOG_NOT_DRAFT);
        }
        if (String.isNotBlank(targetLog.Packaging_Job_Id__c) && !queryRunningJobIds(new Set<String>{ targetLog.Packaging_Job_Id__c }).isEmpty()) {
            throw createAuraException(ERROR_PACKAGING_IN_FLIGHT);
        }
        return targetLog;
    }

    private static Set<String> queryRunningJobIds(Set<String> jobIds) {
        Set<String> runningIds = new Set<String>();
        if (jobIds.isEmpty()) {
            return runningIds;
        }
        for (AsyncApexJob job : [
            SELECT Id FROM AsyncApexJob WHERE Id IN :jobIds AND Status IN :ACTIVE_JOB_STATUSES WITH SYSTEM_MODE
        ]) {
            runningIds.add(String.valueOf(job.Id));
        }
        return runningIds;
    }

    private static void stampPackagingJob(Id changeLogId, Id jobId) {
        Database.update(
            new Auditr_Change_Log__c(Id = changeLogId, Packaging_Job_Id__c = String.valueOf(jobId)),
            false,
            AccessLevel.SYSTEM_MODE
        );
    }

    private static DateTime resolveWindowStart(DateTime windowStart) {
        return windowStart ?? System.now().addDays(-DEFAULT_WINDOW_DAYS);
    }

    private static DateTime resolveWindowEnd(DateTime windowEnd) {
        return windowEnd ?? System.now();
    }

    private static String normalizeActor(String actorUsername) {
        return String.isBlank(actorUsername) ? null : actorUsername.trim();
    }

    private static AuraHandledException createAuraException(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
