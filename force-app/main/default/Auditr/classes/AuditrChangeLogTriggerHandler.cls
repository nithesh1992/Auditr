/**
 * @description Enforces the Change Log compliance lifecycle on Auditr_Change_Log__c: Draft by default,
 * sealed logs become fully immutable, sealing stamps auditor sign-off and requires packaged entries.
 */
public with sharing class AuditrChangeLogTriggerHandler {
    public static final String STATUS_DRAFT = 'Draft';
    public static final String STATUS_SEALED = 'Sealed';
    public static final String SEALED_IMMUTABLE_ERROR = 'Sealed Auditr Change Logs are immutable. Create a new change log instead of modifying a sealed one.';
    public static final String SEALED_DELETE_ERROR = 'Sealed Auditr Change Logs cannot be deleted; they are permanent compliance evidence.';
    public static final String SEAL_REQUIRES_ENTRIES_ERROR = 'A change log must contain at least one packaged entry before it can be sealed.';
    public static final String SEAL_PACKAGING_IN_FLIGHT_ERROR = 'Cannot seal an Auditr Change Log while packaging is in flight. Wait for the packaging batch to finish.';
    public static final String SEAL_PACKAGING_WARNING_REQUIRES_NOTES_ERROR = 'Cannot seal a change log with packaging failures without providing Sign-Off Notes documenting that the discrepancy was reviewed.';
    public static final String INSERT_SEALED_ERROR = 'New change logs must start as Draft. Package entries before sealing.';
    public static final String REMOVE_WARNING_ERROR = 'Packaging warnings must be retained. Document their resolution in Sign-Off Notes.';
    public static final Set<String> ACTIVE_JOB_STATUSES = new Set<String>{ 'Holding', 'Queued', 'Preparing', 'Processing' };

    @TestVisible
    private static Set<Id> testActiveJobIdsOverride;

    /**
     * @description Routes Auditr_Change_Log__c trigger execution by Trigger.operationType.
     */
    public static void run() {
        switch on Trigger.operationType {
            when BEFORE_INSERT {
                beforeInsert((List<Auditr_Change_Log__c>) Trigger.new);
            }
            when BEFORE_UPDATE {
                beforeUpdate((List<Auditr_Change_Log__c>) Trigger.new, (Map<Id, Auditr_Change_Log__c>) Trigger.oldMap);
            }
            when BEFORE_DELETE {
                beforeDelete((List<Auditr_Change_Log__c>) Trigger.old);
            }
        }
    }

    private static void beforeInsert(List<Auditr_Change_Log__c> newLogs) {
        for (Auditr_Change_Log__c changeLog : newLogs) {
            if (changeLog.Status__c == STATUS_SEALED) {
                changeLog.addError(INSERT_SEALED_ERROR);
            }
            if (String.isBlank(changeLog.Status__c)) {
                changeLog.Status__c = STATUS_DRAFT;
            }
        }
    }

    private static void beforeUpdate(List<Auditr_Change_Log__c> newLogs, Map<Id, Auditr_Change_Log__c> oldMap) {
        Map<Id, AsyncApexJob> packagingJobs = findPackagingJobs(newLogs, oldMap);
        Set<Id> activePackagingJobIds = new Set<Id>();
        Set<Id> failedPackagingJobIds = new Set<Id>();
        for (AsyncApexJob job : packagingJobs.values()) {
            if (ACTIVE_JOB_STATUSES.contains(job.Status)) {
                activePackagingJobIds.add(job.Id);
            }
            if (job.Status == 'Failed' || job.Status == 'Aborted' || job.NumberOfErrors > 0) {
                failedPackagingJobIds.add(job.Id);
            }
        }
        if (testActiveJobIdsOverride != null) {
            activePackagingJobIds.addAll(testActiveJobIdsOverride);
        }
        for (Auditr_Change_Log__c changeLog : newLogs) {
            validateAndPrepareUpdate(changeLog, oldMap.get(changeLog.Id), activePackagingJobIds, failedPackagingJobIds);
        }
    }

    @SuppressWarnings('PMD.ExcessiveParameterList')
    private static void validateAndPrepareUpdate(
        Auditr_Change_Log__c changeLog,
        Auditr_Change_Log__c previous,
        Set<Id> activePackagingJobIds,
        Set<Id> failedPackagingJobIds
    ) {
        Boolean failedJob = referencesJob(changeLog, previous, failedPackagingJobIds);
        if (failedJob && !hasPackagingWarning(changeLog)) {
            changeLog.Description__c = (
                '[PACKAGING WARNING: A packaging job failed, was aborted, or reported errors. Review its results.]\n\n' +
                (changeLog.Description__c ?? '')
            ).left(Auditr_Change_Log__c.Description__c.getDescribe().getLength());
        }
        if (previous.Status__c == STATUS_SEALED) {
            changeLog.addError(SEALED_IMMUTABLE_ERROR);
        } else if (hasPackagingWarning(previous) && !hasPackagingWarning(changeLog)) {
            changeLog.addError(REMOVE_WARNING_ERROR);
        } else if (changeLog.Status__c == STATUS_SEALED) {
            validateSealTransition(changeLog, previous, activePackagingJobIds, failedJob);
        }
    }

    @SuppressWarnings('PMD.ExcessiveParameterList')
    private static void validateSealTransition(
        Auditr_Change_Log__c changeLog,
        Auditr_Change_Log__c previous,
        Set<Id> activePackagingJobIds,
        Boolean failedJob
    ) {
        if (referencesJob(changeLog, previous, activePackagingJobIds)) {
            changeLog.addError(SEAL_PACKAGING_IN_FLIGHT_ERROR);
        } else if ((changeLog.Total_Entries__c ?? 0) <= 0) {
            changeLog.addError(SEAL_REQUIRES_ENTRIES_ERROR);
        } else if ((failedJob || hasPackagingWarning(changeLog)) && String.isBlank(changeLog.Sign_Off_Notes__c)) {
            changeLog.addError(SEAL_PACKAGING_WARNING_REQUIRES_NOTES_ERROR);
        } else {
            changeLog.Signed_Off_By__c = UserInfo.getUserId();
            changeLog.Signed_Off_At__c = System.now();
        }
    }

    private static Boolean hasPackagingWarning(Auditr_Change_Log__c changeLog) {
        return String.isNotBlank(changeLog.Description__c) && changeLog.Description__c.contains('[PACKAGING WARNING');
    }

    private static Boolean referencesJob(
        Auditr_Change_Log__c changeLog,
        Auditr_Change_Log__c previous,
        Set<Id> activePackagingJobIds
    ) {
        Id currentJobId = parseJobId(changeLog.Packaging_Job_Id__c);
        Id previousJobId = parseJobId(previous.Packaging_Job_Id__c);
        return (currentJobId != null && activePackagingJobIds.contains(currentJobId)) ||
               (previousJobId != null && activePackagingJobIds.contains(previousJobId));
    }

    private static Id parseJobId(String rawJobId) {
        if (String.isBlank(rawJobId)) {
            return null;
        }
        try {
            return (Id) rawJobId.trim();
        } catch (Exception ex) {
            return null;
        }
    }

    private static Map<Id, AsyncApexJob> findPackagingJobs(
        List<Auditr_Change_Log__c> newLogs,
        Map<Id, Auditr_Change_Log__c> oldMap
    ) {
        Set<Id> candidateJobIds = new Set<Id>();
        for (Auditr_Change_Log__c log : newLogs) {
            Auditr_Change_Log__c prev = (oldMap != null) ? oldMap.get(log.Id) : null;
            Id currentJobId = parseJobId(log.Packaging_Job_Id__c);
            Id prevJobId = (prev != null) ? parseJobId(prev.Packaging_Job_Id__c) : null;
            if (currentJobId != null) {
                candidateJobIds.add(currentJobId);
            }
            if (prevJobId != null) {
                candidateJobIds.add(prevJobId);
            }
        }

        if (candidateJobIds.isEmpty()) {
            return new Map<Id, AsyncApexJob>();
        }
        return new Map<Id, AsyncApexJob>([
            SELECT Id, Status, NumberOfErrors FROM AsyncApexJob
            WHERE Id IN :candidateJobIds WITH SYSTEM_MODE
        ]);
    }

    private static void beforeDelete(List<Auditr_Change_Log__c> oldLogs) {
        for (Auditr_Change_Log__c changeLog : oldLogs) {
            if (changeLog.Status__c == STATUS_SEALED) {
                changeLog.addError(SEALED_DELETE_ERROR);
            }
        }
    }
}
