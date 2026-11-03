/**
 * @description AuraEnabled controller backing the Auditr At-a-Glance Home LWC and Control Center LWC.
 */
public with sharing class AuditrController {
    public static final String SCHEDULED_JOB_NAME = 'Auditr_Daily_Sync';
    public static final String SCHEDULED_PURGE_JOB_NAME = 'Auditr_Daily_Purge';
    public static final Integer DEFAULT_PURGE_HOUR = 3;
    private static final Integer STALE_SYNC_HOURS = 36;
    private static final Integer TOTAL_COUNT_CAP = 25000;
    private static final Integer KPI_COUNT_CAP = 5000;
    private static final Integer UNCLASSIFIED_COUNT_CAP = 10000;
    private static final Integer UNCLASSIFIED_WINDOW_DAYS = 30;
    private static final Integer RECENT_JOBS_LIMIT = 10;

    /** @description Summary KPIs for the Auditr Home At-a-Glance header. */
    public class AtAGlanceDTO {
        @AuraEnabled public Integer totalEntries;
        @AuraEnabled public Integer criticalAndHighCount;
        @AuraEnabled public Integer securityAndAccessCount;
        @AuraEnabled public Integer automationAndMetadataCount;
        @AuraEnabled public Integer impersonatedCount;
        @AuraEnabled public Integer unclassifiedCount;
        @AuraEnabled public Integer unassignedChangeCount;
        @AuraEnabled public DateTime lastSyncedOccurredAt;
    }

    /** @description Audit event entry returned by Incident Mode time-window queries. */
    public class IncidentEntryDTO {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String name;
        @AuraEnabled public DateTime occurredAt;
        @AuraEnabled public String riskLevel;
        @AuraEnabled public String category;
        @AuraEnabled public String section;
        @AuraEnabled public String actionCode;
        @AuraEnabled public String responsibleUsername;
        @AuraEnabled public String actorUsername;
        @AuraEnabled public String delegateUser;
        @AuraEnabled public String displayText;
    }

    /** @description Full operational state for the Auditr Control Center tab. */
    @SuppressWarnings('PMD.TooManyFields,PMD.ExcessivePublicCount')
    public class ControlCenterStatusDTO {
        @AuraEnabled public Boolean isActive;
        @AuraEnabled public Integer backfillDays;
        @AuraEnabled public Integer batchSize;
        @AuraEnabled public Boolean enablePurge;
        @AuraEnabled public Integer retentionDays;
        @AuraEnabled public Integer preferredSyncHour;
        @AuraEnabled public Integer totalEntries;
        @AuraEnabled public Integer unclassifiedEntries;
        @AuraEnabled public DateTime lastSyncedOccurredAt;
        @AuraEnabled public String lastSyncJobStatus;
        @AuraEnabled public DateTime lastSyncJobCompletedAt;
        @AuraEnabled public Boolean isScheduled;
        @AuraEnabled public Integer scheduledSyncHour;
        @AuraEnabled public DateTime nextFireTime;
        @AuraEnabled public String scheduleOwnerUsername;
        @AuraEnabled public Boolean isScheduleOwnerActive;
        @AuraEnabled public Boolean isPurgeScheduled;
        @AuraEnabled public Integer scheduledPurgeHour;
        @AuraEnabled public DateTime nextPurgeFireTime;
        @AuraEnabled public String purgeScheduleOwnerUsername;
        @AuraEnabled public Boolean isPurgeScheduleOwnerActive;
        @AuraEnabled public Boolean isStaleSync;
        @AuraEnabled public String healthWarning;
        @AuraEnabled public List<JobSummaryDTO> recentJobs;
        @AuraEnabled public List<RuleSummaryDTO> activeRules;
        @AuraEnabled public List<UnclassifiedActionDTO> topUnclassifiedActions;
    }

    /** @description Recent AsyncApexJob execution summary. */
    public class JobSummaryDTO {
        @AuraEnabled public Id jobId;
        @AuraEnabled public String className;
        @AuraEnabled public String status;
        @AuraEnabled public Integer jobItemsProcessed;
        @AuraEnabled public Integer totalJobItems;
        @AuraEnabled public Integer numberOfErrors;
        @AuraEnabled public DateTime createdDate;
        @AuraEnabled public DateTime completedDate;
        @AuraEnabled public String extendedStatus;
    }

    /** @description Active Auditr_Rule__mdt summary for the Control Center rule inspector. */
    public class RuleSummaryDTO {
        @AuraEnabled public String developerName;
        @AuraEnabled public String label;
        @AuraEnabled public Integer priority;
        @AuraEnabled public String matchTarget;
        @AuraEnabled public String matchOperator;
        @AuraEnabled public String matchValue;
        @AuraEnabled public String category;
        @AuraEnabled public String riskLevel;
    }

    /** @description Grouped count of Unclassified Action_Code__c + Section__c pairs. */
    public class UnclassifiedActionDTO {
        @AuraEnabled public String actionCode;
        @AuraEnabled public String section;
        @AuraEnabled public Integer entryCount;
    }

    /**
     * @description Returns high-level security KPIs for the Auditr Home At-a-Glance LWC (clamped to max 365 days with LDV-safe row caps).
     * @param windowDays Number of days to look back (1..365; defaults to 365 when <= 0, null, or > 365).
     * @return AtAGlanceDTO populated with counts and latest watermark.
     */
    @AuraEnabled(cacheable=true)
    public static AtAGlanceDTO getAtAGlanceMetrics(Integer windowDays) {
        Integer effectiveDays = (windowDays != null && windowDays > 0 && windowDays <= 365) ? windowDays : 365;
        DateTime sinceDate = System.now().addDays(-effectiveDays);
        String defaultCategory = AuditrUtil.DEFAULT_CATEGORY;
        AtAGlanceDTO metrics = new AtAGlanceDTO();
        metrics.totalEntries = [SELECT COUNT() FROM Auditr_Entry__c WHERE Occurred_At__c >= :sinceDate WITH USER_MODE LIMIT :TOTAL_COUNT_CAP];
        metrics.criticalAndHighCount = [SELECT COUNT() FROM Auditr_Entry__c WHERE Occurred_At__c >= :sinceDate AND Risk_Level__c IN ('Critical', 'High') WITH USER_MODE LIMIT :KPI_COUNT_CAP];
        metrics.securityAndAccessCount = [SELECT COUNT() FROM Auditr_Entry__c WHERE Occurred_At__c >= :sinceDate AND Category__c IN ('Security & Access', 'Users & Sessions') WITH USER_MODE LIMIT :KPI_COUNT_CAP];
        metrics.automationAndMetadataCount = [SELECT COUNT() FROM Auditr_Entry__c WHERE Occurred_At__c >= :sinceDate AND Category__c IN ('Code & Automation', 'Data & Schema') WITH USER_MODE LIMIT :KPI_COUNT_CAP];
        metrics.impersonatedCount = [SELECT COUNT() FROM Auditr_Entry__c WHERE Occurred_At__c >= :sinceDate AND Delegate_User__c != NULL WITH USER_MODE LIMIT :KPI_COUNT_CAP];
        metrics.unclassifiedCount = [SELECT COUNT() FROM Auditr_Entry__c WHERE Occurred_At__c >= :sinceDate AND Category__c = :defaultCategory WITH USER_MODE LIMIT :KPI_COUNT_CAP];
        metrics.unassignedChangeCount = [
            SELECT COUNT() FROM Auditr_Entry__c
            WHERE Occurred_At__c >= :sinceDate AND Id NOT IN (SELECT Entry__c FROM Auditr_Change_Log_Item__c WHERE Entry__c != NULL)
            WITH USER_MODE LIMIT :KPI_COUNT_CAP
        ];
        metrics.lastSyncedOccurredAt = queryLatestOccurredAt();
        return metrics;
    }

    /**
     * @description Returns the newest synced Occurred_At__c watermark for lightweight LWC consumers (Incident Mode).
     * @return Latest Auditr_Entry__c Occurred_At__c value, or null when nothing is synced.
     */
    @AuraEnabled(cacheable=true)
    public static DateTime getLatestSyncedOccurredAt() {
        return queryLatestOccurredAt();
    }

    /**
     * @description Returns chronological audit events around a specific incident timestamp (Incident Mode).
     * @param incidentTime Center timestamp of the incident (defaults to System.now() when null).
     * @param windowMinutes Plus/minus window in minutes around incidentTime (e.g., 15, 30, 60, 240).
     * @param highRiskOnly True to include only Critical and High risk events; false for all risk levels.
     * @return List of IncidentEntryDTO ordered chronologically around the incident.
     */
    @AuraEnabled(cacheable=true)
    @SuppressWarnings('PMD.AvoidBooleanMethodParameters')
    public static List<IncidentEntryDTO> getIncidentTimeline(DateTime incidentTime, Integer windowMinutes, Boolean highRiskOnly) {
        DateTime anchor = incidentTime ?? System.now();
        Integer radius = (windowMinutes != null && windowMinutes > 0 && windowMinutes <= 1440) ? windowMinutes : 30;
        DateTime windowStart = anchor.addMinutes(-radius);
        DateTime windowEnd = anchor.addMinutes(radius);
        List<String> allowedRisks = (highRiskOnly == true) ? new List<String>{ 'Critical', 'High' } : new List<String>{ 'Critical', 'High', 'Medium', 'Low' };

        List<IncidentEntryDTO> timeline = new List<IncidentEntryDTO>();
        for (Auditr_Entry__c entry : [
            SELECT Id, Name, Occurred_At__c, Risk_Level__c, Category__c, Section__c, Action_Code__c,
                   Responsible_Username__c, Actor_Username__c, Delegate_User__c, Display__c
            FROM Auditr_Entry__c
            WHERE Occurred_At__c >= :windowStart AND Occurred_At__c <= :windowEnd AND Risk_Level__c IN :allowedRisks
            WITH USER_MODE ORDER BY Occurred_At__c DESC LIMIT 100
        ]) {
            IncidentEntryDTO dto = new IncidentEntryDTO();
            dto.recordId = entry.Id;
            dto.name = entry.Name;
            dto.occurredAt = entry.Occurred_At__c;
            dto.riskLevel = entry.Risk_Level__c;
            dto.category = entry.Category__c;
            dto.section = entry.Section__c;
            dto.actionCode = entry.Action_Code__c;
            dto.responsibleUsername = entry.Responsible_Username__c;
            dto.actorUsername = entry.Actor_Username__c;
            dto.delegateUser = entry.Delegate_User__c;
            dto.displayText = entry.Display__c;
            timeline.add(dto);
        }
        return timeline;
    }

    /**
     * @description Returns full operational status, schedule health, recent jobs, active rules, and top unclassified actions (last 30 days).
     * @return ControlCenterStatusDTO for the Control Center LWC.
     */
    @AuraEnabled(cacheable=true)
    public static ControlCenterStatusDTO getControlCenterStatus() {
        Auditr_Setting__mdt setting = AuditrUtil.getSetting();
        String defaultCategory = AuditrUtil.DEFAULT_CATEGORY;
        DateTime unclassifiedCutoff = System.now().addDays(-UNCLASSIFIED_WINDOW_DAYS);

        ControlCenterStatusDTO status = new ControlCenterStatusDTO();
        status.isActive = (setting.Is_Active__c == true);
        status.backfillDays = Integer.valueOf(setting.Backfill_Days__c ?? AuditrUtil.DEFAULT_BACKFILL_DAYS);
        status.batchSize = AuditrUtil.getBatchSize();
        status.enablePurge = (setting.Enable_Purge__c == true);
        status.retentionDays = Integer.valueOf(setting.Retention_Days__c ?? 0);
        status.preferredSyncHour = Integer.valueOf(setting.Preferred_Sync_Hour__c ?? AuditrUtil.DEFAULT_SYNC_HOUR);

        status.totalEntries = [SELECT COUNT() FROM Auditr_Entry__c WHERE Source__c != NULL WITH USER_MODE LIMIT :TOTAL_COUNT_CAP];
        status.unclassifiedEntries = [
            SELECT COUNT() FROM Auditr_Entry__c
            WHERE CreatedDate >= :unclassifiedCutoff AND Category__c = :defaultCategory
            WITH USER_MODE LIMIT :UNCLASSIFIED_COUNT_CAP
        ];
        status.lastSyncedOccurredAt = queryLatestOccurredAt();

        populateScheduleStatus(status);
        status.recentJobs = queryRecentJobs(status);
        status.activeRules = buildActiveRuleSummaries();
        status.topUnclassifiedActions = queryTopUnclassifiedActions(unclassifiedCutoff, status.unclassifiedEntries);
        evaluateHealthWarning(status);
        return status;
    }

    /**
     * @description Executes AuditrSyncBatch immediately.
     * @return AsyncApexJob Id of the queued batch.
     */
    @AuraEnabled
    public static Id runSyncNow() {
        requireAdminAccess();
        return Database.executeBatch(new AuditrSyncBatch(), AuditrUtil.getBatchSize());
    }

    /**
     * @description Executes AuditrReclassifyBatch to re-evaluate existing entries against active rules.
     * @param onlyUnclassified True to re-evaluate only Unclassified rows; false to re-evaluate all rows.
     * @return AsyncApexJob Id of the queued batch.
     */
    @AuraEnabled
    @SuppressWarnings('PMD.AvoidBooleanMethodParameters')
    public static Id runReclassify(Boolean onlyUnclassified) {
        requireAdminAccess();
        return Database.executeBatch(new AuditrReclassifyBatch(onlyUnclassified != false), AuditrUtil.getBatchSize());
    }

    /**
     * @description Executes AuditrPurgeBatch to delete expired audit records based on Auditr_Setting__mdt.
     * @return AsyncApexJob Id of the queued purge batch.
     */
    @AuraEnabled
    public static Id runPurgeNow() {
        requireAdminAccess();
        return Database.executeBatch(new AuditrPurgeBatch(), AuditrUtil.getBatchSize());
    }

    /**
     * @description Schedules AuditrSyncBatch to run daily at the specified hour (0..23).
     * @param hourOfDay Hour of day (0-23); defaults to Preferred_Sync_Hour__c when null or out of range.
     * @return Scheduled CronTrigger Id.
     */
    @AuraEnabled
    public static Id scheduleDailySync(Integer hourOfDay) {
        requireAdminAccess();
        unscheduleDailySync();
        Integer targetHour = (hourOfDay != null && hourOfDay >= 0 && hourOfDay <= 23) ? hourOfDay : Integer.valueOf(AuditrUtil.getSetting().Preferred_Sync_Hour__c ?? AuditrUtil.DEFAULT_SYNC_HOUR);
        return System.schedule(SCHEDULED_JOB_NAME, '0 0 ' + targetHour + ' * * ?', new AuditrSyncBatch());
    }

    /**
     * @description Aborts any existing Auditr_Daily_Sync scheduled jobs.
     */
    @AuraEnabled
    public static void unscheduleDailySync() {
        requireAdminAccess();
        abortScheduledJobsByPrefix(SCHEDULED_JOB_NAME);
    }

    /**
     * @description Schedules AuditrPurgeBatch to run daily at the specified hour (0..23).
     * @param hourOfDay Hour of day (0-23); defaults to DEFAULT_PURGE_HOUR (3 AM) when null or out of range.
     * @return Scheduled CronTrigger Id.
     */
    @AuraEnabled
    public static Id scheduleDailyPurge(Integer hourOfDay) {
        requireAdminAccess();
        unscheduleDailyPurge();
        Integer targetHour = (hourOfDay != null && hourOfDay >= 0 && hourOfDay <= 23) ? hourOfDay : DEFAULT_PURGE_HOUR;
        return System.schedule(SCHEDULED_PURGE_JOB_NAME, '0 0 ' + targetHour + ' * * ?', new AuditrPurgeBatch());
    }

    /**
     * @description Aborts any existing Auditr_Daily_Purge scheduled jobs.
     */
    @AuraEnabled
    public static void unscheduleDailyPurge() {
        requireAdminAccess();
        abortScheduledJobsByPrefix(SCHEDULED_PURGE_JOB_NAME);
    }

    private static void requireAdminAccess() {
        if (!Schema.sObjectType.Auditr_Entry__c.isUpdateable()) {
            AuraHandledException ex = new AuraHandledException('Auditr Admin access is required for Control Center operations.');
            ex.setMessage('Auditr Admin access is required for Control Center operations.');
            throw ex;
        }
    }

    private static void abortScheduledJobsByPrefix(String jobNamePrefix) {
        String jobPattern = jobNamePrefix + '%';
        for (CronTrigger job : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE :jobPattern WITH SYSTEM_MODE]) {
            System.abortJob(job.Id);
        }
    }

    private static DateTime queryLatestOccurredAt() {
        String defaultSource = AuditrUtil.DEFAULT_SOURCE;
        List<Auditr_Entry__c> latest = [SELECT Occurred_At__c FROM Auditr_Entry__c WHERE Source__c = :defaultSource WITH USER_MODE ORDER BY Occurred_At__c DESC LIMIT 1];
        return latest.isEmpty() ? null : latest[0].Occurred_At__c;
    }

    private static void populateScheduleStatus(ControlCenterStatusDTO status) {
        CronTrigger syncJob = queryLatestScheduledJob(SCHEDULED_JOB_NAME);
        if (syncJob == null) {
            status.isScheduled = false;
            status.scheduledSyncHour = status.preferredSyncHour;
            status.isScheduleOwnerActive = true;
        } else {
            status.isScheduled = true;
            status.scheduledSyncHour = parseCronHour(syncJob.CronExpression, status.preferredSyncHour);
            status.nextFireTime = syncJob.NextFireTime;
            User syncOwner = queryUserById(syncJob.OwnerId);
            status.scheduleOwnerUsername = syncOwner?.Username;
            status.isScheduleOwnerActive = (syncOwner != null && syncOwner.IsActive);
        }

        CronTrigger purgeJob = queryLatestScheduledJob(SCHEDULED_PURGE_JOB_NAME);
        if (purgeJob == null) {
            status.isPurgeScheduled = false;
            status.scheduledPurgeHour = DEFAULT_PURGE_HOUR;
            status.isPurgeScheduleOwnerActive = true;
        } else {
            status.isPurgeScheduled = true;
            status.scheduledPurgeHour = parseCronHour(purgeJob.CronExpression, DEFAULT_PURGE_HOUR);
            status.nextPurgeFireTime = purgeJob.NextFireTime;
            User purgeOwner = queryUserById(purgeJob.OwnerId);
            status.purgeScheduleOwnerUsername = purgeOwner?.Username;
            status.isPurgeScheduleOwnerActive = (purgeOwner != null && purgeOwner.IsActive);
        }
    }

    private static CronTrigger queryLatestScheduledJob(String jobNamePrefix) {
        String jobPattern = jobNamePrefix + '%';
        List<CronTrigger> jobs = [
            SELECT Id, CronExpression, NextFireTime, OwnerId FROM CronTrigger
            WHERE CronJobDetail.Name LIKE :jobPattern AND State IN ('WAITING', 'ACQUIRED', 'EXECUTING')
            WITH SYSTEM_MODE ORDER BY CreatedDate DESC LIMIT 1
        ];
        return jobs.isEmpty() ? null : jobs[0];
    }

    private static User queryUserById(Id userId) {
        if (userId == null) {
            return null;
        }
        List<User> users = [SELECT Username, IsActive FROM User WHERE Id = :userId WITH SYSTEM_MODE LIMIT 1];
        return users.isEmpty() ? null : users[0];
    }

    private static Integer parseCronHour(String cronExpression, Integer fallbackHour) {
        if (String.isBlank(cronExpression)) {
            return fallbackHour;
        }
        List<String> parts = cronExpression.trim().split('\\s+');
        if (parts.size() >= 3 && parts[2].isNumeric()) {
            Integer parsed = Integer.valueOf(parts[2]);
            if (parsed >= 0 && parsed <= 23) {
                return parsed;
            }
        }
        return fallbackHour;
    }

    private static List<JobSummaryDTO> queryRecentJobs(ControlCenterStatusDTO status) {
        Map<Id, ApexClass> auditrClasses = new Map<Id, ApexClass>([
            SELECT Id, Name FROM ApexClass
            WHERE Name IN ('AuditrSyncBatch', 'AuditrReclassifyBatch', 'AuditrPurgeBatch', 'AuditrChangeLogBatch')
            WITH SYSTEM_MODE
        ]);
        List<JobSummaryDTO> summaries = new List<JobSummaryDTO>();
        if (auditrClasses.isEmpty()) {
            return summaries;
        }
        Id syncClassId;
        for (ApexClass cls : auditrClasses.values()) {
            if (cls.Name == 'AuditrSyncBatch') {
                syncClassId = cls.Id;
                break;
            }
        }
        for (AsyncApexJob job : [
            SELECT Id, ApexClassId, Status, JobItemsProcessed, TotalJobItems, NumberOfErrors, CreatedDate, CompletedDate, ExtendedStatus
            FROM AsyncApexJob
            WHERE ApexClassId IN :auditrClasses.keySet() AND JobType = 'BatchApex'
            WITH SYSTEM_MODE ORDER BY CreatedDate DESC LIMIT :RECENT_JOBS_LIMIT
        ]) {
            JobSummaryDTO dto = new JobSummaryDTO();
            dto.jobId = job.Id;
            dto.className = auditrClasses.get(job.ApexClassId)?.Name;
            dto.status = job.Status;
            dto.jobItemsProcessed = job.JobItemsProcessed;
            dto.totalJobItems = job.TotalJobItems;
            dto.numberOfErrors = job.NumberOfErrors;
            dto.createdDate = job.CreatedDate;
            dto.completedDate = job.CompletedDate;
            dto.extendedStatus = job.ExtendedStatus;
            summaries.add(dto);
            if (status.lastSyncJobStatus == null && job.ApexClassId == syncClassId) {
                status.lastSyncJobStatus = job.Status;
                status.lastSyncJobCompletedAt = job.CompletedDate ?? job.CreatedDate;
            }
        }
        if (status.lastSyncJobStatus == null && syncClassId != null) {
            List<AsyncApexJob> latestSyncJobs = [
                SELECT Status, CreatedDate, CompletedDate
                FROM AsyncApexJob
                WHERE ApexClassId = :syncClassId AND JobType = 'BatchApex'
                WITH SYSTEM_MODE ORDER BY CreatedDate DESC LIMIT 1
            ];
            if (!latestSyncJobs.isEmpty()) {
                status.lastSyncJobStatus = latestSyncJobs[0].Status;
                status.lastSyncJobCompletedAt = latestSyncJobs[0].CompletedDate ?? latestSyncJobs[0].CreatedDate;
            }
        }
        return summaries;
    }

    private static List<RuleSummaryDTO> buildActiveRuleSummaries() {
        List<RuleSummaryDTO> rules = new List<RuleSummaryDTO>();
        for (Auditr_Rule__mdt rule : AuditrUtil.getActiveRules()) {
            RuleSummaryDTO dto = new RuleSummaryDTO();
            dto.developerName = rule.DeveloperName;
            dto.label = rule.MasterLabel;
            dto.priority = (rule.Priority__c != null) ? Integer.valueOf(rule.Priority__c) : null;
            dto.matchTarget = rule.Match_Target__c;
            dto.matchOperator = rule.Match_Operator__c;
            dto.matchValue = rule.Match_Value__c;
            dto.category = rule.Category__c;
            dto.riskLevel = rule.Risk_Level__c;
            rules.add(dto);
        }
        return rules;
    }

    private static List<UnclassifiedActionDTO> queryTopUnclassifiedActions(DateTime cutoffDate, Integer recentUnclassifiedCount) {
        List<UnclassifiedActionDTO> actions = new List<UnclassifiedActionDTO>();
        if (recentUnclassifiedCount == null || recentUnclassifiedCount == 0 || recentUnclassifiedCount >= UNCLASSIFIED_COUNT_CAP) {
            return actions;
        }
        String defaultCategory = AuditrUtil.DEFAULT_CATEGORY;
        for (AggregateResult row : [
            SELECT Action_Code__c actionCode, Section__c sectionName, COUNT(Id) entryCount
            FROM Auditr_Entry__c
            WHERE CreatedDate >= :cutoffDate AND Category__c = :defaultCategory
            WITH USER_MODE GROUP BY Action_Code__c, Section__c ORDER BY COUNT(Id) DESC LIMIT 10
        ]) {
            UnclassifiedActionDTO dto = new UnclassifiedActionDTO();
            dto.actionCode = (String) row.get('actionCode');
            dto.section = (String) row.get('sectionName');
            dto.entryCount = (Integer) row.get('entryCount');
            actions.add(dto);
        }
        return actions;
    }

    private static void evaluateHealthWarning(ControlCenterStatusDTO status) {
        Boolean lastSyncFailed = !status.recentJobs.isEmpty() && (status.recentJobs[0].status == 'Failed' || status.recentJobs[0].numberOfErrors > 0);
        Boolean isWatermarkStale = status.lastSyncedOccurredAt == null || status.lastSyncedOccurredAt < System.now().addHours(-STALE_SYNC_HOURS);

        if (status.isScheduled && !status.isScheduleOwnerActive) {
            status.isStaleSync = true;
            status.healthWarning = 'Scheduled sync job owner (' + status.scheduleOwnerUsername + ') is inactive. Reschedule Daily Sync.';
        } else if (status.isPurgeScheduled && !status.isPurgeScheduleOwnerActive) {
            status.isStaleSync = true;
            status.healthWarning = 'Scheduled purge job owner (' + status.purgeScheduleOwnerUsername + ') is inactive. Reschedule Daily Purge.';
        } else if (lastSyncFailed) {
            status.isStaleSync = true;
            status.healthWarning = 'The most recent Auditr batch job reported errors. Inspect recent jobs below.';
        } else if (isWatermarkStale) {
            status.isStaleSync = true;
            status.healthWarning = 'Audit watermark is over 36 hours old (or initial backfill has not run). Click Sync Now.';
        } else {
            status.isStaleSync = false;
        }
    }
}