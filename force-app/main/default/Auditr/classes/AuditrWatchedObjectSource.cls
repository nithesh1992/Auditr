/**
 * @description Auditr ingestion adapter for Watched Objects using standard Salesforce Field History Tracking.
 * Reads metadata only (Id, ParentId/<Object>Id, Field, CreatedById, CreatedDate) and never selects OldValue or NewValue.
 * Consecutive rows for the same record, same user, and exact same timestamp are grouped into one Auditr_Entry__c;
 * any intervening row from another user, another record, or another timestamp flushes the open group immediately.
 */
public with sharing class AuditrWatchedObjectSource extends AuditrSource {
    public static final String DEFAULT_WATCHED_CATEGORY = 'Data & Schema';
    public static final String DEFAULT_WATCHED_RISK = 'Medium';
    public static final Integer DEFAULT_LOGIN_AS_MAX_MINUTES = 120;

    @TestVisible private static List<Auditr_Watched_Object__mdt> testWatchedObjectsOverride;
    @TestVisible private static List<LoginAsWindow> testLoginAsWindowsOverride;

    /** @description Time window representing an active Login-As impersonation session correlated from Setup Audit Trail. */
    public class LoginAsWindow {
        public Id actorId;
        public String actorUsername;
        public String delegateUser;
        public DateTime startAt;
        public DateTime endAt;

        /**
         * @description Constructs a Login-As correlation window.
         * @param actorId Impersonated user ID.
         * @param actorUsername Impersonated username.
         * @param delegateUser Admin/support username who performed the Login-As action.
         * @param startAt Session start timestamp (suOrgAdminLogin / suNetworkAdminLogin).
         * @param endAt Session end timestamp (suOrgAdminLogout / suNetworkAdminLogout or fallback timeout).
         */
        @SuppressWarnings('PMD.ExcessiveParameterList')
        public LoginAsWindow(
            Id actorId,
            String actorUsername,
            String delegateUser,
            DateTime startAt,
            DateTime endAt
        ) {
            this.actorId = actorId;
            this.actorUsername = actorUsername;
            this.delegateUser = delegateUser;
            this.startAt = startAt;
            this.endAt = endAt;
        }

        /**
         * @description Checks whether a history event for the given actor and timestamp falls inside this Login-As window.
         * @param candidateActorId Actor User ID from the Field History row.
         * @param candidateActorUsername Actor Username from the Field History row.
         * @param occurredAt Timestamp of the Field History row.
         * @return True when the event falls within [startAt, endAt] for the same impersonated user.
         */
        public Boolean matches(Id candidateActorId, String candidateActorUsername, DateTime occurredAt) {
            if (occurredAt == null || String.isBlank(this.delegateUser) || this.startAt == null || this.endAt == null) {
                return false;
            }
            if (occurredAt < this.startAt || occurredAt > this.endAt) {
                return false;
            }
            if (this.actorId != null && candidateActorId != null) {
                return this.actorId == candidateActorId;
            }
            if (String.isNotBlank(this.actorUsername) && String.isNotBlank(candidateActorUsername)) {
                return this.actorUsername.trim().equalsIgnoreCase(candidateActorUsername.trim());
            }
            return false;
        }
    }

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
         * @param fieldName API name of the changed field (or 'created').
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

    private class PendingGroup {
        public String firstHistoryId;
        public String parentId;
        public Id actorId;
        public String actorUsername;
        public DateTime occurredAt;
        public List<String> fields = new List<String>();
        private Set<String> fieldsLower = new Set<String>();

        PendingGroup(HistoryRowInput firstRow) {
            this.firstHistoryId = firstRow.historyId;
            this.parentId = firstRow.parentId;
            this.actorId = firstRow.actorId;
            this.actorUsername = firstRow.actorUsername;
            this.occurredAt = firstRow.occurredAt;
            addField(firstRow.fieldName);
        }

        Boolean isSameRun(
            String candidateParentId,
            Id candidateActorId,
            DateTime candidateOccurredAt,
            String candidateField
        ) {
            if (isCreatedEvent() || 'created'.equalsIgnoreCase(candidateField != null ? candidateField.trim() : '')) {
                return false;
            }
            return this.parentId == candidateParentId
                && this.actorId == candidateActorId
                && this.occurredAt == candidateOccurredAt;
        }

        Boolean isCreatedEvent() {
            return this.fields.size() == 1 && 'created'.equalsIgnoreCase(this.fields[0]);
        }

        void addField(String fieldName) {
            String trimmed = fieldName.trim();
            if (this.fieldsLower.add(trimmed.toLowerCase())) {
                this.fields.add(trimmed);
            }
        }
    }

    private Auditr_Watched_Object__mdt watchedConfig;
    private String objectApiName;
    private String historyObjectName;
    private String parentFieldName;
    private String defaultCategory = DEFAULT_WATCHED_CATEGORY;
    private String defaultRiskLevel = DEFAULT_WATCHED_RISK;
    private Set<String> watchedFieldsLower = new Set<String>();
    private Set<String> validFieldsLower = new Set<String>();
    private PendingGroup pendingGroup;
    private List<LoginAsWindow> cachedLoginAsWindows;

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
     * @return Completed Auditr_Entry__c records (the trailing open group stays buffered until the next chunk or flush).
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
            if (input == null || String.isBlank(input.historyId) || String.isBlank(input.parentId)
                || String.isBlank(input.fieldName) || input.occurredAt == null) {
                continue;
            }
            String canonicalField = canonicalizeFieldName(input.fieldName);
            if (pendingGroup != null
                && !pendingGroup.isSameRun(input.parentId, input.actorId, input.occurredAt, canonicalField)) {
                emitted.add(buildEntryFromGroup(pendingGroup));
                pendingGroup = null;
            }
            if (!isWatchedField(canonicalField)) {
                continue;
            }
            if (pendingGroup == null) {
                pendingGroup = new PendingGroup(new HistoryRowInput(
                    input.historyId,
                    input.parentId,
                    canonicalField,
                    input.actorId,
                    input.actorUsername,
                    input.occurredAt
                ));
            } else {
                pendingGroup.addField(canonicalField);
            }
        }
        return emitted;
    }

    /**
     * @description Emits the trailing open group after the final batch chunk.
     * @return Zero or one Auditr_Entry__c record.
     */
    public override List<Auditr_Entry__c> flush() {
        List<Auditr_Entry__c> emitted = new List<Auditr_Entry__c>();
        if (pendingGroup != null) {
            emitted.add(buildEntryFromGroup(pendingGroup));
            pendingGroup = null;
        }
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
            List<String> untrackedFields = new List<String>();

            HistoryMetadata meta = resolveHistoryMetadata(record.Object_API_Name__c);
            item.isObjectValid = meta.isObjectValid;
            item.isHistoryAvailable = meta.isHistoryAvailable;
            item.historyObjectName = meta.historyObjectName;
            Set<String> trackedLower = new Set<String>();
            if (meta.isObjectValid) {
                item.objectApiName = meta.objectApiName;
                trackedLower = trackedFieldsByObject.get(meta.objectApiName.toLowerCase()) ?? new Set<String>();
                for (String configuredField : item.watchedFields) {
                    String lowerField = configuredField.toLowerCase();
                    if (!meta.validFieldsLower.contains(lowerField)) {
                        item.missingFields.add(configuredField);
                    } else if (!Test.isRunningTest() && !trackedLower.contains(lowerField)) {
                        untrackedFields.add(configuredField);
                    }
                }
            }
            Boolean hasAnyTrackedField = Test.isRunningTest() || !trackedLower.isEmpty();
            item.isReady = item.isObjectValid && item.isHistoryAvailable && hasAnyTrackedField
                && item.missingFields.isEmpty() && untrackedFields.isEmpty();
            item.statusMessage = buildStatusMessage(item, hasAnyTrackedField, untrackedFields);
            results.add(item);
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
        String trimmed = rawObjectApiName.trim();
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        Schema.SObjectType targetType = globalDescribe.get(trimmed);
        if (targetType == null) {
            return meta;
        }
        Schema.DescribeSObjectResult targetDescribe = targetType.getDescribe();
        meta.isObjectValid = true;
        meta.objectApiName = targetDescribe.getName();
        meta.validFieldsLower.addAll(targetDescribe.fields.getMap().keySet());

        List<String> candidateHistoryNames = new List<String>();
        if (meta.objectApiName.endsWithIgnoreCase('__c')) {
            String baseName = meta.objectApiName.substring(0, meta.objectApiName.length() - 3);
            candidateHistoryNames.add(baseName + '__History');
        } else {
            candidateHistoryNames.add(meta.objectApiName + 'FieldHistory');
            candidateHistoryNames.add(meta.objectApiName + 'History');
        }

        for (String candidateName : candidateHistoryNames) {
            Schema.SObjectType historyType = globalDescribe.get(candidateName);
            if (historyType == null) {
                continue;
            }
            Schema.DescribeSObjectResult historyDescribe = historyType.getDescribe();
            Map<String, Schema.SObjectField> historyFields = historyDescribe.fields.getMap();
            if (!historyFields.containsKey('field') || !historyFields.containsKey('createddate')) {
                continue;
            }
            String parentKey = historyFields.containsKey('parentid')
                ? 'parentid'
                : (meta.objectApiName + 'Id').toLowerCase();
            if (!historyFields.containsKey(parentKey)) {
                continue;
            }
            meta.isHistoryAvailable = true;
            meta.historyObjectName = historyDescribe.getName();
            meta.parentFieldName = historyFields.get(parentKey).getDescribe().getName();
            break;
        }
        return meta;
    }

    /**
     * @description Looks up the configured default Category and Risk Level for a watched object API name.
     * @param targetObject SObject API name.
     * @return AuditrUtil.ClassificationResult with the watched object's defaults.
     */
    public static AuditrUtil.ClassificationResult getDefaultsForObject(String targetObject) {
        if (String.isNotBlank(targetObject)) {
            for (Auditr_Watched_Object__mdt record : getWatchedRegistry()) {
                if (String.isNotBlank(record.Object_API_Name__c)
                    && record.Object_API_Name__c.trim().equalsIgnoreCase(targetObject.trim())) {
                    return new AuditrUtil.ClassificationResult(
                        String.isNotBlank(record.Category__c) ? record.Category__c : DEFAULT_WATCHED_CATEGORY,
                        String.isNotBlank(record.Default_Risk_Level__c) ? record.Default_Risk_Level__c : DEFAULT_WATCHED_RISK
                    );
                }
            }
        }
        return new AuditrUtil.ClassificationResult(DEFAULT_WATCHED_CATEGORY, DEFAULT_WATCHED_RISK);
    }

    private String canonicalizeFieldName(String rawFieldName) {
        String trimmed = rawFieldName.trim();
        String lower = trimmed.toLowerCase();
        if (lower != 'created' && !validFieldsLower.contains(lower) && validFieldsLower.contains(lower + 'id')) {
            return trimmed + 'Id';
        }
        return trimmed;
    }

    private Boolean isWatchedField(String fieldName) {
        if (watchedFieldsLower.isEmpty()) {
            return true;
        }
        String normalized = fieldName.trim().toLowerCase();
        return normalized == 'created' || watchedFieldsLower.contains(normalized);
    }

    private Auditr_Entry__c buildEntryFromGroup(PendingGroup grp) {
        String resolvedObject = String.isNotBlank(objectApiName) ? objectApiName : 'UnknownObject';
        String actorUsername = String.isNotBlank(grp.actorUsername)
            ? grp.actorUsername
            : AuditrUtil.DEFAULT_ACTOR_USERNAME;
        Boolean isCreatedOnly = (grp.fields.size() == 1 && grp.fields[0].equalsIgnoreCase('created'));
        String actionCode;
        String displayText;
        if (isCreatedOnly) {
            actionCode = 'record_created';
            displayText = 'Created ' + resolvedObject + ' record (' + grp.parentId + ')';
        } else if (grp.fields.size() == 1) {
            actionCode = ('field_changed:' + grp.fields[0]).left(100);
            displayText = ('Changed ' + grp.fields[0] + ' on ' + resolvedObject + ' (' + grp.parentId + ')').left(1000);
        } else {
            actionCode = 'fields_changed:' + grp.fields.size();
            displayText = ('Changed ' + String.join(grp.fields, ', ') + ' on ' + resolvedObject + ' (' + grp.parentId + ')').left(1000);
        }
        String sectionValue = ('Watched Object: ' + resolvedObject).left(100);
        String inferredDelegate = resolveInferredDelegateUser(grp.actorId, actorUsername, grp.occurredAt);
        String responsibleUsername = String.isNotBlank(inferredDelegate) ? inferredDelegate : actorUsername;
        AuditrUtil.ClassificationResult classification = AuditrUtil.classifyWatchedObject(
            resolvedObject,
            grp.fields,
            actionCode,
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
            Action_Code__c = actionCode,
            Section__c = sectionValue,
            Category__c = classification.category,
            Risk_Level__c = classification.riskLevel,
            Display__c = displayText,
            Payload__c = JSON.serialize(payload)
        );
    }

    private void ensureLoginAsWindowsLoaded(List<HistoryRowInput> inputs) {
        if (testLoginAsWindowsOverride != null || cachedLoginAsWindows != null) {
            return;
        }
        DateTime earliest = null;
        for (HistoryRowInput input : inputs) {
            if (input != null && input.occurredAt != null && (earliest == null || input.occurredAt < earliest)) {
                earliest = input.occurredAt;
            }
        }
        DateTime queryStart = (earliest != null ? earliest : System.now()).addMinutes(-DEFAULT_LOGIN_AS_MAX_MINUTES);
        cachedLoginAsWindows = loadLoginAsWindowsSince(queryStart);
    }

    private String resolveInferredDelegateUser(Id actorId, String actorUsername, DateTime occurredAt) {
        List<LoginAsWindow> windows = (testLoginAsWindowsOverride != null)
            ? testLoginAsWindowsOverride
            : cachedLoginAsWindows;
        if (windows == null || windows.isEmpty() || occurredAt == null) {
            return null;
        }
        for (LoginAsWindow win : windows) {
            if (win != null && win.matches(actorId, actorUsername, occurredAt)) {
                return win.delegateUser;
            }
        }
        return null;
    }

    private static List<LoginAsWindow> loadLoginAsWindowsSince(DateTime queryStart) {
        List<LoginAsWindow> windows = new List<LoginAsWindow>();
        Set<String> loginActions = new Set<String>{ 'suorgadminlogin', 'sunetworkadminlogin' };
        Set<String> logoutActions = new Set<String>{ 'suorgadminlogout', 'sunetworkadminlogout' };
        Map<String, LoginAsWindow> openByActorKey = new Map<String, LoginAsWindow>();
        Set<String> seenSourceIds = new Set<String>();

        for (Auditr_Entry__c entry : [
            SELECT Source_Record_Id__c, Action_Code__c, Actor__c, Actor_Username__c, Delegate_User__c, Occurred_At__c
            FROM Auditr_Entry__c
            WHERE Source__c = :AuditrUtil.DEFAULT_SOURCE
              AND Occurred_At__c >= :queryStart
              AND Delegate_User__c != NULL
            WITH SYSTEM_MODE
            ORDER BY Occurred_At__c ASC, Name ASC
        ]) {
            if (String.isNotBlank(entry.Source_Record_Id__c)) {
                seenSourceIds.add(entry.Source_Record_Id__c);
            }
            applyLoginAsSignal(
                windows,
                openByActorKey,
                loginActions,
                logoutActions,
                entry.Action_Code__c,
                entry.Actor__c,
                entry.Actor_Username__c,
                entry.Delegate_User__c,
                entry.Occurred_At__c
            );
        }

        if (!Test.isRunningTest()) {
            for (SetupAuditTrail sat : [
                SELECT Id, Action, CreatedById, CreatedBy.Username, DelegateUser, CreatedDate
                FROM SetupAuditTrail
                WHERE CreatedDate >= :queryStart
                  AND DelegateUser != NULL
                ORDER BY CreatedDate ASC, Id ASC
            ]) {
                if (seenSourceIds.contains(String.valueOf(sat.Id))) {
                    continue;
                }
                String actorUser = (sat.CreatedBy != null) ? sat.CreatedBy.Username : null;
                applyLoginAsSignal(
                    windows,
                    openByActorKey,
                    loginActions,
                    logoutActions,
                    sat.Action,
                    sat.CreatedById,
                    actorUser,
                    sat.DelegateUser,
                    sat.CreatedDate
                );
            }
        }
        return windows;
    }

    @SuppressWarnings('PMD.ExcessiveParameterList')
    private static void applyLoginAsSignal(
        List<LoginAsWindow> windows,
        Map<String, LoginAsWindow> openByActorKey,
        Set<String> loginActions,
        Set<String> logoutActions,
        String actionCode,
        Id actorId,
        String actorUsername,
        String delegateUser,
        DateTime occurredAt
    ) {
        if (String.isBlank(delegateUser) || occurredAt == null) {
            return;
        }
        String actorKey = actorId != null
            ? String.valueOf(actorId)
            : (String.isNotBlank(actorUsername) ? actorUsername.trim().toLowerCase() : null);
        if (String.isBlank(actorKey)) {
            return;
        }
        String normalizedAction = String.isNotBlank(actionCode) ? actionCode.trim().toLowerCase() : '';
        if (loginActions.contains(normalizedAction)) {
            LoginAsWindow prevOpen = openByActorKey.get(actorKey);
            if (prevOpen != null && prevOpen.endAt > occurredAt) {
                prevOpen.endAt = occurredAt;
            }
            LoginAsWindow nextWin = new LoginAsWindow(
                actorId,
                actorUsername,
                delegateUser,
                occurredAt,
                occurredAt.addMinutes(DEFAULT_LOGIN_AS_MAX_MINUTES)
            );
            windows.add(nextWin);
            openByActorKey.put(actorKey, nextWin);
        } else if (logoutActions.contains(normalizedAction)) {
            LoginAsWindow openWin = openByActorKey.remove(actorKey);
            if (openWin != null) {
                openWin.endAt = occurredAt;
            } else {
                windows.add(new LoginAsWindow(
                    actorId,
                    actorUsername,
                    delegateUser,
                    occurredAt.addMinutes(-DEFAULT_LOGIN_AS_MAX_MINUTES),
                    occurredAt
                ));
            }
        } else {
            LoginAsWindow openWin = openByActorKey.get(actorKey);
            if (openWin == null || occurredAt > openWin.endAt) {
                LoginAsWindow activityWin = new LoginAsWindow(
                    actorId,
                    actorUsername,
                    delegateUser,
                    occurredAt.addMinutes(-5),
                    occurredAt.addMinutes(30)
                );
                windows.add(activityWin);
                openByActorKey.put(actorKey, activityWin);
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
            return 'No fields have Field History Tracking enabled on ' + item.objectApiName + '. Enable it in Object Manager -> Fields & Relationships -> Set History Tracking.';
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

    private static List<Auditr_Watched_Object__mdt> getWatchedRegistry() {
        List<Auditr_Watched_Object__mdt> records;
        if (testWatchedObjectsOverride != null) {
            records = testWatchedObjectsOverride.clone();
        } else if (Test.isRunningTest()) {
            records = new List<Auditr_Watched_Object__mdt>();
        } else {
            records = Auditr_Watched_Object__mdt.getAll().values();
        }
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
