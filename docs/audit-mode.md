# Audit Mode & Change Packaging

**Audit Mode** turns Auditr from an operational audit trail viewer into a compliance certification workspace. Release engineers, security admins, and compliance officers filter audit events by actor and timeframe, review the unassigned change backlog, and bundle selected records into sealed `Auditr_Change_Log__c` containers tied to a mandatory external Change Request (CR) number (Jira, ServiceNow).

---

## The Problem It Solves

Under **SOX ITGC** and **SOC 2** change-management controls, every production change must trace to an approved change request. Audit events with no change log citation are treated as *unauthorized production changes*. Audit Mode surfaces exactly those exceptions and certifies the rest.

---

## Data Model

### `Auditr_Change_Log__c` (container)

| Field Label | API Name | Type | Description |
| :--- | :--- | :--- | :--- |
| **Change Log Number** | `Name` | Auto Number (`CLG-{000000}`) | Human-readable identifier. |
| **Change Request Id** | `Change_Request_Id__c` | Text(40), Required | External CR/ticket number, format-validated by the `Change_Request_Id_Format` rule (3–40 chars: letters, digits, `.`, `_`, `-`). |
| **Status** | `Status__c` | Picklist | `Draft` (accepts packaging) → `Sealed` (fully immutable, terminal). |
| **Target Actor** | `Target_Actor__c` | Text(255) | Responsible username filter stored during filter-driven packaging (reproducibility). |
| **Window Start / End** | `Window_Start__c`, `Window_End__c` | Date/Time | `Occurred_At__c` bounds stored during filter-driven packaging. |
| **Deployment Date** | `Deployment_Date__c` | Date/Time | Planned or actual production deployment timestamp. |
| **Description / Sign-Off Notes** | `Description__c`, `Sign_Off_Notes__c` | Long Text | Business summary and auditor attestation notes. |
| **Signed Off By / At** | `Signed_Off_By__c`, `Signed_Off_At__c` | Lookup(User), Date/Time | Stamped automatically by `AuditrChangeLogTriggerHandler` at sealing. |
| **Total Entries** | `Total_Entries__c` | Roll-Up Summary (COUNT) | Number of packaged citations. |
| **Packaging Job Id** | `Packaging_Job_Id__c` | Text(18) | In-flight `AsyncApexJob` pointer; cleared when the batch finishes. |

### `Auditr_Change_Log_Item__c` (M:N junction)

Each row cites **one audit entry inside one change log**, so the same event can appear in a sprint release manifest, a security incident bundle, *and* a quarterly SOX review. A trigger-stamped unique `Compound_Key__c` (`ChangeLogId-EntryId`, also an External ID) blocks duplicate citations within the same log. `AuditrChangeLogItemTriggerHandler` blocks adding or removing citations once the parent log is sealed.

### Sealed lifecycle rules

- **Sealing requires entries** — a change log with zero packaged citations cannot be sealed.
- **Sealing stamps sign-off** — `Signed_Off_By__c` / `Signed_Off_At__c` are set from the sealing user and timestamp.
- **Sealed = immutable** — no field updates, no re-opening to Draft, no deletion, no citation add/remove. Create a new change log instead.

---

## Using the Audit Mode Tab

The workspace is a single unified LWC (`auditrAuditMode`) integrating incident triage and compliance change packaging:

### 1. Dual-Mode Time Filtering
- **Window (Date Range)** — Specify exact `Occurred From` and `Occurred To` date boundaries (defaults to the last 7 days).
- **Incident (Time ± Radius)** — Anchor around a critical timestamp with radius presets (`± 15 Minutes`, `± 30 Minutes`, `± 1 Hour`, `± 4 Hours`, `± 12 Hours`) for immediate production root-cause analysis. Auto-anchors to the latest synced event on load.

### 2. Investigation Filters
- **Responsible Actor (User Lookup)** — Powered by `lightning-record-picker` with bidirectional Name/Username resolution and avatar preview. Filters against the indexed `Responsible_Username__c` field.
- **High & Critical Risk Only** — Instantly isolates high-severity changes (security alterations, permissions, code modifications).
- **Group Actor Bursts** — Presentation-layer temporal grouping with **cascading selection**:
  - Consecutive actions by the same actor are grouped into a burst row showing `Burst: N`.
  - Checking the burst row checkbox automatically selects **all N underlying audit entries**.
  - Expanding the burst allows checking/unchecking individual actions.

### 3. All Events Visibility & Packaging Status
The table displays all events in the filtered window, showing forensic details and a **Package Status** badge:
- **Packaged Entries**: Show the external Change Request Id (e.g. `[ CR-10492 ]`) linking directly to the parent Change Log.
- **Unassigned Entries**: Labeled `Unassigned`, immediately ready for packaging.

### 4. Scalable Modal-First Packaging Workflow
The top change log table has been replaced with a streamlined, scalable modal:
- **Package Selected (N)** — Packages the explicitly selected entries (or bursts).
- **Package All Unassigned (M)** — Packages every unassigned entry matching the current filter.
- **Package Changes Modal**:
  - **Link to Existing Change Log** — Search open `Draft` change logs by Change Request Id or Name via auto-complete.
  - **Create New Change Log** — On-the-fly creation requiring external `Change Request Id` (Jira, ServiceNow, etc.) with optional deployment date and description.
- Packaging enqueues `AuditrChangeLogBatch` asynchronously in the background and delivers a toast notification with links to the Change Log.

---

## Retention Interplay

`AuditrPurgeBatch` **never purges packaged evidence**: its scope excludes any entry cited by a change log item. Retention purge only removes unpackaged entries older than `Retention_Days__c`.

---

## Multi-Source Foundation (Phase 2 Schema)

`Auditr_Entry__c` now ships with three record types — **Setup Audit Trail** (default, used by `AuditrSyncBatch`), **Login History**, and **Data Change** — plus a reserved `Payload__c` long-text column for compact source payloads. No `LoginHistory` or data-change ingestion pipeline ships in this release; the schema compatibility is intentionally laid now so Phase 2 pipelines land without destructive migration.

---

## Programmatic Access

```apex
// Create a Draft change log
Id logId = AuditrChangeLogController.createChangeLog('PROJ-1234', System.now().addDays(2), 'Q4 release bundle');

// Package every unassigned entry in a window for one actor (async)
Id jobId = AuditrChangeLogController.packageFilteredEntries(logId, System.now().addDays(-7), System.now(), 'release.eng@acme.com');

// Package a curated selection (async)
Id jobId2 = AuditrChangeLogController.packageEntries(logId, new List<Id>{ entryId1, entryId2 });
```
