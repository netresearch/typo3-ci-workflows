#!/usr/bin/env bash
#
# Runs the "Install TYPO3" block of every ci.yml matrix job that requires the
# cell's TYPO3 line with `composer require --no-update`, against a stubbed
# composer, with and without a committed composer.lock, and checks what the
# block asks composer to do.
#
# With a lock, `composer install` after the require refused a lock outside the
# cell's TYPO3 line: a lock at 14.3 failed the ^13.4 cell with exit 4 ("is in
# the lock file as v14.3.7 but that does not satisfy your constraint ^13.4").
# The cell must re-resolve in full (update --with-all-dependencies), as the
# lowest-deps/pinned cell does, and never install. Without a lock it installs.
#
# Every block runs under the runner's own shell flags (`bash --noprofile --norc
# -eo pipefail`), in a shell of its own; the composer stub reaches it through a
# sourced prelude. The blocks are executed, not grepped: a text probe would
# confirm a branch nothing reaches.
#
# Usage: check-matrix-cell-lock.sh [path/to/ci.yml]

set -uo pipefail

WORKFLOW="${1:-.github/workflows/ci.yml}"
[[ -f "${WORKFLOW}" ]] || { printf 'not found: %s\n' "${WORKFLOW}" >&2; exit 2; }
WORKFLOW="$(cd "$(dirname "${WORKFLOW}")" && pwd)/$(basename "${WORKFLOW}")"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FAILED=0

fail() { printf '  FAIL: %s\n' "${1}" >&2; FAILED=1; return; }
pass() { printf '  ok: %s\n' "${1}"; return; }

# What GitHub runs a `run:` block with when the step names no shell.
RUNNER_SHELL=(bash --noprofile --norc -eo pipefail)

JOBS=(phpstan phpstan-unpinned unit-tests acceptance-tests functional-tests functional-tests-sqlite)

printf 'Matrix cells with a committed composer.lock (%s)\n' "${WORKFLOW}"

step_run() { # job, step name
    yq -o json '.jobs' "${WORKFLOW}" \
        | jq -r --arg j "${1}" --arg s "${2}" \
            '.[$j].steps[] | select(.name == $s) | .run'
    return
}

# Runs a job's install block in a fixture checkout with a composer that records
# its arguments one call per line. Prints the exit status; the call log and the
# output land in ${TMP}/case/.
run_install() { # job, with-lock (yes|no)
    local dir="${TMP}/case" block
    rm -rf "${dir}"
    mkdir -p "${dir}/work"
    printf '{"require":{"typo3/cms-core":"^13.4 || ^14.3"}}\n' > "${dir}/work/composer.json"
    [[ "${2}" == yes ]] && printf '{}\n' > "${dir}/work/composer.lock"
    block="$(step_run "${1}" 'Install TYPO3')"
    if [[ -z "${block}" || "${block}" == null ]]; then
        printf 'noblock'
        return
    fi
    {
        printf 'composer() { printf "%%s\\n" "$*" >> %q; }\n' "${dir}/calls"
        cat <<'EOF'
COMPOSER_RETRY='composer_retry() { composer "$@"; }'
EOF
        printf '%s\n' "${block}"
    } > "${dir}/script.sh"
    : > "${dir}/calls"
    (
        cd "${dir}/work" || exit 99
        TYPO3_VERSION='^13.4' TYPO3_PACKAGES='["typo3/cms-core"]' GITHUB_ENV="${dir}/env" \
            "${RUNNER_SHELL[@]}" "${dir}/script.sh"
    ) > "${dir}/out" 2>&1
    printf '%s' "$?"
}

for job in "${JOBS[@]}"; do
    calls="${TMP}/case/calls"

    status="$(run_install "${job}" yes)"
    if [[ "${status}" == 0 ]] \
        && grep -qxF 'require --no-update typo3/cms-core:^13.4' "${calls}" \
        && grep -qxF 'update --with-all-dependencies --prefer-dist --no-progress' "${calls}" \
        && ! grep -q '^install' "${calls}"; then
        pass "${job}: with a composer.lock, the cell re-resolves everything instead of installing"
    else
        fail "${job} with composer.lock: exit ${status}, calls $(tr '\n' '|' < "${calls}" 2>/dev/null)"
    fi

    status="$(run_install "${job}" no)"
    if [[ "${status}" == 0 ]] \
        && grep -qxF 'require --no-update typo3/cms-core:^13.4' "${calls}" \
        && grep -qxF 'install --prefer-dist --no-progress' "${calls}" \
        && ! grep -q '^update' "${calls}"; then
        pass "${job}: without a composer.lock, the cell installs"
    else
        fail "${job} without composer.lock: exit ${status}, calls $(tr '\n' '|' < "${calls}" 2>/dev/null)"
    fi
done

# Every job that requires the TYPO3 line with --no-update must be in JOBS, or a
# new matrix job would fall outside these cases. lowest-deps has its own check.
mapfile -t requiring < <(yq -o json '.jobs' "${WORKFLOW}" \
    | jq -r 'to_entries[] | select(.key != "lowest-deps")
        | select([.value.steps[]?.run // "" | test("composer require --no-update \"\\$pkg:")] | any)
        | .key')
for job in "${requiring[@]}"; do
    if [[ " ${JOBS[*]} " != *" ${job} "* ]]; then
        fail "${job} requires the TYPO3 line with --no-update but is not covered here"
    fi
done
if [[ "${#requiring[@]}" -eq "${#JOBS[@]}" ]]; then
    pass "all ${#JOBS[@]} jobs that require the TYPO3 line are covered"
else
    fail "expected ${#JOBS[@]} jobs requiring the TYPO3 line, found ${#requiring[@]}: ${requiring[*]}"
fi

exit "${FAILED}"
