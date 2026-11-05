# Auditr Release & Quality Assurance Checklist

This persistent checklist documents the end-to-end standard operating procedure (SOP), quality gates, and verification steps for developing, packaging, and releasing the **Auditr** framework.

---

## 1. Version History & Package Registry

| Version | Release Date | Package Version Alias | Subscriber Package Version ID | Key Deliverables |
| :--- | :--- | :--- | :--- | :--- |
| **v1.0.0-1** | Nov 2026 | `Auditr@1.0.0-1` | `04tg7000000clFdAAI` | Initial release: SetupAuditTrail ingestion, 36 rules across 6 categories, immutable entries, Control Center, Incident Mode, Audit Mode change packaging, 6 pre-built reports & dashboard. |
| **v1.0.0-2** | Nov 2026 | `Auditr@1.0.0-2` | `04tg7000000cltxAAA` | Security and tightness uplift: admin CRUD authorization on controllers, platform event removal, empApi removal, background batch progress notification, resilient active AsyncApexJob detection, 100% batch coverage. |
| **v1.1.0-1** | Nov 2026 | `Auditr@1.1.0-1` | `04tg7000000coevAAA` | Major UI/UX redesign: unified Audit Mode (consolidating Incident Mode into dual time modes: Window vs Incident), lightning-record-picker user lookup, cascading burst selection with lightning-tree-grid, scalable modal-first change packaging, conditional purge schedule display. |
| **v1.1.1-1** | Nov 2026 | `Auditr@1.1.1-1` | `04tg7000000coobAAA` | Filter layout alignment fix: symmetric 3-tier compound field alignment (legend, sub-label, input box) across datetime and record picker; clean inline toggles and centered action toolbar. |
| **v1.2.0-1** | Nov 2026 | `Auditr@1.2.0-1` | `Pending Packaging` | Architecture & security hardening: dedicated `Auditr_Admin_Access` Custom Permission, in-flight packaging seal concurrency guard, SaveResult partial DML inspection & accurate counts, deterministic in-memory SetupAuditTrail test mocks, bounded table view envelope with scope aggregates & warning badges, GitHub Actions CI quality gates, and documentation reconciliation. |

---

## 2. Connected Orgs & Repositories

- **Active Dev Hub Org**: `techninja` (`nithesh@agentforce.com` / Org ID: `00Dg700000NXqtpEAD`)
  - Package ID: `0Hog70000004wWrCAI` (`Auditr`)
- **Remote Git Repository**: [https://github.com/nithesh1992/Auditr](https://github.com/nithesh1992/Auditr)
- **Live Documentation Website**: [https://nithesh1992.github.io/Auditr/](https://nithesh1992.github.io/Auditr/)

> [!IMPORTANT]
> **Scope Boundaries**:
> - Core package files live strictly under `force-app/main/default/Auditr/`.
> - Unpackaged test fixtures live strictly under `force-app/test/` and must never pollute the core package folder.
> - Temporary scratch files (e.g. `concepts_brief.md`, local scripts) must never be packaged.

---

## 3. Standard Change & Release Checklist

Execute these steps in sequence every time changes are made.

### Phase A: Pre-Release Quality Gates
- [x] **1. Run LWC Jest Unit Tests**:
  ```bash
  cd /Users/nitheshnekkanti/Repos/SF-Auditr && npm run test:unit
  ```
  *Requirement: All 5 test suites pass (6/6 tests).*

- [x] **2. Deploy Metadata to Target Org**:
  ```bash
  cd /Users/nitheshnekkanti/Repos/SF-Auditr && sf project deploy start --target-org techninja
  ```
  *Requirement: 100% clean deployment of all components with 0 errors or warnings.*

- [x] **3. Run Apex Unit Tests & Code Coverage**:
  ```bash
  cd /Users/nitheshnekkanti/Repos/SF-Auditr && sf apex run test --target-org techninja --test-level RunLocalTests --code-coverage --result-format human --wait 10
  ```
  *Requirement: 39/39 tests passing (100%), org-wide coverage >= 85% (Auditr target: 90%+).*

- [x] **4. Build Documentation Locally**:
  ```bash
  cd /Users/nitheshnekkanti/Repos/SF-Auditr && npm run docs:build
  ```
  *Requirement: Clean VitePress build with 0 broken links or markdown syntax errors.*

- [x] **5. Verify Git Working Tree**:
  ```bash
  cd /Users/nitheshnekkanti/Repos/SF-Auditr && git status
  ```
  *Requirement: Verify only intended tracked files are modified; no unwanted temporary files.*

---

### Phase B: Package Version Creation & Promotion
- [x] **6. Version Config Bumps (if releasing new minor/major)**:
  - In `sfdx-project.json`: verify `versionName` (e.g. `v1.0`) and `versionNumber` (`X.Y.0.NEXT`).
  - In `package.json`: verify `"version": "X.Y.0"`.

- [x] **7. Create Unlocked Package Version**:
  ```bash
  cd /Users/nitheshnekkanti/Repos/SF-Auditr && sf package version create \
    --package Auditr \
    --version-name v1.0 \
    --version-number 1.0.0.NEXT \
    --code-coverage \
    --installation-key-bypass \
    --target-dev-hub techninja \
    --wait 30
  ```
  *Captures newly generated `Auditr@X.Y.0-N: 04t...` alias automatically added to `sfdx-project.json`.*

- [x] **8. Promote Package Version**:
  ```bash
  cd /Users/nitheshnekkanti/Repos/SF-Auditr && sf package version promote \
    --package Auditr@X.Y.0-N \
    --target-dev-hub techninja \
    --no-prompt
  ```
  *Sets the package version as released/promoted for production use.*

---

### Phase C: Documentation Website Update & Verification
- [x] **9. Update Package Version ID (`04t...`) Across Documentation**:
  Replace previous `04t...` ID with the newly generated `04t...` ID across:
  - `README.md` (unlocked package code block, install URLs)
  - `docs/getting-started.md` (install code block, browser URLs)
  - `docs/index.md` (code-group tab label, install command)
  - `docs/.vitepress/config.mjs` (nav items)

- [x] **10. Re-verify VitePress Documentation Build**:
  ```bash
  cd /Users/nitheshnekkanti/Repos/SF-Auditr && npm run docs:build
  ```
  *Confirms markdown syntax, links, and code blocks compile cleanly.*

- [x] **11. Commit, Tag, and Push to GitHub**:
  ```bash
  cd /Users/nitheshnekkanti/Repos/SF-Auditr && git add .
  git commit -m "Release Auditr vX.Y.0-N (<04t_ID>) <brief description>"
  git tag -a vX.Y.0 -m "Release Auditr vX.Y.0"
  git push origin main
  git push origin vX.Y.0
  ```
  *Pushing to `main` automatically triggers the GitHub Actions `docs.yml` workflow to publish the updated documentation website.*

- [x] **12. Publish GitHub Release**:
  ```bash
  TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill | grep "^password=" | cut -d= -f2)

  curl -s -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/repos/nithesh1992/Auditr/releases \
    -d '{
      "tag_name": "vX.Y.0",
      "target_commitish": "main",
      "name": "Auditr vX.Y.0 (<04t_ID>)",
      "body": "### What Changed in vX.Y.0\n...\n- **Install Command**:\n  ```bash\nsf package install --package <04t_ID> --target-org <alias> --apex-compile package --wait 10\n```\n- **Install Links**:\n  - Production / DE: https://login.salesforce.com/packaging/installPackage.apexp?p0=<04t_ID>\n  - Sandbox / Scratch: https://test.salesforce.com/packaging/installPackage.apexp?p0=<04t_ID>",
      "draft": false,
      "prerelease": false
    }'
  ```

- [x] **13. Verify Live Documentation Website Deployment**:
  - Verify GitHub Actions workflow run: `Deploy Documentation to GitHub Pages` completes with `success`.
  - Inspect live site: <https://nithesh1992.github.io/Auditr/> to confirm install links and badges reflect the new version.
