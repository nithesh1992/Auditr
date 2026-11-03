# Getting Started

You can install Auditr either as a versioned **Unlocked Package** or by deploying the source directly from the repository.

## 1. Install into Your Org

::: code-group

```bash [Unlocked Package (Recommended)]
sf package install --package 04tg7000000coevAAA --wait 10 --target-org <org-alias>
```

```bash [Deploy from Source]
git clone https://github.com/nithesh1992/Auditr.git
cd Auditr
sf project deploy start --source-dir force-app/main/default/Auditr --target-org <org-alias>
```

:::

Or install directly in the browser:

- **Production / Developer Edition**: `https://login.salesforce.com/packaging/installPackage.apexp?p0=04tg7000000coevAAA`
- **Sandbox / Scratch Org**: `https://test.salesforce.com/packaging/installPackage.apexp?p0=04tg7000000coevAAA`

## 2. Assign Permission Sets

Auditr ships with two permission sets following the principle of least privilege:

| Permission Set | API Name | Intended Audience |
| :--- | :--- | :--- |
| **Auditr Admin** | `Auditr_Admin` | Security administrators and release managers. Grants access to the **Auditr** Lightning App, **Auditr Home**, **Audit Mode** (investigation & change packaging), **Auditr Control Center**, batch execution, scheduling, and rule reclassification. |
| **Auditr Viewer** | `Auditr_Viewer` | Compliance auditors and read-only reviewers. Grants read-only access to `Auditr_Entry__c`, `Auditr_Change_Log__c`, **Auditr Home**, **Audit Mode**, reports, and the security dashboard without packaging or Control Center actions. |

```bash
# For security admins and release managers
sf org assign permset --name Auditr_Admin --target-org <org-alias>

# For read-only compliance auditors
sf org assign permset --name Auditr_Viewer --target-org <org-alias>
```

## 3. Run Initial Backfill & Schedule Daily Sync

1. Open the **App Launcher** in Lightning Experience and select **Auditr**.
2. Navigate to the **Auditr Control Center** tab.
3. Click **Sync Now** in the top-right header to ingest your org's historical `SetupAuditTrail` entries (up to `Backfill_Days__c`, default `180` days).
4. In the green **Daily Sync Hour (Org Time Zone)** card, select your preferred hour (default `02:00`) and click **Schedule Daily Sync**.

::: tip Safe Incremental Watermark
You can click **Sync Now** as often as you want. `AuditrSyncBatch` queries `SetupAuditTrail` from the latest `Occurred_At__c` watermark (minus a 1-hour overlap buffer) and upserts using `Source_Record_Id__c` as an external ID, guaranteeing zero duplicate `Auditr_Entry__c` rows.
:::

## 4. Explore Auditr Home & Reports

After `AuditrSyncBatch` finishes:

- Open **Auditr Home** to inspect the 7 rolling KPI cards (**Total Events**, **Critical & High**, **Security & Access**, **Automation & Code**, **Impersonated**, **Unclassified**, **Unassigned Changes**) and the embedded **Auditr Security Dashboard**.
- Open the **Incident Mode** tab to investigate changes around a specific timestamp (`±15m` to `±12h`).
- Open the **Audit Mode** tab to review the unassigned changes backlog and package audit entries into sealed change logs tied to Change Requests — see [Audit Mode & Change Packaging](/audit-mode).
- Open the **Auditr Entries** tab to browse list views (`Critical & High Risk`, `Impersonated Changes`, `Security & Access`, `Code & Automation`, `Unclassified Entries`).
