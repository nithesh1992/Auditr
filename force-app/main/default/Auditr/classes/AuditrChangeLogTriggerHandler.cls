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
            if (String.isBlank(changeLog.Status__c)) {
                changeLog.Status__c = STATUS_DRAFT;
            }
        }
    }

    private static void beforeUpdate(List<Auditr_Change_Log__c> newLogs, Map<Id, Auditr_Change_Log__c> oldMap) {
        Set<Id> activePackagingJobIds = findActivePackagingJobIds(newLogs, oldMap);

        for (Auditr_Change_Log__c changeLog : newLogs) {
            Auditr_Change_Log__c previous = oldMap.get(changeLog.Id);
            if (previous.Status__c == STATUS_SEALED) {
                changeLog.addError(SEALED_IMMUTABLE_ERROR);
            } else if (changeLog.Status__c == STATUS_SEALED && previous.Status__c != STATUS_SEALED) {
                if (isPackagingInFlight(changeLog, previous, activePackagingJobIds)) {
                    changeLog.addError(SEAL_PACKAGING_IN_FLIGHT_ERROR);
                } else if ((changeLog.Total_Entries__c ?? 0) <= 0) {
                    changeLog.addError(SEAL_REQUIRES_ENTRIES_ERROR);
                } else if (String.isNotBlank(changeLog.Description__c) && changeLog.Description__c.contains('[PACKAGING WARNING') && String.isBlank(changeLog.Sign_Off_Notes__c)) {
                    changeLog.addError(SEAL_PACKAGING_WARNING_REQUIRES_NOTES_ERROR);
                } else {
                    changeLog.Signed_Off_By__c = UserInfo.getUserId();
                    changeLog.Signed_Off_At__c = System.now();
                }
            }
        }
    }

    private static Boolean isPackagingInFlight(
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

    private static Set<Id> findActivePackagingJobIds(
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

        Set<Id> activeJobIds = new Set<Id>();
        if (testActiveJobIdsOverride != null) {
            activeJobIds.addAll(testActiveJobIdsOverride);
        }
        if (!candidateJobIds.isEmpty()) {
            for (AsyncApexJob job : [
                SELECT Id FROM AsyncApexJob
                WHERE Id IN :candidateJobIds AND Status IN :ACTIVE_JOB_STATUSES
            ]) {
                activeJobIds.add(job.Id);
            }
        }
        return activeJobIds;
    }

    private static void beforeDelete(List<Auditr_Change_Log__c> oldLogs) {
        for (Auditr_Change_Log__c changeLog : oldLogs) {
            if (changeLog.Status__c == STATUS_SEALED) {
                changeLog.addError(SEALED_DELETE_ERROR);
            }
        }
    }
}
