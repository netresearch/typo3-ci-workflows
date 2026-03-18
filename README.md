# typo3-ci-workflows

Reusable GitHub Actions workflows for Netresearch TYPO3 extension repositories.

## Quick Start

Copy these caller workflows into your extension's `.github/workflows/` directory. Most workflows work with zero configuration.

### Minimal CI (required)

```yaml
# .github/workflows/ci.yml
name: CI
on:
  push:
    branches: [main]
  pull_request:
permissions: {}
jobs:
  ci:
    uses: netresearch/typo3-ci-workflows/.github/workflows/ci.yml@main
    permissions:
      contents: read
```

### Recommended additions

```yaml
# .github/workflows/security.yml
name: Security
on:
  push:
    branches: [main]
  pull_request:
permissions: {}
jobs:
  security:
    uses: netresearch/typo3-ci-workflows/.github/workflows/security.yml@main
    permissions:
      contents: read
      security-events: write
    secrets:
      GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }}
```

```yaml
# .github/workflows/codeql.yml
name: CodeQL
on:
  push:
    branches: [main]
  schedule:
    - cron: '0 6 * * 1'
permissions: {}
jobs:
  codeql:
    uses: netresearch/typo3-ci-workflows/.github/workflows/codeql.yml@main
    permissions:
      contents: read
      security-events: write
      actions: read
```

```yaml
# .github/workflows/auto-merge-deps.yml
name: Auto-merge dependency PRs
on:
  pull_request:
permissions: {}
jobs:
  auto-merge:
    uses: netresearch/typo3-ci-workflows/.github/workflows/auto-merge-deps.yml@main
    permissions:
      contents: write
      pull-requests: write
```

## Required Webhooks

In addition to workflow callers, each extension repo needs these GitHub webhooks configured. Go to **Settings → Webhooks → Add webhook** in each repo.

### Packagist (required for all public extensions)

| Setting | Value |
|---------|-------|
| Payload URL | `https://packagist.org/api/github` |
| Content type | `application/json` |
| SSL verification | Enabled |
| Events | Just the push event |

Auto-updates the Composer package on Packagist whenever you push.

### TYPO3 Documentation (required for all extensions with `Documentation/`)

| Setting | Value |
|---------|-------|
| Payload URL | `https://docs-hook.typo3.org` |
| Content type | `application/json` |
| SSL verification | Enabled |
| Events | Just the push event |

Triggers automatic documentation rendering and publishing on [docs.typo3.org](https://docs.typo3.org). First-time builds require manual approval by the TYPO3 Documentation Team (1-3 business days). See the [typo3-docs skill](https://github.com/netresearch/typo3-docs-skill) for the full deployment guide.

### CLI setup

```bash
# Add both webhooks to a repo
gh api repos/netresearch/REPO/hooks --method POST \
  -f name=web -f "config[url]=https://packagist.org/api/github" \
  -f "config[content_type]=json" --raw-field "events[]=push" -f active=true

gh api repos/netresearch/REPO/hooks --method POST \
  -f name=web -f "config[url]=https://docs-hook.typo3.org" \
  -f "config[content_type]=json" --raw-field "events[]=push" -f active=true
```

## Workflows

### Core CI

| Workflow | Purpose | Trigger |
|----------|---------|---------|
| [`ci.yml`](#ci) | PHP lint, CGL, PHPStan, Rector, unit/functional tests | push, PR |
| [`extended-testing.yml`](#extended-testing) | Coverage, mutation testing, fuzz testing, JS tests | push, PR |
| [`e2e.yml`](#e2e-tests) | Playwright browser tests with TYPO3 backend | push, PR |

### Security & Compliance

| Workflow | Purpose | Trigger |
|----------|---------|---------|
| [`security.yml`](#security) | Gitleaks secret scanning + Composer audit | push, PR |
| [`codeql.yml`](#codeql) | GitHub CodeQL security scanning | push, schedule |
| [`dependency-review.yml`](#dependency-review) | Dependency vulnerability review | PR only |
| [`license-check.yml`](#license-check) | PHP dependency license audit | push, PR |
| [`scorecard.yml`](#scorecard) | OpenSSF Scorecard analysis | push, schedule |

### Release & Publish

| Workflow | Purpose | Trigger |
|----------|---------|---------|
| [`release.yml`](#release) | Enterprise release pipeline (archive, SBOM, cosign, attestation) | tag push |
| [`publish-to-ter.yml`](#publish-to-ter) | Publish extension to TYPO3 TER | tag push |

### Repository Hygiene

| Workflow | Purpose | Trigger |
|----------|---------|---------|
| [`auto-merge-deps.yml`](#auto-merge-dependency-prs) | Auto-merge Dependabot/Renovate PRs | PR |
| [`pr-quality.yml`](#pr-quality-gates) | PR size check + auto-approve for solo maintainers | PR |
| [`labeler.yml`](#labeler) | Automatic PR labeling based on file paths | PR |
| [`stale.yml`](#stale-issues) | Mark and close stale issues and PRs | schedule |
| [`lock.yml`](#lock-threads) | Lock old inactive issues and PRs | schedule |
| [`greetings.yml`](#greetings) | Greet first-time contributors | issue, PR |
| [`docs.yml`](#documentation) | Render and verify TYPO3 documentation | push, PR |

---

## CI

The main CI workflow. Runs PHP lint, code style, PHPStan, Rector, and unit/functional tests across a PHP/TYPO3 version matrix.

### Minimal caller

```yaml
jobs:
  ci:
    uses: netresearch/typo3-ci-workflows/.github/workflows/ci.yml@main
    permissions:
      contents: read
```

### Customized caller

```yaml
jobs:
  ci:
    uses: netresearch/typo3-ci-workflows/.github/workflows/ci.yml@main
    permissions:
      contents: read
    with:
      php-versions: '["8.2", "8.3", "8.4"]'
      typo3-versions: '["^13.4", "^14.0"]'
      matrix-exclude: '[{"php":"8.2","typo3":"^14.0"}]'
      run-functional-tests: true
      functional-test-db: mariadb
      db-image: 'mariadb:11.4'
      upload-coverage: true
      remove-dev-deps: '[{"dep":"saschaegerer/phpstan-typo3","only-for":"^12|^13"}]'
    secrets:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `php-versions` | string | `'["8.4"]'` | JSON array of PHP versions |
| `typo3-versions` | string | `'["^13.4"]'` | JSON array of TYPO3 versions |
| `matrix-exclude` | string | `'[]'` | JSON array of `{php, typo3}` combinations to exclude |
| `typo3-packages` | string | `'["typo3/cms-core"]'` | JSON array of TYPO3 packages to require |
| `php-extensions` | string | `intl, mbstring, xml` | PHP extensions to install |
| `run-lint` | boolean | `true` | Run PHP syntax lint |
| `run-cgl` | boolean | `true` | Run code style check (PHP-CS-Fixer) |
| `run-phpstan` | boolean | `true` | Run PHPStan static analysis |
| `run-rector` | boolean | `true` | Run Rector dry-run |
| `run-unit-tests` | boolean | `true` | Run PHPUnit unit tests |
| `run-functional-tests` | boolean | `false` | Run PHPUnit functional tests |
| `functional-test-db` | string | `sqlite` | Database: `sqlite`, `mysql`, `mariadb`, `postgres` |
| `db-image` | string | `mysql:9.6` | Docker image for database service |
| `upload-coverage` | boolean | `false` | Upload coverage to Codecov |
| `coverage-tool` | string | `pcov` | Coverage driver: `pcov` or `xdebug` |
| `remove-dev-deps` | string | `'[]'` | JSON array of dev deps to remove for TYPO3 version compat |
| `cgl-command` | string | auto-detect | Override CGL command |
| `phpstan-command` | string | auto-detect | Override PHPStan command |
| `rector-command` | string | auto-detect | Override Rector command |
| `unit-test-command` | string | auto-detect | Override unit test command |
| `functional-test-command` | string | auto-detect | Override functional test command |

### Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `CODECOV_TOKEN` | No | Required when `upload-coverage: true` |

### Auto-detection

Commands are auto-detected from composer scripts (in order):
- **CGL:** `ci:test:php:cgl`, `ci:cgl` (+ `--dry-run`), `ci:lint:php`, `check:php:cs-fixer`, `code:style:check`
- **PHPStan:** `ci:test:php:phpstan` (+ `--error-format=github`), `ci:phpstan` (+ `--error-format=github`), `ci:stan`, `check:php:stan`, `code:phpstan`
- **Rector:** `ci:test:php:rector`, `check:php:rector`
- **Unit tests:** `ci:test:php:unit` (+ `--no-coverage`/`--coverage-clover`), `ci:tests:unit`, `check:tests:unit`, `test:unit`
- **Functional tests:** `ci:test:php:functional` (+ `--no-coverage`/`--coverage-clover`), `ci:tests:functional`, `check:tests:functional`, `test:functional`

CGL and Rector run on the first PHP version only (code style is PHP-version-independent). PHPStan and tests run on the full matrix.

---

## Extended Testing

Coverage, mutation testing, fuzz testing, and JavaScript testing. Each suite is a simple boolean toggle.

### Minimal caller (defaults: unit + functional coverage, mutation, fuzz, JS)

```yaml
jobs:
  extended:
    uses: netresearch/typo3-ci-workflows/.github/workflows/extended-testing.yml@main
    permissions:
      contents: read
    secrets:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
      INFECTION_DASHBOARD_API_KEY: ${{ secrets.INFECTION_DASHBOARD_API_KEY }}
```

### Customized caller (enable integration + E2E, disable JS)

```yaml
jobs:
  extended:
    uses: netresearch/typo3-ci-workflows/.github/workflows/extended-testing.yml@main
    permissions:
      contents: read
    with:
      run-integration-tests: true
      run-e2e-tests: true
      run-js-tests: false
    secrets:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
      INFECTION_DASHBOARD_API_KEY: ${{ secrets.INFECTION_DASHBOARD_API_KEY }}
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `php-version` | string | `8.5` | PHP version for coverage runs |
| `node-version` | string | `24` | Node.js version for JS testing |
| `run-unit-tests` | boolean | `true` | Run PHP unit tests with coverage |
| `run-functional-tests` | boolean | `true` | Run PHP functional tests with coverage |
| `run-integration-tests` | boolean | `false` | Run PHP integration tests with coverage |
| `run-e2e-tests` | boolean | `false` | Run PHP E2E tests with coverage |
| `run-js-tests` | boolean | `true` | Run JavaScript tests (Vitest) |
| `run-mutation-tests` | boolean | `true` | Run PHP mutation testing (Infection) |
| `run-fuzz-tests` | boolean | `true` | Run PHP fuzz tests |
| `unit-test-config` | string | `Build/phpunit/UnitTests.xml` | PHPUnit config for unit tests |
| `functional-test-config` | string | `Build/phpunit/FunctionalTests.xml` | PHPUnit config for functional tests |
| `integration-test-config` | string | `Build/phpunit/IntegrationTests.xml` | PHPUnit config for integration tests |
| `e2e-test-config` | string | `Build/phpunit/E2ETests.xml` | PHPUnit config for E2E tests |

### Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `CODECOV_TOKEN` | No | Codecov upload token |
| `INFECTION_DASHBOARD_API_KEY` | No | Infection dashboard API key |

### Jobs

| Job | Default | Depends on | Description |
|-----|---------|------------|-------------|
| `unit-coverage` | on | - | Unit tests with coverage upload |
| `functional-coverage` | on | - | Functional tests with coverage upload |
| `integration-coverage` | off | - | Integration tests with coverage upload |
| `e2e-coverage` | off | - | E2E tests with coverage upload |
| `mutation-testing` | on | unit-coverage | Infection mutation testing |
| `js-coverage` | on | - | Vitest with coverage upload |
| `fuzz-testing` | on | - | PHPUnit fuzz test group |

---

## E2E Tests

Playwright browser tests against a running TYPO3 instance with database.

### Minimal caller

```yaml
jobs:
  e2e:
    uses: netresearch/typo3-ci-workflows/.github/workflows/e2e.yml@main
    permissions:
      contents: read
```

### Customized caller

```yaml
jobs:
  e2e:
    uses: netresearch/typo3-ci-workflows/.github/workflows/e2e.yml@main
    permissions:
      contents: read
    with:
      php-version: '8.4'
      db-image: 'mariadb:11.4'
      test-command: 'npm run test:e2e -- --project=chromium'
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `php-version` | string | `8.4` | PHP version |
| `node-version` | string | `24` | Node.js version |
| `typo3-setup-extensions` | boolean | `true` | Run extension:setup after TYPO3 setup |
| `playwright-browser` | string | `chromium` | Playwright browser to install |
| `test-command` | string | `npm run test:e2e` | E2E test command |
| `db-image` | string | `mariadb:11.4` | Database Docker image |
| `php-extensions` | string | `mysqli, pdo_mysql, gd, intl, curl, zip` | PHP extensions to install |
| `timeout-minutes` | number | `30` | Job timeout in minutes |
| `artifact-path` | string | `Tests/E2E/Playwright/reports/` | Path to Playwright reports |
| `web-dir` | string | `.Build/Web` | TYPO3 web directory (document root) |

---

## Security

Gitleaks secret scanning and Composer dependency audit.

### Minimal caller

```yaml
jobs:
  security:
    uses: netresearch/typo3-ci-workflows/.github/workflows/security.yml@main
    permissions:
      contents: read
      security-events: write
    secrets:
      GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }}
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `php-version` | string | `8.4` | PHP version for Composer audit |
| `skip-gitleaks` | boolean | `false` | Skip Gitleaks secret scanning |
| `skip-composer-audit` | boolean | `false` | Skip Composer dependency audit |

### Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `GITLEAKS_LICENSE` | No | License key for Gitleaks |

---

## CodeQL

GitHub CodeQL security scanning.

### Minimal caller

```yaml
jobs:
  codeql:
    uses: netresearch/typo3-ci-workflows/.github/workflows/codeql.yml@main
    permissions:
      contents: read
      security-events: write
      actions: read
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `languages` | string | `actions` | CodeQL languages to analyze (comma-separated) |

---

## Dependency Review

Dependency vulnerability review on pull requests.

### Minimal caller

```yaml
jobs:
  dependency-review:
    uses: netresearch/typo3-ci-workflows/.github/workflows/dependency-review.yml@main
    permissions:
      contents: read
      pull-requests: write
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `fail-on-severity` | string | `high` | Minimum severity to fail on (`low`, `moderate`, `high`, `critical`) |

---

## License Check

PHP dependency license audit. Fails when forbidden licenses are found.

### Minimal caller

```yaml
jobs:
  license-check:
    uses: netresearch/typo3-ci-workflows/.github/workflows/license-check.yml@main
    permissions:
      contents: read
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `php-version` | string | `8.4` | PHP version for license checking |
| `forbidden-licenses` | string | `"(SSPL\|BSL)"` | Regex pattern for forbidden licenses |

---

## Scorecard

OpenSSF Scorecard analysis. No inputs.

### Minimal caller

```yaml
jobs:
  scorecard:
    uses: netresearch/typo3-ci-workflows/.github/workflows/scorecard.yml@main
    permissions:
      contents: read
      security-events: write
      id-token: write
      actions: read
```

---

## Release

Enterprise release pipeline: git archive, SBOM generation (SPDX + CycloneDX), SHA256 checksums, Cosign keyless signing, build provenance attestation, and GitHub Release.

### Minimal caller

```yaml
jobs:
  release:
    uses: netresearch/typo3-ci-workflows/.github/workflows/release.yml@main
    permissions:
      contents: write
      id-token: write
      attestations: write
    with:
      archive-prefix: my-extension
      package-name: vendor/my-extension
```

### Inputs

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `archive-prefix` | string | **yes** | - | Prefix for archive files (e.g., `contexts`) |
| `package-name` | string | **yes** | - | Composer package name (e.g., `netresearch/contexts`) |
| `include-sbom` | boolean | no | `true` | Include SPDX and CycloneDX SBOMs |
| `sign-artifacts` | boolean | no | `true` | Sign artifacts with Cosign keyless signing |

---

## Publish to TER

Publish extension to TYPO3 TER on tag push. Auto-resolves extension key from `composer.json` and validates the tag version against `ext_emconf.php`.

### Minimal caller

```yaml
jobs:
  publish:
    uses: netresearch/typo3-ci-workflows/.github/workflows/publish-to-ter.yml@main
    permissions:
      contents: read
    secrets:
      TYPO3_TER_ACCESS_TOKEN: ${{ secrets.TYPO3_TER_ACCESS_TOKEN }}
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `php-version` | string | `8.4` | PHP version for tailor CLI |

### Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `TYPO3_TER_ACCESS_TOKEN` | Yes | TER API access token |
| `TYPO3_EXTENSION_KEY` | No | Deprecated: auto-resolved from composer.json |

---

## Auto-merge Dependency PRs

Automatically approves and merges Dependabot/Renovate PRs. Auto-detects the repo's allowed merge strategy.

### Minimal caller

```yaml
jobs:
  auto-merge:
    uses: netresearch/typo3-ci-workflows/.github/workflows/auto-merge-deps.yml@main
    permissions:
      contents: write
      pull-requests: write
```

No inputs.

---

## PR Quality Gates

PR size check and auto-approve for solo maintainer projects. Skips draft PRs.

### Minimal caller

```yaml
jobs:
  pr-quality:
    uses: netresearch/typo3-ci-workflows/.github/workflows/pr-quality.yml@main
    permissions:
      contents: read
      pull-requests: write
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `size-warning-threshold` | number | `500` | Lines changed for medium size |
| `size-alert-threshold` | number | `1000` | Lines changed for large size warning |
| `security-controls-path` | string | `.github/SECURITY_CONTROLS.md` | Path to security controls docs |

---

## Labeler

Automatic PR labeling based on file paths.

### Minimal caller

```yaml
jobs:
  labeler:
    uses: netresearch/typo3-ci-workflows/.github/workflows/labeler.yml@main
    permissions:
      contents: read
      pull-requests: write
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `configuration-path` | string | `.github/labeler.yml` | Path to the labeler configuration file |

---

## Stale Issues

Mark and close stale issues and PRs.

### Minimal caller

```yaml
jobs:
  stale:
    uses: netresearch/typo3-ci-workflows/.github/workflows/stale.yml@main
    permissions:
      issues: write
      pull-requests: write
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `days-before-stale` | number | `60` | Days before marking as stale |
| `days-before-close` | number | `7` | Days before closing stale issues |
| `exempt-issue-labels` | string | `pinned,security,bug` | Comma-separated labels to exempt |
| `exempt-pr-labels` | string | `pinned,security` | Comma-separated PR labels to exempt |
| `operations-per-run` | number | `30` | Max operations per run |
| `stale-issue-message` | string | Generic message | Message when marking issue as stale |
| `stale-pr-message` | string | Generic message | Message when marking PR as stale |
| `close-issue-message` | string | Generic message | Message when closing stale issue |
| `close-pr-message` | string | Generic message | Message when closing stale PR |

---

## Lock Threads

Lock old inactive issues and PRs.

### Minimal caller

```yaml
jobs:
  lock:
    uses: netresearch/typo3-ci-workflows/.github/workflows/lock.yml@main
    permissions:
      issues: write
      pull-requests: write
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `issue-inactive-days` | number | `365` | Days before locking inactive issues |
| `pr-inactive-days` | number | `365` | Days before locking inactive PRs |
| `issue-lock-reason` | string | `resolved` | Reason for locking issues |
| `pr-lock-reason` | string | `resolved` | Reason for locking PRs |
| `log-output` | boolean | `true` | Log processed threads |

---

## Greetings

Greet first-time contributors on issues and PRs.

### Minimal caller

```yaml
jobs:
  greetings:
    uses: netresearch/typo3-ci-workflows/.github/workflows/greetings.yml@main
    permissions:
      issues: write
      pull-requests: write
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `issue-message` | string | Generic welcome | Message for first-time issue authors |
| `pr-message` | string | Generic welcome | Message for first-time PR authors |

---

## Documentation

Render and verify TYPO3 documentation.

### Minimal caller

```yaml
jobs:
  docs:
    uses: netresearch/typo3-ci-workflows/.github/workflows/docs.yml@main
    permissions:
      contents: read
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `input` | string | `Documentation` | Path to documentation source |
| `output` | string | `Documentation-GENERATED-temp` | Path for rendered output |
| `upload-artifact` | boolean | `true` | Upload rendered docs as artifact on PRs |
| `artifact-retention-days` | number | `7` | Days to retain uploaded artifact |

---

## Fuzzing

Standalone fuzz tests and mutation testing with Infection (for repos not using `extended-testing.yml`).

### Minimal caller

```yaml
jobs:
  fuzz:
    uses: netresearch/typo3-ci-workflows/.github/workflows/fuzz.yml@main
    permissions:
      contents: read
    with:
      run-fuzz-tests: true
      run-mutation-tests: true
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `php-version` | string | `8.4` | PHP version for tests |
| `php-extensions` | string | `intl, mbstring, xml` | PHP extensions to install |
| `fuzz-testsuite` | string | `Fuzz` | PHPUnit testsuite name for fuzz tests |
| `phpunit-config` | string | `Build/phpunit.xml` | Path to PHPUnit config |
| `run-fuzz-tests` | boolean | `false` | Run fuzz tests |
| `run-mutation-tests` | boolean | `false` | Run mutation tests with Infection |
| `mutation-min-msi` | number | `50` | Minimum Mutation Score Indicator |
| `mutation-min-covered-msi` | number | `60` | Minimum Covered MSI |

---

## Two-Entrypoint Architecture

This repository provides **two complementary ways** to run CI tooling:

| Entrypoint | Environment | Use case |
|------------|-------------|----------|
| `Build/Scripts/runTests.sh` | Local development | Interactive use, quick feedback loop. Uses `.Build/bin/` tools directly (no Docker). |
| `composer ci:test:php:*` | GitHub Actions CI | Automated CI on native runners. One PHP/DB version per matrix cell. |

Both entrypoints share the **same tool configurations** (`Build/phpstan.neon`, `Build/.php-cs-fixer.php`, `Build/rector.php`, `Build/phpunit.xml`), ensuring local results match CI.

### runTests.sh Template

A generic `runTests.sh` template is provided at `assets/Build/Scripts/runTests.sh.dist`. To use it:

1. Copy to your extension: `cp .Build/vendor/netresearch/typo3-ci-workflows/assets/Build/Scripts/runTests.sh.dist Build/Scripts/runTests.sh`
2. Make executable: `chmod +x Build/Scripts/runTests.sh`
3. Customize the extension-point variables at the top of the script (config paths, etc.)

Supported commands: `unit`, `functional`, `fuzz`, `mutation`, `phpstan`, `cgl`, `cgl:fix`, `rector`, `rector:fix`, `ci`, `all`.

## Extension Setup

Add this package to your extension's `require-dev`:

```json
{
    "require-dev": {
        "netresearch/typo3-ci-workflows": "^1.1"
    }
}
```

This brings in all dev-dependencies (PHPStan, PHP-CS-Fixer, Rector, Infection, testing-framework, etc.) with a single requirement. Your extension only needs tool configuration files (`Build/phpstan.neon`, `Build/.php-cs-fixer.php`, etc.) and the reusable GitHub Actions workflows.

## Git Worktree + captainhook Workaround

When using [git worktrees](https://git-scm.com/docs/git-worktree), `.git` is a file (not a directory), which causes `captainhook/hook-installer` to fail during `composer install`.

### Problem

```
captainhook/hook-installer fails: .git/hooks is not a directory
```

### Solutions

**Solution 1: `--no-plugins`** (simplest)

```bash
composer install --no-plugins
```

This skips all Composer plugins including captainhook *and* `phpstan/extension-installer`. PHPStan plugins will not auto-register.

**Solution 2: Explicit PHPStan includes** (recommended with Solution 1)

After `--no-plugins`, include the explicit plugin file in your `Build/phpstan.neon`:

```neon
includes:
    - %currentWorkingDirectory%/.Build/vendor/netresearch/typo3-ci-workflows/config/phpstan/includes-no-extension-installer.neon
    - phpstan-baseline.neon
```

This file lists all PHPStan plugin neon files that `extension-installer` would normally auto-load.

**Solution 3: Create hooks directory first**

```bash
# For git worktrees, .git is a file pointing to the real git dir.
# Create a hooks dir where captainhook expects it:
GITDIR=$(git rev-parse --git-dir)
mkdir -p "${GITDIR}/hooks"
composer install
```

## Security

- All third-party actions are SHA-pinned
- `step-security/harden-runner` on every job
- Top-level `permissions: {}` with job-level least-privilege
- `persist-credentials: false` on all checkout steps
- No `${{ }}` expression interpolation in `run:` blocks
- Randomized heredoc delimiters to prevent output injection
- Timeout-minutes on every job
