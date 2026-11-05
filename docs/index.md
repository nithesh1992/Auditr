---
layout: home

hero:
  name: "Auditr"
  text: "Long-term, classified Setup Audit Trail."
  tagline: "Covers Setup Audit Trail (SetupAuditTrail) only — retaining history beyond 180 days inside your org. Classify setup changes by risk level and domain, investigate incidents by timestamp, and block edits and deletes through normal use."
  image:
    src: /auditr-logo.svg
    alt: Auditr
  actions:
    - theme: brand
      text: Get Started
      link: /getting-started
    - theme: alt
      text: Audit Mode & Change Packaging
      link: /audit-mode
    - theme: alt
      text: Control Center & Incident Mode
      link: /control-center-and-incident-mode
    - theme: alt
      text: Rules & Retention
      link: /classification-and-retention
    - theme: alt
      text: View on GitHub
      link: https://github.com/nithesh1992/Auditr

features:
  - title: Beyond the 180-Day Cliff
    details: Incrementally sync SetupAuditTrail into indexed Auditr_Entry__c records using a deduplicated Source_Record_Id__c watermark — no external SIEM required.
  - title: Metadata-Driven Risk Engine
    details: Ships with 36 Auditr_Rule__mdt rules across Critical, High, Medium, and Low risk levels and 6 security domains, evaluated in priority order.
  - title: Incident Mode Investigator
    details: Pinpoint what changed in your org within ±15m to ±12h of an outage or security incident with one-click filtering for Critical & High risk actions.
  - title: Audit Mode Change Packaging
    details: Bundle audit events into sealed Auditr_Change_Log__c containers tied to mandatory Change Request numbers via asynchronous packaging — built for 10,000+ entry release windows.
  - title: Unassigned Changes Backlog
    details: SOX/SOC 2 governance view that surfaces every audit event with no change log citation as an unauthorized-change exception, on Home and in Audit Mode.
  - title: Blocks Edits & Deletes in Normal Use
    details: AuditrEntryTrigger blocks manual edits to source fields and blocks deletes unless AuditrPurgeBatch.execute is on the call stack.
  - title: Impersonation & Delegate Attribution
    details: Automatically resolves Responsible_Username__c and flags Is_Impersonated__c when changes are executed via delegated admin or "Log in As".
  - title: Operational Control Center
    details: Run Sync Now, schedule daily sync and retention purge side-by-side, reclassify historical entries, and spot top unclassified setup actions.
---

## What an Auditr Entry Record Looks Like

Standard `SetupAuditTrail` rows only give you a raw `Action` string, a `Section`, and a free-text `Display` message that disappears after 180 days. Auditr enriches each event at ingestion time into an immutable, reportable `Auditr_Entry__c` record:

**Classified fields on `Auditr_Entry__c`:**

```text
Name:                    AUD-0001428
Occurred_At__c:          2026-11-01T14:22:09.000Z
Risk_Level__c:           Critical
Category__c:             Security & Access
Section__c:              Manage Users
Action_Code__c:          PermSetAssign
Responsible_Username__c: contractor@acme.example.com (via Delegate_User__c)
Actor_Username__c:       sysadmin@acme.example.com
Is_Impersonated__c:      true
Display__c:              Assigned Permission Set "Modify_All_Data" to user john.doe@acme.example.com
```

## Quick Install & Setup

Install the Unlocked Package or deploy from source, assign `Auditr_Admin`, and schedule your daily sync from the **Auditr Control Center** (or via Anonymous Apex):

::: code-group

```bash [Install Package v1.2.1-1]
# Install the Unlocked Package
sf package install --package 04tg7000000dLJ7AAM --target-org <alias> --wait 10

# Assign Admin permissions
sf org assign permset --name Auditr_Admin --target-org <alias>
```

```apex [Schedule Sync & Backfill]
// Run an immediate backfill + incremental sync
AuditrController.runSyncNow();

// Schedule daily sync at 02:00 AM (Org Time Zone)
AuditrController.scheduleDailySync(2);
```

```apex [Reclassify & Retention Purge]
// Re-evaluate only Unclassified rows after adding a new Auditr_Rule__mdt
AuditrController.runReclassify(true);

// Optional: Schedule daily retention purge at 03:00 AM (requires Enable_Purge__c = true)
AuditrController.scheduleDailyPurge(3);
```

:::

## How It Compares

| Capability | **Auditr** | Native `SetupAuditTrail` |
| :--- | :--- | :--- |
| **Retention window** | **Indefinite or custom (`Retention_Days__c`)** | 180 days (UI download) |
| **Risk classification (`Critical`..`Low`)** | **Built-in (`36 Auditr_Rule__mdt` rules)** | None |
| **Domain categorization** | **6 normalized categories + custom rules** | Raw `Section` text only |
| **Impersonation / Login-As attribution** | **`Is_Impersonated__c` + `Responsible_Username__c`** | Raw `DelegateUser` column |
| **Incident time-window investigator** | **Built-in Incident Mode (`±15m` to `±4h`)** | Manual CSV grep |
| **Native Lightning Reports & Dashboards** | **6 reports + 6-widget Security Dashboard included** | Not supported on `SetupAuditTrail` |
| **Edit & delete protection** | **Blocks edits/deletes through normal use + Field History** | System read-only |

## Roadmap

- **Export to external systems**: Offloading classified `Auditr_Entry__c` records to an external system or object storage prior to retention purge (planned roadmap item, not a current feature).
- **AI-assisted Incident Mode narratives**: Grouping multi-day audit windows into per-actor trail stories to speed up root-cause triage.
