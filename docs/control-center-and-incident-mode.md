# Control Center, Audit Mode & Record Detail

Auditr ships focused Lightning surfaces — **Auditr Home**, **Audit Mode** (unified investigation and packaging), **Auditr Control Center**, and **Change Logs** — so operational and governance workflows are clean, fast, and scalable.

---

## 1. Auditr Home: At-a-Glance (`auditrAtAGlance`)

Placed at the top of the **Auditr Home** page above the embedded `Auditr_Security_Dashboard`, `auditrAtAGlance` provides an immediate rolling security posture summary.

### Rolling KPI Strip

Select a lookback window (**Last 24 Hours** through **Last 1 Year**) to evaluate seven real-time metrics with compact formatting (`25K`, `1.5M`, with exact counts on hover):

1. **Total Events** — Total `Auditr_Entry__c` records within the selected window.
2. **Critical & High** — High-severity changes requiring security review.
3. **Security & Access** — Profile, Permission Set, Sharing, Auth, and Session changes.
4. **Automation & Code** — Apex, Flow, Trigger, Validation Rule, and Custom Object changes.
5. **Impersonated** — Actions executed via *Log in As* or delegated administration (`Delegate_User__c != null`).
6. **Unclassified** — Events that did not match an active `Auditr_Rule__mdt` rule.
7. **Unassigned Changes** — Entries with no change log citation; the SOX/SOC 2 compliance backlog. Click **Audit Mode** in the header to package them.

---

## 2. Unified Investigation & Audit Mode (`auditrAuditMode`)

Incident triage and compliance packaging are unified into a single workspace:

- **Incident Investigation**: Rapidly pinpoint changes around an outage or deployment using **Incident (Time ± Radius)** mode (`±15m` to `±12h`) and the **High & Critical Risk Only** filter.
- **Change Packaging**: Package investigated changes or unassigned backlogs directly into **Change Logs** via the modal-first workflow.
- See the complete guide at [Audit Mode & Change Packaging](/audit-mode).

---

## 3. Audit Mode (`auditrAuditMode`)

The compliance workspace for change packaging, unassigned backlog review, and auditor sign-off — see [Audit Mode & Change Packaging](/audit-mode).

---

## 4. Auditr Control Center (`auditrControlCenter`)

The **Auditr Control Center** tab gives administrators complete visibility and control over ingestion, classification, and retention without writing Apex.

### Operational Summary Cards

- **Ingestion Engine**: Shows whether `Auditr_Setting__mdt.Is_Active__c` is `Active` or `Paused`, along with configured `Backfill_Days__c` and `Batch_Size__c`.
- **Last Sync Job & Entry Age**: Displays the status and completed timestamp of the last `AsyncApexJob` for `AuditrSyncBatch` alongside the age of the newest `Auditr_Entry__c.Occurred_At__c` (since `allOrNone=false` batch runs can finish as `Completed` even if individual rows fail).
- **Daily Sync Schedule**: Displays whether `Auditr_Daily_Sync` is `Scheduled` or `Not Scheduled` and shows the next scheduled fire timestamp.
- **Retention Policy**: Schedule-aware status indicator:
  - `Retain Indefinitely (Purge Off)` when `Enable_Purge__c` is `false`.
  - `Purge > 720d (Not Scheduled)` when `Enable_Purge__c` is `true` in `Setup → Custom Metadata Types → Auditr Setting` but the daily purge job is not yet scheduled.
  - `Purge > 720d (Scheduled)` with the `Next:` execution time when both `Enable_Purge__c` is `true` and `Auditr_Daily_Purge` is scheduled.

### Side-by-Side Daily Schedule Controls

Below the summary cards, a two-column schedule grid separates ingestion from retention:

- **Daily Sync Hour (Green Card)**: Pick an hour (`00:00`–`23:00` in the org's time zone) and click **Schedule Daily Sync** (or **Unschedule**). Clicking **Schedule Daily Sync** automatically unschedules any existing `Auditr_Daily_Sync` job before creating the new schedule so duplicate jobs never accumulate.
- **Daily Purge Hour (Red Card)**: Pick an hour (`00:00`–`23:00` in the org's time zone) and click **Schedule Daily Purge** (or **Unschedule**). Requires `Enable_Purge__c = true` and `Retention_Days__c > 0` in `Setup → Custom Metadata Types → Auditr Setting`. Packaged entries are always exempt from purge.

### On-Demand Batch Actions

- **Sync Now**: Immediately queues `AuditrSyncBatch`.
- **Reclassify Unclassified**: Queues `AuditrReclassifyBatch(true)` to re-evaluate only `Unclassified` entries against active `Auditr_Rule__mdt` rules.
- **Reclassify All**: Queues `AuditrReclassifyBatch(false)` to re-evaluate every stored `Auditr_Entry__c` record after rule priority or severity adjustments.
- **Run Retention Purge**: Immediately queues `AuditrPurgeBatch` (warns if `Enable_Purge__c` is currently disabled).

### Unclassified Setup Actions, Batch Monitor & Rule Inspector

- **Top Unclassified Setup Actions (Last 30 Days • Top 10)**: Groups unclassified entries by `Action_Code__c` and `Section__c` so you can immediately see which new Salesforce Setup actions need a custom `Auditr_Rule__mdt` record.
- **Recent Batch Jobs (Last 10 Runs)**: Live `AsyncApexJob` monitor across `AuditrSyncBatch`, `AuditrReclassifyBatch`, `AuditrPurgeBatch`, and `AuditrChangeLogBatch`.
- **Active Classification Rules**: Searchable table of all active `Auditr_Rule__mdt` rules ordered by `Priority__c`.

---

## 5. Custom Read-Only Record Detail (`auditrRecordDetail`)

Standard Salesforce record pages display inline-edit pencil icons on fields the user has object-level edit access to. To guarantee audit integrity in the UI while still supporting administrative reclassification:

- `auditrRecordDetail` replaces the standard record detail component on `Auditr_Entry_Record_Page`.
- Every provenance field (**Occurred At**, **Action Code**, **Setup Section**, **Responsible Username**, **Actor Username**, **Delegate User**, **Actor Context**, **Source Record ID**, **Display**) is rendered strictly read-only with zero inline-edit pencils.
- Clicking **Reclassify** in the component header opens a controlled modal that updates only `Category__c` and `Risk_Level__c` through `AuditrEntryTriggerHandler`'s authorized reclassification pathway, while **Field History Tracking** logs the before/after values on the **Histories** tab.
