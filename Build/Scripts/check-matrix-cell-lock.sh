#!/usr/bin/env bash
#
# Runs the "Install TYPO3" block of every ci.yml matrix job that requires the
# cell's TYPO3 line with `composer require --no-update`, together with the
# workflow's own COMPOSER_RETRY and COMPOSER_INSTALL_CELL snippets, against a
# stubbed composer, and checks what the block asks composer to do.
#
# With a committed composer.lock outside the cell's TYPO3 line, `composer
# install` refused the lock and exited 4 ("is in the lock file as v14.3.7 but
# that does not satisfy your constraint ^13.4"), #264. The cells must:
#
#   - without a lock: install;
#   - with a lock that fits the cell: install it, no update;
#   - with a lock composer refuses (exit 4): update --with-all-dependencies,
#     with a notice naming the cell;
#   - on any other install failure: fail, without falling back to update;
#   - on a network error: retry the install through composer_retry.
#
# The stub answers `install --dry-run` with DRY_STATUS and a real install with
# INSTALL_STATUS (or with a transport error on its first call when
# INSTALL_FLAKY is set). Every block runs under the runner's own shell flags
# (`bash --noprofile --norc -eo pipefail`), in a shell of its own. The blocks
# are executed, not grepped: a text probe would confirm a branch nothing
# reaches.
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

COMPOSER_RETRY_SNIPPET="$(yq -o json '.env' "${WORKFLOW}" | jq -r '.COMPOSER_RETRY // empty')"
INSTALL_CELL_SNIPPET="$(yq -o json '.env' "${WORKFLOW}" | jq -r '.COMPOSER_INSTALL_CELL // empty')"
if [[ -z "${COMPOSER_RETRY_SNIPPET}" ]]; then
    fail 'ci.yml defines no COMPOSER_RETRY in its env'
    exit 1
fi

# Runs a job's install block in a fixture checkout. Prints the exit status; the
# composer call log (one call per line) and the output land in ${TMP}/case/.
run_install() { # job, with-lock (yes|no), dry-run status, install status, [typo3 line], [flaky]
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
    # shellcheck disable=SC2016 # expanded by the block's shell, not here
    {
        printf 'CALLS=%q\n' "${dir}/calls"
        cat <<'EOF'
composer() {
    printf '%s\n' "$*" >> "$CALLS"
    case "$*" in
        'install --dry-run'*)
            printf 'dry-run output\n'
            return "$DRY_STATUS" ;;
        install*)
            if [[ -n "${INSTALL_FLAKY:-}" && ! -e "$CALLS.flaked" ]]; then
                : > "$CALLS.flaked"
                printf 'curl error 28 while downloading https://repo.packagist.org/packages.json\n'
                return 100
            fi
            [[ "$INSTALL_STATUS" == 0 ]] || printf 'Problem 1\n'
            return "$INSTALL_STATUS" ;;
    esac
    return 0
}
sleep() { return 0; }
EOF
        printf '%s\n' "${block}"
    } > "${dir}/script.sh"
    : > "${dir}/calls"
    (
        cd "${dir}/work" || exit 99
        COMPOSER_RETRY="${COMPOSER_RETRY_SNIPPET}" COMPOSER_INSTALL_CELL="${INSTALL_CELL_SNIPPET}" \
            DRY_STATUS="${3}" INSTALL_STATUS="${4}" INSTALL_FLAKY="${6:-}" GITHUB_JOB="${1}" \
            TYPO3_VERSION="${5:-^13.4}" TYPO3_PACKAGES='["typo3/cms-core"]' GITHUB_ENV="${dir}/env" \
            "${RUNNER_SHELL[@]}" "${dir}/script.sh"
    ) > "${dir}/out" 2>&1
    printf '%s' "$?"
}

calls="${TMP}/case/calls"
out="${TMP}/case/out"
show() {
    printf 'exit %s, calls %s, out %s' "${1}" "$(tr '\n' '|' < "${calls}" 2>/dev/null)" "$(tr '\r\n' '||' < "${out}" 2>/dev/null)"
    return
}

# The composer call a real install is logged as.
INSTALL_CALL='install --prefer-dist --no-progress'

for job in "${JOBS[@]}"; do
    status="$(run_install "${job}" no 0 0)"
    if [[ "${status}" == 0 ]] \
        && grep -qxF 'require --no-update typo3/cms-core:^13.4' "${calls}" \
        && grep -qxF "${INSTALL_CALL}" "${calls}" \
        && ! grep -q '^update\|--dry-run' "${calls}"; then
        pass "${job}: without a composer.lock, the cell installs"
    else
        fail "${job} without composer.lock: $(show "${status}")"
    fi

    status="$(run_install "${job}" yes 0 0)"
    if [[ "${status}" == 0 ]] \
        && grep -qxF 'install --dry-run --no-progress' "${calls}" \
        && grep -qxF "${INSTALL_CALL}" "${calls}" \
        && ! grep -q '^update' "${calls}" \
        && ! grep -q '::notice::\|::error::' "${out}"; then
        pass "${job}: a composer.lock that fits the cell is installed, not updated"
    else
        fail "${job} with a fitting composer.lock: $(show "${status}")"
    fi

    status="$(run_install "${job}" yes 4 0)"
    if [[ "${status}" == 0 ]] \
        && grep -qxF 'update --with-all-dependencies --prefer-dist --no-progress' "${calls}" \
        && ! grep -qxF "${INSTALL_CALL}" "${calls}" \
        && grep -q "^::notice::composer.lock does not satisfy the constraints of this cell (${job}, PHP [^,]*, TYPO3 ^13.4): composer install exits 4" "${out}" \
        && grep -qxF 'dry-run output' "${out}" \
        && ! grep -q '::error::' "${out}"; then
        pass "${job}: a composer.lock composer refuses (exit 4) falls back to update, with a notice"
    else
        fail "${job} with a refused composer.lock: $(show "${status}")"
    fi

    status="$(run_install "${job}" yes 2 2)"
    if [[ "${status}" == 2 ]] \
        && grep -qxF "${INSTALL_CALL}" "${calls}" \
        && ! grep -q '^update' "${calls}" \
        && ! grep -q '::notice::' "${out}"; then
        pass "${job}: any other install failure fails the step, without an update"
    else
        fail "${job} with another install failure: $(show "${status}")"
    fi
done

# A network error in the install is retried by composer_retry, as before, and
# is no reason to update.
status="$(run_install unit-tests yes 100 0 '^13.4' yes)"
if [[ "${status}" == 0 ]] \
    && [[ "$(grep -cxF "${INSTALL_CALL}" "${calls}")" == 2 ]] \
    && ! grep -q '^update' "${calls}"; then
    pass 'a network error in the install is retried through composer_retry, not updated'
else
    fail "network error: $(show "${status}")"
fi

# The TYPO3 line is quoted in the notice: a line break in it must not end the
# annotation.
status="$(run_install unit-tests yes 4 0 $'^13.4\r\n::error::INJECTED')"
if [[ "${status}" == 0 ]] \
    && ! tr '\r' '\n' < "${out}" | grep -q '^::error::INJECTED' \
    && grep -qF 'TYPO3 ^13.4%0D%0A::error::INJECTED)' "${out}"; then
    pass 'a line break in the TYPO3 line is escaped in the notice'
else
    fail "line break in the notice: $(show "${status}")"
fi

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
