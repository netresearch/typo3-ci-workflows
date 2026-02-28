# Design: Grouped Caller Workflows

## Problem

Each TYPO3 extension repo currently needs 16 individual workflow files, each containing
a tiny `uses:` reference to a centralized reusable workflow. This creates unnecessary
boilerplate and maintenance burden. The `ci.yml` reusable workflow bundles 7 jobs, yet
every other concern gets its own file.

## Decision

Consolidate caller workflow files from 16 to 4 per repo, grouped by trigger pattern.
The 17 reusable workflows in typo3-ci-workflows remain unchanged.

## Grouped Structure (4 files per repo)

### 1. ci.yml

Trigger: `push + pull_request + schedule (weekly)`

Jobs calling reusable workflows:
- ci (lint, cgl, phpstan, rector, unit tests, functional tests)
- security (gitleaks + composer audit)
- fuzz (fuzz tests + mutation testing)
- license-check (PHP license audit)
- codeql (CodeQL security scanning)
- scorecard (OpenSSF scorecard, push-only via `if:`)
- dependency-review (PR-only via `if:`)
- pr-quality (PR-only via `if:`)
- labeler (PR-only via `if:`)

Single weekly cron schedule covers security, fuzz, license, codeql, scorecard.
PR-only jobs use `if: github.event_name == 'pull_request'`.

### 2. release.yml

Trigger: `push tags v*`

Jobs:
- release (archive, SBOM, Cosign signing, attestation, GitHub Release)
- publish-to-ter (TER publishing)
- slsa-provenance (SLSA Level 3 provenance, needs: release)

### 3. community.yml

Trigger: `schedule (daily) + issues (opened) + pull_request_target (opened) + workflow_dispatch`

Jobs:
- stale (mark/close stale issues, daily)
- lock (lock old threads, daily)
- greetings (welcome first-time contributors, on issue/PR open)

### 4. auto-merge-deps.yml

Trigger: `pull_request`

Jobs:
- auto-merge (approve + merge Dependabot/Renovate PRs)

Kept separate because it requires `contents: write` which should not be granted
to CI jobs, and it is a clear opt-in/opt-out feature.

## Per-repo Customization

Each repo customizes ci.yml with its own inputs:
- `php-versions`, `typo3-versions`, `matrix-exclude`
- Feature flags: `run-fuzz-tests`, `skip-gitleaks`, etc.
- `archive-prefix`, `package-name` in release.yml

## Reusable Workflows (unchanged)

The 17 reusable workflows in typo3-ci-workflows stay as-is:
ci, codeql, dependency-review, scorecard, auto-merge-deps, publish-to-ter,
pr-quality, security, stale, lock, greetings, labeler, license-check,
docs, release, fuzz, slsa-provenance.

## Migration

- Close or update the 17 existing PRs (created with 16-file granular approach)
- Create new PRs with the 4-file grouped structure
- Delete old individual caller workflow files from repos that already had them
