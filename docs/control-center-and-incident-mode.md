# Control Center, Incident Mode & Record Detail

Auditr includes three purpose-built Lightning Web Components designed for security operations, incident triage, and audit governance.

---

## 1. Auditr Home: At-a-Glance & Incident Mode (`auditrAtAGlance`)

Placed at the top of the **Auditr Home** page, `auditrAtAGlance` provides an immediate rolling security posture summary and an interactive incident timeline investigator.

### Rolling KPI Strip

Select a lookback window (**Last 7 Days**, **Last 30 Days**, **Last 90 Days**, or **Last 1 Year**) to evaluate six real-time metrics with compact formatting (`25K`, `1.5M`, with exact counts on hover):

1. **Total Events** — Total `Auditr_Entry__c` records within the selected window.
2. **Critical & High** — High-severity changes requiring security review.
3. **Security & Access** — Profile, Permission Set, Sharing, Auth, and Session changes.
4. **Automation & Code** — Apex, Flow, Trigger, Validation Rule, and Custom Object changes.
5. **Impersonated** — Actions executed via *Log in As* or delegated administration (`Delegate_User__c != null`).
6. **Unclassified** — Events that did not match an active `Auditr_Rule__mdt` rule.

### Incident Mode Investigator

Click **Incident Mode** in the header to expand the time-window triage panel:

- **Incident Timestamp (UTC / Local)**: Pick the exact date and time an outage, deployment issue, or suspicious activity occurred.
- **Radius Window**: Choose `±15 min`, `±30 min`, `±1 hour`, or `±4 hours` around the anchor timestamp.
- **High Risk Only Toggle**: Filter strictly to `Critical` and `High` risk changes or view all risk levels.
- **Direct Record Navigation**: Click any event name (`AUD-xxxxxxx`) in the timeline table to open its immutable detail view.

---

## 2. Auditr Control Center (`auditrControlCenter`)

The **Auditr Control Center** tab gives administrators complete visibility and control over ingestion, classification, and retention without writing Apex.

### Operational Summary Cards

- **Ingestion Engine**: Shows whether `Auditr_Setting__mdt.Is_Active__c` is `Active` or `Paused`, along with configured `Backfill_Days__c` and `Batch_Size__c`.
- **Last Sync Job & Entry Age**: Displays the status and completed timestamp of the last `AsyncApexJob` for `AuditrSyncBatch` alongside the age of the newest `Auditr_Entry__c.Occurred_At__c` (since `allOrNone=false` batch runs can finish as `Completed` even if individual rows fail).
- **Daily Sync Schedule**: Displays whether `Auditr_Daily_Sync` is `Scheduled` or `Not Scheduled` and shows the next scheduled fire timestamp.
- **Retention Policy**:Schedule-aware status indicator:
  - `Retain Indefinitely (Purge Off)` when `Enable_Purge__c` is `false`.
  - `Purge > 720d (Not Scheduled)` when `Enable_Purge__c` is `true` in `Setup → Custom Metadata Types → Auditr Setting` but the daily purge job is not yet scheduled.
  - `Purge > 720d (Scheduled)` with the `Next:` execution time when both `Enable_Purge__c` is `true` and `Auditr_Daily_Purge` is scheduled.

### Side-by-Side Daily Schedule Controls

Below the summary cards, a two-column schedule grid separates ingestion from retention:

- **Daily Sync Hour (Green Card)**: Pick an hour (`00:00`–`23:00` in the org's time zone) and click **Schedule Daily Sync** (or **Unschedule**). Clicking **Schedule Daily Sync** automatically unschedules any existing `Auditr_Daily_Sync` job before creating the new schedule so duplicate jobs never accumulate.
- **Daily Purge Hour (Red Card)**: Pick an hour (`00:00`–`23:00` in the org's time zone) and click **Schedule Daily Purge** (or **Unschedule**). Requires `Enable_Purge__c = true` and `Retention_Days__c > 0` in `Setup → Custom Metadata Types → Auditr Setting`.

### On-Demand Batch Actions

- **Sync Now**: Immediately queues `AuditrSyncBatch`.
- **Reclassify Unclassified**: Queues `AuditrReclassifyBatch(true)` to re-evaluate only `Unclassified` entries against active `Auditr_Rule__mdt` rules.
- **Reclassify All**: Queues `AuditrReclassifyBatch(false)` to re-evaluate every stored `Auditr_Entry__c` record after rule priority or severity adjustments.
- **Run Retention Purge**: Immediately queues `AuditrPurgeBatch` (warns if `Enable_Purge__c` is currently disabled).

### Unclassified Setup Actions, Batch Monitor & Rule Inspector

- **Top Unclassified Setup Actions (Last 30 Days • Top 10)**: Groups unclassified entries by `Action_Code__c` and `Section__c` so you can immediately see which new Salesforce Setup actions need a custom `Auditr_Rule__mdt` record.
- **Recent Batch Jobs (Last 10 Runs)**: Live `AsyncApexJob` monitor across `AuditrSyncBatch`, `AuditrReclassifyBatch`, and `AuditrPurgeBatch`.
- **Active Classification Rules**: Searchable table of all active `Auditr_Rule__mdt` rules ordered by `Priority__c`.

---

## 3. Custom Read-Only Record Detail (`auditrRecordDetail`)

Standard Salesforce record pages display inline-edit pencil icons on fields the user has object-level edit access to. To guarantee audit integrity in the UI while still supporting administrative reclassification:

- `auditrRecordDetail` replaces the standard record detail component on `Auditr_Entry_Record_Page`.
- Every provenance field (**Occurred At**, **Action Code**, **Setup Section**, **Responsible Username**, **Actor Username**, **Delegate User**, **Actor Context**, **Source Record ID**, **Display**) is rendered strictly read-only with zero inline-edit pencils.
- Clicking **Reclassify** in the component header opens a controlled modal that updates only `Category__c` and `Risk_Level__c` through `AuditrEntryTriggerHandler`'s authorized reclassification pathway, while **Field History Tracking** logs the before/after values on the **Histories** tab.
