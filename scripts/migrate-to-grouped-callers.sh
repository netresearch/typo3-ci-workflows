#!/usr/bin/env bash
# migrate-to-grouped-callers.sh
#
# Generates 4 grouped caller workflow files for a TYPO3 extension repo
# and optionally pushes them to a PR branch.
#
# Usage:
#   ./scripts/migrate-to-grouped-callers.sh <config-file> [--dry-run]
#
# Config file: shell variables (sourced). See scripts/repo-configs/*.conf
#
# Required variables:
#   REPO              - GitHub repo (e.g. netresearch/t3x-contexts)
#   BRANCH            - PR branch name
#   DEFAULT_BRANCH    - Default branch (e.g. main)
#   PHP_VERSIONS      - JSON array (e.g. '["8.2","8.3","8.4"]')
#   TYPO3_VERSIONS    - JSON array (e.g. '["^13.4"]')
#   ARCHIVE_PREFIX    - Release archive prefix (e.g. contexts)
#   PACKAGE_NAME      - Composer package name (e.g. netresearch/contexts)
#
# Optional variables:
#   MATRIX_EXCLUDE        - JSON array of {php,typo3} combos to exclude (default: '[]')
#   REMOVE_DEV_DEPS       - JSON array (default: '[]')
#   RUN_FUNCTIONAL_TESTS  - true/false (default: false)
#   UPLOAD_COVERAGE       - true/false (default: false)
#   FUNCTIONAL_TEST_DB    - sqlite/mysql/mariadb/postgres (default: sqlite)
#   DB_IMAGE              - Docker image for DB (default: mysql:9.6)
#   PHP_EXTENSIONS        - Comma-separated (default: intl, mbstring, xml)
#   TYPO3_PACKAGES        - JSON array (default: '["typo3/cms-core"]')
#   RUN_UNIT_TESTS        - true/false (default: true)
#   SKIP_CI               - true to skip ci job (default: false)
#   SKIP_FUZZ             - true to skip fuzz job (default: false)
#   SKIP_RELEASE          - true to skip release.yml entirely (default: false)

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────────────────────────────
DRY_RUN=false
CONFIG_FILE=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -*) echo "Unknown option: $arg" >&2; exit 1 ;;
    *) CONFIG_FILE="$arg" ;;
  esac
done

if [[ -z "$CONFIG_FILE" ]]; then
  echo "Usage: $0 <config-file> [--dry-run]" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: config file not found: $CONFIG_FILE" >&2
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────
# Source config with defaults
# ──────────────────────────────────────────────────────────────────────
MATRIX_EXCLUDE='[]'
REMOVE_DEV_DEPS='[]'
RUN_FUNCTIONAL_TESTS=false
UPLOAD_COVERAGE=false
FUNCTIONAL_TEST_DB=sqlite
DB_IMAGE='mysql:9.6'
PHP_EXTENSIONS='intl, mbstring, xml'
TYPO3_PACKAGES='["typo3/cms-core"]'
RUN_UNIT_TESTS=true
SKIP_CI=false
SKIP_FUZZ=false
SKIP_RELEASE=false

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ──────────────────────────────────────────────────────────────────────
# Validate required variables
# ──────────────────────────────────────────────────────────────────────
MISSING=()
for var in REPO BRANCH DEFAULT_BRANCH PHP_VERSIONS TYPO3_VERSIONS ARCHIVE_PREFIX PACKAGE_NAME; do
  if [[ -z "${!var:-}" ]]; then
    MISSING+=("$var")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Error: missing required config variables: ${MISSING[*]}" >&2
  exit 1
fi

echo "=== Migration: ${REPO} ==="
echo "  Branch:     ${BRANCH}"
echo "  PHP:        ${PHP_VERSIONS}"
echo "  TYPO3:      ${TYPO3_VERSIONS}"
echo "  Dry run:    ${DRY_RUN}"

# ──────────────────────────────────────────────────────────────────────
# Setup output directory
# ──────────────────────────────────────────────────────────────────────
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

OUTPUT_DIR="${WORK_DIR}/workflows"
mkdir -p "$OUTPUT_DIR"

# ──────────────────────────────────────────────────────────────────────
# Workflow reference base
# ──────────────────────────────────────────────────────────────────────
WF_BASE="netresearch/typo3-ci-workflows/.github/workflows"

# ──────────────────────────────────────────────────────────────────────
# Helper: build ci.yml 'with' block
# Only emit inputs that differ from reusable workflow defaults.
# ──────────────────────────────────────────────────────────────────────
build_ci_with_block() {
  local lines=()

  # Always include php-versions and typo3-versions (repo-specific)
  lines+=("        php-versions: '${PHP_VERSIONS}'")
  lines+=("        typo3-versions: '${TYPO3_VERSIONS}'")

  if [[ "$MATRIX_EXCLUDE" != "[]" ]]; then
    lines+=("        matrix-exclude: '${MATRIX_EXCLUDE}'")
  fi

  if [[ "$RUN_FUNCTIONAL_TESTS" == "true" ]]; then
    lines+=("        run-functional-tests: true")
  fi

  if [[ "$RUN_UNIT_TESTS" == "false" ]]; then
    lines+=("        run-unit-tests: false")
  fi

  if [[ "$UPLOAD_COVERAGE" == "true" ]]; then
    lines+=("        upload-coverage: true")
  fi

  if [[ "$FUNCTIONAL_TEST_DB" != "sqlite" ]]; then
    lines+=("        functional-test-db: ${FUNCTIONAL_TEST_DB}")
  fi

  if [[ "$DB_IMAGE" != "mysql:9.6" ]]; then
    lines+=("        db-image: '${DB_IMAGE}'")
  fi

  if [[ "$PHP_EXTENSIONS" != "intl, mbstring, xml" ]]; then
    lines+=("        php-extensions: ${PHP_EXTENSIONS}")
  fi

  if [[ "$TYPO3_PACKAGES" != '["typo3/cms-core"]' ]]; then
    lines+=("        typo3-packages: '${TYPO3_PACKAGES}'")
  fi

  if [[ "$REMOVE_DEV_DEPS" != "[]" ]]; then
    lines+=("        remove-dev-deps: '${REMOVE_DEV_DEPS}'")
  fi

  for line in "${lines[@]}"; do
    echo "$line"
  done
}

# ──────────────────────────────────────────────────────────────────────
# Generate ci.yml
# ──────────────────────────────────────────────────────────────────────
generate_ci_yml() {
  local file="${OUTPUT_DIR}/ci.yml"

  # Start with the header - use single-quoted heredoc for literal ${{ }}
  cat > "$file" << 'HEADER'
name: CI

on:
  push:
  pull_request:
  schedule:
    - cron: '0 6 * * 1'

permissions: {}

HEADER

  # Now build jobs section
  echo "jobs:" >> "$file"

  # ci job
  if [[ "$SKIP_CI" != "true" ]]; then
    cat >> "$file" << CIEOF
  ci:
    uses: ${WF_BASE}/ci.yml@main
    permissions:
      contents: read
    with:
$(build_ci_with_block)
    secrets:
      CODECOV_TOKEN: \${{ secrets.CODECOV_TOKEN }}

CIEOF
  fi

  # security job
  cat >> "$file" << SECEOF
  security:
    uses: ${WF_BASE}/security.yml@main
    permissions:
      contents: read
      security-events: write
    secrets:
      GITLEAKS_LICENSE: \${{ secrets.GITLEAKS_LICENSE }}

SECEOF

  # fuzz job
  if [[ "$SKIP_FUZZ" != "true" ]]; then
    cat >> "$file" << FUZZEOF
  fuzz:
    uses: ${WF_BASE}/fuzz.yml@main
    permissions:
      contents: read

FUZZEOF
  fi

  # license-check job
  cat >> "$file" << 'LICEOF'
  license-check:
LICEOF
  cat >> "$file" << LICEOF2
    uses: ${WF_BASE}/license-check.yml@main
    permissions:
      contents: read

LICEOF2

  # codeql job
  cat >> "$file" << CQLEOF
  codeql:
    uses: ${WF_BASE}/codeql.yml@main
    permissions:
      contents: read
      security-events: write
      actions: read

CQLEOF

  # scorecard job - uses single-quoted heredoc for if condition
  cat >> "$file" << 'SCIF'
  scorecard:
    if: github.event_name == 'schedule' || (github.event_name == 'push' && github.ref_name == github.event.repository.default_branch)
SCIF
  cat >> "$file" << SCEOF
    uses: ${WF_BASE}/scorecard.yml@main
    permissions:
      contents: read
      security-events: write
      id-token: write
      actions: read

SCEOF

  # dependency-review job
  cat >> "$file" << 'DRIF'
  dependency-review:
    if: github.event_name == 'pull_request'
DRIF
  cat >> "$file" << DREOF
    uses: ${WF_BASE}/dependency-review.yml@main
    permissions:
      contents: read
      pull-requests: write

DREOF

  # pr-quality job
  cat >> "$file" << 'PRIF'
  pr-quality:
    if: github.event_name == 'pull_request'
PRIF
  cat >> "$file" << PREOF
    uses: ${WF_BASE}/pr-quality.yml@main
    permissions:
      contents: read
      pull-requests: write

PREOF

  # labeler job
  cat >> "$file" << 'LBIF'
  labeler:
    if: github.event_name == 'pull_request'
LBIF
  cat >> "$file" << LBEOF
    uses: ${WF_BASE}/labeler.yml@main
    permissions:
      contents: read
      pull-requests: write
LBEOF

  echo "  Generated: ci.yml"
}

# ──────────────────────────────────────────────────────────────────────
# Generate release.yml
# ──────────────────────────────────────────────────────────────────────
generate_release_yml() {
  if [[ "$SKIP_RELEASE" == "true" ]]; then
    echo "  Skipped:   release.yml (SKIP_RELEASE=true)"
    return
  fi

  local file="${OUTPUT_DIR}/release.yml"

  cat > "$file" << RELEOF
name: Release

on:
  push:
    tags:
      - 'v*'

permissions: {}

jobs:
  release:
    uses: ${WF_BASE}/release.yml@main
    permissions:
      contents: write
      id-token: write
      attestations: write
    with:
      archive-prefix: ${ARCHIVE_PREFIX}
      package-name: ${PACKAGE_NAME}

  publish-to-ter:
    uses: ${WF_BASE}/publish-to-ter.yml@main
    permissions:
      contents: read
    secrets:
      TYPO3_EXTENSION_KEY: \${{ secrets.TYPO3_EXTENSION_KEY }}
      TYPO3_TER_ACCESS_TOKEN: \${{ secrets.TYPO3_TER_ACCESS_TOKEN }}

  slsa-provenance:
    needs: release
    uses: ${WF_BASE}/slsa-provenance.yml@main
    permissions:
      actions: read
      contents: write
      id-token: write
    with:
      version: \${{ github.ref_name }}
RELEOF

  echo "  Generated: release.yml"
}

# ──────────────────────────────────────────────────────────────────────
# Generate community.yml
# ──────────────────────────────────────────────────────────────────────
generate_community_yml() {
  local file="${OUTPUT_DIR}/community.yml"

  # Use single-quoted heredoc to preserve ${{ }} literals
  cat > "$file" << 'COMEOF'
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
COMEOF

  cat >> "$file" << COMEOF2
    uses: ${WF_BASE}/stale.yml@main
COMEOF2

  cat >> "$file" << 'COMEOF3'
    permissions:
      issues: write
      pull-requests: write

  lock:
    if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
COMEOF3

  cat >> "$file" << COMEOF4
    uses: ${WF_BASE}/lock.yml@main
COMEOF4

  cat >> "$file" << 'COMEOF5'
    permissions:
      issues: write
      pull-requests: write

  greetings:
    if: github.event_name == 'issues' || github.event_name == 'pull_request_target'
COMEOF5

  cat >> "$file" << COMEOF6
    uses: ${WF_BASE}/greetings.yml@main
COMEOF6

  cat >> "$file" << 'COMEOF7'
    permissions:
      issues: write
      pull-requests: write
COMEOF7

  echo "  Generated: community.yml"
}

# ──────────────────────────────────────────────────────────────────────
# Generate auto-merge-deps.yml
# ──────────────────────────────────────────────────────────────────────
generate_auto_merge_deps_yml() {
  local file="${OUTPUT_DIR}/auto-merge-deps.yml"

  cat > "$file" << 'AMHDR'
name: Auto-merge dependency PRs

on:
  pull_request:

permissions: {}

jobs:
  auto-merge:
AMHDR

  cat >> "$file" << AMEOF
    uses: ${WF_BASE}/auto-merge-deps.yml@main
AMEOF

  cat >> "$file" << 'AMEOF2'
    permissions:
      contents: write
      pull-requests: write
AMEOF2

  echo "  Generated: auto-merge-deps.yml"
}

# ──────────────────────────────────────────────────────────────────────
# Generate all workflow files
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "--- Generating workflow files ---"
generate_ci_yml
generate_release_yml
generate_community_yml
generate_auto_merge_deps_yml
echo ""

# ──────────────────────────────────────────────────────────────────────
# Dry-run mode: print files and exit
# ──────────────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  echo "=== DRY RUN: Generated files ==="
  for f in "$OUTPUT_DIR"/*.yml; do
    echo ""
    echo "────────────────────────────────────────"
    echo "File: $(basename "$f")"
    echo "────────────────────────────────────────"
    cat "$f"
  done
  echo ""
  echo "=== DRY RUN complete. No changes pushed. ==="
  exit 0
fi

# ──────────────────────────────────────────────────────────────────────
# Clone, update, commit, push
# ──────────────────────────────────────────────────────────────────────
CLONE_DIR="${WORK_DIR}/repo"
echo "--- Cloning ${REPO} (branch: ${DEFAULT_BRANCH}) ---"
gh repo clone "$REPO" "$CLONE_DIR" -- --depth=1 --branch="$DEFAULT_BRANCH" --single-branch

cd "$CLONE_DIR"

echo "--- Creating/checking out branch: ${BRANCH} ---"
git checkout -B "$BRANCH"

echo "--- Removing old granular workflow files ---"
OLD_FILES=(
  codeql.yml
  dependency-review.yml
  fuzz.yml
  greetings.yml
  labeler.yml
  license-check.yml
  lock.yml
  pr-quality.yml
  scorecard.yml
  security.yml
  slsa-provenance.yml
  stale.yml
  publish-to-ter.yml
)
for f in "${OLD_FILES[@]}"; do
  if [[ -f ".github/workflows/${f}" ]]; then
    git rm -q ".github/workflows/${f}"
    echo "  Removed: ${f}"
  fi
done

echo "--- Copying new grouped workflow files ---"
mkdir -p .github/workflows
cp "$OUTPUT_DIR"/*.yml .github/workflows/

echo "--- Staging changes ---"
git add .github/workflows/

echo "--- Committing ---"
git commit -S --signoff -m "chore: consolidate caller workflows into 4 grouped files"

echo "--- Pushing to origin/${BRANCH} ---"
git push --force-with-lease origin "$BRANCH"

echo ""
echo "=== Migration complete for ${REPO} ==="
echo "  Branch: ${BRANCH}"
echo "  PR URL: https://github.com/${REPO}/compare/${DEFAULT_BRANCH}...${BRANCH}"
