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
| [`security.yml`](#security) | Composer audit + Opengrep SAST | push, PR |
| [`codeql.yml`](#codeql) | GitHub CodeQL security scanning | push, schedule |
| [`dependency-review.yml`](#dependency-review) | Dependency vulnerability review | PR only |
| [`license-check.yml`](#license-check) | PHP dependency license audit | push, PR |
| [`scorecard.yml`](#scorecard) | OpenSSF Scorecard analysis | push, schedule |

### Release & Publish

| Workflow | Purpose | Trigger |
|----------|---------|---------|
| [`release.yml`](#release) | Enterprise release pipeline (archive, SBOM, cosign, attestation) | tag push |
| [`publish-to-ter.yml`](#publish-to-ter) | Publish extension to TYPO3 TER | tag push |
| [`changelog-assemble.yml`](#changelog-fragments) | Assemble changelog fragments into a released section | release prep |
| [`changelog-check.yml`](#changelog-fragments) | Require a changelog fragment on a pull request | PR |

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
      php-versions: '["8.2", "8.3", "8.4", "8.5"]'
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
| `php-versions` | string | `'["8.5"]'` | JSON array of PHP versions |
| `typo3-versions` | string | `'["^13.4"]'` | JSON array of TYPO3 versions |
| `matrix-exclude` | string | `'[]'` | JSON array of `{php, typo3}` combinations to exclude |
| `rector-php-version` | string | `''` | PHP version for the Rector job; empty falls back to `php-versions[0]`. Set it when `php-versions` varies by event — see below |
| `cgl-php-version` | string | `''` | PHP version for the Code Style job; empty falls back to `php-versions[0]`. Set it when the code style toolchain needs a newer PHP than the repo's support floor (the dev meta-package requires `php ^8.2`) |
| `typo3-packages` | string | `'["typo3/cms-core"]'` | JSON array of TYPO3 packages to require |
| `php-extensions` | string | `intl, mbstring, xml` | PHP extensions to install |
| `run-lint` | boolean | `true` | Run PHP syntax lint |
| `run-cgl` | boolean | `true` | Run code style check (PHP-CS-Fixer) |
| `run-phpstan` | boolean | `true` | Run PHPStan static analysis |
| `run-phpstan-unpinned` | boolean | `true` | Additionally analyse one cell against the PHPUnit the matrix really resolves. Warns, does not fail. See [PHPStan and the PHPUnit cap](#phpstan-and-the-phpunit-cap). |
| `phpstan-unpinned-blocking` | boolean | `false` | Make that pass fail the build instead of warning. Turn on per repo once it is clean. |
| `run-rector` | boolean | `true` | Run Rector dry-run |
| `run-fractor` | boolean | `false` | Run Fractor dry-run (TYPO3/Fluid migrations) |
| `run-repo-checks` | boolean | `false` | Run the caller's own file checks (CHANGELOG shape, workflow hygiene, anything repo-specific), so an extension needs no workflow job of its own |
| `run-unit-tests` | boolean | `true` | Run PHPUnit unit tests |
| `run-functional-tests` | boolean | `false` | Run PHPUnit functional tests |
| `run-acceptance-tests` | boolean | `false` | Run PHPUnit acceptance tests |
| `functional-test-db` | string | `sqlite` | Database: `sqlite`, `mysql`, `mariadb`, `postgres` |
| `db-image` | string | `mysql:9.6` | Docker image for database service |
| `upload-coverage` | boolean | `false` | Upload coverage to Codecov |
| `upload-test-results` | boolean | `false` | Upload per-test JUnit reports to [Codecov Test Analytics](https://docs.codecov.com/docs/test-analytics) (flaky-test detection, per-test durations). Custom `*-test-command` overrides must emit `junit-unit.xml` / `junit-functional.xml` themselves. |
| `coverage-tool` | string | `xdebug` | Coverage driver: `xdebug` (branch + path coverage, matches local `XDEBUG_MODE=coverage`) or `pcov` (line-only, ~3-10× faster) |
| `remove-dev-deps` | string | `'[]'` | JSON array of dev deps to remove for TYPO3 version compat |
| `skip-paths` | string | `''` | Newline-separated globs. On `pull_request` only, skip the whole workflow when **every** changed file matches. See [Path gating](#path-gating). |
| `cgl-command` | string | auto-detect | Override CGL command |
| `phpstan-command` | string | auto-detect | Override PHPStan command |
| `rector-command` | string | auto-detect | Override Rector command |
| `fractor-command` | string | auto-detect | Override Fractor command |
| `repo-checks-command` | string | auto-detect | Override the repo-checks command (default `composer ci:test:repo`). Must not need vendor — the job runs no `composer install`. |
| `unit-test-command` | string | auto-detect | Override unit test command |
| `functional-test-command` | string | auto-detect | Override functional test command |
| `acceptance-test-command` | string | auto-detect | Override acceptance test command |

### Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `CODECOV_TOKEN` | No | Required when `upload-coverage: true` or `upload-test-results: true` |

### Auto-detection

Commands are auto-detected from composer scripts (in order):
- **CGL:** `ci:test:php:cgl`, `ci:cgl` (+ `--dry-run`), `ci:lint:php`, `check:php:cs-fixer`, `code:style:check`
- **PHPStan:** `ci:test:php:phpstan` (+ `--error-format=github`), `ci:phpstan` (+ `--error-format=github`), `ci:stan`, `check:php:stan`, `code:phpstan`
- **Rector:** `ci:test:php:rector`, `check:php:rector`
- **Unit tests:** `ci:test:php:unit` (+ `--no-coverage`/`--coverage-clover`), `ci:tests:unit`, `check:tests:unit`, `test:unit`
- **Functional tests:** `ci:test:php:functional` (+ `--no-coverage`/`--coverage-clover`), `ci:tests:functional`, `check:tests:functional`, `test:functional`
- **Acceptance tests:** `ci:test:php:acceptance`

CGL and Rector run on a single PHP version — `php-versions[0]`, or `cgl-php-version` / `rector-php-version` when the respective input is set. PHPStan and tests run on the full matrix.

> [!WARNING]
> **Set `rector-php-version` if `php-versions` varies by event.**
> Since Rector 2.6.0 the PHPUnit rule set is activated from the *installed* phpunit, and phpunit's resolution follows the PHP version. A caller that narrows the matrix for the merge queue, e.g.
>
> ```yaml
> php-versions: ${{ github.event_name == 'merge_group' && '["8.4"]' || '["8.2","8.3","8.4","8.5"]' }}
> ```
>
> then runs Rector on 8.2 for the pull request and on 8.4 in the queue. Different PHP, different phpunit, different rule set: the PR goes green and the merge group goes red on an unchanged commit, and the queue entry is dropped without a failing check on the PR itself. Pin the job instead:
>
> ```yaml
> rector-php-version: '8.2'
> ```
>
> Choose the version the code is meant to satisfy. For a library supporting a PHP range, that is normally the lowest supported version — a rule set activated by a newer phpunit can emit code the oldest supported one cannot run.

> [!WARNING]
> **Your composer script must forward `"$@"`, or coverage silently uploads nothing.**
> The flags above are appended by composer as `<script> -- --coverage-clover=…`. A script wrapped in `sh -c '…'` receives them as `$0` of the *wrapper*, not as tool flags, so PHPUnit never sees them — no report is written, and because the Codecov step uses `fail_ci_if_error: false`, the upload of a nonexistent file passes silently. `--filter` is swallowed the same way.
>
> ```jsonc
> // Broken: flags land in $0 and vanish.
> "ci:test:php:unit": "sh -c 'if [ -n \"${CI:-}\" ]; then phpunit --testsuite unit; else ./Build/Scripts/runTests.sh -s unit; fi'"
>
> // Fixed: "$@" in each branch, and `--` terminates the sh -c script.
> "ci:test:php:unit": "sh -c 'if [ -n \"${CI:-}\" ]; then phpunit --testsuite unit \"$@\"; else ./Build/Scripts/runTests.sh -s unit \"$@\"; fi' --"
> ```
>
> Check for it: `composer ci:test:php:unit -- --filter NoSuchTest` should report no tests. If it runs the whole suite, the flags are being swallowed and your coverage has never been uploaded.
> A PHPUnit config also needs a `<source>` block, or PHPUnit answers with `No filter is configured, code coverage will not be processed` and writes nothing.

### PHPStan and the PHPUnit cap

The **PHPStan** job installs `phpunit/phpunit:<13` before analysing. Your test jobs do not — on PHP 8.4/8.5, `typo3/testing-framework` resolves PHPUnit 13. Static analysis therefore runs against a PHPUnit that half the matrix never executes.

The cap exists because PHPUnit 13 narrowed `Stub::method()` to return `InvocationStubber`, which declares no `with*()`. Every `->method()->with()` chain without `expects()` becomes a PHPStan `method.notFound`, and PHPUnit deprecates the same call at runtime ("will no longer be possible in PHPUnit 14"). Those findings are real, not a `phpstan-phpunit` gap — but turning them on for every consumer at once would redden repos that have not migrated yet.

So the **PHPStan (unpinned PHPUnit)** job analyses one cell — the highest non-excluded `php`/`typo3` combination, which resolves the newest PHPUnit — with no cap, and reports what the capped job cannot see:

| Outcome | Job result | What you get |
|---------|------------|--------------|
| Clean | pass | Resolved PHPUnit version in the step summary |
| Errors, `phpstan-unpinned-blocking: false` (default) | pass | PHPStan annotations on the diff, plus a warning and a step summary |
| Errors, `phpstan-unpinned-blocking: true` | **fail** | Same annotations, build fails |

The capped job must be green for the run to pass, so anything this job reports is the PHPUnit delta and nothing else.

Turn `phpstan-unpinned-blocking: true` on once your repo is clean, so the cleanup cannot regress. When every consumer is there, the cap and this job both go away.

Set `run-phpstan-unpinned: false` to skip the extra job (one job per run).

### Path gating

`skip-paths` gates a whole workflow off when a PR touches nothing that could affect it — a docs-only PR need not run an 8-cell functional matrix.

```yaml
    with:
      skip-paths: |
        Documentation/*
        *.md
```

Patterns are shell `case` globs, so `*` also crosses `/` (`Documentation/*` matches `Documentation/a/b.rst`, and `*.md` matches any `.md` at any depth).

> [!IMPORTANT]
> **Use this instead of the caller's `paths-ignore`, not alongside it.** Branch rulesets name the matrix jobs as required checks, and a workflow that never *starts* never reports them — `paths-ignore` leaves docs PRs permanently BLOCKED. Gating inside `preflight` means the jobs still run and report `skipped`, which satisfies the ruleset.

Safety properties:

- **`pull_request` only.** `merge_group` and `push` are never gated, so nothing reaches the default branch unvalidated.
- **All-or-nothing.** One changed file outside the globs runs everything — a PR mixing docs and source is never skipped.
- **Fails open.** API errors, or a file list at the compare endpoint's 300-file cap, run everything.
- Needs only `contents: read` (uses the compare endpoint, not `pulls/{n}/files`).

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
      php-version: '8.5'
      db-image: 'mariadb:11.4'
      test-command: 'npm run test:e2e -- --project=chromium'
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `php-version` | string | `8.5` | PHP version |
| `node-version` | string | `24` | Node.js version |
| `typo3-setup-extensions` | boolean | `true` | Run extension:setup after TYPO3 setup |
| `playwright-browser` | string | `chromium` | Playwright browser to install |
| `playwright-install-timeout-minutes` | number | `5` | Wall-clock bound for one `playwright install` attempt; the step retries once. Browsers are cached under `~/.cache/ms-playwright`, so most runs never download. |
| `php-server-workers` | string | `'1'` | Worker processes for the built-in `php -S` server. Raise to at least the Playwright worker count before setting `workers > 1`, or the suite serialises at the web server. |
| `skip-paths` | string | `''` | Newline-separated globs. On `pull_request` only, skip the whole workflow when **every** changed file matches. See [Path gating](#path-gating). |
| `test-command` | string | `npm run test:e2e` | E2E test command |
| `db-image` | string | `mariadb:11.4` | Database Docker image |
| `php-extensions` | string | `mysqli, pdo_mysql, gd, intl, curl, zip` | PHP extensions to install |
| `timeout-minutes` | number | `30` | Job timeout in minutes |
| `artifact-path` | string | `Tests/E2E/Playwright/reports/` | Path to Playwright reports |
| `web-dir` | string | `.Build/Web` | TYPO3 web directory (document root) |
| `typo3-versions` | string (JSON) | `'[""]'` | Matrix dimension: TYPO3 core version constraints (e.g. `'["^13.4.21","^14.3"]'`). Empty entry = use composer.json as-is. Each entry runs as a separate job. |
| `typo3-packages` | string (JSON) | `'["typo3/cms-core"]'` | Packages whose constraints get bumped per `typo3-versions` matrix entry, applied via `composer require --no-update` (or `composer require --with-all-dependencies` when a `composer.lock` is committed) before install. |
| `setup-variants` | string (JSON) | `'[""]'` | Matrix dimension: setup variant names (e.g. `'["bootstrap","core-only","fsc-set"]'`). Passed to `setup-script` and tests as `$E2E_VARIANT`. |
| `setup-script` | string | `''` | Path to a custom setup script (relative to repo root). When set, replaces the entire built-in pipeline — the script must install deps, set up TYPO3, start any servers, and run tests. Receives `E2E_VARIANT`, `E2E_TYPO3_VERSION`, `E2E_TYPO3_PACKAGES` as env vars. Use this for extensions with comprehensive containerized setups (Apache+PHP-FPM, custom DB seeding, Content Blocks fixtures). |

### Matrix expansion across setup variants

Many TYPO3 extensions need to be tested against several "extension neighborhoods" to catch regressions that are only visible in specific configurations — e.g. a vanilla TYPO3 install with no `fluid_styled_content` site set behaves differently than one with Bootstrap Package, and bugs that show up in one setup are silently masked in the other. Use `typo3-versions` × `setup-variants` to fan out:

```yaml
jobs:
  e2e:
    uses: netresearch/typo3-ci-workflows/.github/workflows/e2e.yml@main
    permissions:
      contents: read
    with:
      typo3-versions: '["^13.4.21","^14.3"]'
      setup-variants: '["bootstrap","core-only","fsc-set"]'
      setup-script: 'Build/Scripts/runTests.sh'   # reads $E2E_VARIANT, $E2E_TYPO3_VERSION, $E2E_TYPO3_PACKAGES
      artifact-path: 'Build/test-results/'
```

This produces 6 jobs (2 TYPO3 versions × 3 variants), each isolated. The setup script branches on `$E2E_VARIANT` to install the right neighborhood (e.g. with/without `bk2k/bootstrap-package`, with/without `typo3/cms-fluid-styled-content`).

---

## Security

Composer dependency audit and [Opengrep](https://github.com/opengrep/opengrep) SAST (the fully-OSS LGPL-2.1 fork of Semgrep). Both jobs run by default.

Opengrep **blocks CI on findings at severity WARNING or higher** and also uploads SARIF to the repo's **Security** tab. Override `opengrep-config` to tune behavior:

- **Report-only (all findings, CI never fails):** `--config auto` — drop both `--error` and `--severity` so every finding reaches the Security tab without gating merges.
- **Block only on critical (RCE/SQLi/XXE):** `--config auto --error --severity ERROR`.
- **Block on everything, including INFO:** `--config auto --error --severity INFO`.

### Minimal caller

```yaml
jobs:
  security:
    uses: netresearch/typo3-ci-workflows/.github/workflows/security.yml@main
    permissions:
      contents: read
      security-events: write
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `php-version` | string | `8.5` | PHP version for Composer audit |
| `skip-composer-audit` | boolean | `false` | Skip Composer dependency audit |
| `skip-opengrep` | boolean | `false` | Skip Opengrep SAST scanning |
| `opengrep-config` | string | `--config auto --error --severity WARNING` | Opengrep scan arguments (rules + behavior flags). See the [overrides above](#security) for report-only, ERROR-only, and INFO-blocking variants. |

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
| `php-version` | string | `8.5` | PHP version for license checking |
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
| `make-latest` | boolean | no | `true` | Mark the release as the repository's "Latest". Set `false` on backport branches — see [Backport releases and the Latest badge](#backport-releases-and-the-latest-badge) |

### Backport releases and the Latest badge

GitHub's release API defaults `make_latest` to `true`, so a release cut from a maintenance branch takes the "Latest" badge and the `/releases/latest` redirect away from the newest version — `v2.0.12` off the `TYPO3-12` line displacing `v4.0.0`. Composer resolution is unaffected (it is constraint- and tag-based), the repository landing page is not.

Set `make-latest: false` in the release caller on every branch that is not the top major line. `release-typo3-extension.yml` takes the same input.

```yaml
# .github/workflows/release.yml on branch TYPO3-12
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
      make-latest: false
```

---

## Changelog Fragments

**Opt-in.** A repository that does not call these workflows is unaffected.

A shared `CHANGELOG.md` is the one file every pull request edits in the same
place, right under `## [Unreleased]`. Every pull request after the first one to
merge therefore conflicts, and always in the same shape: both sides added a
bullet. Measured on `netresearch/t3x-nr-llm` on 2026-08-09, all 28 pairings of
eight open pull requests conflicted — in `CHANGELOG.md` and in nothing else.

Two things that do **not** solve it, so nobody spends an afternoon on them:

- `.gitattributes` with `merge=union` is the git-native answer, and GitHub
  ignores repository-supplied merge drivers server-side — in pull requests and
  in the merge queue alike ([community discussion #9288](https://github.com/orgs/community/discussions/9288)).
- A ruleset cannot help either. Rulesets *gate* a merge; they do not decide how
  one resolves.

Fragments remove the conflict by construction: one file per change, so no two
pull requests touch the same path.

### How a contributor uses it

Add one file per user-visible change:

```
Changelog.d/701.fixed.md
```

`<name>.<type>.md`, where `<type>` is `added`, `changed`, `deprecated`,
`removed`, `fixed` or `security` — the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
headings. The name is free (a PR number, an issue number, a slug) and only
orders entries within their group. The file contains the entry itself, without
the leading `- `:

```markdown
Model discovery seeds the capabilities the provider actually reports (#671).
Continuation lines are indented into the bullet automatically.
```

Mark a breaking change inline (`**Breaking:** …`) as before. There is no
`### Breaking` heading, because the released section must stay in the shape
`publish-to-ter.yml` already parses for its TER upload comment.

### Assembling at release time

```yaml
jobs:
  changelog:
    uses: netresearch/typo3-ci-workflows/.github/workflows/changelog-assemble.yml@main
    permissions:
      contents: write
    with:
      version: ${{ inputs.version }}
```

It writes `## [<version>] - <date>` with the grouped entries, deletes the
consumed fragments, and commits both in one signed commit. The commit is made
through the GitHub API on purpose: a plain `git commit` on a runner is
unsigned, and a repository with a `required_signatures` ruleset refuses it.
`expectedHeadOid` makes the commit fail on a concurrent push rather than
overwrite it.

`## [Unreleased]` is left alone. A repository migrating to fragments still has
hand-written entries there, and folding them into a release would attribute
them to a version nobody checked them against — the workflow warns instead.

#### Inputs

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `version` | string | **yes** | - | Version being released, no leading `v` |
| `fragments-dir` | string | no | `Changelog.d` | Directory holding the fragments |
| `changelog-file` | string | no | `CHANGELOG.md` | Changelog to write into |
| `release-date` | string | no | today (UTC) | Release date as `YYYY-MM-DD` |
| `commit` | boolean | no | `true` | Commit the result via the GitHub API |
| `branch` | string | no | current ref | Branch to commit to |
| `allow-empty` | boolean | no | `false` | Succeed with no fragments at all |

#### Outputs

| Output | Description |
|--------|-------------|
| `section` | The assembled markdown, without its version heading |
| `fragment-count` | Number of fragments consumed |

The run fails — loudly, before writing anything — on an unknown fragment type, a
file without a `.<type>` segment, an empty fragment, a version the changelog
already has, a non-semantic version, and on no fragments at all unless
`allow-empty` says otherwise.

### Requiring a fragment on a pull request

```yaml
jobs:
  changelog:
    uses: netresearch/typo3-ci-workflows/.github/workflows/changelog-check.yml@main
    permissions:
      contents: read
      pull-requests: read
```

Separately opt-in, because assembly works without it — but without it a fragment
is simply forgotten and the entry quietly disappears from the release. The check
only reports; whether it blocks is the repository's ruleset decision.

#### Inputs

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `fragments-dir` | string | no | `Changelog.d` | Directory a fragment must be added to |
| `paths-ignore` | string | no | see below | Newline-separated patterns needing no fragment |
| `skip-label` | string | no | `skip-changelog` | Label that waives the requirement |

`paths-ignore` defaults to `.github/**`, `Build/**`, `Tests/**`, `docs/**`,
`Documentation/**`, `*.md`, `.gitignore`, `.gitattributes`, `.editorconfig`. A
pull request touching only those passes.

### Migrating a repository

1. Create `Changelog.d/` with a `.gitkeep`.
2. Call `changelog-check.yml` from the pull-request workflow.
3. Call `changelog-assemble.yml` from release preparation, before the tag.
4. Leave the existing `CHANGELOG.md` untouched — assembled sections are added
   above the newest released one, and old sections keep working.

Existing hand-written `## [Unreleased]` entries stay where they are until
someone moves them into fragments or into a release by hand.

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
| `php-version` | string | `8.5` | PHP version for tailor CLI |
| `ref` | string | _event ref_ | Git ref (tag or SHA) to check out. Set explicitly when re-triggering from `workflow_dispatch` against a branch. |
| `verify-timeout-minutes` | number | `10` | Max minutes to wait for TER to serve the published version |
| `verify-poll-interval-seconds` | number | `30` | Seconds between TER verification polls |
| `update-metadata` | boolean | `true` | After publish, sync composer/issues/repository URLs via `tailor ter:update`. The manual URL is only written when `manual-url` is non-empty. |
| `manual-url` | string | `''` | TER's "External manual" field. **Empty preserves TER's existing value** — recommended for extensions that auto-publish to `https://docs.typo3.org/p/<vendor>/<package>/...` (TER then auto-links the "Extension Manual" button there). Set explicitly only when your extension does NOT auto-publish and you need a custom manual URL. |
| `issues-url` | string | `''` | TER's "issues" URL. Empty defaults to `${{ github.server_url }}/${{ github.repository }}/issues`. |
| `repository-url` | string | `''` | TER's "repository" URL. Empty defaults to `${{ github.server_url }}/${{ github.repository }}`. |

### Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `TYPO3_TER_ACCESS_TOKEN` | Yes | TER API access token |
| `TYPO3_EXTENSION_KEY` | No | Deprecated: auto-resolved from composer.json |

### Notes on the "External manual" field

TER surfaces a prominent "Extension Manual" button on every listing. If `external_manual` is empty, TER auto-links it to `https://docs.typo3.org/p/<vendor>/<package>/<major>.<minor>/en-us` — the composer-docs auto-publish route. If `external_manual` is set, the button links there instead.

Most TYPO3 extensions that ship a `Documentation/` directory and are listed on Packagist get automatic docs.typo3.org publishing, and the auto-link delivers users to nicely rendered manuals. Writing the GitHub repo URL into `external_manual` would point readers at raw PHP source instead — worse UX, and not what most consumers want.

This workflow defaults to preserving whatever TER currently has for `external_manual` (typically empty for auto-publishing extensions). Only set `manual-url` explicitly if your extension does NOT use docs.typo3.org auto-publish.

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
| `php-version` | string | `8.5` | PHP version for tests |
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

### runTests.sh — consumed, not copied

The Docker-based runner is versioned here and declared as a composer `bin`, so
installing this package links it into the extension:

```
.Build/bin/runTests.sh -> .Build/vendor/netresearch/typo3-ci-workflows/assets/Build/Scripts/runTests.sh
```

An extension keeps two small files of its own:

1. **`Build/Scripts/runTests.sh`** — a bootstrap stub, copied once from
   `assets/Build/Scripts/runTests.stub.sh`. It exists because the runner
   provisions the environment it lives in, so a fresh clone has no
   `.Build/bin/` yet; the stub runs `composer install` in that case and hands
   over. Keep it at that — anything it grows is drift.
2. **`Build/Scripts/runTests.conf`** — optional, and for most extensions
   unnecessary. The runner reads `composer.json` for the vendor and bin
   directories, the extension key, and the PHP version to default to; it looks
   for the PHPUnit / PHPStan / Rector / Infection configs where extensions
   actually keep them; it reads testsuite names out of the PHPUnit config; and
   it derives the sharded functional run's directories from that config's own
   testsuites. What remains for the conf: PHPUnit/PHPStan/Rector config paths, the directories the
   sharded functional run walks, the URL `-s e2e` tests against, the default
   the e2e wiring, and anything an extension places somewhere the runner does
   not look. The runner starts no TYPO3 for `-s e2e` and knows no local
   environment by name. It takes the target from `TYPO3_BASE_URL` (the shared
   e2e workflow passes it in default mode), else from `e2e_target()` in the
   conf when the run creates its own — `t3x-rte_ckeditor_image` starts an
   Apache container per run and reaches it under a name carrying that run's
   suffix — else from `E2E_BASE_URL`, and stops if none is set. Where the
   container cannot reach that URL on the default network, the conf defines
   `e2e_container_args()` and prints the arguments to add. The extension's own name is not among them — the container
   network prefix and the label `-h` prints are read from `composer.json`
   (package name, and `extra.typo3/cms.extension-key`). Environment variables
   override the file, so a one-off run needs no edit:
   `DEFAULT_PHP_VERSION=8.2 Build/Scripts/runTests.sh -s unit`.

```bash
cp .Build/vendor/netresearch/typo3-ci-workflows/assets/Build/Scripts/runTests.stub.sh Build/Scripts/runTests.sh
chmod +x Build/Scripts/runTests.sh
cp .Build/vendor/netresearch/typo3-ci-workflows/assets/Build/Scripts/runTests.conf.dist Build/Scripts/runTests.conf   # optional
```

Suites: `unit`, `unitCoverage`, `unitCoveragePath`, `functional`,
`functionalParallel`, `functionalCoverage`, `integration`, `fuzz` (or
`fuzzy`), `mutation`, `e2e`, `architecture`, `lint`, `cgl`, `phpstan`,
`phpstanBaseline`, `rector`, `composer`, `composerValidate`,
`composerNormalize`, `composerUpdate`, `clean` (or `cleanCache`). Databases:
`-d sqlite|mariadb|mysql|postgres` with `-i <version>`; PHP with `-p`; a TYPO3
core constraint with `-t`.

A suite that is genuinely one extension's own — rendering its documentation,
publishing coverage, installing the lowest supported dependency set — does not
need a fork: define `suite_<name>()` in `Build/Scripts/runTests.conf` and
`-s <name>` calls it with the remaining arguments. The runner's own suites
always win, so a conf can extend the list but not quietly redefine it.

The default PHP is the newest the runner has images for that the extension's
own `require.php` allows: `^8.2` resolves to 8.5 today, `>=8.2 <8.5` to 8.4. So
a repository states its PHP support once, in the place that already had to
state it.

The runner resolves the extension root from the **working directory** (nearest
ancestor with a `composer.json`), never from its own path — which is what makes
running it out of `vendor/` work at all. `RUNTESTS_PROJECT_ROOT` overrides it.

> Replaced `assets/Build/Scripts/runTests.sh.dist`, a 224-line variant with no
> Docker and no database handling that no extension ran. Extensions that forked
> the TYPO3-Core-derived runner instead drifted into five different accepted
> version lists; that drift is what this replaces (#178).

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

## Code Style

`config/php-cs-fixer/config.php` builds the shared PHP-CS-Fixer configuration. A third argument adds project rules on top of the shared set:

```php
$createConfig = require __DIR__ . '/../.Build/vendor/netresearch/typo3-ci-workflows/config/php-cs-fixer/config.php';

return $createConfig($header, __DIR__ . '/..', [
    'Netresearch/blank_line_after_control_structure' => true,
    'Netresearch/blank_line_before_comment' => true,
    'Netresearch/break_long_method_chain' => ['minimum_links' => 2],
]);
```

### `Netresearch/blank_line_before_comment`

Separates a comment on a line of its own from the code above it. Inside an array or an argument list the rule is off — a comment there explains the entry below, and a blank line would split a list that belongs together.

**Registered but not enabled**, like the two below.

Why it exists: `blank_line_before_statement` can write a blank line in front of a docblock, but not in front of a `//` comment — a comment is not a statement, and no shipped fixer treats it as one. So a comment introducing the next few statements loses the gap that made it an introduction the first time a file is written back from a syntax tree.

Measured over the 48 classes of `t3x-nr-passkeys-be` plus its tests: a line comment on a line of its own has a blank line above it in **274 of 309 places, 89 %** — docblocks sit at 99 % and are left to the rules that own them. All 35 counter-examples are inside brackets, which is where the exception comes from.

On the re-printed corpus it puts 643 of 916 blank lines back in place against 624 without it — a smaller step than the other two, because most comment positions are already covered by the blank line after a block or before a statement.

`Build/Scripts/check-blank-line-before-comment.php` holds the fixtures.

### `Netresearch/blank_line_after_control_structure`

Separates a control structure from the statement after it by a blank line — `if`, `else`, `elseif`, `for`, `foreach`, `while`, `do … while`, `switch`, `try`, `catch`, `finally`. A continuation (`else`, `catch`, `finally`, the `while` of a `do`) is never torn off its structure, a closure or a `match` arm list is not a control structure, and a brace that ends its parent gets nothing.

Also **registered but not enabled**, for the same reason as the rule below.

Why it exists: `blank_line_before_statement` writes a blank line in *front* of a statement; nothing writes one *after* a block. That gap is not a matter of taste. Measured over the 48 classes of `t3x-nr-passkeys-be`, a closing brace inside a method body is followed by a blank line in **232 of 247 places — 93 %**, against 37 % for the blank line before an `if` that the shipped rule does enforce. The one rule the code actually keeps is the one no fixer knows, and it is gone the first time a file is written back from a syntax tree.

What it recovers, on the same 48 classes re-printed from their syntax tree, counted by position rather than by number of blank lines:

| rules | blank lines back in place | at a new place |
|---|---|---|
| `@PER-CS3.0` alone | 185 of 916 (20 %) | 0 |
| `+ class_attributes_separation + blank_line_before_statement` | 512 (55 %) | 208 |
| `+ Netresearch/blank_line_after_control_structure` | 624 (68 %) | 213 |

The rule adds 112 correct positions and 5 wrong ones. What no rule recovers — 180 blank lines between plain statements, 28 in front of comments — is habit rather than rule: the authors set them in 45 % of the eligible places. The blank lines *at a new place* are the rules doing their job, not a defect: the shipped `blank_line_before_statement` enforces something the authors did in 37–50 % of cases.

`Build/Scripts/check-blank-line-after-control-structure.php` holds the fixtures, including the hand-off to `blank_line_before_statement`, which wants to write at the same place.

### `Netresearch/break_long_method_chain`

Puts every call of a method chain on its own line once the chain has at least `minimum_links` calls (default `3`). Property hops are neither counted nor broken, so `$this->connectionPool->getQueryBuilderForTable('pages')->select('uid')->executeQuery()` keeps its subject together and moves the three calls onto their own lines.

The fixer is **registered but not enabled**. Reflowing every long chain in a code base is a decision each project makes in a commit of its own; arriving with a dependency update it would simply turn CGL red.

Why it exists: no shipped fixer breaks a line. None of PHP-CS-Fixer's rules has a line-width concept, and `method_chaining_indentation` only indents a chain somebody already broke by hand — so a chain written on one line stays on one line however long it grows. That is invisible while humans write the code and break their own chains, and it stops being invisible as soon as code is generated from a syntax tree, because a printer reproduces whatever the rules say and a rule nobody wrote is a rule nobody applies.

The trigger is the number of calls, not the width, because a fixer works on tokens and has no budget to compare against. The cost of that is real and worth knowing before switching the rule on: a short chain is broken too, so `$a->b()->c()->d();` becomes four lines at `minimum_links = 3`. `minimum_links` is where a project sets how much of that it wants.

Measured on `t3x-nr-passkeys-be` (47 classes) after re-printing it from its syntax tree: 174 lines over 120 columns without the rule, 169 at `minimum_links = 3`, 153 at `minimum_links = 2`. On the same code as its authors wrote it the rule touches 14 of 47 files at `minimum_links = 2` and 2 of 47 at `minimum_links = 3`.

Cost: the fixer is linear in file size and mildly superlinear in the number of chains per file — 0.05 s for 100 chains, 0.69 s for 400, against 0.10 s for the largest class of a real extension.

`Build/Scripts/check-break-long-method-chain.php` holds the fixtures, including idempotence and the structural property that a break never lands in front of an argument separator.

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

### Secret Propagation

**Never use `secrets: inherit`** when calling these workflows. Always pass only the specific secrets each workflow needs:

```yaml
# Good - explicit secrets
secrets:
  CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}

# Bad - exposes all secrets accessible to the caller to every action in the chain
secrets: inherit
```

Using `secrets: inherit` is a supply chain risk. If any third-party action in the
workflow chain is compromised (cf. [netresearch/ofelia#535](https://github.com/netresearch/ofelia/issues/535)),
the attacker gains access to every secret the calling workflow can access. Passing
secrets explicitly limits the blast radius to only what the workflow actually needs.
See the [GitHub documentation on passing secrets](https://docs.github.com/en/actions/using-workflows/reusing-workflows#passing-secrets-to-a-reusable-workflow).

## Releasing This Repository

This repository releases itself the same way it makes its consumers release:
a signed annotated tag, and nothing else.

```bash
git -C .bare fetch origin
# The tag message IS the release notes — write it in a file, not with -m.
git tag -s -F notes.txt v1.8.3 <sha-on-main>
git push origin v1.8.3
```

`.github/workflows/self-release.yml` takes it from there: it refuses a
lightweight or unsigned tag, refuses a tag whose message has no body, builds
the Composer payload with `git archive` (so `.gitattributes` export-ignore
applies and the archive matches what a consumer installs), signs
`SHA256SUMS.txt` with Cosign, attaches SLSA build provenance, and publishes
the Release with all assets at once.

There is no version file to bump. `composer.json` carries no `version` field
by design — Packagist reads the tag — so the tag is the only surface, and
version parity cannot drift.

Verify a downloaded archive:

```bash
gh attestation verify typo3-ci-workflows-v1.8.3.tar.gz \
  --repo netresearch/typo3-ci-workflows

cosign verify-blob \
  --bundle SHA256SUMS.txt.sigstore.json \
  --certificate-identity-regexp "^https://github\.com/netresearch/typo3-ci-workflows/\.github/workflows/self-release\.yml@" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  SHA256SUMS.txt

sha256sum --check SHA256SUMS.txt
```

Consumers referencing the workflows with `@main` are unaffected by any of
this. A release changes what a tag produces, not what a workflow does.
