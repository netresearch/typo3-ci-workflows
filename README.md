# typo3-ci-workflows

Reusable GitHub Actions workflows for Netresearch TYPO3 extension repositories.

## Workflows

| Workflow | Purpose |
|----------|---------|
| `ci.yml` | PHP lint, CGL, PHPStan, Rector, unit tests, functional tests |
| `scorecard.yml` | OpenSSF Scorecard analysis |
| `codeql.yml` | GitHub CodeQL security scanning |
| `dependency-review.yml` | Dependency vulnerability review on PRs |
| `auto-merge-deps.yml` | Auto-merge Dependabot/Renovate PRs |
| `publish-to-ter.yml` | Publish extension to TYPO3 TER on tag |

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
- PHPStan: `ci:test:php:phpstan` (+ `--error-format=github`), `ci:stan`, `check:php:stan`, `code:phpstan`
- Rector: `ci:test:php:rector`, `check:php:rector`
- Unit tests: `ci:test:php:unit` (+ `--no-coverage`/`--coverage-clover`), `check:tests:unit`
- Functional tests: `ci:test:php:functional` (+ `--no-coverage`/`--coverage-clover`), `check:tests:functional`

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

## Security

- All third-party actions are SHA-pinned
- `step-security/harden-runner` on every job
- Top-level `permissions: {}` with job-level least-privilege
- No `${{ }}` expression interpolation in `run:` blocks
- Timeout-minutes on every job
