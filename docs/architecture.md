# Architecture, Data Model & Considerations

Auditr is intentionally compact — 10 production Apex classes, 3 triggers, 5 Lightning Web Components, 3 custom objects, 1 platform event, and 2 custom metadata types — so your security and engineering teams can audit the entire codebase in minutes.

---

## Package Structure

```text
force-app/main/default/Auditr/
├── applications/    Auditr Lightning App (branded with Auditr_Logo)
├── classes/         AuditrUtil · AuditrEntryTriggerHandler · AuditrSyncBatch
│                    AuditrReclassifyBatch · AuditrPurgeBatch · AuditrController
│                    AuditrChangeLogController · AuditrChangeLogBatch
│                    AuditrChangeLogTriggerHandler · AuditrChangeLogItemTriggerHandler
│                    + 9 test classes (AuditrTestDataFactory, etc.)
├── triggers/        AuditrEntryTrigger · AuditrChangeLogTrigger · AuditrChangeLogItemTrigger
├── lwc/             auditrAtAGlance · auditrIncidentMode · auditrAuditMode
│                    auditrControlCenter · auditrRecordDetail
├── objects/         Auditr_Entry__c · Auditr_Change_Log__c · Auditr_Change_Log_Item__c
│                    Auditr_Rule__mdt · Auditr_Setting__mdt
├── layouts/         Auditr_Entry__c · Auditr_Change_Log__c · Rule/Setting layouts
├── customMetadata/  36 classification rules + Default setting
├── flexipages/      Auditr_Home · Auditr_Incident_Mode · Auditr_Audit_Mode
│                    Auditr_Control_Center · Auditr_Entry_Record_Page
├── dashboards/      Auditr_Security_Dashboard (6 components)
├── reports/         6 audit & security reports
└── permissionsets/  Auditr_Admin · Auditr_Viewer
```

---

## End-to-End Pipeline

```mermaid
flowchart LR
    SAT[("SetupAuditTrail")] -->|"AuditrSyncBatch (Watermark + 1h Overlap)"| UTIL["AuditrUtil Rule Engine (36 Auditr_Rule__mdt)"]
    UTIL -->|"Upsert by Source_Record_Id__c"| ENTRY[("Auditr_Entry__c")]
    TRIG["AuditrEntryTrigger"] -->|"Blocks Delete & Unauthorized Update"| ENTRY
    REC["AuditrReclassifyBatch"] -->|"Updates Category & Risk Only"| ENTRY
    PURGE["AuditrPurgeBatch"] -->|"Deletes > Retention_Days__c (packaged exempt)"| ENTRY
    ENTRY --> HOME["Auditr Home (At-a-Glance KPIs + Dashboard)"]
    ENTRY --> INC["Incident Mode (time-window triage)"]
    ENTRY --> AM["Audit Mode (change packaging)"]
    ENTRY --> CC["Auditr Control Center"]
    AM -->|"AuditrChangeLogBatch (async)"| ITEM[("Auditr_Change_Log_Item__c")]
    LOG[("Auditr_Change_Log__c")] -->|"1:N citations"| ITEM
    ITEM -->|"cites (M:N)"| ENTRY
```

1. **Watermark Resolution (`AuditrSyncBatch.resolveCutoffTimestamp`)**:
   - Queries the newest `Auditr_Entry__c.Occurred_At__c` where `Source__c = 'SetupAuditTrail'`.
   - Subtracts a **60-minute overlap buffer** so late-committed `SetupAuditTrail` rows are never missed across batch boundaries.
   - If no `Auditr_Entry__c` rows exist yet, falls back to `System.now().addDays(-Backfill_Days__c)`.
2. **Idempotent Upsert (`Source_Record_Id__c`)**:
   - Maps `String.valueOf(SetupAuditTrail.Id)` into `Auditr_Entry__c.Source_Record_Id__c` (`External ID`, `Unique`, `Case Insensitive`).
   - Uses `Database.upsert(entries, Auditr_Entry__c.Source_Record_Id__c, false, AccessLevel.SYSTEM_MODE)` so overlapping windows never create duplicates.
3. **Edit & Delete Protection (`AuditrEntryTrigger` & `AuditrEntryTriggerHandler`)**:
   - **`before delete`**: Blocks deletions through normal use unless `new DmlException().getStackTraceString().contains('AuditrPurgeBatch.execute')`, tying deletion directly to `AuditrPurgeBatch`'s execution context without a public static flag.
   - **`before update`**: Blocks any modification to source and attribution fields (`Source__c`, `Source_Record_Id__c`, `Occurred_At__c`, `Actor__c`, `Actor_Username__c`, `Delegate_User__c`, `Responsible_Username__c`, `Actor_Context__c`, `Action_Code__c`, `Section__c`, `Namespace_Prefix__c`, `Display__c`), allowing only `Category__c` and `Risk_Level__c` to be reclassified.

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
| **Payload** | `Payload__c` | Long Text Area(32768) | Reserved compact JSON payload for Phase 2 high-velocity sources (unused for SetupAuditTrail). |
| **Source** | `Source__c` | Picklist | Audit source (`SetupAuditTrail`; `LoginHistory` and `DataChange` reserved for Phase 2). |
| **Source Record ID** | `Source_Record_Id__c` | Text(64) (External ID, Unique) | 18-character `SetupAuditTrail.Id` used for idempotent upserts. |

`Auditr_Entry__c` also carries three record types — **Setup Audit Trail** (default for `AuditrSyncBatch`), **Login History**, and **Data Change** — as the Phase 2 multi-source ingestion foundation. For the change packaging schema, see [Audit Mode & Change Packaging](/audit-mode).

---

## Operational Considerations

- **Large Data Volume (LDV) Query Caps**: To keep `auditrAtAGlance` and `auditrControlCenter` fast even in orgs with hundreds of thousands of setup changes, KPI `COUNT()` queries apply defensive `LIMIT` caps (`25,000` for total counts, `5,000` for category/risk KPIs, and `10,000` for 30-day unclassified aggregation).
- **Asynchronous Packaging**: `AuditrChangeLogBatch` packages citations in bounded chunks with partial-success DML and per-chunk deduplication, so releases spanning 10,000+ changes never hit synchronous Apex DML limits. The workspace provides immediate feedback that the background packaging job is in flight.
- **Junction Storage Cost**: Each `Auditr_Change_Log_Item__c` citation consumes ~2 KB (unavoidable for M:N multi-audit citation). Unpackaged entries consume zero citation storage; citations are created only when compliance teams package.
- **Packaged Purge Exemption**: `AuditrPurgeBatch` excludes entries cited by any change log, so sealed compliance evidence is never deleted by retention policy.
- **Scheduled Job Ownership**: If the admin user who scheduled `Auditr_Daily_Sync` or `Auditr_Daily_Purge` is later deactivated, the Control Center displays a prominent **Health Notice** banner prompting an active admin to click **Schedule Daily Sync** or **Schedule Daily Purge**.
- **Storage Footprint**: Each `Auditr_Entry__c` record consumes standard Salesforce custom object storage (~2 KB per record). Use `Enable_Purge__c` and `Retention_Days__c` in `Auditr_Setting__mdt` to align storage usage with your compliance retention window.
