<p align="center">
  <img src="assets/auditr-banner.svg" alt="Auditr — Salesforce Change &amp; Audit Tracking" width="100%" />
</p>

# Auditr for Salesforce

[![Platform: Salesforce](https://img.shields.io/badge/Platform-Salesforce-00A1E0?style=flat-square&logo=salesforce)](https://developer.salesforce.com/)
[![API Version](https://img.shields.io/badge/API-v68.0-blue?style=flat-square)](https://developer.salesforce.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)

**Long-term, classified Setup Audit Trail history inside your org.** Auditr syncs `SetupAuditTrail` into tamper-resistant `Auditr_Entry__c` records, classifies every change by risk level and category using Custom Metadata rules, and gives admins an **Incident Mode** time-window investigator, a **Control Center**, reports, and a security dashboard.

---

## What Auditr does

- **Retains Setup Audit Trail beyond 180 days.** `AuditrSyncBatch` incrementally syncs `SetupAuditTrail` using an indexed `External_Id__c` watermark (`Database.upsert(..., External_Id__c, false)`) so duplicate rows are never created.
- **Tamper-resistant records.** `AuditrEntryTrigger` blocks `before delete` entirely and blocks `before update` on every audit field except classification fields (`Category__c`, `Risk_Level__c`, `Matched_Rule__c`, `Is_Classified__c`) during an explicit `AuditrReclassifyBatch` run.
- **Metadata-driven classification.** Ships with 36 `Auditr_Rule__mdt` rules (`EXACT`, `STARTS_WITH`, `CONTAINS`, `REGEX`) evaluated in priority order across `Critical`, `High`, `Medium`, and `Low` risk levels and 6 domain categories (`Security & Access`, `Users & Sessions`, `Code & Automation`, `Data & Schema`, `Org Preferences`, `Packages & Integrations`).
- **Impersonation & delegate tracking.** Automatically computes `Is_Impersonated__c` and `Responsible_Username__c` when changes are made via delegated admin or *Log in As*.
- **At-a-Glance + Incident Mode (`auditrAtAGlance`).** 6-KPI rolling summary strip (`Total Events`, `Critical & High`, `Security & Access`, `Automation & Code`, `Impersonated`, `Unclassified`) with reader-friendly compact numbers (`25K`, `1.5M`), window filters (up to 1 year), and an expandable **Incident Mode** investigator to pinpoint changes around an exact incident timestamp.
- **Custom Read-Only Detail Component (`auditrRecordDetail`).** Enforces immutable audit provenance (Section, Action Code, Responsible Actor, Delegate User, Context, Timestamp, Display) with zero inline editing pencils, while allowing authorized admins to reclassify Risk Level & Category in a dedicated modal.
- **Field History Tracking.** Built-in field history tracking across all audit entry fields with a dedicated `Histories` tab on the record page.
- **Control Center (`auditrControlCenter`).** Run **Sync Now**, schedule daily automated sync, trigger **Reclassify Unclassified** or **Reclassify All**, inspect top unclassified setup actions (last 30 days), monitor recent batch runs, and search active classification rules.
- **Reports & Security Dashboard.** 6 pre-built reports and a 6-widget `Auditr_Security_Dashboard` embedded directly on the **Auditr Home** page.

---

## Install & Set Up

### 1. Deploy from source

```bash
sf project deploy start --source-dir force-app/main/default/SF-Auditr --target-org <alias>
```

### 2. Assign permission sets

- **`Auditr_Admin`** — Full access to the Auditr app, Control Center operations, Setup Audit Trail sync/reclassification, and read-all access to `Auditr_Entry__c`.
- **`Auditr_Viewer`** — Read-only auditor access to `Auditr_Entry__c`, Auditr Home, Incident Mode, reports, and dashboards.

```bash
sf org assign permset --name Auditr_Admin --target-org <alias>
```

### 3. Run initial sync & schedule daily sync

Open the **Auditr** app from the Lightning App Launcher → **Auditr Control Center** → click **Sync Now** and **Schedule Daily**, or run via Apex:

```apex
Database.executeBatch(new AuditrSyncBatch(), 2000);
System.schedule('Auditr Daily Sync', '0 0 2 * * ?', new AuditrSyncBatch());
```

---

## Architecture

```mermaid
flowchart LR
    SAT[("SetupAuditTrail")] -->|"AuditrSyncBatch (Incremental Watermark)"| UTIL["AuditrUtil Rule Engine (36 Auditr_Rule__mdt)"]
    UTIL -->|"Upsert by External_Id__c"| ENTRY[("Auditr_Entry__c")]
    TRIG["AuditrEntryTrigger"] -->|"Blocks Delete & Unauthorized Update"| ENTRY
    REC["AuditrReclassifyBatch"] -->|"Re-evaluates Rules"| ENTRY
    PURGE["AuditrPurgeBatch"] -->|"Retention_Days__c + hardDelete"| ENTRY
    ENTRY --> HOME["Auditr Home (At-a-Glance + Incident Mode + Dashboard)"]
    ENTRY --> CC["Auditr Control Center"]
```

```text
force-app/main/default/SF-Auditr/
├── applications/    Auditr Lightning App (branded with Auditr_Logo)
├── classes/         AuditrUtil · AuditrEntryTriggerHandler · AuditrSyncBatch
│                    AuditrReclassifyBatch · AuditrPurgeBatch · AuditrController
│                    + 5 test classes (AuditrTestDataFactory, etc.)
├── triggers/        AuditrEntryTrigger (immutability enforcement)
├── lwc/             auditrAtAGlance · auditrControlCenter · auditrRecordDetail
├── objects/         Auditr_Entry__c · Auditr_Rule__mdt · Auditr_Setting__mdt
├── customMetadata/  36 classification rules + Default setting (730-day retention)
├── flexipages/      Auditr_Home · Auditr_Control_Center · Auditr_Entry_Record_Page
├── dashboards/      Auditr_Security_Dashboard (6 components)
├── reports/         6 audit & security reports
└── permissionsets/  Auditr_Admin · Auditr_Viewer
```

## License

MIT.
