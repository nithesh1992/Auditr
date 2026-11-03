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

The workspace is a single LWC (`auditrAuditMode`) with two panels:

1. **Change Logs** — recent logs with CR number, status, entry counts, and sign-off time. Single-select any **Draft** row to make it the packaging target. Click **New Change Log** to create one (CR Id required, deployment date and description optional).
2. **Unassigned Changes Backlog** — audit entries with **no change log citation**, filtered by:
   - **Occurred From / To** — `Occurred_At__c` window (defaults to the last 30 days).
   - **Responsible Actor (exact)** — filter to a single responsible username.
   - **Group Actor Bursts** — UI-layer temporal grouping that collapses consecutive changes by the same actor into expandable bursts. Raw database records are never coalesced; this is presentation-only to preserve forensic integrity.

### Packaging actions

- **Package Selected (N)** — cites the datatable-selected entries (up to the 200-row page) into the target log.
- **Package All Matching (M)** — packages *every* unassigned entry matching the current filter. Confirmation panel shows the exact scope; the filter is stored on the change log for reproducibility.

Both actions enqueue `AuditrChangeLogBatch` asynchronously — sized for 10,000+ entry release windows, well beyond synchronous Apex DML limits. The workspace notifies the auditor that packaging has started in the background. A change log with an in-flight job (`Packaging_Job_Id__c`) refuses new packaging until the job completes.

### Home posture

The **Unassigned Changes** KPI on the Auditr Home At-a-Glance strip counts entries within the selected window that no change log cites (capped at 5,000) — the headline governance metric for compliance officers.

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
