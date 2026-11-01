/**
 * @description Loads Auditr Custom Metadata, evaluates classification rules, and maps SetupAuditTrail to Auditr_Entry__c.
 */
public with sharing class AuditrUtil {
    public static final String DEFAULT_SOURCE = 'SetupAuditTrail';
    public static final String DEFAULT_ACTOR_USERNAME = 'System';
    public static final String DEFAULT_SECTION = 'General';
    public static final String DEFAULT_CATEGORY = 'Unclassified';
    public static final String DEFAULT_RISK_LEVEL = 'Low';

    public static final Integer DEFAULT_BACKFILL_DAYS = 180;
    public static final Integer DEFAULT_BATCH_SIZE = 2000;
    public static final Integer DEFAULT_SYNC_HOUR = 2;

    @TestVisible private static Auditr_Setting__mdt testSettingOverride;
    @TestVisible private static List<Auditr_Rule__mdt> testRulesOverride;
    private static List<Auditr_Rule__mdt> cachedActiveRules;

    /**
     * @description Holds the resolved Category and Risk Level for an audit event.
     */
    public class ClassificationResult {
        /** @description Resolved Category__c picklist value. */
        public String category { get; private set; }
        /** @description Resolved Risk_Level__c picklist value. */
        public String riskLevel { get; private set; }

        /**
         * @description Constructs a classification result with fallback defaults.
         * @param category Resolved Category__c value.
         * @param riskLevel Resolved Risk_Level__c value.
         */
        public ClassificationResult(String category, String riskLevel) {
            this.category = String.isNotBlank(category) ? category : DEFAULT_CATEGORY;
            this.riskLevel = String.isNotBlank(riskLevel) ? riskLevel : DEFAULT_RISK_LEVEL;
        }
    }

    private class RulePriorityComparator implements Comparator<Auditr_Rule__mdt> {
        /**
         * @description Orders rules by Priority__c ASC, then DeveloperName ASC.
         * @param firstRule First rule to compare.
         * @param secondRule Second rule to compare.
         * @return Negative, zero, or positive sort order.
         */
        public Integer compare(Auditr_Rule__mdt firstRule, Auditr_Rule__mdt secondRule) {
            Decimal firstPriority = firstRule.Priority__c ?? 99999;
            Decimal secondPriority = secondRule.Priority__c ?? 99999;
            if (firstPriority != secondPriority) {
                return (firstPriority < secondPriority) ? -1 : 1;
            }
            return (firstRule.DeveloperName ?? '').compareTo(secondRule.DeveloperName ?? '');
        }
    }

    /**
     * @description Returns the active Auditr_Setting__mdt Default record or a safe fallback instance.
     * @return Auditr_Setting__mdt configuration record.
     */
    public static Auditr_Setting__mdt getSetting() {
        return testSettingOverride ?? Auditr_Setting__mdt.getInstance('Default') ?? new Auditr_Setting__mdt(
            DeveloperName = 'Default',
            MasterLabel = 'Default',
            Is_Active__c = true,
            Backfill_Days__c = DEFAULT_BACKFILL_DAYS,
            Enable_Purge__c = false,
            Retention_Days__c = 0,
            Batch_Size__c = DEFAULT_BATCH_SIZE,
            Preferred_Sync_Hour__c = DEFAULT_SYNC_HOUR
        );
    }

    /**
     * @description Resolves a valid Batch Apex scope size (1..2000) from Auditr_Setting__mdt.
     * @return Integer batch scope size.
     */
    public static Integer getBatchSize() {
        Decimal configured = getSetting().Batch_Size__c;
        Integer size = (configured != null) ? Integer.valueOf(configured) : DEFAULT_BATCH_SIZE;
        return (size > 0 && size <= 2000) ? size : DEFAULT_BATCH_SIZE;
    }

    /**
     * @description Returns all active Auditr_Rule__mdt rules ordered by Priority__c ASC.
     * @return Ordered list of active Auditr_Rule__mdt records.
     */
    public static List<Auditr_Rule__mdt> getActiveRules() {
        if (testRulesOverride != null) {
            return filterAndSortRules(testRulesOverride);
        }
        if (cachedActiveRules == null) {
            cachedActiveRules = filterAndSortRules(Auditr_Rule__mdt.getAll().values());
        }
        return cachedActiveRules;
    }

    /**
     * @description Evaluates active Auditr_Rule__mdt rules in priority order and returns the first match.
     * @param actionCode SetupAuditTrail.Action value.
     * @param section SetupAuditTrail.Section value.
     * @param namespacePrefix SetupAuditTrail.ResponsibleNamespacePrefix value.
     * @param delegateUser SetupAuditTrail.DelegateUser value.
     * @return ClassificationResult with matched Category and Risk Level (or Unclassified / Low).
     */
    @SuppressWarnings('PMD.ExcessiveParameterList')
    public static ClassificationResult classify(String actionCode, String section, String namespacePrefix, String delegateUser) {
        for (Auditr_Rule__mdt rule : getActiveRules()) {
            String target = resolveTargetValue(rule.Match_Target__c, actionCode, section, namespacePrefix, delegateUser);
            if (matchesRule(target, rule.Match_Operator__c, rule.Match_Value__c)) {
                return new ClassificationResult(rule.Category__c, rule.Risk_Level__c);
            }
        }
        return new ClassificationResult(DEFAULT_CATEGORY, DEFAULT_RISK_LEVEL);
    }

    /**
     * @description Maps a raw SetupAuditTrail record to an Auditr_Entry__c record with classification applied.
     * @param rawAudit SetupAuditTrail record.
     * @return Populated Auditr_Entry__c record ready for insertion.
     */
    public static Auditr_Entry__c buildEntryFromAuditTrail(SetupAuditTrail rawAudit) {
        String actorUsername = (rawAudit.CreatedBy != null && String.isNotBlank(rawAudit.CreatedBy.Username))
            ? rawAudit.CreatedBy.Username
            : DEFAULT_ACTOR_USERNAME;
        String sectionValue = String.isNotBlank(rawAudit.Section) ? rawAudit.Section : DEFAULT_SECTION;
        ClassificationResult classification = classify(rawAudit.Action, sectionValue, rawAudit.ResponsibleNamespacePrefix, rawAudit.DelegateUser);

        return new Auditr_Entry__c(
            Source__c = DEFAULT_SOURCE,
            Source_Record_Id__c = String.valueOf(rawAudit.Id),
            Occurred_At__c = rawAudit.CreatedDate,
            Actor__c = rawAudit.CreatedById,
            Actor_Username__c = actorUsername,
            Delegate_User__c = rawAudit.DelegateUser,
            Responsible_Username__c = String.isNotBlank(rawAudit.DelegateUser) ? rawAudit.DelegateUser : actorUsername,
            Actor_Context__c = rawAudit.CreatedByContext,
            Actor_Issuer__c = rawAudit.CreatedByIssuer,
            Action_Code__c = rawAudit.Action,
            Section__c = sectionValue,
            Category__c = classification.category,
            Risk_Level__c = classification.riskLevel,
            Namespace_Prefix__c = rawAudit.ResponsibleNamespacePrefix,
            Display__c = rawAudit.Display
        );
    }

    private static List<Auditr_Rule__mdt> filterAndSortRules(List<Auditr_Rule__mdt> rules) {
        List<Auditr_Rule__mdt> active = new List<Auditr_Rule__mdt>();
        for (Auditr_Rule__mdt rule : rules) {
            if (rule.Is_Active__c == true) {
                active.add(rule);
            }
        }
        active.sort(new RulePriorityComparator());
        return active;
    }

    @SuppressWarnings('PMD.ExcessiveParameterList')
    private static String resolveTargetValue(String matchTarget, String actionCode, String section, String namespacePrefix, String delegateUser) {
        switch on matchTarget {
            when 'Action' { return actionCode; }
            when 'Section' { return section; }
            when 'NamespacePrefix' { return namespacePrefix; }
            when 'DelegateUser' { return delegateUser; }
            when else { return null; }
        }
    }

    private static Boolean matchesRule(String targetValue, String operatorName, String matchValue) {
        if (operatorName == 'NotBlank') {
            return String.isNotBlank(targetValue);
        }
        if (String.isBlank(targetValue) || String.isBlank(matchValue)) {
            return false;
        }
        String target = targetValue.toLowerCase();
        String pattern = matchValue.trim().toLowerCase();
        switch on operatorName {
            when 'Equals' { return target == pattern; }
            when 'Contains' { return target.contains(pattern); }
            when 'StartsWith' { return target.startsWith(pattern); }
            when else { return false; }
        }
    }
}
