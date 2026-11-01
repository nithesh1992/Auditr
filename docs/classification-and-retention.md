# Classification Rules & Data Retention

Auditr uses Custom Metadata Types (`Auditr_Setting__mdt` and `Auditr_Rule__mdt`) so your classification taxonomy and retention policy can be versioned in Git, deployed across sandboxes, or tuned in Setup without modifying Apex code.

---

## 1. Engine Settings (`Auditr_Setting__mdt`)

Navigate to **Setup → Custom Metadata Types → Auditr Setting → Manage Auditr Settings** and edit the **Default** record:

| Field Label | API Name | Default | Description |
| :--- | :--- | :--- | :--- |
| **Is Active** | `Is_Active__c` | `true` | Master toggle for scheduled `AuditrSyncBatch` runs. When `false`, scheduled sync exits without querying. |
| **Backfill Days** | `Backfill_Days__c` | `180` | How many days back `AuditrSyncBatch` looks on initial run when no `Auditr_Entry__c` watermark exists yet. |
| **Batch Size** | `Batch_Size__c` | `2000` | Batch scope size (`1`–`2000`) used by `AuditrSyncBatch`, `AuditrReclassifyBatch`, and `AuditrPurgeBatch`. |
| **Preferred Sync Hour** | `Preferred_Sync_Hour__c` | `2` | Default hour of day (`0`–`23`, Org Time Zone) pre-selected in the Control Center for daily sync. |
| **Enable Purge** | `Enable_Purge__c` | `false` | Opt-in safety switch for retention purging. When `false`, `AuditrPurgeBatch` will never delete records. |
| **Retention Days** | `Retention_Days__c` | `720` | Age threshold in days (`Occurred_At__c < NOW - Retention_Days__c`) for records purged when `Enable_Purge__c = true`. |

---

## 2. Classification Rule Engine (`Auditr_Rule__mdt`)

Every `SetupAuditTrail` record is evaluated against active `Auditr_Rule__mdt` records sorted by `Priority__c ASC` (lowest number wins; ties break alphabetically by `DeveloperName`). The first matching rule assigns `Category__c` and `Risk_Level__c`. If no rule matches, the entry is stored as `Category__c = 'Unclassified'` and `Risk_Level__c = 'Low'`.

### Rule Fields

| Field Label | API Name | Options / Type | Description |
| :--- | :--- | :--- | :--- |
| **Is Active** | `Is_Active__c` | Checkbox | Enables or disables the rule. |
| **Priority** | `Priority__c` | Number | Evaluation order (`10` runs before `100`). Put specific action rules at lower numbers and broad section fallbacks at higher numbers. |
| **Match Target** | `Match_Target__c` | `Action`, `Section`, `NamespacePrefix`, `DelegateUser` | Which `SetupAuditTrail` attribute to inspect. |
| **Match Operator** | `Match_Operator__c` | `Equals`, `Contains`, `StartsWith`, `NotBlank` | Case-insensitive comparison operator (`NotBlank` ignores `Match_Value__c`). |
| **Match Value** | `Match_Value__c` | Text(255) | Target string to match against (case-insensitive). |
| **Category** | `Category__c` | Picklist | `Security & Access`, `Users & Sessions`, `Code & Automation`, `Data & Schema`, `Org Preferences`, `Packages & Integrations`, or `Unclassified`. |
| **Risk Level** | `Risk_Level__c` | Picklist | `Critical`, `High`, `Medium`, or `Low`. |

### Built-In Rule Priorities (36 Shipped Rules)

Auditr ships with 36 curated rules organized into priority tiers:

- **Priority `10`–`50` (`Critical`)**: Admin impersonation (`suorgadminlogin`, `suNetworkAdminLogin`), password/MFA resets, permission set & profile privileges, SAML/SSO/Auth Provider changes, Named Credentials, Remote Site Settings, Connected Apps, and Sharing OWD changes.
- **Priority `60`–`150` (`High`)**: User creation/deactivation/freezing, role/group/queue membership changes, Apex classes & triggers, Flows, Validation Rules, Custom Objects/Fields, and package installs/uninstalls.
- **Priority `200`–`400` (`Medium` / `Low`)**: Page layouts, Lightning pages, email templates, list views, reports/dashboards, and general org preferences.

### Adding a Custom Rule & Reclassifying

1. Check the **Top Unclassified Setup Actions** card in **Auditr Control Center** to identify any unmapped `Action_Code__c` or `Section__c` values in your org.
2. Go to **Setup → Custom Metadata Types → Auditr Rule → Manage Auditr Rules** and click **New**.
3. Populate `Priority__c`, `Match_Target__c`, `Match_Operator__c`, `Match_Value__c`, `Category__c`, and `Risk_Level__c`, and check **Is Active**.
4. Return to **Auditr Control Center** and click **Reclassify Unclassified** (or **Reclassify All** if your new rule overrides an existing broad rule).

---

## 3. Data Retention & Purge Management (`AuditrPurgeBatch`)

By default, Auditr retains all `Auditr_Entry__c` records indefinitely (`Enable_Purge__c = false`) to satisfy long-term compliance and forensic requirements.

To enable automated retention cleanup:

1. Open **Setup → Custom Metadata Types → Auditr Setting → Manage Auditr Settings** and edit **Default**.
2. Check **Enable Purge** (`Enable_Purge__c = true`) and set **Retention Days** (e.g., `720` for 2 years or `365` for 1 year).
3. Open **Auditr Control Center**:
   - Notice the **Retention Policy** card updates to `Purge > 720d (Not Scheduled)`.
   - In the red **Daily Purge Hour (Org Time Zone)** card, select an off-peak hour (default `03:00`) and click **Schedule Daily Purge**.
   - The **Retention Policy** card immediately updates to `Purge > 720d (Scheduled)` and displays the `Next:` execution time.
4. For an immediate one-time cleanup, click **Run Retention Purge** in the Control Center header.
