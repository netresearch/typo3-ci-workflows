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
| [`release-gate.yml`](#release-gate) | Block a release until named workflows succeeded for the released commit | `workflow_call` (first job of a release workflow) |
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

### CI image mirror

[`ci-mirror.yml`](.github/workflows/ci-mirror.yml) is not a reusable workflow. It runs in this repository every Monday and on `workflow_dispatch`, and copies the database images the shared workflows and `runTests.sh` use to `ghcr.io/netresearch/ci-mirror/<name>:<tag>`, for `linux/amd64` and `linux/arm64`. The source is ECR Public (`public.ecr.aws/docker/library/`), with Docker Hub as fallback per image; both are pulled anonymously. After each copy the job compares both platform manifest digests with the source and fails on a difference.

The images are listed in [`Build/ci-mirror-images.txt`](Build/ci-mirror-images.txt): `mariadb` 10.11, 11.4, 11.8, 12.3; `mysql` 8.0, 8.4, 9.0, 9.6; `postgres` 12 to 17 (`-alpine`); `alpine:3.20`. Self-CI fails when the list misses a tag the code can request, or holds one nothing requests.

The `db-image` defaults of `ci.yml` and `e2e.yml`, the database and alpine images of `runTests.sh` and the MariaDB image of `e2e-provision.sh` pull from this mirror. The packages are public, so no login is needed. `runTests.sh` with `DBMS_VERSION_EXACT=1` can request a MariaDB version outside the list; that image comes from ECR Public.

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
      db-image: 'ghcr.io/netresearch/ci-mirror/mariadb:11.4'
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
| `typo3-packages` | string | `'["typo3/cms-core"]'` | JSON array of TYPO3 packages to require, per `typo3-versions` line, with `composer require --no-update` before `composer install`. A committed `composer.lock` is installed as it is wherever it can serve the cell. Where it cannot — install exits 4 because the locked TYPO3 lies outside the cell's line, or exits 2 with `php` as the only failing requirement of `composer check-platform-reqs --lock` because the lock was built on a newer PHP — the cell runs a full `composer update --with-all-dependencies` instead and says so in a notice. Only a lock in sync with the committed `composer.json` (same `content-hash`) is re-resolved: a stale lock is not re-resolved and fails the cell with an error, while a stale lock the cell can install still installs with Composer's warning, as before. No fallback runs when `config.platform.php` is set (in `composer.json` or the global Composer config), since the update would resolve for that PHP rather than the cell's. A missing or failing `ext-*`, and any other install failure, fails the cell. |
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
| `functional-db-matrix` | string | `'[]'` | Additional explicit server functional cells `{php,typo3,db,image}`, up to 256 unique rows. Nonempty requires enabled functional tests with a SQLite primary. Empty preserves the original matrix. |
| `db-image` | string | `ghcr.io/netresearch/ci-mirror/mysql:9.6` | Docker image for database service. The default comes from our [mirror](#ci-image-mirror) of the Docker official images on GHCR. A bare name such as `mariadb:11.4` pulls anonymously from Docker Hub, whose pull limit can fail the job before a test runs |
| `upload-coverage` | boolean | `false` | Upload coverage to Codecov, under the flags `unit`, `functional` and `acceptance`. Custom `*-test-command` overrides run unchanged and must write `coverage-unit.xml` / `coverage-functional.xml` / `coverage-acceptance.xml` themselves — the upload uses `fail_ci_if_error: false`, so a missing report passes silently. |
| `functional-coverage-php-versions` | string | `''` | Compact mode only: JSON array of retained PHP versions that collect functional coverage across their TYPO3 cells. Empty inherits `upload-coverage`; `[]` disables functional coverage while the full suite still runs. A nonempty array requires `upload-coverage: true`. Unit coverage is unchanged. |
| `upload-test-results` | boolean | `false` | Upload per-test JUnit reports to [Codecov Test Analytics](https://docs.codecov.com/docs/test-analytics) (flaky-test detection, per-test durations). Custom `*-test-command` overrides must emit `junit-unit.xml` / `junit-functional.xml` themselves. |
| `coverage-tool` | string | `xdebug` | Coverage driver: `xdebug` (matches local `XDEBUG_MODE=coverage`, and the only driver for branch and path coverage) or `pcov` (line-only, ~3-10× faster) |
| `path-coverage` | boolean | `false` | Pass `--path-coverage` to the built-in unit, functional and acceptance runs when `upload-coverage` is on and `coverage-tool` is `xdebug`. A custom `*-test-command` gets `PHPUNIT_PATH_COVERAGE=true` and passes the flag itself. Off by default because Xdebug 3.5 crashed under `--path-coverage` on the netresearch/t3x-nr-llm suites |
| `unit-timeout-minutes` | number | `15` | Job timeout of the unit test job |
| `functional-timeout-minutes` | number | `30` | Job timeout of the functional test jobs |
| `acceptance-timeout-minutes` | number | `15` | Job timeout of the acceptance test job |
| `remove-dev-deps` | string | `'[]'` | JSON array of dev deps to remove for TYPO3 version compat |
| `lowest-deps` | boolean | `false` | Run one extra cell with the lowest installable dependencies (`composer update --prefer-lowest --prefer-stable`; with `roave/security-advisories`, the lowest release without a known advisory) on the lowest php/typo3 cell of the matrix. See [Lowest and pinned dependencies](#lowest-and-pinned-dependencies). |
| `pin-packages` | string | `''` | Space-separated `vendor/package:constraint` pairs applied in that extra cell only (e.g. `guzzlehttp/guzzle:^7.10`). Set alone, it runs the cell with the newest versions of everything else. |
| `skip-paths` | string | `''` | Newline-separated globs. On `pull_request` only, skip the whole workflow when **every** changed file matches. See [Path gating](#path-gating). |
| `compact-jobs` | boolean | `false` | Opt in to combined SQLite unit/functional cells, lint inside one cell per PHP, and compatible combined quality checks. See [Compact CI](#compact-ci). |
| `upload-docs-artifact` | boolean | `false` | Upload the CI documentation render as the existing `documentation` PR artifact. |
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
- **Acceptance tests:** `ci:test:php:acceptance` (+ `--no-coverage`/`--coverage-clover`)

CGL and Rector run on a single PHP version — `php-versions[0]`, or `cgl-php-version` / `rector-php-version` when the respective input is set. PHPStan and tests run on the full matrix.

### Compact CI

`compact-jobs: true` reduces runner appointments while retaining the full PHP/TYPO3 matrix. Each cell runs unit and functional suites as separate processes with distinct coverage and JUnit reports. Functional tests still execute after a unit failure when dependencies installed successfully; the final cell verdict fails on either outcome. One retained cell per PHP also runs that PHP's syntax check. The first PHP's carrier checks `ext_emconf.php` and `.gitattributes` as before. Matrix exclusions select carriers from the remaining cells; removing every cell for one PHP is rejected.

The first version supports unit and functional suites enabled with `functional-test-db: sqlite`. CGL and Rector must use the same effective PHP version. Their commands, repository checks and documentation detection share one quality job, with independent outcomes and an explicit final verdict. Custom quality commands must be compatible read-only checks; they now share a checkout. PHPStan retains its separate matrix and PHPUnit resolution, including the unpinned pass. Other optional jobs keep their existing inputs.

Suite step timeouts retain `unit-timeout-minutes` and `functional-timeout-minutes`; the combined job's timeout is their sum, at most 360 minutes. Coverage and JUnit uploads retain their file names, flags and nonblocking transport-error policy. In compact mode, a successful suite must actually produce every requested report as a nonempty file. Custom suite commands must honor that existing report contract too. A missing report, unexpected skip, cancellation or failed check cannot pass the compact aggregate.

By default, `upload-coverage: true` requires both unit and functional reports
in every compact cell. To collect functional coverage on selected PHP versions,
set `functional-coverage-php-versions: '["8.4"]'`: every retained PHP 8.4/TYPO3
cell must then produce `coverage-functional.xml`, while the other cells still
execute their complete functional suite without requesting or uploading that
report. `[]` explicitly disables only functional coverage. Unit coverage and
requested JUnit reports remain required as before. An absent report never
selects coverage-off. Invalid JSON, duplicate or unretained PHP versions, an
explicit declaration outside compact mode, or enabling functional coverage
while global coverage is disabled fail preflight before test-matrix allocation.
Custom commands run unchanged and must implement the declared selection and
their own content checks; a nonempty report alone does not establish positive
covered statements.

### Additional server functional tests

An enabled SQLite primary can add server functional cells to the same CI call:

```yaml
      run-functional-tests: true
      functional-test-db: sqlite
      functional-db-matrix: >-
        [{"php":"8.5","typo3":"^14.3","db":"mariadb","image":"ghcr.io/netresearch/ci-mirror/mariadb:10.11"},
         {"php":"8.5","typo3":"^14.3","db":"mysql","image":"ghcr.io/netresearch/ci-mirror/mysql:8.0"},
         {"php":"8.5","typo3":"^14.3","db":"postgres","image":"ghcr.io/netresearch/ci-mirror/postgres:16-alpine"}]
```

Rows specify complete cells and create no PHP/TYPO3 cross product. They run in
parallel with the primary checks, using the existing server job, isolated
services, functional command, timeout and global coverage/JUnit settings.
For these server rows, `upload-coverage` applies to every row. The
`functional-coverage-php-versions` selector controls only compact primary cells;
even an explicit `[]` does not disable server-row coverage when `upload-coverage` is on.
Every row must succeed before `All CI checks` succeeds. Explicit whole-workflow
reuse may skip the rows only when every execution family is skipped; missing
or inconsistent planning/results fail. Malformed, duplicate, incomplete or
unknown-field rows and image values containing whitespace/control characters
fail preflight. Rows cannot provide commands, credentials or service options.

The default `[]`, including whitespace-formatted empty arrays, keeps existing
server-primary callers' PHP/TYPO3/exclusion matrix and check names. Default
callers need no change. This option also works without compact mode. Local
planner, command, verdict and mutation probes run inside the existing compact
fixture command; real database/test inventories still require native consumer
qualification.

For a four-PHP by two-TYPO3 consumer with CGL, Rector, repo checks, unit, functional and docs enabled, the graph uses 21 runners rather than 36: preflight, eight PHPStan cells, the unpinned analysis, eight combined test cells, quality, docs and the stable `ci / All CI checks` gate. This is a job-count reduction, not a measured speed claim. Serial suites can lengthen a cell when capacity is free. Compare test/report inventories, runner occupation and elapsed time under comparable load before adopting it.

Set `upload-docs-artifact: true` to obtain the current renderer's `documentation` PR artifact from CI. A consumer can then keep its standalone docs workflow manual-only and avoid rendering the same source twice. Check required contexts and template rules before removing an automatic workflow trigger. The documentation configure/render/warning behavior is unchanged.

Both inputs default off. Set `compact-jobs: false` to restore the old job graph and names; no queue, signing, DCO or review policy changes are needed. Consumers requiring individual old job names must migrate to the stable aggregate deliberately. The local executable fixture check is `bash Build/Scripts/check-compact-ci.sh .github/workflows/ci.yml`; a bounded native CI pilot is still required to validate GitHub step conditions and scheduling. A local fixture pass alone does not demonstrate hosted runtime or performance parity.

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

### Lowest and pinned dependencies

Every matrix cell resolves the newest version each constraint allows, or installs a committed `composer.lock` that fits the cell. A `composer.json` that still admits an older major — `guzzlehttp/guzzle: ^7.10 || ^8.0`, say — is then never tested against it, and a defect that exists only there reaches installations unseen.

Two inputs add one extra cell, reported as its own check, that runs the unit and functional tests (whichever of `run-unit-tests` / `run-functional-tests` is on) against a different resolution:

```yaml
    with:
      lowest-deps: true                          # everything as low as composer can go
      # or, narrower and cheaper:
      pin-packages: 'guzzlehttp/guzzle:^7.10'    # newest everything, except these
```

| Inputs | Check name | Resolution |
|--------|------------|------------|
| `lowest-deps: true` | `Lowest dependencies` | `composer update --prefer-lowest --prefer-stable` |
| `pin-packages` only | `Pinned dependencies` | after the pins: `composer install`, or with a committed `composer.lock` always a full `composer update --with-all-dependencies`, since install refuses a lock the pins put out of date |
| both | `Lowest dependencies` | the pins, then `--prefer-lowest` within them |

- **Cell:** the lowest PHP of `php-versions`, then the lowest TYPO3 line of `typo3-versions` within it, skipping `matrix-exclude` (a partial entry such as `{"typo3": "^12.4"}` excludes that whole column, as it does for the matrix). The TYPO3 line is required first, as in every cell, so `--prefer-lowest` picks the oldest release of that line — not of your whole `typo3/cms-*` range. Unlike the matrix cells, the line is ANDed with the constraint `composer.json` already declares: `^13.4` against a declared `^13.4.21 || ^14.3` resolves from 13.4.21, not 13.4.0. **The lowest line of `typo3-versions` must therefore overlap that constraint**: a matrix line `composer.json` rules out (`^13.4` against `^14.3`) leaves nothing to install, and the cell fails with an error naming both constraints rather than a solver error. Align `typo3-versions` with `composer.json`, or exclude the line with `matrix-exclude`.
- **"Lowest" is the lowest installable release, not the constraint's lower bound.** With `roave/security-advisories` in `require-dev`, every release with a known advisory is a conflict, so the cell tests the lowest release *without* one — and that floor rises over time as advisories are published. In the first real run, `guzzlehttp/guzzle: ^7.10 || ^8.0` locked at 7.15.2 and `typo3/cms-core` at 13.4.35 for that reason.
- **Pins** are applied with `composer require --no-update`, with `--dev` when the package is in `require-dev`. Package names are lowercased (Composer treats them case-insensitively), then each entry must match Composer's package-name pattern followed by `:constraint`, and a constraint must not contain spaces: write `>=7.10,<8`, not `>=7.10 <8`. A `pin-packages` that holds no entry, with `lowest-deps` off, fails the cell rather than passing it untested.
- **`--prefer-lowest` lowers dev dependencies too** (PHPUnit, `typo3/testing-framework`, this package). If your `require-dev` lower bounds are older than your tests can run on, the cell fails on tooling — raise those bounds, or use `pin-packages` for the package that matters.
- The cell uses the same `functional-test-db`, `remove-dev-deps` and `*-test-command` inputs as the matrix, and the same coverage driver (`coverage-tool` when `upload-coverage` is on), so a custom command that writes or reads a coverage report behaves as it does in the matrix. It uploads no coverage and no JUnit report, and it uses a Composer cache namespace of its own.
- With both test inputs off, the cell does not run: it would otherwise pass having tested nothing.
- `All CI checks` includes it; when it is off it reports `skipped` under the name `Lowest or pinned dependencies`, which passes.

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
| `npm-install-scripts` | boolean | `false` | Run install scripts during `npm ci` / `npm install` in the JS job. See [npm install scripts](#npm-install-scripts). |
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

### npm install scripts

The JS job here and the default mode of [E2E Tests](#e2e-tests) install npm dependencies with `--ignore-scripts`. No install script runs: not a dependency's `preinstall`, `install` or `postinstall`, and not the project's own `postinstall` or `prepare`. An install script is arbitrary code that runs with the job's permissions at install time, so a compromised dependency could run it on the runner.

Until this change both workflows ran install scripts. A project that builds assets or native modules in an install script sets `npm-install-scripts: true`; the step then passes `--ignore-scripts=false`, which is npm's default. Scripts run with `npm run` in the test command are not affected.

```yaml
    with:
      npm-install-scripts: true
```

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
      db-image: 'ghcr.io/netresearch/ci-mirror/mariadb:11.4'
      test-command: 'npm run test:e2e -- --project=chromium'
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `php-version` | string | `8.5` | PHP version |
| `node-version` | string | `24` | Node.js version |
| `npm-install-scripts` | boolean | `false` | Run install scripts during `npm ci` / `npm install` (default mode only). See [npm install scripts](#npm-install-scripts). |
| `typo3-setup-extensions` | boolean | `true` | Run extension:setup after TYPO3 setup |
| `playwright-browser` | string | `chromium` | Playwright browser to install |
| `playwright-install-timeout-minutes` | number | `5` | Wall-clock bound for one `playwright install` attempt; the step retries once. Browsers are cached under `~/.cache/ms-playwright`, so most runs never download. |
| `php-server-workers` | string | `'1'` | Worker processes for the built-in `php -S` server. Raise to at least the Playwright worker count before setting `workers > 1`, or the suite serialises at the web server. |
| `skip-paths` | string | `''` | Newline-separated globs. On `pull_request` only, skip the whole workflow when **every** changed file matches. See [Path gating](#path-gating). |
| `test-command` | string | `npm run test:e2e` | E2E test command |
| `db-image` | string | `ghcr.io/netresearch/ci-mirror/mariadb:11.4` | Database Docker image. The default comes from our [mirror](#ci-image-mirror) of the Docker official images on GHCR. A bare name such as `mariadb:11.4` pulls anonymously from Docker Hub, whose pull limit can fail the job before a test runs |
| `php-extensions` | string | `mysqli, pdo_mysql, gd, intl, curl, zip` | PHP extensions to install |
| `timeout-minutes` | number | `30` | Job timeout in minutes |
| `artifact-path` | string | `Tests/E2E/Playwright/reports/` | Path to Playwright reports |
| `web-dir` | string | `.Build/Web` | TYPO3 web directory (document root) |
| `typo3-versions` | string (JSON) | `'[""]'` | Matrix dimension: TYPO3 core version constraints (e.g. `'["^13.4.21","^14.3"]'`). Empty entry = use composer.json as-is. Each entry runs as a separate job. |
| `typo3-packages` | string (JSON) | `'["typo3/cms-core"]'` | Packages whose constraints get bumped per `typo3-versions` matrix entry, applied via `composer require --no-update` (or `composer require --with-all-dependencies` when a `composer.lock` is committed) before install. |
| `setup-variants` | string (JSON) | `'[""]'` | Matrix dimension: setup variant names (e.g. `'["bootstrap","core-only","fsc-set"]'`). Passed to `setup-script` and tests as `$E2E_VARIANT`. |
| `setup-script` | string | `''` | Path to a custom setup script (relative to repo root). When set, replaces the entire built-in pipeline — the script must install deps, set up TYPO3, start any servers, and run tests. Receives `E2E_VARIANT`, `E2E_TYPO3_VERSION`, `E2E_TYPO3_PACKAGES` as env vars. Use this for extensions with comprehensive containerized setups (Apache+PHP-FPM, custom DB seeding, Content Blocks fixtures). |

In the default mode, npm dependencies are installed without their install scripts, because an install script is arbitrary code run on the runner at install time. A project that needs them sets `npm-install-scripts: true`. See [npm install scripts](#npm-install-scripts).

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

### The PHP built-in server (default mode)

The server runs with OPcache but without the OPcache JIT (`-d opcache.jit=disable`): setup-php enables the tracing JIT, and under it `php -S` crashed with SIGSEGV partway through a suite. The server's exit status is appended to `/tmp/php-server.log` (uploaded on failure as `php-server-logs`, followed by `-<typo3>` and `-<variant>` for each of the matrix values `typo3` and `variant` the calling job sets — `php-server-logs-14.3-default` for `typo3: '^14.3'` and `variant: default`, the same suffix as `playwright-report`). Core dumps are enabled for php and its child processes and written to `/tmp/php-cores`. If the server is gone when the tests end, a `php-server-workers` worker died (it stays a zombie of the running master), or a `core.php*` file exists, the step "Report PHP server status" prints the log tail, kernel messages about segfaults, OOM and killed processes, and a gdb backtrace of every `core.php*` file; core files of other programs are only listed. It reports "PHP server was not started." when an earlier step failed before the server started, and "did not come up" when the server never answered.

---

## Security

Composer dependency audit and [Opengrep](https://github.com/opengrep/opengrep) SAST (the fully-OSS LGPL-2.1 fork of Semgrep). Both jobs run by default.

Opengrep **blocks CI on findings of severity WARNING and ERROR** (`--severity WARNING --severity ERROR`) and also uploads SARIF to the repo's **Security** tab. `--severity` selects exactly the level it names and can be repeated, so every level that should report and gate is listed; findings of an unlisted level are neither reported nor uploaded. A `merge_group` run scans and gates but does not upload, because GitHub deletes the queue ref when the queue merges and the upload then fails with `ref ... not found`; Opengrep therefore runs on every `push`, unless `skip-opengrep` is `true`, even when the preflight skips the other jobs, so the default branch's Security tab gets the result of each merge. Override `opengrep-config` to tune behavior:

- **Report-only (all findings, CI never fails):** `--config auto` — drop both `--error` and `--severity` so every finding reaches the Security tab without gating merges.
- **Block only on critical (RCE/SQLi/XXE):** `--config auto --error --severity ERROR`.
- **Block on everything, including INFO:** `--config auto --error` — without `--severity` every level is reported and gates.

Whatever `opengrep-config` says, the scan excludes the registry rule `php.lang.security.exec-use.exec-use` and runs a replacement written for the workflow (the registry rules are under the Semgrep Rules License v1.0, which does not allow distributing them, so none of their text is copied). Since [semgrep/semgrep-rules#4081](https://github.com/semgrep/semgrep-rules/pull/4081) the registry version matches every callee whose name starts with a sink name in any case, so static calls such as `ExecutionIdentity::interactive()` fail the job. The replacement matches only the whole names `exec`, `passthru`, `proc_open`, `popen`, `shell_exec`, `system` and `pcntl_exec`, in any case and with an optional leading `\`. Its id in the SARIF and the Security tab is `netresearch.php.lang.security.exec-use.exec-use`, and a `nosemgrep: php.lang.security.exec-use.exec-use` comment suppresses it.

`--config auto` does not load the registry's current rule set. It loads the same rules (the registry's `p/default`) from two pinned commits, [semgrep/semgrep-rules](https://github.com/semgrep/semgrep-rules) and [trailofbits/semgrep-rules](https://github.com/trailofbits/semgrep-rules), which the job fetches at run time; `SEMGREP_RULES_SHA` and `TRAILOFBITS_RULES_SHA` in the step *Fetch the pinned Opengrep rules* name them. The rules keep their registry ids, so findings, Security-tab alerts and `nosemgrep` comments are the same. A change to the rules therefore reaches callers only through a pull request here. `--config p/default` still loads the registry's current set. Without `--config auto` in `opengrep-config`, the job does not fetch the pinned set. The scan passes `--no-rewrite-rule-ids` for every config, including a caller's own rule files: a rule `my-local-rule` in `.github/opengrep/local.yaml` reports as `my-local-rule`, not as `github.opengrep.my-local-rule`, so `nosemgrep` comments and `--exclude-rule` arguments must name the id as the file writes it. No caller passes a rule file of its own today.

To move a pin, Renovate opens a pull request and does not merge it. Run `Build/Scripts/refresh-opengrep-rules.sh .github/workflows/security.yml` on that branch: it rebuilds the list of rule files and `RULES_DIGEST` from the registry's current `p/default`, and refuses when the pinned commits do not reproduce it. If the new commits add, rename or remove a rule file of the list, the job fails until then, because the fetched rules no longer match `RULES_DIGEST`. A change inside a listed rule keeps its id: the job passes, and the pull request's diff shows only the new commit id. The script therefore ends by listing the listed rule files whose content differs between the pins on `main` and the new ones; review those before merging (for `5a8a6be` → `2fc50a25` it lists `php/lang/security/exec-use.yaml`, the change behind #292). The same script takes up rules the registry adds to `p/default`.

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
| `opengrep-config` | string | `--config auto --error --severity WARNING --severity ERROR` | Opengrep scan arguments (rules + behavior flags). See the [overrides above](#security) for report-only, ERROR-only, and INFO-blocking variants. |

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
| `forbidden-licenses` | string | `"(SSPL\|BSL\|BUSL)"\|(^\|[^A-Za-z0-9])(SSPL\|BUSL)-[0-9]` | Extended regex matched against `composer licenses --format=json`. The default refuses `SSPL-1.0` and `BUSL-1.1` (also inside a licence expression) and the bare strings `SSPL`, `BSL` and `BUSL`; `BSL-1.0` (Boost Software License) passes. |

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
| `make-latest` | boolean | no | `true` | Let the release become the repository's "Latest" when its version is the highest released one; `false` keeps it off Latest in every case — see [Backport releases and the Latest badge](#backport-releases-and-the-latest-badge) |

### Backport releases and the Latest badge

GitHub's release API makes every new release "Latest" unless told otherwise, so a release cut from a maintenance branch took the badge and the `/releases/latest` redirect away from the newest version — `v3.0.6` off the `TYPO3_13` line displacing `v4.1.0`. Composer resolution is unaffected (it is constraint- and tag-based), the repository landing page is not.

`release.yml` and `release-typo3-extension.yml` therefore compare the pushed tag with every published, non-prerelease release of the repository and make it Latest only when its version is the highest. A leading `v` is ignored on both sides, so a repository that changed its tag style compares `4.0.0` and `v3.0.6` correctly. Drafts, prereleases and release tags that are not `X.Y.Z` do not count, and a pushed tag that is not `X.Y.Z` (`release.yml` accepts one) does not become Latest. A repository with a single release line is unaffected: each new release is its highest. A backport branch needs no setting.

If the releases cannot be listed, the release is still created, without Latest, and the run shows a warning. `make-latest: false` keeps a release off Latest in every case; it is not needed for backports any more, and a caller that already sets it can keep it.

A release that is already published keeps its badge. To move Latest back to the newest version after a wrong badge, use "Set as the latest release" on that release's edit page.

### TYPO3 extension releases: the release first, then the targets

`release-typo3-extension.yml` treats a release as the signed tag plus its GitHub release. TER, Packagist and docs.typo3.org are publication targets. The order is:

1. Build and sign the archives, SBOMs and checksums.
2. Create the GitHub release with every asset. Its body carries a "Publication status" section between the markers `<!-- publication-status:start -->` and `<!-- publication-status:end -->`.
3. Publish to TER and check Packagist and docs.typo3.org.
4. Write the result of each target into the marked section, also when a target failed.

A failed target turns the run red and shows as failed in the release body; the release stays. To retry a failed target, re-run the failed jobs of the tag-push run (`gh run rerun <run-id> --failed`, or "Re-run failed jobs" in the UI). For a release left as a draft, re-run all jobs (`gh run rerun <run-id>`): the build artifact is kept for one day, so a later failed-jobs re-run has nothing to upload. GitHub allows re-runs for 30 days after the run. If the repository's release workflow also declares `workflow_dispatch`, `gh workflow run release.yml --ref vX.Y.Z` starts a fresh run on the tag. The re-run leaves a published release and its assets as they are, runs the targets again and rewrites only the marked section, so a body rewritten by hand keeps everything else. A release left as a draft by a failed asset upload loses its partial assets, gets the full set from the current build, and is published.

A missing `TYPO3_TER_ACCESS_TOKEN` fails the TER target, not the release. For an extension that is not published to TER, pass `skip-ter: true`.

---

## Release gate

Blocks a release until the named workflows have succeeded for the exact commit being released. Without it, a release and the workflows that judge the same commit run side by side, and a failed test matrix or security check is only *visible next to* a release that is already signed and published. With it, the failure stops the release.

The gate reads the newest run of each named workflow for the commit, waits while it is queued or running, and fails unless it concluded `success`. It fails closed: a run that never appears within `grace-seconds`, an API error, a cancelled or failed run, and the timeout all stop the release.

It is a separate reusable rather than an input of `release-typo3-extension.yml` on purpose: listing workflow runs needs `actions: read`, and GitHub rejects every caller of a reusable that declares a permission the caller did not grant. Only repositories that opt in grant it.

### Minimal caller

```yaml
jobs:
  gate:
    uses: netresearch/typo3-ci-workflows/.github/workflows/release-gate.yml@main
    permissions:
      actions: read
      contents: read
    with:
      required-workflows: 'ci.yml release-evidence.yml'

  release:
    needs: gate
    uses: netresearch/typo3-ci-workflows/.github/workflows/release-typo3-extension.yml@main
    permissions:
      attestations: write
      contents: write
      id-token: write
    with:
      archive-prefix: my-extension
      package-name: vendor/my-extension
      extension-key: my_extension
    secrets:
      TYPO3_TER_ACCESS_TOKEN: ${{ secrets.TYPO3_TER_ACCESS_TOKEN }}
```

Every named workflow must run for the released commit: for a tag on `main`, a workflow triggered by pushes to `main` has run for it, and one triggered by the tag push runs alongside the release. The calling workflow itself cannot be named — it would wait for itself.

### Inputs

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `required-workflows` | string | **yes** | - | Whitespace-separated workflow file names in the calling repository |
| `sha` | string | no | triggering commit | Commit to gate |
| `timeout-minutes` | number | no | `120` | How long to wait for the named workflows; positive integer |
| `grace-seconds` | number | no | `600` | How long a named workflow may take to create its run for the commit; positive integer |
| `poll-interval-seconds` | number | no | `30` | Seconds between status polls; positive number, fractions allowed |

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

If `composer.json` sets `extra.typo3/cms.version` or the top-level `version`, each of them that is set must equal the release version exactly, or the run fails before this workflow uploads anything to TER, and the error names the field that differs. `v1.2.3`, `1.2.3.0` and `1.2.3+meta` are refused for a `1.2.3` release. Without either field nothing is compared. If `composer.json` is not exactly one JSON document (empty, invalid, or several documents), the run fails. If `composer.json`, its `extra` or its `extra.typo3/cms` is present but not a JSON object, the run fails with an error that names that path. Packagist and docs.typo3.org react to the tag push itself, not to this workflow, so the check does not hold them back.

Why: TYPO3 14.3 takes the version from `extra.typo3/cms.version`, falling back to `version`, on every path. `ext_emconf.php` overrides only the top-level `version`, and it is not read at all once `extra.typo3/cms.Package.providesPackages` is set together with `version` or `extra.typo3/cms.version`. So a stale `extra.typo3/cms.version` always wins, and a stale top-level `version` wins once `providesPackages` is set. A release that bumps only `ext_emconf.php` would then install from TER showing the old number. TYPO3 13.4 never reads `extra.typo3/cms.version`, so for 13.4 the check is stricter than needed. The exact match is a policy rather than a 14.3 requirement: 14.3 normalises `v1.2.3` to `1.2.3`, but 13.4 shows the top-level `version` as written when it does not read `ext_emconf.php` (in classic mode the `ext_emconf.php` value replaces it), and an exact match keeps both fields unambiguous. `release-typo3-extension.yml` runs the same check in its first job, before archives are built and signed.

Republishing a tag with `republish.yml` or `force-republish` runs the same check. A historic tag whose `composer.json` was stale is refused, and the `tailor ter:update` metadata sync for it is skipped as well, because it runs in the same job. A pushed tag cannot be corrected, so the fix is a new release with matching fields. There is no input to skip the check.

The TER upload comment is the `CHANGELOG.md` section of the released version at the tagged commit: a level-1 or level-2 heading naming the version (`# 1.2.3`, `## [1.2.3] - 2026-01-01`, `## v1.2.3`), up to the next heading of the same or a higher level. Without such a section it falls back to the `release-notes` input, the GitHub release body, and the commit log since the previous tag. A filter in front of the TER API refuses some comment texts with an HTML 403 page, which tailor reports as `Reason: Unknown (Status 403)`. Before uploading, the job therefore sends a neutral text and then the comment to the upload endpoint without credentials, which cannot publish anything. When only the comment is refused, the job fails with an error that says so, prints the comment, and sets the `comment-refused` output. Re-running the same workflow on the tag sends the same text. A CHANGELOG section is fixed at the tagged commit, so it needs a reworded section and a new release; any other comment can be corrected by editing the GitHub release body and publishing again with `republish.yml`, which passes no `release-notes` and so takes the comment from the release body. When the neutral text does not reach the API either, the check is skipped with a warning. The section ends at a heading outside a code fence, so a `# comment` line in a shell sample stays in the section.

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

### Outputs

| Output | Description |
|--------|-------------|
| `comment-refused` | `true` when the job failed because the TER upload comment was refused before it reached the API. `release-typo3-extension.yml` uses it to say so in the release's publication status instead of recommending a re-run. When the output does not arrive, the status falls back to the generic re-run advice. |

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
| `mutation-timeout-minutes` | number | `30` | Job timeout of the mutation job |

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
        "netresearch/typo3-ci-workflows": "^2.0"
    }
}
```

This brings in all dev-dependencies (PHPStan, PHP-CS-Fixer, Rector, Infection, testing-framework, etc.) with a single requirement. It also ships PHP for tests: the PHPat layer rules ([Architecture rules (PHPat)](#architecture-rules-phpat)) and the `TypedArray` helper ([Test helper: TypedArray](#test-helper-typedarray)), autoloaded from `src/`. Your extension only needs tool configuration files (`Build/phpstan.neon`, `Build/.php-cs-fixer.php`, etc.) and the reusable GitHub Actions workflows. The `Build/` paths are examples, not a requirement: `runTests.sh` also finds, for instance, a `.php-cs-fixer.dist.php` in the repository root.

## Rector

`config/rector/rector.php` returns a function that applies the shared Rector configuration. With the project root as second argument it also sets the paths (`Classes/`, `Configuration/`, `Resources/` and `ext_*.php`), skips `ext_emconf.php`, points Rector at `config/phpstan/phpstan-rector.neon` and sets PHP 8.2. A third argument sets options:

```php
$configure = require __DIR__ . '/../.Build/vendor/netresearch/typo3-ci-workflows/config/rector/rector.php';

return static function (RectorConfig $rectorConfig) use ($configure): void {
    $configure($rectorConfig, __DIR__ . '/..', [
        'tests' => true,
        'php'   => '8.3',
        'typo3' => 13,
    ]);
};
```

| Option | Values | Effect |
|---|---|---|
| `tests` | `true`, `false` | `Tests/` joins the paths when the directory exists. Without the option an extension has to re-declare every path to add it, because `paths()` replaces the list. |
| `php` | `'8.2'` to `'8.5'` | The lowest PHP version the extension supports: sets `phpVersion()` and adds the matching `LevelSetList::UP_TO_PHP_*` set. Default `'8.2'`. |
| `typo3` | `12`, `13`, `14` | The lowest TYPO3 major version the extension supports: adds `Typo3LevelSetList::UP_TO_TYPO3_<n>`. With `14` the rule `MigratePluginContentElementAndPluginSubtypesRector` is skipped. |

An unknown option or value throws an `InvalidArgumentException`, and so does an option without the project root.

Why `14` skips the plugin rule: TYPO3 14 registers every plugin as a content element, and the rule's edits no longer fit its API. In `ExtensionUtility::configurePlugin()` it adds a plugin type argument that TYPO3 14 only accepts as `CType`. In an `ExtensionManagementUtility::addPlugin()` call without a second argument, it writes `CType` there, and in TYPO3 14 that parameter is `$flexForm`. It also writes an upgrade wizard with an empty `list_type` mapping into `Classes/Updates/`; a normal run writes that file, a `--dry-run` does not show it. Records with a `list_type` from an earlier TYPO3 version still need a migration with a real mapping.

`Build/Scripts/check-rector-options.php` checks each option.

## PHPUnit

`config/phpunit/phpunit.xml` (unit tests) and `config/phpunit/FunctionalTests.xml` are templates. Copy them to `Build/phpunit.xml` and `Build/FunctionalTests.xml`, then adjust the vendor directory if `composer.json` sets another `vendor-dir` than `.Build/vendor`, and the test suites and source set. Both validate against the schemas of every PHPUnit version that `typo3/testing-framework` allows, from 10.1 to 13, and use its bootstraps.

PHPUnit has no includes, so the copies drift. The Composer bin `check-phpunit-config` asserts the flags that matter on the `<phpunit>` element of each file and ignores everything else, so a project's own suites and source set never fail it:

| Profile | Flags, each `"true"` |
|---|---|
| baseline (default) | `failOnRisky`, `failOnWarning` |
| strict (`--strict`) | the baseline plus `beStrictAboutOutputDuringTests`, `requireCoverageMetadata`, `beStrictAboutCoverageMetadata`, `failOnDeprecation`, `failOnNotice`, `failOnPhpunitDeprecation`, `failOnEmptyTestSuite` |

`failOnPhpunitDeprecation` exists from PHPUnit 10.5 in the 10 series and from 11.3 in the 11 series. On an older PHPUnit, for example in a cell that installs the lowest dependencies, the configuration fails schema validation, and `failOnWarning` turns that into a failed run. Raise the PHPUnit floor in `require-dev` before adopting the strict profile.

It needs the installed package, so it cannot run in the repo-checks job of `ci.yml`, which skips `composer install`. Do not chain it into the test scripts either: the test jobs call them with PHPUnit options (`composer ci:test:php:unit -- --no-coverage`), Composer appends those options to every script in the chain, and the check rejects them as unknown options. The CGL job calls `composer ci:test:php:cgl` after `composer install` and without arguments, so chain it there:

```json
{
    "scripts": {
        "ci:test:php:phpunit-config": "check-phpunit-config Build/phpunit.xml Build/FunctionalTests.xml",
        "ci:test:php:cgl": [
            "@ci:test:php:phpunit-config",
            "php-cs-fixer check --config Build/.php-cs-fixer.dist.php"
        ]
    }
}
```

The exit code is 0 when every file carries the profile, 1 when a flag is missing or not `"true"` (each one is named), and 2 for a file that cannot be read or is not a PHPUnit configuration.

## Editor and lint templates

Two more templates for files every extension keeps:

| Template | Copy to | Content |
|---|---|---|
| `config/editorconfig/.editorconfig` | `.editorconfig` | UTF-8, LF, final newline, no trailing whitespace, 4 spaces; 2 spaces for JSON, YAML and XLIFF (`*.xlf`, `*.xliff`); tabs in a `Makefile`; trailing whitespace kept in Markdown. The `[*]` section is what all 17 extensions in the org with an `.editorconfig` set. |
| `config/phplint/.phplint.yml` | `Build/.phplint.yml` | `overtrue/phplint` 9.6.2 or later over the repository root, excluding the top-level `.Build/` and `vendor/`, with the cache in `.Build/.phplint.cache`. Run it from the repository root as `phplint --configuration Build/.phplint.yml`. |

Two details of the phplint template matter when you compare it with an older copy:

- It uses `cache-dir`. From 9.6.2, phplint ignores a `cache` key in the configuration file and writes the cache to `./.phplint.cache` in the repository root.
- Its excludes are anchored regular expressions. A plain string matches anywhere in the path, so `vendor` also skips `Classes/Payment/vendorApi/`, and `.Build` skips a file named `Query.BuildHelper.php`.

phplint reports neither of the two, so the Composer bin `check-phplint-config` asserts them on a project's copy: no `cache` key, and each `exclude` entry a delimited regular expression that starts with `^` (`'#^vendor/#'`). The other settings stay the project's. Chain it into the CGL script for the same reason as `check-phpunit-config`:

```json
{
    "scripts": {
        "ci:test:php:phplint-config": "check-phplint-config Build/.phplint.yml",
        "ci:test:php:cgl": [
            "@ci:test:php:phplint-config",
            "php-cs-fixer check --config Build/.php-cs-fixer.dist.php"
        ]
    }
}
```

The exit code is 0 when the file passes, 1 when a setting is wrong (each one is named), and 2 for a file that cannot be read or is not YAML.

## PHPStan

An extension includes `config/phpstan/phpstan.neon` in its own `Build/phpstan.neon` and adds its `paths`; the header of that file shows the include. The shared file turns on more than the usual tool list, so an extension that switches to it meets new findings. They come from three places.

**Parameters** in `phpstan.neon`:

| Parameter | Effect |
|---|---|
| `level: 10` | The highest level. Level 9 reports an explicit `mixed` where a specific type is required; level 10 does the same for values with no declared type at all (implicit `mixed`). |
| `checkMissingCallableSignature: true` | A `callable` or `Closure` type without a signature (`callable(int): string`) is reported. |
| `checkUninitializedProperties: true` | A typed property that the constructor leaves unset is reported. |
| `reportUnmatchedIgnoredErrors: true` | PHPStan's default, restated: an `ignoreErrors` entry that matches nothing is reported. It changes only an extension that had set it to `false`. The shared `ignoreErrors` entries carry `reportUnmatched: false`, so they never fire it. |
| `treatPhpDocTypesAsCertain: false` | PHPDoc types do not make a later check "always true", so defensive checks are not reported. |

**`ergebnis/phpstan-rules`**, with `allRules: false` and six rules switched on: `declareStrictTypes`, `noCompact`, `noErrorSuppression` (no `@`), `noEval`, `noReturnByReference` and `testCaseWithSuffix` (a test class name ends in `Test`). The other rules are off because they conflict with TYPO3 patterns, such as extending `ActionController`; the comments in `phpstan.neon` list them.

**Extensions** that `phpstan/extension-installer` registers, among them `phpstan-strict-rules`, `phpstan-deprecation-rules`, `phpstan-phpunit`, `saschaegerer/phpstan-typo3`, `phpat/phpat` and `ergebnis/phpstan-rules`. Two more, `bnf/phpstan-psr-container` and `composer/pcre`, arrive as dependencies and add type information only.

`phpstan-strict-rules` reports, among others, loose comparisons (`==`, `!=`), non-boolean conditions, `empty()`, the short ternary `?:`, a missing parent constructor call, `in_array()` and similar calls without strict mode, useless casts and dynamic properties. `phpstan-deprecation-rules` reports every use of a deprecated API, TYPO3's included; the shared `ignoreErrors` entries for `Classes/Updates/` exist for the upgrade wizards that must use them. `phpat/phpat` reports nothing until an extension registers an architecture test; [Architecture rules (PHPat)](#architecture-rules-phpat) describes the shared layer rules.

`phpstan-phpunit` adds rules on test code, among them:

- `assertSame(true, …)`, `assertSame(false, …)` and `assertSame(null, …)` should be `assertTrue()`, `assertFalse()` and `assertNull()`;
- `assertSame($n, count($x))` should be `assertCount($n, $x)`;
- a class or method named in a `@covers` or `@coversDefaultClass` annotation must exist (the `#[CoversClass]` attribute is not checked);
- a mocked method must exist on the mocked type;
- in a test class, `setUp()` and `tearDown()` must call `parent::setUp()` and `parent::tearDown()` when an ancestor other than PHPUnit's `TestCase` declares them, as `UnitTestCase` and `FunctionalTestCase` of `typo3/testing-framework` do;
- a data provider must be declared correctly.

`saschaegerer/phpstan-typo3` gives TYPO3 APIs real return types, for example for `GeneralUtility::makeInstance()`. An extension that did not use it before gets findings where it relied on `mixed`, and has to regenerate its baseline.

## Architecture rules (PHPat)

The trait `Netresearch\Typo3CiWorkflows\Architecture\LayerRules` holds the layer dependency rules that the extensions using this package assert in their own PHPat tests. A test class uses it and names the extension's root namespace:

```php
<?php

declare(strict_types=1);

namespace Vendor\MyExtension\Tests\Architecture;

use Netresearch\Typo3CiWorkflows\Architecture\LayerRules;
use Netresearch\Typo3CiWorkflows\Architecture\Layers;

final class ArchitectureTest
{
    use LayerRules;

    private function layers(): Layers
    {
        return Layers::below('Vendor\MyExtension');
    }
}
```

PHPat finds a test class only as a service tagged `phpat.test` in the PHPStan configuration, so register it in `Build/phpstan.neon` (the class has to be autoloadable, for example through `autoload-dev`):

```neon
services:
    -
        class: Vendor\MyExtension\Tests\Architecture\ArchitectureTest
        tags: [phpat.test]
```

Each layer has conventional namespaces below the root. A second argument replaces them for a layer, relative to the root:

```php
return Layers::below('Vendor\MyExtension', [
    Layers::EVENT_LISTENER => 'Backend\EventListener',
    Layers::REPOSITORY => ['Domain\Repository', 'Persistence'],
]);
```

| Layer | Conventional namespaces |
|---|---|
| `Layers::DOMAIN` | `Domain` |
| `Layers::REPOSITORY` | `Domain\Repository`, `Repository` |
| `Layers::SERVICE` | `Service` |
| `Layers::EVENT` | `Event` |
| `Layers::EVENT_LISTENER` | `EventListener`, `Listener` |
| `Layers::CONTROLLER` | `Controller` |
| `Layers::COMMAND` | `Command` |
| `Layers::MIDDLEWARE` | `Middleware` |
| `Layers::VIEW_HELPER` | `ViewHelpers`, `ViewHelper` |
| `Layers::HOOK` | `Hook`, `Hooks` |
| `Layers::FORM` | `Form` |
| `Layers::UTILITY` | `Utility`, `Utils` |

An unknown layer, an empty list, and a namespace in two layers throw an `InvalidArgumentException`.

The rules, each a method of the trait:

| Rule | The layer … must not depend on … |
|---|---|
| `testLayerDomainDoesNotDependOnOuterLayers` | domain: service, controller, command, middleware, event listener, view helper, hook, form |
| `testLayerServiceDoesNotDependOnPresentation` | service: controller, command, middleware, event listener, form |
| `testLayerEventDoesNotDependOnServiceOrController` | event: service, controller |
| `testLayerEventListenerDoesNotDependOnPresentation` | event listener: controller, middleware, form |
| `testLayerFormDoesNotDependOnPresentation` | form: controller, middleware, event listener |
| `testLayerControllerDoesNotDependOnCommand` | controller: command |
| `testLayerCommandDoesNotDependOnController` | command: controller |
| `testLayerMiddlewareDoesNotDependOnController` | middleware: controller |
| `testLayerViewHelperDoesNotDependOnController` | view helper: controller |
| `testLayerHookDoesNotDependOnController` | hook: controller |
| `testLayerRepositoryDoesNotDependOnController` | repository: controller |
| `testLayerUtilityDoesNotDependOnController` | utility: controller |

A layer the extension does not have keeps its conventional namespace. No class matches it, so its rules pass, and they apply as soon as a class of that layer is added. A layer namespace inside another layer's namespace, such as event listeners in `Service\EventListener`, is not reported for depending on itself.

To drop a rule, hide its method; PHPat runs only public methods:

```php
use LayerRules {
    testLayerControllerDoesNotDependOnCommand as private;
}
```

The `testLayer` prefix keeps the trait's methods apart from an extension's own rules in the same class, such as a `testServicesDoNotDependOnControllers` it already has. A method of the class with the same name as a trait method replaces it without a warning.

The trait covers layer direction only. Rules on single classes, `final` and `readonly` stay in the extension's own test class. `Tests/Unit/Architecture/LayerRulesTest.php` runs PHPStan over the fixture extensions in `Tests/Fixtures/Architecture`.

## Test helper: TypedArray

`Netresearch\Typo3CiWorkflows\Testing\TypedArray` reads typed values out of an untyped array in a test: TCA, `$GLOBALS['TYPO3_CONF_VARS']`, a parsed YAML file. A path is a dotted string, or a list of keys where a key contains a dot:

```php
use Netresearch\Typo3CiWorkflows\Testing\TypedArray;

$tca = TypedArray::fromGlobals('TCA');
self::assertSame('input', $tca->string('tx_myext_item.columns.title.config.type'));
self::assertSame(10, $tca->int('tx_myext_item.ctrl.sortby'));
self::assertCount(2, $tca->list('tx_myext_item.columns.type.config.items'));

$features = TypedArray::fromGlobals('TYPO3_CONF_VARS');
self::assertTrue($features->bool(['SYS', 'features', 'security.backend.enforceReferrer']));

$services = TypedArray::fromYamlFile(__DIR__ . '/../../Configuration/Services.yaml');
self::assertTrue($services->bool('services._defaults.autowire'));

$data = TypedArray::fromArray($decoded, 'response body');
```

`fromYamlFile()` parses with the flags Symfony uses for `Services.yaml`: `!php/const` gives the constant's value, and a custom tag such as `!tagged_iterator` gives a `Symfony\Component\Yaml\Tag\TaggedValue`.

The reads are `string()`, `int()`, `bool()`, `array()` and `list()`. Nothing is converted: `"1"` is neither an int nor a bool, and `list()` wants the keys 0, 1, 2, …. A value of another type, a missing key or a scalar on the way throws an `UnexpectedValueException` that names the source, the full path and the type found:

```
$GLOBALS['TCA']: "tx_myext_item.ctrl.sortby" is string, expected int.
$GLOBALS['TCA']: no value at "tx_myext_item.columns.title.config.renderType", because "tx_myext_item.columns.title.config" has no key "renderType".
```

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

The factory scans the project root and excludes `.Build`, `.build`, `.ddev`, `.pnpm-store`, `config`, `node_modules`, `public`, `var` and `ext_emconf.php`. PHP-CS-Fixer itself excludes every directory named `vendor`. The dot directories are listed because PHP-CS-Fixer 4 no longer skips dot directories by default (`PHP_CS_FIXER_FUTURE_MODE=1` shows that behaviour today). `public` is TYPO3's web directory when `composer.json` sets no `extra.typo3/cms.web-dir`.

A fourth argument excludes more directories. A plain name excludes a directory of that name at any depth. A name with a slash is a path below the project root:

```php
return $createConfig($header, __DIR__ . '/..', [], ['packages', 'Tests/Fixtures/generated']);
```

`Build/Scripts/check-cgl-finder.php` checks the list in both modes.

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

## CaptainHook

This package requires `captainhook/hook-installer` and allows its Composer plugin. On every `composer install` and `composer update` the plugin installs the Git hooks that a CaptainHook configuration defines. It reads the configuration from `extra.captainhook.config` in your `composer.json`, a path relative to the directory Composer runs in, and falls back to `captainhook.json`.

`config/captainhook/captainhook.json` is a template: a Conventional Commits check on the commit message, lint, CGL and PHPStan before a commit, and unit tests before a push. It calls the Composer scripts `ci:test:php:lint`, `ci:test:php:cgl`, `ci:test:php:phpstan` and `ci:test:php:unit`, so your extension has to define them. Copy the template to `Build/captainhook.json` and point the plugin at it:

```json
{
    "extra": {
        "captainhook": {
            "config": "Build/captainhook.json"
        }
    }
}
```

The plugin installs nothing, and prints a notice instead, in these cases:

| Situation | Notice |
|---|---|
| No configuration at the configured path | `CaptainHook configuration not found` |
| `CI=true` in the environment, as on GitHub Actions | `disabling plugin due to CI-environment` |
| The checkout is an additional Git worktree | `ARRRRR! We ARRR in a worktree, install is skipped!` |
| The plugin is switched off | `plugin is disabled` |

An extension that does not use Git hooks switches the plugin off. Either set `extra.captainhook.disable-plugin` to `true` in `composer.json`, or set the environment variable `CAPTAINHOOK_DISABLE=true` for one run. Without one of the two, every `composer install` prints the "configuration not found" notice.

### Git worktrees

In a worktree, `.git` is a file and not a directory. The plugin skips the install there with the notice above. Before 1.0.5, `captainhook/hook-installer` threw `invalid .git path` instead when the worktree's git directory is not named `.git`, as in a worktree of a bare repository or of one created with `--separate-git-dir`. The exception also stopped the remaining Composer plugins, so `phpstan/extension-installer` did not register the PHPStan extensions. This package requires 1.0.5 or later.

`composer install --no-plugins` also skips the plugin, but it skips `phpstan/extension-installer` as well, so the PHPStan extensions are no longer registered. Include them explicitly in your `Build/phpstan.neon` in that case:

```neon
includes:
    - %currentWorkingDirectory%/.Build/vendor/netresearch/typo3-ci-workflows/config/phpstan/includes-no-extension-installer.neon
    - phpstan-baseline.neon
```

`includes-no-extension-installer.neon` lists the PHPStan extension files that `phpstan/extension-installer` would otherwise register.

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
