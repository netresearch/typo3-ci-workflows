# Grouped Caller Workflows Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace 16 individual caller workflow files per repo with 4 grouped caller files across 17 Netresearch TYPO3 extension repos.

**Architecture:** Fix the slsa-provenance reusable workflow to support being called from grouped release callers, then create a migration script that generates per-repo caller workflows and force-pushes to existing PR branches.

**Tech Stack:** Bash, Git, GitHub CLI (gh)

---

## Per-Repo Configuration Reference

| Repo | php-versions | typo3-versions | matrix-exclude | remove-dev-deps | run-functional-tests | upload-coverage | archive-prefix | package-name | Notes |
|------|-------------|----------------|----------------|-----------------|---------------------|-----------------|----------------|--------------|-------|
| t3x-rte_ckeditor_image | `["8.2","8.3","8.4","8.5"]` | `["^13.4.21","^14.0"]` | — | — | true | — | rte-ckeditor-image | netresearch/rte-ckeditor-image | typo3-packages set |
| t3x-nr-image-sitemap | `["8.2","8.3","8.4","8.5"]` | `["^13.0"]` | — | — | — | — | nr-image-sitemap | netresearch/nr-image-sitemap | run-unit-tests: false |
| t3x-universal-messenger | `["8.2","8.3","8.4","8.5"]` | `["^13.4"]` | — | — | — | — | universal-messenger | netresearch/universal-messenger | |
| t3x-contexts_geolocation | `["8.2","8.3","8.4","8.5"]` | `["^12.4","^13.4"]` | — | — | true | true | contexts-geolocation | netresearch/contexts-geolocation | mysql db |
| t3x-contexts_wurfl | `["8.3","8.4","8.5"]` | `["^12.4","^13.4"]` | `[{"php":"8.5","typo3":"^12.4"}]` | `[{"dep":"saschaegerer/phpstan-typo3","only-for":"^13"}]` | true | true | contexts-wurfl | netresearch/contexts-wurfl | mysql db |
| t3x-nr-saml-auth | `["8.1","8.2","8.3","8.4","8.5"]` | `["^12.4","^13.4"]` | `[{"php":"8.1","typo3":"^13.4"},{"php":"8.5","typo3":"^12.4"}]` | — | true | — | nr-saml-auth | netresearch/nr-saml-auth | |
| t3x-nr-xliff-streaming | `["8.2","8.3","8.4","8.5"]` | `["^13.4"]` | — | — | — | — | nr-xliff-streaming | netresearch/nr-xliff-streaming | |
| t3x-nr-image-optimize | `["8.2","8.3","8.4","8.5"]` | `["^13.4","^14.0"]` | — | — | — | — | nr-image-optimize | netresearch/nr-image-optimize | |
| t3x-nr-textdb | `["8.2","8.3","8.4","8.5"]` | `["^13.4"]` | — | — | — | — | nr-textdb | netresearch/nr-textdb | |
| t3x-nr-extension-scanner-cli | `["8.2","8.3","8.4","8.5"]` | `["^12.4","^13.4","^14.0"]` | — | — | — | — | extension-scanner-cli | netresearch/extension-scanner-cli | |
| t3x-scheduler | `["8.2","8.3","8.4"]` | `["^12.4"]` | — | — | — | — | nr-scheduler | netresearch/nr-scheduler | |
| t3x-sync | `["8.1","8.2","8.3"]` | `["^12.4"]` | — | — | — | — | nr-sync | netresearch/nr-sync | default branch: master |
| t3x-nr-temporal-cache | `["8.1","8.2","8.3","8.4","8.5"]` | `["^12.4","^13.0","^14.0"]` | `[{"php":"8.1","typo3":"^13.0"},{"php":"8.1","typo3":"^14.0"},{"php":"8.2","typo3":"^14.0"},{"php":"8.5","typo3":"^12.4"}]` | — | true | — | nr-temporal-cache | netresearch/nr-temporal-cache | |
| t3x-nr-vault | `["8.2","8.3","8.4","8.5"]` | `["^13.4","^14.0"]` | — | — | true | true | nr-vault | netresearch/nr-vault | php-extensions: +sodium,json |
| t3x-nr-llm | `["8.2","8.3","8.4","8.5"]` | `["^13.4","^14.0"]` | — | — | — | true | nr-llm | netresearch/nr-llm | keep local e2e.yml |
| t3x-cowriter | `["8.2","8.3","8.4","8.5"]` | `["^13.4","^14.0"]` | — | — | true | true | t3-cowriter | netresearch/t3-cowriter | |
| t3x-demio | — | — | — | — | — | — | — | — | legacy: no CI, no release |

---

### Task 1: Update slsa-provenance.yml to support version input

The `prepare` job has an `if:` condition that only allows `workflow_dispatch` and `workflow_run` events. When called from a grouped release.yml caller (triggered by `push tags`), the event is `push`, which is blocked. Fix by also allowing runs when `inputs.version` is explicitly provided.

**Files:**
- Modify: `/home/cybot/projects/typo3-ci-workflows/main/.github/workflows/slsa-provenance.yml:24-26`

**Step 1: Edit the `if` condition**

Change:
```yaml
    if: >-
      github.event_name == 'workflow_dispatch' ||
      github.event.workflow_run.conclusion == 'success'
```

To:
```yaml
    if: >-
      inputs.version != '' ||
      github.event_name == 'workflow_dispatch' ||
      github.event.workflow_run.conclusion == 'success'
```

This allows the job to run when a version is explicitly passed (from the grouped release.yml caller), while preserving existing behavior for workflow_run and workflow_dispatch triggers.

**Step 2: Commit and push**

```bash
cd /home/cybot/projects/typo3-ci-workflows/main
git add .github/workflows/slsa-provenance.yml
git commit -S --signoff -m "fix(slsa-provenance): allow runs with explicit version input

The prepare job's if-condition blocked calls from grouped release
callers where the event is 'push' (tags). Adding a check for
inputs.version allows the workflow to work when called with an
explicit version parameter."
git push
```

---

### Task 2: Create the migration script

**Files:**
- Create: `/home/cybot/projects/typo3-ci-workflows/main/scripts/migrate-to-grouped-callers.sh`

**Step 1: Write the migration script**

The script accepts a repo config file, generates 4 workflow files, clones the repo, and pushes to the PR branch.

```bash
#!/usr/bin/env bash
# migrate-to-grouped-callers.sh — Generate grouped caller workflows for a TYPO3 extension repo
#
# Usage: ./migrate-to-grouped-callers.sh <config-file> [--dry-run]
#
# Config file format: shell variables (sourced)
#   REPO=netresearch/t3x-example
#   BRANCH=chore/add-centralized-workflows
#   DEFAULT_BRANCH=main
#   PHP_VERSIONS='["8.2","8.3","8.4"]'
#   TYPO3_VERSIONS='["^13.4"]'
#   ARCHIVE_PREFIX=example
#   PACKAGE_NAME=netresearch/example
#   # Optional overrides (only include if non-default):
#   MATRIX_EXCLUDE='[...]'
#   REMOVE_DEV_DEPS='[...]'
#   RUN_FUNCTIONAL_TESTS=true
#   UPLOAD_COVERAGE=true
#   FUNCTIONAL_TEST_DB=mysql
#   DB_IMAGE='mysql:8.4'
#   PHP_EXTENSIONS='intl, mbstring, xml, sodium, json'
#   TYPO3_PACKAGES='["typo3/cms-core","typo3/cms-backend"]'
#   RUN_UNIT_TESTS=false
#   SKIP_CI=true        # Skip CI job (legacy repos)
#   SKIP_FUZZ=true      # Skip fuzz job (legacy repos)
#   SKIP_RELEASE=true   # Skip release.yml entirely (legacy repos)

set -euo pipefail

CONFIG_FILE="${1:?Usage: $0 <config-file> [--dry-run]}"
DRY_RUN="${2:-}"

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Validate required vars
: "${REPO:?REPO is required}"
: "${BRANCH:?BRANCH is required}"
: "${DEFAULT_BRANCH:?DEFAULT_BRANCH is required}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

WORKFLOW_DIR="$TMPDIR/.github/workflows"
mkdir -p "$WORKFLOW_DIR"

# --- Helper: build ci.yml with: block ---
build_ci_with() {
  local indent="      "
  echo "${indent}php-versions: '${PHP_VERSIONS}'"
  echo "${indent}typo3-versions: '${TYPO3_VERSIONS}'"
  [[ -n "${MATRIX_EXCLUDE:-}" ]] && echo "${indent}matrix-exclude: '${MATRIX_EXCLUDE}'"
  [[ -n "${REMOVE_DEV_DEPS:-}" ]] && echo "${indent}remove-dev-deps: '${REMOVE_DEV_DEPS}'"
  [[ "${RUN_FUNCTIONAL_TESTS:-}" == "true" ]] && echo "${indent}run-functional-tests: true"
  [[ "${RUN_UNIT_TESTS:-}" == "false" ]] && echo "${indent}run-unit-tests: false"
  [[ "${UPLOAD_COVERAGE:-}" == "true" ]] && echo "${indent}upload-coverage: true"
  [[ -n "${FUNCTIONAL_TEST_DB:-}" ]] && echo "${indent}functional-test-db: ${FUNCTIONAL_TEST_DB}"
  [[ -n "${DB_IMAGE:-}" ]] && echo "${indent}db-image: '${DB_IMAGE}'"
  [[ -n "${PHP_EXTENSIONS:-}" ]] && echo "${indent}php-extensions: '${PHP_EXTENSIONS}'"
  [[ -n "${TYPO3_PACKAGES:-}" ]] && echo "${indent}typo3-packages: '${TYPO3_PACKAGES}'"
  return 0
}

# --- Generate ci.yml ---
generate_ci() {
  local ci_with
  ci_with=$(build_ci_with)

  cat > "$WORKFLOW_DIR/ci.yml" <<CIEOF
name: CI
on:
  push:
  pull_request:
  schedule:
    - cron: '0 6 * * 1'
permissions: {}
jobs:
CIEOF

  # CI job (optional — skipped for legacy repos)
  if [[ "${SKIP_CI:-}" != "true" ]]; then
    cat >> "$WORKFLOW_DIR/ci.yml" <<CIEOF
  ci:
    uses: netresearch/typo3-ci-workflows/.github/workflows/ci.yml@main
    permissions:
      contents: read
    with:
${ci_with}
    secrets:
      CODECOV_TOKEN: \${{ secrets.CODECOV_TOKEN }}

CIEOF
  fi

  # Security job (always)
  cat >> "$WORKFLOW_DIR/ci.yml" <<'CIEOF'
  security:
    uses: netresearch/typo3-ci-workflows/.github/workflows/security.yml@main
    permissions:
      contents: read
      security-events: write
    secrets:
      GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }}

CIEOF

  # Fuzz job (optional — skipped for legacy repos)
  if [[ "${SKIP_FUZZ:-}" != "true" ]]; then
    cat >> "$WORKFLOW_DIR/ci.yml" <<'CIEOF'
  fuzz:
    uses: netresearch/typo3-ci-workflows/.github/workflows/fuzz.yml@main
    permissions:
      contents: read

CIEOF
  fi

  # License check (always)
  cat >> "$WORKFLOW_DIR/ci.yml" <<'CIEOF'
  license-check:
    uses: netresearch/typo3-ci-workflows/.github/workflows/license-check.yml@main
    permissions:
      contents: read

CIEOF

  # CodeQL (always)
  cat >> "$WORKFLOW_DIR/ci.yml" <<'CIEOF'
  codeql:
    uses: netresearch/typo3-ci-workflows/.github/workflows/codeql.yml@main
    permissions:
      contents: read
      security-events: write
      actions: read

CIEOF

  # Scorecard (push to default branch + schedule only)
  cat >> "$WORKFLOW_DIR/ci.yml" <<'CIEOF'
  scorecard:
    if: >-
      github.event_name == 'schedule' ||
      (github.event_name == 'push' && github.ref_name == github.event.repository.default_branch)
    uses: netresearch/typo3-ci-workflows/.github/workflows/scorecard.yml@main
    permissions:
      contents: read
      security-events: write
      id-token: write
      actions: read

CIEOF

  # PR-only jobs
  cat >> "$WORKFLOW_DIR/ci.yml" <<'CIEOF'
  dependency-review:
    if: github.event_name == 'pull_request'
    uses: netresearch/typo3-ci-workflows/.github/workflows/dependency-review.yml@main
    permissions:
      contents: read
      pull-requests: write

  pr-quality:
    if: github.event_name == 'pull_request'
    uses: netresearch/typo3-ci-workflows/.github/workflows/pr-quality.yml@main
    permissions:
      contents: read
      pull-requests: write

  labeler:
    if: github.event_name == 'pull_request'
    uses: netresearch/typo3-ci-workflows/.github/workflows/labeler.yml@main
    permissions:
      contents: read
      pull-requests: write
CIEOF
}

# --- Generate release.yml ---
generate_release() {
  if [[ "${SKIP_RELEASE:-}" == "true" ]]; then
    return 0
  fi

  cat > "$WORKFLOW_DIR/release.yml" <<RELEOF
name: Release
on:
  push:
    tags: ['v*']
permissions: {}
jobs:
  release:
    uses: netresearch/typo3-ci-workflows/.github/workflows/release.yml@main
    permissions:
      contents: write
      id-token: write
      attestations: write
    with:
      archive-prefix: '${ARCHIVE_PREFIX}'
      package-name: '${PACKAGE_NAME}'

  publish-to-ter:
    uses: netresearch/typo3-ci-workflows/.github/workflows/publish-to-ter.yml@main
    permissions:
      contents: read
    secrets:
      TYPO3_EXTENSION_KEY: \${{ secrets.TYPO3_EXTENSION_KEY }}
      TYPO3_TER_ACCESS_TOKEN: \${{ secrets.TYPO3_TER_ACCESS_TOKEN }}

  slsa-provenance:
    needs: release
    uses: netresearch/typo3-ci-workflows/.github/workflows/slsa-provenance.yml@main
    permissions:
      actions: read
      contents: write
      id-token: write
    with:
      version: \${{ github.ref_name }}
RELEOF
}

# --- Generate community.yml ---
generate_community() {
  cat > "$WORKFLOW_DIR/community.yml" <<'COMEOF'
name: Community
on:
  schedule:
    - cron: '0 0 * * *'
  issues:
    types: [opened]
  pull_request_target:
    types: [opened]
  workflow_dispatch:
permissions: {}
jobs:
  stale:
    if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
    uses: netresearch/typo3-ci-workflows/.github/workflows/stale.yml@main
    permissions:
      issues: write
      pull-requests: write

  lock:
    if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
    uses: netresearch/typo3-ci-workflows/.github/workflows/lock.yml@main
    permissions:
      issues: write
      pull-requests: write

  greetings:
    if: github.event_name == 'issues' || github.event_name == 'pull_request_target'
    uses: netresearch/typo3-ci-workflows/.github/workflows/greetings.yml@main
    permissions:
      issues: write
      pull-requests: write
COMEOF
}

# --- Generate auto-merge-deps.yml ---
generate_auto_merge() {
  cat > "$WORKFLOW_DIR/auto-merge-deps.yml" <<'AMEOF'
name: Auto-merge Dependencies
on:
  pull_request:
permissions: {}
jobs:
  auto-merge:
    uses: netresearch/typo3-ci-workflows/.github/workflows/auto-merge-deps.yml@main
    permissions:
      contents: write
      pull-requests: write
AMEOF
}

# --- Generate all files ---
generate_ci
generate_release
generate_community
generate_auto_merge

echo "Generated files:"
ls -la "$WORKFLOW_DIR/"

if [[ "$DRY_RUN" == "--dry-run" ]]; then
  echo ""
  echo "=== DRY RUN — showing generated files ==="
  for f in "$WORKFLOW_DIR"/*.yml; do
    echo ""
    echo "--- $(basename "$f") ---"
    cat "$f"
  done
  exit 0
fi

# --- Clone, commit, push ---
CLONE_DIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR" "$CLONE_DIR"' EXIT

echo "Cloning $REPO..."
gh repo clone "$REPO" "$CLONE_DIR" -- --depth=1 --branch="$DEFAULT_BRANCH" --single-branch

cd "$CLONE_DIR"
git checkout -B "$BRANCH"

# Delete old granular caller files (preserve non-workflow files and e2e.yml)
OLD_FILES=(
  codeql.yml dependency-review.yml fuzz.yml greetings.yml labeler.yml
  license-check.yml lock.yml pr-quality.yml scorecard.yml security.yml
  slsa-provenance.yml stale.yml publish-to-ter.yml
)
for f in "${OLD_FILES[@]}"; do
  rm -f ".github/workflows/$f"
done

# Copy new grouped files
mkdir -p .github/workflows
cp "$WORKFLOW_DIR"/*.yml .github/workflows/

git add .github/workflows/
git status

git commit -S --signoff -m "chore: consolidate caller workflows into 4 grouped files

Replaces 16 individual caller workflow files with 4 grouped files:
- ci.yml: CI, security, fuzz, license, CodeQL, scorecard, dep-review, PR quality, labeler
- release.yml: release, publish-to-TER, SLSA provenance
- community.yml: stale, lock, greetings
- auto-merge-deps.yml: auto-merge dependency PRs

All jobs call reusable workflows from netresearch/typo3-ci-workflows@main.
See: https://github.com/netresearch/typo3-ci-workflows/blob/main/docs/plans/2026-02-28-grouped-caller-workflows-design.md"

git push --force-with-lease origin "$BRANCH"
echo "Done: $REPO"
```

**Step 2: Make executable and commit**

```bash
cd /home/cybot/projects/typo3-ci-workflows/main
chmod +x scripts/migrate-to-grouped-callers.sh
git add scripts/migrate-to-grouped-callers.sh
git commit -S --signoff -m "chore: add grouped caller workflow migration script"
git push
```

---

### Task 3: Create per-repo config files

**Files:**
- Create: `/home/cybot/projects/typo3-ci-workflows/main/scripts/repo-configs/` (17 files)

**Step 1: Create config directory**

```bash
mkdir -p /home/cybot/projects/typo3-ci-workflows/main/scripts/repo-configs
```

**Step 2: Write config files**

Each file is a sourceable shell script. Only include variables that differ from defaults.

**`rte_ckeditor_image.conf`:**
```bash
REPO=netresearch/t3x-rte_ckeditor_image
BRANCH=chore/add-centralized-workflows
DEFAULT_BRANCH=main
PHP_VERSIONS='["8.2","8.3","8.4","8.5"]'
TYPO3_VERSIONS='["^13.4.21","^14.0"]'
ARCHIVE_PREFIX=rte-ckeditor-image
PACKAGE_NAME=netresearch/rte-ckeditor-image
RUN_FUNCTIONAL_TESTS=true
TYPO3_PACKAGES='["typo3/cms-core","typo3/cms-rte-ckeditor"]'
```

**`nr-image-sitemap.conf`:**
```bash
REPO=netresearch/t3x-nr-image-sitemap
BRANCH=chore/add-centralized-workflows
DEFAULT_BRANCH=main
PHP_VERSIONS='["8.2","8.3","8.4","8.5"]'
TYPO3_VERSIONS='["^13.0"]'
ARCHIVE_PREFIX=nr-image-sitemap
PACKAGE_NAME=netresearch/nr-image-sitemap
RUN_UNIT_TESTS=false
```

**`universal-messenger.conf`:**
```bash
REPO=netresearch/t3x-universal-messenger
BRANCH=chore/add-centralized-workflows
DEFAULT_BRANCH=main
PHP_VERSIONS='["8.2","8.3","8.4","8.5"]'
TYPO3_VERSIONS='["^13.4"]'
ARCHIVE_PREFIX=universal-messenger
PACKAGE_NAME=netresearch/universal-messenger
```

**`contexts_geolocation.conf`:**
```bash
REPO=netresearch/t3x-contexts_geolocation
BRANCH=chore/add-centralized-workflows
DEFAULT_BRANCH=main
PHP_VERSIONS='["8.2","8.3","8.4","8.5"]'
TYPO3_VERSIONS='["^12.4","^13.4"]'
ARCHIVE_PREFIX=contexts-geolocation
PACKAGE_NAME=netresearch/contexts-geolocation
RUN_FUNCTIONAL_TESTS=true
UPLOAD_COVERAGE=true
FUNCTIONAL_TEST_DB=mysql
DB_IMAGE='mysql:8.4'
```

**`contexts_wurfl.conf`:**
```bash
REPO=netresearch/t3x-contexts_wurfl
BRANCH=chore/add-centralized-workflows
DEFAULT_BRANCH=main
PHP_VERSIONS='["8.3","8.4","8.5"]'
TYPO3_VERSIONS='["^12.4","^13.4"]'
ARCHIVE_PREFIX=contexts-wurfl
PACKAGE_NAME=netresearch/contexts-wurfl
MATRIX_EXCLUDE='[{"php":"8.5","typo3":"^12.4"}]'
REMOVE_DEV_DEPS='[{"dep":"saschaegerer/phpstan-typo3","only-for":"^13"}]'
RUN_FUNCTIONAL_TESTS=true
UPLOAD_COVERAGE=true
FUNCTIONAL_TEST_DB=mysql
DB_IMAGE='mysql:8.4'
```

**`nr-saml-auth.conf`:**
```bash
REPO=netresearch/t3x-nr-saml-auth
BRANCH=chore/add-centralized-workflows
DEFAULT_BRANCH=main
PHP_VERSIONS='["8.1","8.2","8.3","8.4","8.5"]'
TYPO3_VERSIONS='["^12.4","^13.4"]'
ARCHIVE_PREFIX=nr-saml-auth
PACKAGE_NAME=netresearch/nr-saml-auth
MATRIX_EXCLUDE='[{"php":"8.1","typo3":"^13.4"},{"php":"8.5","typo3":"^12.4"}]'
RUN_FUNCTIONAL_TESTS=true
```

**`nr-xliff-streaming.conf`:**
```bash
REPO=netresearch/t3x-nr-xliff-streaming
BRANCH=chore/add-centralized-workflows
DEFAULT_BRANCH=main
PHP_VERSIONS='["8.2","8.3","8.4","8.5"]'
TYPO3_VERSIONS='["^13.4"]'
ARCHIVE_PREFIX=nr-xliff-streaming
PACKAGE_NAME=netresearch/nr-xliff-streaming
```

**`nr-image-optimize.conf`:**
```bash
REPO=netresearch/t3x-nr-image-optimize
BRANCH=chore/add-centralized-workflows
DEFAULT_BRANCH=main
PHP_VERSIONS='["8.2","8.3","8.4","8.5"]'
TYPO3_VERSIONS='["^13.4","^14.0"]'
ARCHIVE_PREFIX=nr-image-optimize
PACKAGE_NAME=netresearch/nr-image-optimize
```

**`nr-textdb.conf`:**
```bash
REPO=netresearch/t3x-nr-textdb
BRANCH=chore/add-centralized-workflows
DEFAULT_BRANCH=main
PHP_VERSIONS='["8.2","8.3","8.4","8.5"]'
TYPO3_VERSIONS='["^13.4"]'
ARCHIVE_PREFIX=nr-textdb
PACKAGE_NAME=netresearch/nr-textdb
```

**`nr-extension-scanner-cli.conf`:**
```bash
REPO=netresearch/t3x-nr-extension-scanner-cli
BRANCH=chore/add-centralized-workflows
DEFAULT_BRANCH=main
PHP_VERSIONS='["8.2","8.3","8.4","8.5"]'
TYPO3_VERSIONS='["^12.4","^13.4","^14.0"]'
ARCHIVE_PREFIX=extension-scanner-cli
PACKAGE_NAME=netresearch/extension-scanner-cli
```

**`scheduler.conf`:**
```bash
REPO=netresearch/t3x-scheduler
BRANCH=chore/add-centralized-workflows
DEFAULT_BRANCH=main
PHP_VERSIONS='["8.2","8.3","8.4"]'
TYPO3_VERSIONS='["^12.4"]'
ARCHIVE_PREFIX=nr-scheduler
PACKAGE_NAME=netresearch/nr-scheduler
```

**`sync.conf`:**
```bash
REPO=netresearch/t3x-sync
BRANCH=chore/add-centralized-workflows
DEFAULT_BRANCH=master
PHP_VERSIONS='["8.1","8.2","8.3"]'
TYPO3_VERSIONS='["^12.4"]'
ARCHIVE_PREFIX=nr-sync
PACKAGE_NAME=netresearch/nr-sync
```

**`nr-temporal-cache.conf`:**
```bash
REPO=netresearch/t3x-nr-temporal-cache
BRANCH=chore/add-centralized-workflows
DEFAULT_BRANCH=main
PHP_VERSIONS='["8.1","8.2","8.3","8.4","8.5"]'
TYPO3_VERSIONS='["^12.4","^13.0","^14.0"]'
ARCHIVE_PREFIX=nr-temporal-cache
PACKAGE_NAME=netresearch/nr-temporal-cache
MATRIX_EXCLUDE='[{"php":"8.1","typo3":"^13.0"},{"php":"8.1","typo3":"^14.0"},{"php":"8.2","typo3":"^14.0"},{"php":"8.5","typo3":"^12.4"}]'
RUN_FUNCTIONAL_TESTS=true
```

**`nr-vault.conf`:**
```bash
REPO=netresearch/t3x-nr-vault
BRANCH=chore/add-centralized-workflows
DEFAULT_BRANCH=main
PHP_VERSIONS='["8.2","8.3","8.4","8.5"]'
TYPO3_VERSIONS='["^13.4","^14.0"]'
ARCHIVE_PREFIX=nr-vault
PACKAGE_NAME=netresearch/nr-vault
RUN_FUNCTIONAL_TESTS=true
UPLOAD_COVERAGE=true
PHP_EXTENSIONS='intl, mbstring, xml, sodium, json'
```

**`nr-llm.conf`:**
```bash
REPO=netresearch/t3x-nr-llm
BRANCH=chore/add-centralized-workflows
DEFAULT_BRANCH=main
PHP_VERSIONS='["8.2","8.3","8.4","8.5"]'
TYPO3_VERSIONS='["^13.4","^14.0"]'
ARCHIVE_PREFIX=nr-llm
PACKAGE_NAME=netresearch/nr-llm
UPLOAD_COVERAGE=true
```

**`cowriter.conf`:**
```bash
REPO=netresearch/t3x-cowriter
BRANCH=chore/add-centralized-workflows
DEFAULT_BRANCH=main
PHP_VERSIONS='["8.2","8.3","8.4","8.5"]'
TYPO3_VERSIONS='["^13.4","^14.0"]'
ARCHIVE_PREFIX=t3-cowriter
PACKAGE_NAME=netresearch/t3-cowriter
RUN_FUNCTIONAL_TESTS=true
UPLOAD_COVERAGE=true
```

**`demio.conf`:**
```bash
REPO=netresearch/t3x-demio
BRANCH=chore/migrate-centralized-workflows
DEFAULT_BRANCH=main
PHP_VERSIONS='["8.1","8.2","8.3"]'
TYPO3_VERSIONS='["^11.5","^12.4"]'
ARCHIVE_PREFIX=demio
PACKAGE_NAME=netresearch/demio
SKIP_CI=true
SKIP_FUZZ=true
SKIP_RELEASE=true
```

**Step 3: Commit config files**

```bash
cd /home/cybot/projects/typo3-ci-workflows/main
git add scripts/repo-configs/
git commit -S --signoff -m "chore: add per-repo config files for grouped caller migration"
git push
```

---

### Task 4: Dry-run test on t3x-nr-textdb

**Step 1: Run the script in dry-run mode**

```bash
cd /home/cybot/projects/typo3-ci-workflows/main
./scripts/migrate-to-grouped-callers.sh scripts/repo-configs/nr-textdb.conf --dry-run
```

**Step 2: Verify the output**

Check that:
- ci.yml has 9 jobs (ci, security, fuzz, license-check, codeql, scorecard, dependency-review, pr-quality, labeler)
- release.yml has 3 jobs (release, publish-to-ter, slsa-provenance)
- community.yml has 3 jobs (stale, lock, greetings)
- auto-merge-deps.yml has 1 job (auto-merge)
- All `permissions: {}` at top level
- Correct `if:` conditions on scorecard, dependency-review, pr-quality, labeler, stale, lock, greetings
- php-versions and typo3-versions match the config

**Step 3: Fix any issues found**

Iterate on the script until dry-run output is correct.

---

### Task 5: Migrate standard repos (batch 1: 6 repos)

**Step 1: Run the script for repos 1-6**

```bash
cd /home/cybot/projects/typo3-ci-workflows/main
for conf in rte_ckeditor_image nr-image-sitemap universal-messenger contexts_geolocation contexts_wurfl nr-saml-auth; do
  echo "=== Migrating $conf ==="
  ./scripts/migrate-to-grouped-callers.sh "scripts/repo-configs/${conf}.conf"
  echo ""
done
```

**Step 2: Verify PRs updated**

```bash
for repo in t3x-rte_ckeditor_image t3x-nr-image-sitemap t3x-universal-messenger t3x-contexts_geolocation t3x-contexts_wurfl t3x-nr-saml-auth; do
  echo "--- $repo ---"
  gh pr list --repo "netresearch/$repo" --head chore/add-centralized-workflows --json number,title --jq '.[0]'
done
```

---

### Task 6: Migrate standard repos (batch 2: 7 repos)

**Step 1: Run the script for repos 7-13**

```bash
cd /home/cybot/projects/typo3-ci-workflows/main
for conf in nr-xliff-streaming nr-image-optimize nr-textdb nr-extension-scanner-cli scheduler sync nr-temporal-cache; do
  echo "=== Migrating $conf ==="
  ./scripts/migrate-to-grouped-callers.sh "scripts/repo-configs/${conf}.conf"
  echo ""
done
```

**Step 2: Verify PRs updated**

```bash
for repo in t3x-nr-xliff-streaming t3x-nr-image-optimize t3x-nr-textdb t3x-nr-extension-scanner-cli t3x-scheduler t3x-sync t3x-nr-temporal-cache; do
  echo "--- $repo ---"
  gh pr list --repo "netresearch/$repo" --head chore/add-centralized-workflows --json number,title --jq '.[0]'
done
```

---

### Task 7: Migrate special repos (vault, llm, cowriter)

These repos had additional local workflows before migration.

**Step 1: Run the script**

```bash
cd /home/cybot/projects/typo3-ci-workflows/main
for conf in nr-vault nr-llm cowriter; do
  echo "=== Migrating $conf ==="
  ./scripts/migrate-to-grouped-callers.sh "scripts/repo-configs/${conf}.conf"
  echo ""
done
```

**Step 2: Verify e2e.yml preserved in nr-llm**

```bash
gh api "repos/netresearch/t3x-nr-llm/contents/.github/workflows/e2e.yml?ref=chore/add-centralized-workflows" --jq '.name'
# Expected: e2e.yml
```

---

### Task 8: Migrate legacy repo (demio)

**Step 1: Run the script**

```bash
cd /home/cybot/projects/typo3-ci-workflows/main
./scripts/migrate-to-grouped-callers.sh scripts/repo-configs/demio.conf
```

**Step 2: Verify no CI or release jobs**

```bash
gh api "repos/netresearch/t3x-demio/contents/.github/workflows/ci.yml?ref=chore/migrate-centralized-workflows" --jq '.content' | base64 -d | head -20
# Expected: no 'ci:' job, no 'fuzz:' job
gh api "repos/netresearch/t3x-demio/contents/.github/workflows?ref=chore/migrate-centralized-workflows" --jq '.[].name'
# Expected: ci.yml, community.yml, auto-merge-deps.yml (NO release.yml)
```

---

### Task 9: Update all PR titles and descriptions

**Step 1: Update PR descriptions**

```bash
PR_BODY=$(cat <<'PREOF'
## Summary

- Consolidates 16 individual caller workflow files into 4 grouped files
- Groups workflows by trigger pattern for cleaner repo structure

### New structure

| File | Jobs | Trigger |
|------|------|---------|
| `ci.yml` | CI, security, fuzz, license, CodeQL, scorecard, dep-review, PR quality, labeler | push + PR + weekly schedule |
| `release.yml` | Release, publish-to-TER, SLSA provenance | push tags `v*` |
| `community.yml` | Stale, lock, greetings | daily schedule + issues + PR |
| `auto-merge-deps.yml` | Auto-merge Dependabot/Renovate PRs | pull_request |

All jobs call reusable workflows from `netresearch/typo3-ci-workflows@main`.

## Design

See [grouped-caller-workflows-design.md](https://github.com/netresearch/typo3-ci-workflows/blob/main/docs/plans/2026-02-28-grouped-caller-workflows-design.md)
PREOF
)

REPOS=(
  "t3x-rte_ckeditor_image:chore/add-centralized-workflows"
  "t3x-nr-image-sitemap:chore/add-centralized-workflows"
  "t3x-universal-messenger:chore/add-centralized-workflows"
  "t3x-contexts_geolocation:chore/add-centralized-workflows"
  "t3x-contexts_wurfl:chore/add-centralized-workflows"
  "t3x-nr-saml-auth:chore/add-centralized-workflows"
  "t3x-nr-xliff-streaming:chore/add-centralized-workflows"
  "t3x-nr-image-optimize:chore/add-centralized-workflows"
  "t3x-nr-textdb:chore/add-centralized-workflows"
  "t3x-nr-extension-scanner-cli:chore/add-centralized-workflows"
  "t3x-scheduler:chore/add-centralized-workflows"
  "t3x-sync:chore/add-centralized-workflows"
  "t3x-nr-temporal-cache:chore/add-centralized-workflows"
  "t3x-nr-vault:chore/add-centralized-workflows"
  "t3x-nr-llm:chore/add-centralized-workflows"
  "t3x-cowriter:chore/add-centralized-workflows"
  "t3x-demio:chore/migrate-centralized-workflows"
)

for entry in "${REPOS[@]}"; do
  repo="${entry%%:*}"
  branch="${entry##*:}"
  PR_NUM=$(gh pr list --repo "netresearch/$repo" --head "$branch" --json number --jq '.[0].number')
  if [[ -n "$PR_NUM" ]]; then
    gh pr edit "$PR_NUM" --repo "netresearch/$repo" \
      --title "chore: consolidate caller workflows into 4 grouped files" \
      --body "$PR_BODY"
    echo "Updated PR #$PR_NUM in $repo"
  else
    echo "WARNING: No PR found for $repo ($branch)"
  fi
done
```

---

### Task 10: Final verification

**Step 1: List all PRs and their status**

```bash
for entry in "${REPOS[@]}"; do
  repo="${entry%%:*}"
  branch="${entry##*:}"
  gh pr list --repo "netresearch/$repo" --head "$branch" --json number,title,url,statusCheckRollup --jq '.[0] | "\(.number) \(.title) \(.url)"'
done
```

**Step 2: Spot-check workflow syntax with actionlint**

```bash
# Pick 3 repos to verify
for repo in t3x-nr-textdb t3x-contexts_wurfl t3x-demio; do
  echo "=== $repo ==="
  BRANCH=$(if [[ "$repo" == "t3x-demio" ]]; then echo "chore/migrate-centralized-workflows"; else echo "chore/add-centralized-workflows"; fi)
  for wf in ci.yml release.yml community.yml auto-merge-deps.yml; do
    echo "  $wf:"
    gh api "repos/netresearch/$repo/contents/.github/workflows/$wf?ref=$BRANCH" --jq '.content' 2>/dev/null | base64 -d | head -5
    echo "  ---"
  done
done
```

**Step 3: Wait for CI checks on one PR, verify all jobs trigger correctly**

Pick t3x-nr-textdb PR and check that CI runs show all expected jobs.
