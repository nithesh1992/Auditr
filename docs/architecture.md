# Architecture, Data Model & Considerations

Auditr is intentionally compact — 14 production Apex classes, 3 triggers, 4 Lightning Web Components, 3 custom objects, 1 custom permission, and 4 custom metadata types — so your security and engineering teams can audit the entire codebase in minutes.

---

## Package Structure

```text
force-app/main/default/Auditr/
├── applications/        Auditr Lightning App (branded with Auditr_Logo)
├── classes/             AuditrSource · AuditrSetupAuditTrailSource · AuditrWatchedObjectSource
│                        AuditrLoginAsCorrelator · AuditrUtil · AuditrEntryTriggerHandler
│                        AuditrSyncBatch · AuditrReclassifyBatch · AuditrPurgeBatch
│                        AuditrController · AuditrChangeLogController · AuditrChangeLogBatch
│                        AuditrChangeLogTriggerHandler · AuditrChangeLogItemTriggerHandler
│                        + 8 test classes (AuditrSourceTest, AuditrTestDataFactory, etc.)
├── triggers/            AuditrEntryTrigger · AuditrChangeLogTrigger · AuditrChangeLogItemTrigger
├── lwc/                 auditrAtAGlance · auditrAuditMode
│                        auditrControlCenter · auditrRecordDetail
├── objects/             Auditr_Entry__c · Auditr_Change_Log__c · Auditr_Change_Log_Item__c
│                        Auditr_Source__mdt · Auditr_Watched_Object__mdt
│                        Auditr_Rule__mdt · Auditr_Setting__mdt
├── layouts/             Auditr_Entry__c · Auditr_Change_Log__c · Rule/Setting layouts
├── customMetadata/      38 classification rules + Setup_Audit_Trail source + Account_Example watched object + Default setting
├── customPermissions/   Auditr_Admin_Access
├── flexipages/          Auditr_Home · Auditr_Audit_Mode
│                        Auditr_Control_Center · Auditr_Entry_Record_Page
├── dashboards/          Auditr_Security_Dashboard (6 components)
├── reports/             6 audit & security reports
└── permissionsets/      Auditr_Admin · Auditr_Viewer
```

---

## End-to-End Pipeline

![Auditr End-to-End Pipeline](/auditr-pipeline.svg)

1. **Per-Source Watermark Resolution (`AuditrSource.resolveCutoff`)**:
   - Each active `AuditrSource` adapter (`AuditrSetupAuditTrailSource` and each active `AuditrWatchedObjectSource`) resolves its own watermark (`Occurred_At__c` scoped by `Source__c` and `Target_Object__c`) and subtracts its configured `Overlap_Hours__c` (default 48 hours).
   - If no entries exist for that source yet, falls back to `System.now().addDays(-Backfill_Days__c)`.
2. **Watched Objects Consecutive Grouping, Special Token Normalization & Login-As Correlation (`AuditrWatchedObjectSource` + `AuditrLoginAsCorrelator`)**:
   - Groups consecutive `<Object>History` rows sharing the same record, same user, and exact same timestamp within each chunk. The trailing group is flushed in `execute()`, so a failure reported by `finish()` cannot roll back its valid entries.
   - Anchors each group to its first history ID, even if that row is unwatched. A save crossing a chunk boundary becomes multiple groups, and changed replay boundaries can produce additional fragments. No cross-chunk state or per-field evidence expansion is used; grouping is not an exact save-transaction guarantee.
   - Normalizes platform-specific `<Object>History.Field` tokens (`TextName` -> `Name`, lookup tokens `Owner`/`Account` -> `OwnerId`/`AccountId`), isolates lifecycle events (`created` -> `record_created`, `accountMerged`/`contactMerged`/`leadMerged` -> `record_merged`, `locked` -> `record_locked`, `unlocked` -> `record_unlocked`), and ignores non-field noise tokens (`feedEvent`, `ownerAccepted`, `ownerAssignment`).
   - Reloads Login-As correlation for each chunk's `[earliest - 120m, latest + 120m]` range. Archived and raw Setup Audit Trail signals are deduplicated and globally sorted, with login before logout on timestamp ties. The wider upper bound includes logout-only signals whose inferred windows extend backwards. Existing display-target and active substitute `AuthSession` support is preserved.
3. **Deduplication and Partial DML (`Source_Record_Id__c`)**:
   - Maps `String.valueOf(SetupAuditTrail.Id)` into `Auditr_Entry__c.Source_Record_Id__c` (`External ID`, `Unique`, `Case Insensitive`).
   - Filters out existing IDs within each batch chunk, inserts new records via `Database.insert(newEntries, false, AccessLevel.SYSTEM_MODE)`, and inspects `Database.SaveResult[]` to record accurate successful insert counts and log any failed rows.
3. **Privilege & Permission Boundary (`Auditr_Admin_Access`)**:
   - All privileged operations (Sync Now, Reclassify, Purge, Scheduling, Change Log creation, and Packaging) are explicitly authorized by the `Auditr_Admin_Access` custom permission granted via the `Auditr_Admin` permission set.
4. **Edit & Delete Protection (`AuditrEntryTrigger` & `AuditrEntryTriggerHandler`)**:
   - **`before delete`**: Blocks deletions through normal use unless `new DmlException().getStackTraceString().contains('AuditrPurgeBatch.execute')`, tying deletion directly to `AuditrPurgeBatch`'s execution context without a public static flag.
   - **`before update`**: Blocks any modification to source and attribution fields (`Source__c`, `Source_Record_Id__c`, `Occurred_At__c`, `Actor__c`, `Actor_Username__c`, `Delegate_User__c`, `Responsible_Username__c`, `Actor_Context__c`, `Action_Code__c`, `Section__c`, `Namespace_Prefix__c`, `Display__c`), allowing only `Category__c` and `Risk_Level__c` to be reclassified.
5. **Sealing Guard Against In-Flight Packaging**:
   - New logs must start as Draft. Packaging locks the parent before checking/enqueueing work, and completion clears only its own job pointer. Sealing is blocked during active packaging; warnings and failed/aborted jobs require Sign-Off Notes. Row-level warnings commit during execution and completion, without a post-DML exception. A `Completed` packaging job alone is not proof of completeness.

---

## Data Model (`Auditr_Entry__c`)

| Field Label | API Name | Type | Description |
| :--- | :--- | :--- | :--- |
| **Audit Entry Number** | `Name` | Auto Number (`AUD-{0000000}`) | Unique human-readable audit identifier. |
| **Occurred At** | `Occurred_At__c` | Date/Time | Original `SetupAuditTrail.CreatedDate` timestamp. |
| **Risk Level** | `Risk_Level__c` | Picklist | `Critical`, `High`, `Medium`, or `Low`. |
| **Category** | `Category__c` | Picklist | `Security & Access`, `Users & Sessions`, `Code & Automation`, `Data & Schema`, `Org Preferences`, `Packages & Integrations`, or `Unclassified`. |
| **Setup Section** | `Section__c` | Text(120) | Setup section where the change occurred (defaults to `General` when blank). |
| **Action Code** | `Action_Code__c` | Text(120) | Raw `SetupAuditTrail.Action` identifier. |
| **Responsible Username** | `Responsible_Username__c` | Text(255) | Resolved actor (`Delegate_User__c` when impersonated, otherwise `Actor_Username__c`). |
| **Actor** | `Actor__c` | Lookup(`User`) | Lookup to the `CreatedById` User record. |
| **Actor Username** | `Actor_Username__c` | Text(255) | Snapshot of `CreatedBy.Username` at the time of the event (defaults to `System` for automated actions). |
| **Delegate User** | `Delegate_User__c` | Text(255) | Populated when an admin acts via *Log in As* or delegated administration. |
| **Is Impersonated** | `Is_Impersonated__c` | Formula (Checkbox) | `NOT(ISBLANK(Delegate_User__c))` — flags delegated/impersonated actions for reports and list views. |
| **Actor Context** | `Actor_Context__c` | Text(80) | `SetupAuditTrail.CreatedByContext` value. |
| **Namespace Prefix** | `Namespace_Prefix__c` | Text(80) | `SetupAuditTrail.ResponsibleNamespacePrefix` value. |
| **Display** | `Display__c` | Long Text Area(32768) | Full human-readable description of the setup change. |
| **Payload** | `Payload__c` | Long Text Area(32768) | Compact JSON metadata payload (for Watched Objects: `object`, `recordId`, `fieldCount`, `fields`, `firstHistoryId` — never field values). |
| **Source** | `Source__c` | Picklist | Audit source (`SetupAuditTrail`, `DataChange` for Watched Objects, and `LoginHistory` reserved for optional Login History adapters). |
| **Source Record ID** | `Source_Record_Id__c` | Text(18) (External ID, Unique) | 18-character source record ID (`SetupAuditTrail.Id` or first `<Object>History.Id` in a save run) used for chunk deduplication. |
| **Target Object** | `Target_Object__c` | Text(80) | SObject API name for Watched Object events (for example `Account` or `Opportunity`). |
| **Target Record ID** | `Target_Record_Id__c` | Text(18) | 18-character Salesforce record ID of the modified watched record. |

::: info Pluggable Sources & Watched Objects Privacy by Design
`AuditrWatchedObjectSource` queries history identity, parent record, field name, actor, and timestamp — **never `OldValue` or `NewValue`**. This minimizes copied data, but audit metadata is still visible org-wide to `Auditr_Viewer` through `viewAllRecords`/`viewAllFields`, irrespective of underlying business-record sharing. Approve that access boundary explicitly. Grouping is chunk-local and timestamp-based, not proof of one save transaction. Field History does not capture reads/exports or deletion events; source history removed before ingestion cannot be recovered by Auditr.
:::

---

## Operational Considerations

- **Large Data Volume (LDV) Query Caps & Bounded Table Views**: Home/Control Center retain their existing KPI caps (`25,000` total, `5,000` category/risk, `10,000` recent unclassified). Audit Mode loads 200 entries per keyset page and caps scope counts at `5,000`. Packaged counts measure cited entries directly; unassigned counts include only eligible Setup entries. **Package All Unassigned** applies the actor/date/risk filters across the full eligible scope, independently of the display/count caps.
- **Source health**: Configuration and dispatch exceptions are logged per adapter so remaining sources can proceed. The Control Center checks for any failed, aborted, or error-reporting sync job in a rolling 36-hour window, including jobs outside its ten-row display. This is a conservative recent-run warning, not a persisted cycle ledger: a later successful run does not immediately dismiss an earlier failure.
- **Replay limits**: The 48-hour overlap supports ordinary recent retries, not guaranteed recovery of older backfill failures. No retry-ledger object is maintained.
- **Full metadata configuration**: Source `Options__c` and watched `Watched_Fields__c` are loaded through cached SOQL, avoiding `getAll()`'s 255-character long-text truncation.
- **Asynchronous Packaging**: `AuditrChangeLogBatch` packages citations in bounded chunks with partial-success DML and per-chunk deduplication, so releases spanning 10,000+ changes never hit synchronous Apex DML limits. The workspace provides immediate feedback that the background packaging job is in flight. Sealed change logs are protected against in-flight packaging races.
- **Junction Storage Cost**: Each `Auditr_Change_Log_Item__c` citation consumes ~2 KB (unavoidable for M:N multi-audit citation). Unpackaged entries consume zero citation storage; citations are created only when compliance teams package.
- **Packaged Purge Exemption**: `AuditrPurgeBatch` excludes entries cited by any change log, so sealed compliance evidence is never deleted by retention policy.
- **Scheduled Job Ownership**: If the admin user who scheduled `Auditr_Daily_Sync` or `Auditr_Daily_Purge` is later deactivated, the Control Center displays a prominent **Health Notice** banner prompting an active admin to click **Schedule Daily Sync** or **Schedule Daily Purge**.
- **Storage Footprint**: Each `Auditr_Entry__c` record consumes standard Salesforce custom object storage (~2 KB per record). Use `Enable_Purge__c` and `Retention_Days__c` in `Auditr_Setting__mdt` to align storage usage with your compliance retention window.
