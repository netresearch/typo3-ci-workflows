# typo3-ci-workflows

Reusable GitHub Actions workflows for Netresearch TYPO3 extension repositories.

## Workflows

| Workflow | Purpose |
|----------|--------|
| `ci.yml` | PHP lint, CGL, PHPStan, Rector, unit tests, functional tests |
| `scorecard.yml` | OpenSSF Scorecard analysis |
| `codeql.yml` | GitHub CodeQL security scanning |
| `dependency-review.yml` | Dependency vulnerability review on PRs |
| `auto-merge-deps.yml` | Auto-merge Dependabot/Renovate PRs |
| `publish-to-ter.yml` | Publish extension to TYPO3 TER on tag |
| `labeler.yml` | Automatic PR labeling based on file paths |
| `lock.yml` | Lock old inactive issues and PRs |
| `greetings.yml` | Greet first-time contributors |
| `docs.yml` | Render and verify TYPO3 documentation |
| `stale.yml` | Mark and close stale issues and PRs |
| `license-check.yml` | PHP dependency license audit |
| `security.yml` | Gitleaks secret scanning + Composer audit |
| `pr-quality.yml` | PR size check + auto-approve for solo maintainers |
| `release.yml` | Enterprise release pipeline (archive, SBOM, cosign, attestation) |

## Quick Start

Create `.github/workflows/ci.yml` in your extension repository:

```yaml
name: CI
on:
  push:
  pull_request:
permissions: {}
jobs:
  ci:
    uses: netresearch/typo3-ci-workflows/.github/workflows/ci.yml@main
    permissions:
      contents: read
    with:
      php-versions: '["8.2", "8.3", "8.4"]'
      typo3-versions: '["^13.4", "^14.0"]'
```

## CI Workflow Inputs

### Matrix Configuration

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `php-versions` | string | `'["8.4"]'` | JSON array of PHP versions |
| `typo3-versions` | string | `'["^13.4"]'` | JSON array of TYPO3 versions |
| `matrix-exclude` | string | `'[]'` | JSON array of `{php, typo3}` combinations to exclude |
| `typo3-packages` | string | `'["typo3/cms-core"]'` | JSON array of TYPO3 packages to require |

### Feature Flags

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `run-lint` | boolean | `true` | Run PHP syntax lint |
| `run-cgl` | boolean | `true` | Run code style check (PHP-CS-Fixer) |
| `run-phpstan` | boolean | `true` | Run PHPStan static analysis |
| `run-rector` | boolean | `true` | Run Rector dry-run |
| `run-unit-tests` | boolean | `true` | Run PHPUnit unit tests |
| `run-functional-tests` | boolean | `false` | Run PHPUnit functional tests |

### Custom Commands

Override auto-detection with custom commands:

| Input | Type | Default |
|-------|------|---------|
| `cgl-command` | string | auto-detect |
| `phpstan-command` | string | auto-detect |
| `rector-command` | string | auto-detect |
| `unit-test-command` | string | auto-detect |
| `functional-test-command` | string | auto-detect |

Auto-detection looks for these composer scripts (in order):
- CGL: `ci:test:php:cgl`, `ci:cgl` (+ `--dry-run`), `ci:lint:php`, `check:php:cs-fixer`, `code:style:check`
- PHPStan: `ci:test:php:phpstan` (+ `--error-format=github`), `ci:phpstan` (+ `--error-format=github`), `ci:stan`, `check:php:stan`, `code:phpstan`
- Rector: `ci:test:php:rector`, `check:php:rector`
- Unit tests: `ci:test:php:unit` (+ `--no-coverage`/`--coverage-clover`), `ci:tests:unit`, `check:tests:unit`, `test:unit`
- Functional tests: `ci:test:php:functional` (+ `--no-coverage`/`--coverage-clover`), `ci:tests:functional`, `check:tests:functional`, `test:functional`

**Note:** Some scripts get additional arguments appended automatically (shown in parentheses). Ensure your composer scripts accept `--` pass-through arguments.

### PHP Extensions

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `php-extensions` | string | `intl, mbstring, xml` | PHP extensions to install |

CGL and Rector run on the first PHP version only (code style is PHP-version-independent). PHPStan and tests run on the full matrix.

### Functional Tests

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `functional-test-db` | string | `sqlite` | Database: `sqlite`, `mysql`, `mariadb`, `postgres` |
| `db-image` | string | `mysql:9.6` | Docker image for database service |

### Coverage

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `upload-coverage` | boolean | `false` | Upload coverage to Codecov |
| `coverage-tool` | string | `pcov` | Coverage driver: `pcov` or `xdebug` |

Requires `CODECOV_TOKEN` secret when enabled.

### Incompatible Dev Dependencies

Remove dev dependencies that are incompatible with certain TYPO3 versions:

```yaml
remove-dev-deps: '[{"dep":"saschaegerer/phpstan-typo3","only-for":"^12|^13"}]'
```

The `only-for` field supports pipe-separated version prefixes. Dependencies are removed when the TYPO3 version doesn't match any pattern.

## Other Workflows

### Scorecard

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

### CodeQL

```yaml
jobs:
  codeql:
    uses: netresearch/typo3-ci-workflows/.github/workflows/codeql.yml@main
    permissions:
      contents: read
      security-events: write
      actions: read
```

### Dependency Review

```yaml
jobs:
  dependency-review:
    uses: netresearch/typo3-ci-workflows/.github/workflows/dependency-review.yml@main
    permissions:
      contents: read
      pull-requests: write
```

### Auto-merge Dependency PRs

```yaml
jobs:
  auto-merge:
    uses: netresearch/typo3-ci-workflows/.github/workflows/auto-merge-deps.yml@main
    permissions:
      contents: write
      pull-requests: write
```

### Publish to TER

```yaml
jobs:
  publish:
    uses: netresearch/typo3-ci-workflows/.github/workflows/publish-to-ter.yml@main
    permissions:
      contents: read
    secrets:
      TYPO3_EXTENSION_KEY: ${{ secrets.TYPO3_EXTENSION_KEY }}
      TYPO3_TER_ACCESS_TOKEN: ${{ secrets.TYPO3_TER_ACCESS_TOKEN }}
```

### Labeler

```yaml
jobs:
  labeler:
    uses: netresearch/typo3-ci-workflows/.github/workflows/labeler.yml@main
    permissions:
      contents: read
      pull-requests: write
```

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `configuration-path` | string | `.github/labeler.yml` | Path to the labeler configuration file |

### Lock Threads

```yaml
jobs:
  lock:
    uses: netresearch/typo3-ci-workflows/.github/workflows/lock.yml@main
    permissions:
      issues: write
      pull-requests: write
```

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `issue-inactive-days` | number | `365` | Days before locking inactive issues |
| `pr-inactive-days` | number | `365` | Days before locking inactive PRs |
| `issue-lock-reason` | string | `resolved` | Reason for locking issues |
| `pr-lock-reason` | string | `resolved` | Reason for locking PRs |
| `log-output` | boolean | `true` | Log processed threads |

### Greetings

```yaml
jobs:
  greetings:
    uses: netresearch/typo3-ci-workflows/.github/workflows/greetings.yml@main
    permissions:
      issues: write
      pull-requests: write
    with:
      issue-message: 'Custom welcome message for issues'
      pr-message: 'Custom welcome message for PRs'
```

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `issue-message` | string | Generic welcome | Message for first-time issue authors |
| `pr-message` | string | Generic welcome | Message for first-time PR authors |

### Documentation

```yaml
jobs:
  docs:
    uses: netresearch/typo3-ci-workflows/.github/workflows/docs.yml@main
    permissions:
      contents: read
```

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `source-path` | string | `Documentation` | Path to documentation source |
| `output-path` | string | `Documentation-GENERATED-temp` | Path for rendered output |
| `upload-artifact` | boolean | `true` | Upload rendered docs as artifact on PRs |
| `artifact-retention-days` | number | `7` | Days to retain uploaded artifact |

### Stale Issues

```yaml
jobs:
  stale:
    uses: netresearch/typo3-ci-workflows/.github/workflows/stale.yml@main
    permissions:
      issues: write
      pull-requests: write
```

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

Stale labels (`stale`) are hardcoded to stay within the 10-input workflow_call limit.

### License Check

```yaml
jobs:
  license-check:
    uses: netresearch/typo3-ci-workflows/.github/workflows/license-check.yml@main
    permissions:
      contents: read
```

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `php-version` | string | `8.4` | PHP version for license checking |
| `forbidden-licenses` | string | `"(SSPL\|BSL)"` | Regex pattern for forbidden licenses |

Fails the job (exit 1) when forbidden licenses are found, not just a warning.

### Security

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

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `php-version` | string | `8.4` | PHP version for Composer audit |
| `skip-gitleaks` | boolean | `false` | Skip Gitleaks secret scanning |
| `skip-composer-audit` | boolean | `false` | Skip Composer dependency audit |

| Secret | Required | Description |
|--------|----------|-------------|
| `GITLEAKS_LICENSE` | No | License key for Gitleaks |

Gitleaks automatically skips dependabot PRs and merge_group events.

### PR Quality Gates

```yaml
jobs:
  pr-quality:
    uses: netresearch/typo3-ci-workflows/.github/workflows/pr-quality.yml@main
    permissions:
      contents: read
      pull-requests: write
```

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `size-warning-threshold` | number | `500` | Lines changed for medium size |
| `size-alert-threshold` | number | `1000` | Lines changed for large size warning |
| `security-controls-path` | string | `.github/SECURITY_CONTROLS.md` | Path to security controls docs |

Includes two jobs: PR size check and auto-approve for solo maintainer projects. Skips draft PRs.

### Release

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

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `archive-prefix` | string | **yes** | — | Prefix for archive files (e.g., `contexts`) |
| `package-name` | string | **yes** | — | Composer package name (e.g., `netresearch/contexts`) |
| `include-sbom` | boolean | no | `true` | Include SPDX and CycloneDX SBOMs |
| `sign-artifacts` | boolean | no | `true` | Sign artifacts with Cosign keyless signing |

Full enterprise release pipeline: git archive, SBOM generation (SPDX + CycloneDX), SHA256 checksums, Cosign keyless signing, build provenance attestation, and GitHub Release with verification instructions.

## Security

- All third-party actions are SHA-pinned
- `step-security/harden-runner` on every job
- Top-level `permissions: {}` with job-level least-privilege
- No `${{ }}` expression interpolation in `run:` blocks
- Timeout-minutes on every job
