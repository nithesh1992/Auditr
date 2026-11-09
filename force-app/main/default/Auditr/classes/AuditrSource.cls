/**
 * @description Base contract for an Auditr ingestion source. Each adapter reads one platform audit object
 * (for example SetupAuditTrail) and maps its rows to Auditr_Entry__c. AuditrSyncBatch drives every adapter
 * with the same dedupe, partial-DML tracking, and failure surfacing. Adapters are registered through
 * Auditr_Source__mdt and instantiated by class name, so a new source needs no change to core classes.
 */
public with sharing abstract class AuditrSource {
    public static final Integer DEFAULT_OVERLAP_HOURS = 48;
    public static final Integer MAX_CONCURRENT_SOURCES = 25;

    @TestVisible private static List<Auditr_Source__mdt> testSourcesOverride;

    /** @description Registry record backing this adapter instance (null when constructed directly). */
    protected Auditr_Source__mdt config;

    /**
     * @description Binds the registry record to this adapter. Override to parse Options__c.
     * @param config Auditr_Source__mdt registry record.
     */
    public virtual void configure(Auditr_Source__mdt config) {
        this.config = config;
    }

    /**
     * @description Value written to Auditr_Entry__c.Source__c and used for watermarking and rule scoping.
     * @return Source key, for example 'SetupAuditTrail'.
     */
    public abstract String sourceKey();

    /**
     * @description Builds the query over the platform source starting at the supplied cutoff, ordered oldest first.
     * @param cutoff Earliest source timestamp to read.
     * @return Database.QueryLocator over the source object.
     */
    public abstract Database.QueryLocator getQueryLocator(DateTime cutoff);

    /**
     * @description Maps a chunk of source rows to unsaved Auditr_Entry__c records with a unique Source_Record_Id__c.
     * Adapters that group rows may hold an open group in instance state and emit it later.
     * @param rows Chunk of source rows returned by the query locator.
     * @return Entries to insert (duplicates are removed by the caller).
     */
    public abstract List<Auditr_Entry__c> toEntries(List<SObject> rows);

    /**
     * @description Emits entries still held in adapter state after the last chunk. Default: none.
     * @return Remaining entries to insert.
     */
    public virtual List<Auditr_Entry__c> flush() {
        return new List<Auditr_Entry__c>();
    }

    /**
     * @description Replay window in hours (Overlap_Hours__c, default 48).
     * @return Overlap in hours.
     */
    public virtual Integer overlapHours() {
        Decimal configured = (config != null) ? config.Overlap_Hours__c : null;
        return (configured != null && configured > 0) ? Integer.valueOf(configured) : DEFAULT_OVERLAP_HOURS;
    }

    /**
     * @description Batch scope for this source (Batch_Size__c, else global Auditr Setting).
     * @return Batch scope size between 1 and 2000.
     */
    public virtual Integer batchSize() {
        Decimal configured = (config != null) ? config.Batch_Size__c : null;
        Integer size = (configured != null) ? Integer.valueOf(configured) : null;
        return (size != null && size > 0 && size <= 2000) ? size : AuditrUtil.getBatchSize();
    }

    /**
     * @description Resolves the earliest timestamp to read: latest ingested Occurred_At__c for this source minus the
     * overlap (never later than now minus the overlap), or the configured backfill window on first run.
     * @return Cutoff DateTime.
     */
    public virtual DateTime resolveCutoff() {
        List<Auditr_Entry__c> latestEntries = queryLatestEntry();
        DateTime overlapFloor = System.now().addHours(-overlapHours());
        if (!latestEntries.isEmpty() && latestEntries[0].Occurred_At__c != null) {
            DateTime watermarkOverlap = latestEntries[0].Occurred_At__c.addHours(-overlapHours());
            return (watermarkOverlap < overlapFloor) ? watermarkOverlap : overlapFloor;
        }
        Decimal configuredBackfill = AuditrUtil.getSetting().Backfill_Days__c;
        Integer backfillDays = (configuredBackfill != null && configuredBackfill > 0)
            ? Integer.valueOf(configuredBackfill)
            : AuditrUtil.DEFAULT_BACKFILL_DAYS;
        return System.now().addDays(-backfillDays);
    }

    /**
     * @description Returns the most recently created entry for this source. Override to narrow the watermark scope.
     * @return Zero or one Auditr_Entry__c rows.
     */
    protected virtual List<Auditr_Entry__c> queryLatestEntry() {
        String key = sourceKey();
        return [
            SELECT Occurred_At__c, CreatedDate
            FROM Auditr_Entry__c
            WHERE Source__c = :key
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
    }

    /**
     * @description Instantiates and configures every active Auditr_Source__mdt adapter. Misconfigured records
     * (unknown class or not an AuditrSource) are skipped and logged so one bad record cannot block other sources.
     * @return Active, configured adapters ordered by DeveloperName.
     */
    public static List<AuditrSource> loadActiveSources() {
        List<AuditrSource> adapters = new List<AuditrSource>();
        for (Auditr_Source__mdt record : getRegistry()) {
            if (record.Is_Active__c != true) {
                continue;
            }
            AuditrSource adapter = instantiate(record);
            if (adapter != null) {
                adapters.add(adapter);
            }
        }
        for (AuditrSource watchedAdapter : AuditrWatchedObjectSource.loadActiveWatchedObjects()) {
            if (adapters.size() >= MAX_CONCURRENT_SOURCES) {
                System.debug(
                    LoggingLevel.WARN,
                    'AuditrSource reached MAX_CONCURRENT_SOURCES (' + MAX_CONCURRENT_SOURCES +
                    '); remaining watched objects were skipped for this dispatch.'
                );
                break;
            }
            adapters.add(watchedAdapter);
        }
        return adapters;
    }

    /**
     * @description Instantiates the adapter named in a registry record.
     * @param record Auditr_Source__mdt record.
     * @return Configured adapter, or null when the class is missing or does not extend AuditrSource.
     */
    public static AuditrSource instantiate(Auditr_Source__mdt record) {
        if (record == null || String.isBlank(record.Adapter_Class__c)) {
            return null;
        }
        Type adapterType = Type.forName(record.Adapter_Class__c.trim());
        Object candidate = (adapterType != null) ? adapterType.newInstance() : null;
        if (!(candidate instanceof AuditrSource)) {
            System.debug(
                LoggingLevel.ERROR,
                'Auditr_Source__mdt.' + record.DeveloperName + ' skipped: ' + record.Adapter_Class__c +
                ' was not found or does not extend AuditrSource.'
            );
            return null;
        }
        AuditrSource adapter = (AuditrSource) candidate;
        adapter.configure(record);
        return adapter;
    }

    /**
     * @description Returns the Setup Audit Trail adapter bound to its registry record when present.
     * @return Configured AuditrSetupAuditTrailSource.
     */
    public static AuditrSource defaultSource() {
        AuditrSource adapter = new AuditrSetupAuditTrailSource();
        for (Auditr_Source__mdt record : getRegistry()) {
            if (record.Adapter_Class__c == 'AuditrSetupAuditTrailSource') {
                adapter.configure(record);
                break;
            }
        }
        return adapter;
    }

    private static List<Auditr_Source__mdt> getRegistry() {
        List<Auditr_Source__mdt> records = (testSourcesOverride != null)
            ? testSourcesOverride.clone()
            : Auditr_Source__mdt.getAll().values();
        List<String> names = new List<String>();
        Map<String, Auditr_Source__mdt> byName = new Map<String, Auditr_Source__mdt>();
        for (Auditr_Source__mdt record : records) {
            names.add(record.DeveloperName);
            byName.put(record.DeveloperName, record);
        }
        names.sort();
        List<Auditr_Source__mdt> ordered = new List<Auditr_Source__mdt>();
        for (String name : names) {
            ordered.add(byName.get(name));
        }
        return ordered;
    }
}
