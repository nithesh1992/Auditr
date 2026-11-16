/**
 * @description Auditr ingestion adapter for Watched Objects using standard Salesforce Field History Tracking.
 * Reads metadata only (Id, ParentId/<Object>Id, Field, CreatedById, CreatedDate) and never selects OldValue or NewValue.
 * Consecutive rows for the same record, same user, and exact same timestamp are grouped into one Auditr_Entry__c;
 * any intervening row from another user, another record, or another timestamp flushes the open group immediately.
 */
public with sharing class AuditrWatchedObjectSource extends AuditrSource {
    public static final String DEFAULT_WATCHED_CATEGORY = 'Data & Schema';
    public static final String DEFAULT_WATCHED_RISK = 'Medium';

    private static final Set<String> IGNORED_HISTORY_FIELDS = new Set<String>{
        'feedevent',
        'owneraccepted',
        'ownerassignment'
    };
    private static final Set<String> MERGE_HISTORY_FIELDS = new Set<String>{
        'accountmerged',
        'contactmerged',
        'leadmerged'
    };
    private static final Set<String> ISOLATED_EVENT_TOKENS = new Set<String>{
        'created',
        'record_merged',
        'record_locked',
        'record_unlocked'
    };

    @TestVisible private static List<Auditr_Watched_Object__mdt> testWatchedObjectsOverride;
    @TestVisible private static Map<String, Set<String>> testTrackedFieldsOverride;
    private static List<Auditr_Watched_Object__mdt> cachedRegistry;

    private Auditr_Watched_Object__mdt watchedConfig;
    private String objectApiName;
    private String historyObjectName;
    private String parentFieldName;
    private String defaultCategory = DEFAULT_WATCHED_CATEGORY;
    private String defaultRiskLevel = DEFAULT_WATCHED_RISK;
    private Set<String> watchedFieldsLower = new Set<String>();
    private Set<String> validFieldsLower = new Set<String>();
    private PendingGroup pendingGroup;
    private SaveRunAnchor currentRunAnchor;
    private List<AuditrLoginAsCorrelator.LoginAsWindow> cachedLoginAsWindows;

    /** @description Resolved Field History table metadata for a watched SObject. */
    public class HistoryMetadata {
        public String objectApiName;
        public String historyObjectName;
        public String parentFieldName;
        public Boolean isObjectValid = false;
        public Boolean isHistoryAvailable = false;
        public Set<String> validFieldsLower = new Set<String>();
    }

    /** @description Normalized representation of one Field History row (metadata only, no old/new values). */
    public class HistoryRowInput {
        public String historyId;
        public String parentId;
        public String fieldName;
        public Id actorId;
        public String actorUsername;
        public DateTime occurredAt;

        /**
         * @description Constructs a normalized Field History row input.
         * @param historyId 18-character ID of the history row.
         * @param parentId 18-character ID of the modified target record.
         * @param fieldName API name of the changed field (or lifecycle token).
         * @param actorId User ID of the actor who made the change.
         * @param actorUsername Username of the actor.
         * @param occurredAt Timestamp of the history row.
         */
        @SuppressWarnings('PMD.ExcessiveParameterList')
        public HistoryRowInput(
            String historyId,
            String parentId,
            String fieldName,
            Id actorId,
            String actorUsername,
            DateTime occurredAt
        ) {
            this.historyId = historyId;
            this.parentId = parentId;
            this.fieldName = fieldName;
            this.actorId = actorId;
            this.actorUsername = actorUsername;
            this.occurredAt = occurredAt;
        }
    }

    /** @description Readiness status of a configured Auditr_Watched_Object__mdt record. */
    @SuppressWarnings('PMD.AvoidBooleanMethodParameters,PMD.ApexDoc')
    public class WatchedObjectReadiness {
        @AuraEnabled public String developerName { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String objectApiName { get; set; }
        @AuraEnabled public Boolean isActive { get; set; }
        @AuraEnabled public Boolean isObjectValid { get; set; }
        @AuraEnabled public Boolean isHistoryAvailable { get; set; }
        @AuraEnabled public String historyObjectName { get; set; }
        @AuraEnabled public String defaultRiskLevel { get; set; }
        @AuraEnabled public String category { get; set; }
        @AuraEnabled public List<String> watchedFields { get; set; }
        @AuraEnabled public List<String> missingFields { get; set; }
        @AuraEnabled public Boolean isReady { get; set; }
        @AuraEnabled public String statusMessage { get; set; }
    }

    /** @description Tracks the first history row ID of a consecutive (parentId, actorId, occurredAt) save run. */
    private class SaveRunAnchor {
        public String firstHistoryId;
        public String parentId;
        public Id actorId;
        public DateTime occurredAt;

        SaveRunAnchor(HistoryRowInput row) {
            this.firstHistoryId = row.historyId;
            this.parentId = row.parentId;
            this.actorId = row.actorId;
            this.occurredAt = row.occurredAt;
        }

        Boolean matches(HistoryRowInput row) {
            return this.parentId == row.parentId
                && this.actorId == row.actorId
                && this.occurredAt == row.occurredAt;
        }
    }

    private class PendingGroup {
        public String firstHistoryId;
        public String parentId;
        public Id actorId;
        public String actorUsername;
        public DateTime occurredAt;
        public List<String> fields = new List<String>();
        private Set<String> fieldsLower = new Set<String>();

        PendingGroup(String anchoredHistoryId, HistoryRowInput firstRow, String canonicalField) {
            this.firstHistoryId = anchoredHistoryId;
            this.parentId = firstRow.parentId;
            this.actorId = firstRow.actorId;
            this.actorUsername = firstRow.actorUsername;
            this.occurredAt = firstRow.occurredAt;
            addField(canonicalField);
        }

        Boolean isSameRun(HistoryRowInput candidate, String canonicalField) {
            if (isIsolatedEvent() || isIsolatedToken(canonicalField)) {
                return false;
            }
            return this.parentId == candidate.parentId
                && this.actorId == candidate.actorId
                && this.occurredAt == candidate.occurredAt;
        }

        Boolean isIsolatedEvent() {
            return this.fields.size() == 1 && isIsolatedToken(this.fields[0]);
        }

        void addField(String fieldName) {
            String trimmed = fieldName.trim();
            if (this.fieldsLower.add(trimmed.toLowerCase())) {
                this.fields.add(trimmed);
            }
        }
    }

    /**
     * @description Default constructor for dynamic instantiation.
     */
    public AuditrWatchedObjectSource() {
        this(null);
    }

    /**
     * @description Constructs a Watched Object source adapter from its metadata configuration.
     * @param watchedConfig Auditr_Watched_Object__mdt configuration record.
     */
    public AuditrWatchedObjectSource(Auditr_Watched_Object__mdt watchedConfig) {
        if (watchedConfig != null) {
            configureWatchedObject(watchedConfig);
        }
    }

    /**
     * @description Configures this adapter from an Auditr_Watched_Object__mdt record.
     * @param record Auditr_Watched_Object__mdt record.
     */
    public void configureWatchedObject(Auditr_Watched_Object__mdt record) {
        this.watchedConfig = record;
        this.objectApiName = (record != null && String.isNotBlank(record.Object_API_Name__c))
            ? record.Object_API_Name__c.trim()
            : null;
        this.defaultCategory = (record != null && String.isNotBlank(record.Category__c))
            ? record.Category__c
            : DEFAULT_WATCHED_CATEGORY;
        this.defaultRiskLevel = (record != null && String.isNotBlank(record.Default_Risk_Level__c))
            ? record.Default_Risk_Level__c
            : DEFAULT_WATCHED_RISK;
        this.watchedFieldsLower = parseWatchedFieldsLower(record != null ? record.Watched_Fields__c : null);
        if (String.isNotBlank(this.objectApiName)) {
            HistoryMetadata meta = resolveHistoryMetadata(this.objectApiName);
            this.objectApiName = meta.objectApiName;
            this.historyObjectName = meta.historyObjectName;
            this.parentFieldName = meta.parentFieldName;
            this.validFieldsLower = meta.validFieldsLower;
        }
    }

    /**
     * @description Identifier for logging and failure attribution (for example 'DataChange:Account').
     * @return Source key with watched object suffix.
     */
    public override String sourceKey() {
        return String.isNotBlank(objectApiName)
            ? AuditrUtil.DATA_CHANGE_SOURCE + ':' + objectApiName
            : AuditrUtil.DATA_CHANGE_SOURCE;
    }

    /**
     * @description Replay window in hours (Overlap_Hours__c on Auditr_Watched_Object__mdt, default 48).
     * @return Overlap in hours.
     */
    public override Integer overlapHours() {
        Decimal configured = (watchedConfig != null) ? watchedConfig.Overlap_Hours__c : null;
        return (configured != null && configured > 0) ? Integer.valueOf(configured) : super.overlapHours();
    }

    /**
     * @description Batch scope size (Batch_Size__c on Auditr_Watched_Object__mdt, else global Auditr Setting).
     * @return Batch scope size between 1 and 2000.
     */
    public override Integer batchSize() {
        Decimal configured = (watchedConfig != null) ? watchedConfig.Batch_Size__c : null;
        Integer size = (configured != null) ? Integer.valueOf(configured) : null;
        return (size != null && size > 0 && size <= 2000) ? size : super.batchSize();
    }

    /**
     * @description Builds the dynamic Field History query starting at the cutoff, ordered by CreatedDate ASC, Id ASC.
     * Never selects OldValue or NewValue.
     * @param cutoff Earliest CreatedDate to read.
     * @return Database.QueryLocator over the resolved <Object>History table.
     */
    public override Database.QueryLocator getQueryLocator(DateTime cutoff) {
        if (String.isBlank(historyObjectName) || String.isBlank(parentFieldName)) {
            throw new AuditrSyncBatch.AuditrSyncException(
                'Field History table is not available for watched object: ' + objectApiName
            );
        }
        String soql =
            'SELECT Id, ' + String.escapeSingleQuotes(parentFieldName) +
            ', Field, CreatedById, CreatedBy.Username, CreatedDate FROM ' +
            String.escapeSingleQuotes(historyObjectName) +
            ' WHERE CreatedDate >= :cutoff ORDER BY CreatedDate ASC, Id ASC';
        return Database.getQueryLocatorWithBinds(
            soql,
            new Map<String, Object>{ 'cutoff' => cutoff },
            AccessLevel.SYSTEM_MODE
        );
    }

    /**
     * @description Converts a chunk of <Object>History SObject rows into grouped Auditr_Entry__c records.
     * @param rows History SObject rows ordered by CreatedDate ASC, Id ASC.
     * @return Completed Auditr_Entry__c records (the trailing group is flushed by execute before it commits).
     */
    public override List<Auditr_Entry__c> toEntries(List<SObject> rows) {
        if (rows == null || rows.isEmpty()) {
            return new List<Auditr_Entry__c>();
        }
        Map<Id, String> usernameByUserId = resolveMissingUsernames(rows);
        List<HistoryRowInput> inputs = new List<HistoryRowInput>();
        String resolvedParentField = String.isNotBlank(parentFieldName) ? parentFieldName : 'ParentId';
        for (SObject row : rows) {
            Id actorId = (Id) row.get('CreatedById');
            String actorUsername = extractCreatedByUsername(row);
            if (String.isBlank(actorUsername) && actorId != null) {
                actorUsername = usernameByUserId.get(actorId);
            }
            Object rawParent = row.get(resolvedParentField);
            inputs.add(new HistoryRowInput(
                String.valueOf(row.Id),
                rawParent != null ? String.valueOf(rawParent) : null,
                String.valueOf(row.get('Field')),
                actorId,
                actorUsername,
                (DateTime) row.get('CreatedDate')
            ));
        }
        return processHistoryInputs(inputs);
    }

    /**
     * @description Processes normalized HistoryRowInput items using consecutive, unbroken grouping by
     * (parentId, actorId, occurredAt). Any change in record, user, or timestamp flushes the open group first.
     * @param inputs Ordered HistoryRowInput records.
     * @return Completed Auditr_Entry__c records.
     */
    public List<Auditr_Entry__c> processHistoryInputs(List<HistoryRowInput> inputs) {
        List<Auditr_Entry__c> emitted = new List<Auditr_Entry__c>();
        if (inputs == null || inputs.isEmpty()) {
            return emitted;
        }
        ensureLoginAsWindowsLoaded(inputs);
        for (HistoryRowInput input : inputs) {
            processSingleInput(input, emitted);
        }
        return emitted;
    }

    /**
     * @description Emits the trailing open group and clears chunk-local state before execute commits.
     * @return Zero or one Auditr_Entry__c record.
     */
    public override List<Auditr_Entry__c> flush() {
        List<Auditr_Entry__c> emitted = new List<Auditr_Entry__c>();
        if (pendingGroup != null) {
            emitted.add(buildEntryFromGroup(pendingGroup));
            pendingGroup = null;
        }
        currentRunAnchor = null;
        cachedLoginAsWindows = null;
        return emitted;
    }

    /**
     * @description Scopes the watermark query to this watched object's entries (Source__c = 'DataChange'
     * and Target_Object__c = objectApiName).
     * @return Latest ingested Auditr_Entry__c for this watched object.
     */
    protected override List<Auditr_Entry__c> queryLatestEntry() {
        return [
            SELECT Occurred_At__c, CreatedDate
            FROM Auditr_Entry__c
            WHERE Source__c = :AuditrUtil.DATA_CHANGE_SOURCE
              AND Target_Object__c = :objectApiName
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
    }

    /**
     * @description Loads all active Auditr_Watched_Object__mdt records whose Field History table is available.
     * @return List of configured AuditrWatchedObjectSource adapters ordered by DeveloperName.
     */
    public static List<AuditrSource> loadActiveWatchedObjects() {
        List<AuditrSource> adapters = new List<AuditrSource>();
        for (Auditr_Watched_Object__mdt record : getWatchedRegistry()) {
            if (record.Is_Active__c != true || String.isBlank(record.Object_API_Name__c)) {
                continue;
            }
            try {
                AuditrWatchedObjectSource adapter = new AuditrWatchedObjectSource(record);
                if (String.isBlank(adapter.historyObjectName)) {
                    System.debug(
                        LoggingLevel.ERROR,
                        'Auditr_Watched_Object__mdt.' + record.DeveloperName + ' skipped: Field History table for ' +
                        record.Object_API_Name__c + ' is not available.'
                    );
                    continue;
                }
                adapters.add(adapter);
            } catch (Exception ex) {
                System.debug(LoggingLevel.ERROR, 'Auditr_Watched_Object__mdt.' + record.DeveloperName +
                    ' could not be configured: ' + ex.getMessage());
            }
        }
        return adapters;
    }

    /**
     * @description Inspects all Auditr_Watched_Object__mdt records and verifies target object existence,
     * Field History table availability, and watched-field validity via Schema describe.
     * @return Ordered list of WatchedObjectReadiness descriptors.
     */
    public static List<WatchedObjectReadiness> getWatchedObjectReadiness() {
        List<Auditr_Watched_Object__mdt> registry = getWatchedRegistry();
        Map<String, Set<String>> trackedFieldsByObject = queryTrackedFieldsByObject(registry);
        List<WatchedObjectReadiness> results = new List<WatchedObjectReadiness>();
        for (Auditr_Watched_Object__mdt record : registry) {
            results.add(evaluateRecordReadiness(record, trackedFieldsByObject));
        }
        return results;
    }

    /**
     * @description Resolves the target SObject, its Field History table, and its parent lookup field via Schema describe.
     * @param rawObjectApiName SObject API name (for example Account, Opportunity, or Custom__c).
     * @return Populated HistoryMetadata descriptor.
     */
    public static HistoryMetadata resolveHistoryMetadata(String rawObjectApiName) {
        HistoryMetadata meta = new HistoryMetadata();
        if (String.isBlank(rawObjectApiName)) {
            return meta;
        }
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        Schema.SObjectType targetType = globalDescribe.get(rawObjectApiName.trim());
        if (targetType == null) {
            return meta;
        }
        Schema.DescribeSObjectResult targetDescribe = targetType.getDescribe();
        meta.isObjectValid = true;
        meta.objectApiName = targetDescribe.getName();
        meta.validFieldsLower.addAll(targetDescribe.fields.getMap().keySet());

        for (String candidateName : buildCandidateHistoryNames(meta.objectApiName)) {
            if (populateHistoryTableDetails(meta, globalDescribe.get(candidateName))) {
                break;
            }
        }
        return meta;
    }

    /**
     * @description Looks up the configured default Category and Risk Level for a watched object API name.
     * @param targetObject SObject API name.
     * @return AuditrUtil.ClassificationResult with the watched object's defaults.
     */
    public static AuditrUtil.ClassificationResult getDefaultsForObject(String targetObject) {
        if (String.isBlank(targetObject)) {
            return new AuditrUtil.ClassificationResult(DEFAULT_WATCHED_CATEGORY, DEFAULT_WATCHED_RISK);
        }
        for (Auditr_Watched_Object__mdt record : getWatchedRegistry()) {
            if (matchesObjectApiName(record, targetObject)) {
                return buildDefaultClassification(record);
            }
        }
        return new AuditrUtil.ClassificationResult(DEFAULT_WATCHED_CATEGORY, DEFAULT_WATCHED_RISK);
    }

    private static Boolean matchesObjectApiName(Auditr_Watched_Object__mdt record, String targetObject) {
        return record != null
            && String.isNotBlank(record.Object_API_Name__c)
            && record.Object_API_Name__c.trim().equalsIgnoreCase(targetObject.trim());
    }

    private static AuditrUtil.ClassificationResult buildDefaultClassification(Auditr_Watched_Object__mdt record) {
        String category = String.isNotBlank(record.Category__c) ? record.Category__c : DEFAULT_WATCHED_CATEGORY;
        String risk = String.isNotBlank(record.Default_Risk_Level__c) ? record.Default_Risk_Level__c : DEFAULT_WATCHED_RISK;
        return new AuditrUtil.ClassificationResult(category, risk);
    }

    private void processSingleInput(HistoryRowInput input, List<Auditr_Entry__c> emitted) {
        if (!isValidInput(input) || isIgnoredHistoryToken(input.fieldName)) {
            return;
        }
        String canonicalField = canonicalizeFieldName(input.fieldName);
        if (pendingGroup != null && !pendingGroup.isSameRun(input, canonicalField)) {
            emitted.add(buildEntryFromGroup(pendingGroup));
            pendingGroup = null;
        }
        String anchoredHistoryId = resolveSaveRunAnchorId(input, canonicalField);
        if (!isWatchedField(canonicalField)) {
            return;
        }
        if (pendingGroup == null) {
            pendingGroup = new PendingGroup(anchoredHistoryId, input, canonicalField);
        } else {
            pendingGroup.addField(canonicalField);
        }
    }

    private static Boolean isValidInput(HistoryRowInput input) {
        return input != null
            && String.isNotBlank(input.historyId)
            && String.isNotBlank(input.parentId)
            && String.isNotBlank(input.fieldName)
            && input.occurredAt != null;
    }

    private static Boolean isIgnoredHistoryToken(String rawFieldName) {
        return String.isNotBlank(rawFieldName)
            && IGNORED_HISTORY_FIELDS.contains(rawFieldName.trim().toLowerCase());
    }

    private static Boolean isIsolatedToken(String canonicalField) {
        return String.isNotBlank(canonicalField)
            && ISOLATED_EVENT_TOKENS.contains(canonicalField.trim().toLowerCase());
    }

    private String resolveSaveRunAnchorId(HistoryRowInput input, String canonicalField) {
        if (isIsolatedToken(canonicalField)) {
            currentRunAnchor = null;
            return input.historyId;
        }
        if (currentRunAnchor == null || !currentRunAnchor.matches(input)) {
            currentRunAnchor = new SaveRunAnchor(input);
        }
        return currentRunAnchor.firstHistoryId;
    }

    private String canonicalizeFieldName(String rawFieldName) {
        String trimmed = rawFieldName.trim();
        String lower = trimmed.toLowerCase();
        if (lower == 'textname') {
            return 'Name';
        }
        if (MERGE_HISTORY_FIELDS.contains(lower)) {
            return 'record_merged';
        }
        if (lower == 'locked') {
            return 'record_locked';
        }
        if (lower == 'unlocked') {
            return 'record_unlocked';
        }
        if (!isIsolatedToken(lower) && !validFieldsLower.contains(lower) && validFieldsLower.contains(lower + 'id')) {
            return trimmed + 'Id';
        }
        return trimmed;
    }

    private Boolean isWatchedField(String canonicalField) {
        if (watchedFieldsLower.isEmpty() || isIsolatedToken(canonicalField)) {
            return true;
        }
        return watchedFieldsLower.contains(canonicalField.trim().toLowerCase());
    }

    private Auditr_Entry__c buildEntryFromGroup(PendingGroup grp) {
        String resolvedObject = String.isNotBlank(objectApiName) ? objectApiName : 'UnknownObject';
        String actorUsername = String.isNotBlank(grp.actorUsername)
            ? grp.actorUsername
            : AuditrUtil.DEFAULT_ACTOR_USERNAME;
        ActionDescriptor actionDesc = buildActionDescriptor(grp, resolvedObject);
        String sectionValue = ('Watched Object: ' + resolvedObject).left(100);
        String inferredDelegate = AuditrLoginAsCorrelator.resolveDelegateUser(
            cachedLoginAsWindows,
            grp.actorId,
            actorUsername,
            grp.occurredAt
        );
        String responsibleUsername = String.isNotBlank(inferredDelegate) ? inferredDelegate : actorUsername;
        AuditrUtil.ClassificationResult classification = AuditrUtil.classifyWatchedObject(
            resolvedObject,
            grp.fields,
            actionDesc.actionCode,
            sectionValue,
            inferredDelegate,
            defaultCategory,
            defaultRiskLevel
        );
        Map<String, Object> payload = new Map<String, Object>{
            'object' => resolvedObject,
            'recordId' => grp.parentId,
            'fieldCount' => grp.fields.size(),
            'fields' => grp.fields,
            'firstHistoryId' => grp.firstHistoryId
        };
        if (String.isNotBlank(inferredDelegate)) {
            payload.put('inferredDelegateUser', inferredDelegate);
            payload.put('delegateInferredFromLoginAs', true);
        }

        return new Auditr_Entry__c(
            RecordTypeId = AuditrUtil.getDataChangeRecordTypeId(),
            Source__c = AuditrUtil.DATA_CHANGE_SOURCE,
            Source_Record_Id__c = grp.firstHistoryId,
            Target_Object__c = resolvedObject,
            Target_Record_Id__c = grp.parentId,
            Occurred_At__c = grp.occurredAt,
            Actor__c = grp.actorId,
            Actor_Username__c = actorUsername,
            Delegate_User__c = inferredDelegate,
            Responsible_Username__c = responsibleUsername,
            Action_Code__c = actionDesc.actionCode,
            Section__c = sectionValue,
            Category__c = classification.category,
            Risk_Level__c = classification.riskLevel,
            Display__c = actionDesc.displayText,
            Payload__c = JSON.serialize(payload)
        );
    }

    private class ActionDescriptor {
        public String actionCode;
        public String displayText;

        ActionDescriptor(String actionCode, String displayText) {
            this.actionCode = actionCode;
            this.displayText = displayText;
        }
    }

    private static ActionDescriptor buildActionDescriptor(PendingGroup grp, String resolvedObject) {
        if (grp.fields.size() == 1) {
            String singleToken = grp.fields[0].toLowerCase();
            if (singleToken == 'created') {
                return new ActionDescriptor(
                    'record_created',
                    'Created ' + resolvedObject + ' record (' + grp.parentId + ')'
                );
            }
            if (singleToken == 'record_merged') {
                return new ActionDescriptor(
                    'record_merged',
                    'Merged ' + resolvedObject + ' record (' + grp.parentId + ')'
                );
            }
            if (singleToken == 'record_locked') {
                return new ActionDescriptor(
                    'record_locked',
                    'Locked ' + resolvedObject + ' record (' + grp.parentId + ')'
                );
            }
            if (singleToken == 'record_unlocked') {
                return new ActionDescriptor(
                    'record_unlocked',
                    'Unlocked ' + resolvedObject + ' record (' + grp.parentId + ')'
                );
            }
            return new ActionDescriptor(
                ('field_changed:' + grp.fields[0]).left(100),
                ('Changed ' + grp.fields[0] + ' on ' + resolvedObject + ' (' + grp.parentId + ')').left(1000)
            );
        }
        return new ActionDescriptor(
            'fields_changed:' + grp.fields.size(),
            ('Changed ' + String.join(grp.fields, ', ') + ' on ' + resolvedObject + ' (' + grp.parentId + ')').left(1000)
        );
    }

    private void ensureLoginAsWindowsLoaded(List<HistoryRowInput> inputs) {
        DateTime earliest = pendingGroup?.occurredAt;
        DateTime latest = earliest;
        for (HistoryRowInput input : inputs) {
            if (input == null || input.occurredAt == null) {
                continue;
            }
            if (earliest == null || input.occurredAt < earliest) {
                earliest = input.occurredAt;
            }
            if (latest == null || input.occurredAt > latest) {
                latest = input.occurredAt;
            }
        }
        cachedLoginAsWindows = AuditrLoginAsCorrelator.loadWindowsForRange(earliest, latest);
    }

    private static List<String> buildCandidateHistoryNames(String objectApiName) {
        List<String> candidateHistoryNames = new List<String>();
        if (objectApiName.endsWithIgnoreCase('__c')) {
            String baseName = objectApiName.substring(0, objectApiName.length() - 3);
            candidateHistoryNames.add(baseName + '__History');
        } else {
            candidateHistoryNames.add(objectApiName + 'FieldHistory');
            candidateHistoryNames.add(objectApiName + 'History');
        }
        return candidateHistoryNames;
    }

    private static Boolean populateHistoryTableDetails(HistoryMetadata meta, Schema.SObjectType historyType) {
        if (historyType == null) {
            return false;
        }
        Schema.DescribeSObjectResult historyDescribe = historyType.getDescribe();
        Map<String, Schema.SObjectField> historyFields = historyDescribe.fields.getMap();
        if (!historyFields.containsKey('field') || !historyFields.containsKey('createddate')) {
            return false;
        }
        String parentKey = historyFields.containsKey('parentid')
            ? 'parentid'
            : (meta.objectApiName + 'Id').toLowerCase();
        if (!historyFields.containsKey(parentKey)) {
            return false;
        }
        meta.isHistoryAvailable = true;
        meta.historyObjectName = historyDescribe.getName();
        meta.parentFieldName = historyFields.get(parentKey).getDescribe().getName();
        return true;
    }

    private static WatchedObjectReadiness evaluateRecordReadiness(
        Auditr_Watched_Object__mdt record,
        Map<String, Set<String>> trackedFieldsByObject
    ) {
        WatchedObjectReadiness item = new WatchedObjectReadiness();
        item.developerName = record.DeveloperName;
        item.label = record.MasterLabel;
        item.objectApiName = record.Object_API_Name__c;
        item.isActive = (record.Is_Active__c == true);
        item.defaultRiskLevel = String.isNotBlank(record.Default_Risk_Level__c)
            ? record.Default_Risk_Level__c
            : DEFAULT_WATCHED_RISK;
        item.category = String.isNotBlank(record.Category__c)
            ? record.Category__c
            : DEFAULT_WATCHED_CATEGORY;
        item.watchedFields = parseWatchedFieldsDisplay(record.Watched_Fields__c);
        item.missingFields = new List<String>();

        HistoryMetadata meta = resolveHistoryMetadata(record.Object_API_Name__c);
        item.isObjectValid = meta.isObjectValid;
        item.isHistoryAvailable = meta.isHistoryAvailable;
        item.historyObjectName = meta.historyObjectName;

        List<String> untrackedFields = new List<String>();
        Set<String> trackedLower = new Set<String>();
        if (meta.isObjectValid) {
            item.objectApiName = meta.objectApiName;
            trackedLower = trackedFieldsByObject.get(meta.objectApiName.toLowerCase()) ?? new Set<String>();
            classifyConfiguredFields(item, meta.validFieldsLower, trackedLower, untrackedFields);
        }
        Boolean hasAnyTrackedField = !trackedLower.isEmpty();
        item.isReady = item.isObjectValid && item.isHistoryAvailable && hasAnyTrackedField
            && item.missingFields.isEmpty() && untrackedFields.isEmpty();
        item.statusMessage = buildStatusMessage(item, hasAnyTrackedField, untrackedFields);
        return item;
    }

    @SuppressWarnings('PMD.ExcessiveParameterList')
    private static void classifyConfiguredFields(
        WatchedObjectReadiness item,
        Set<String> validFieldsLower,
        Set<String> trackedLower,
        List<String> untrackedFields
    ) {
        for (String configuredField : item.watchedFields) {
            String lowerField = configuredField.toLowerCase();
            if (!validFieldsLower.contains(lowerField)) {
                item.missingFields.add(configuredField);
            } else if (!trackedLower.contains(lowerField)) {
                untrackedFields.add(configuredField);
            }
        }
    }

    private static String extractCreatedByUsername(SObject row) {
        try {
            SObject createdBy = row.getSObject('CreatedBy');
            if (createdBy != null && createdBy.get('Username') != null) {
                return String.valueOf(createdBy.get('Username'));
            }
        } catch (SObjectException ex) {
            return null;
        }
        return null;
    }

    private static Map<Id, String> resolveMissingUsernames(List<SObject> rows) {
        Set<Id> missingUserIds = new Set<Id>();
        for (SObject row : rows) {
            if (String.isBlank(extractCreatedByUsername(row))) {
                Id actorId = (Id) row.get('CreatedById');
                if (actorId != null) {
                    missingUserIds.add(actorId);
                }
            }
        }
        Map<Id, String> usernames = new Map<Id, String>();
        if (missingUserIds.isEmpty()) {
            return usernames;
        }
        for (User usr : [SELECT Id, Username FROM User WHERE Id IN :missingUserIds WITH SYSTEM_MODE]) {
            usernames.put(usr.Id, usr.Username);
        }
        return usernames;
    }

    private static Set<String> parseWatchedFieldsLower(String rawWatchedFields) {
        Set<String> parsed = new Set<String>();
        for (String item : parseWatchedFieldsDisplay(rawWatchedFields)) {
            parsed.add(item.toLowerCase());
        }
        return parsed;
    }

    private static List<String> parseWatchedFieldsDisplay(String rawWatchedFields) {
        List<String> fields = new List<String>();
        if (String.isBlank(rawWatchedFields)) {
            return fields;
        }
        Set<String> seenLower = new Set<String>();
        for (String token : rawWatchedFields.split('[,;\\n\\r]+')) {
            String trimmed = token.trim();
            if (String.isNotBlank(trimmed) && seenLower.add(trimmed.toLowerCase())) {
                fields.add(trimmed);
            }
        }
        return fields;
    }

    private static String buildStatusMessage(
        WatchedObjectReadiness item,
        Boolean hasAnyTrackedField,
        List<String> untrackedFields
    ) {
        if (!item.isObjectValid) {
            return 'Object "' + item.objectApiName + '" was not found in this org.';
        }
        if (!item.isHistoryAvailable || !hasAnyTrackedField) {
            return 'No fields have Field History Tracking enabled on ' + item.objectApiName +
                '. Enable it in Object Manager -> Fields & Relationships -> Set History Tracking.';
        }
        if (!item.missingFields.isEmpty()) {
            return 'Unknown field(s) on ' + item.objectApiName + ': ' + String.join(item.missingFields, ', ') + '.';
        }
        if (untrackedFields != null && !untrackedFields.isEmpty()) {
            return 'Field History Tracking is not enabled on ' + item.objectApiName + ' field(s): ' +
                String.join(untrackedFields, ', ') + '. Check them in Set History Tracking.';
        }
        return 'Ready (' + item.historyObjectName + '). All watched fields have Field History Tracking enabled.';
    }

    private static Map<String, Set<String>> queryTrackedFieldsByObject(List<Auditr_Watched_Object__mdt> records) {
        if (testTrackedFieldsOverride != null) {
            return testTrackedFieldsOverride;
        }
        Map<String, Set<String>> trackedByObj = new Map<String, Set<String>>();
        Set<String> objectNames = new Set<String>();
        for (Auditr_Watched_Object__mdt rec : records) {
            if (String.isNotBlank(rec.Object_API_Name__c)) {
                objectNames.add(rec.Object_API_Name__c.trim());
            }
        }
        if (objectNames.isEmpty()) {
            return trackedByObj;
        }
        /* sfge-disable-next-line ApexFlsViolation */
        for (FieldDefinition fd : [
            SELECT EntityDefinition.QualifiedApiName, QualifiedApiName
            FROM FieldDefinition
            WHERE EntityDefinition.QualifiedApiName IN :objectNames
              AND IsFieldHistoryTracked = true
            WITH SYSTEM_MODE
        ]) {
            String objKey = fd.EntityDefinition.QualifiedApiName.toLowerCase();
            if (!trackedByObj.containsKey(objKey)) {
                trackedByObj.put(objKey, new Set<String>());
            }
            trackedByObj.get(objKey).add(fd.QualifiedApiName.toLowerCase());
        }
        return trackedByObj;
    }

    @TestVisible
    private static List<Auditr_Watched_Object__mdt> queryWatchedRegistry() {
        return [
            SELECT DeveloperName, MasterLabel, Object_API_Name__c, Is_Active__c,
                   Watched_Fields__c, Default_Risk_Level__c, Category__c, Overlap_Hours__c, Batch_Size__c
            FROM Auditr_Watched_Object__mdt WITH SYSTEM_MODE ORDER BY DeveloperName LIMIT 200
        ];
    }

    private static List<Auditr_Watched_Object__mdt> getWatchedRegistry() {
        if (testWatchedObjectsOverride == null) {
            if (Test.isRunningTest()) {
                return new List<Auditr_Watched_Object__mdt>();
            }
            if (cachedRegistry == null) {
                // Org-wide job configuration, including the complete long-text field list.
                cachedRegistry = queryWatchedRegistry();
            }
            return cachedRegistry;
        }
        List<Auditr_Watched_Object__mdt> records = testWatchedObjectsOverride.clone();
        List<String> names = new List<String>();
        Map<String, Auditr_Watched_Object__mdt> byName = new Map<String, Auditr_Watched_Object__mdt>();
        for (Auditr_Watched_Object__mdt record : records) {
            names.add(record.DeveloperName);
            byName.put(record.DeveloperName, record);
        }
        names.sort();
        List<Auditr_Watched_Object__mdt> ordered = new List<Auditr_Watched_Object__mdt>();
        for (String name : names) {
            ordered.add(byName.get(name));
        }
        return ordered;
    }
}
