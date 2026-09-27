#!/usr/bin/env bash
#
# Runs the `run:` blocks of ci.yml's lowest-deps job (and the cell selection
# of phpstan-unpinned, which shares its shape) against stubbed composer and
# fixture inputs, and checks what they do. Each case below was a review finding
# on the pull request that introduced the job (#258):
#
#   1. A pin whose name starts with "-" reached `composer require` as an
#      option: `-dother/x:y` became --working-dir, exited 0, pinned nothing.
#   2. A whitespace-only pin-packages ran a green cell that pinned nothing.
#   3. `for pin in $PIN_PACKAGES` glob-expanded `a/b:*` against the checkout.
#   4. matrix-exclude was compared as whole {php, typo3} tuples, so a partial
#      entry such as {"typo3": "^13.4"} excluded nothing. GitHub excludes on a
#      partial match.
#   5. The matrix TYPO3 string replaced the extension's own floor, so
#      `^13.4` against a composer.json `^13.4.21` let --prefer-lowest take
#      13.4.0.
#   6. `functional-test-db: ''` ran SQLite here and MySQL in the matrix.
#   7. The cell ran without the coverage driver the matrix cells have.
#
# The blocks are executed, not grepped: a text probe would confirm a guard
# that sits in a branch nothing reaches.
#
# Usage: check-lowest-deps-cell.sh [path/to/ci.yml]

set -uo pipefail

WORKFLOW="${1:-.github/workflows/ci.yml}"
[[ -f "${WORKFLOW}" ]] || { printf 'not found: %s\n' "${WORKFLOW}" >&2; exit 2; }
WORKFLOW="$(cd "$(dirname "${WORKFLOW}")" && pwd)/$(basename "${WORKFLOW}")"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FAILED=0

fail() { printf '  FAIL: %s\n' "${1}" >&2; FAILED=1; }
pass() { printf '  ok: %s\n' "${1}"; }

step_run() { # job, step id or name
    yq -o json '.jobs' "${WORKFLOW}" \
        | jq -r --arg j "${1}" --arg s "${2}" \
            '.[$j].steps[] | select(.id == $s or .name == $s) | .run'
}

printf 'Lowest-deps cell (%s)\n' "${WORKFLOW}"

# --- Cell selection ---------------------------------------------------------

select_cell() { # job, php-versions, typo3-versions, matrix-exclude -> "php typo3" or "exit N"
    local out status
    out="${TMP}/select.out"
    : > "${out}"
    (
        cd "${TMP}" || exit 99
        PHP_VERSIONS="${2}" TYPO3_VERSIONS="${3}" MATRIX_EXCLUDE="${4}" GITHUB_OUTPUT="${out}" \
            bash -e -c "$(step_run "${1}" cell)"
    ) > /dev/null 2>&1
    status=$?
    if [[ "${status}" -ne 0 ]]; then
        printf 'exit %s' "${status}"
        return
    fi
    printf '%s %s' "$(sed -n 's/^php=//p' "${out}")" "$(sed -n 's/^typo3=//p' "${out}")"
}

expect_cell() { # label, expected, job, php, typo3, exclude
    local got
    got="$(select_cell "${3}" "${4}" "${5}" "${6}")"
    if [[ "${got}" == "${2}" ]]; then
        pass "${3}: ${1} -> ${got}"
    else
        fail "${3}: ${1}: expected '${2}', got '${got}'"
    fi
}

P='["8.3","8.2"]'
T='["^14.3","^13.4"]'
expect_cell 'no exclude' '8.2 ^13.4' lowest-deps "${P}" "${T}" '[]'
expect_cell 'full exclude' '8.2 ^14.3' lowest-deps "${P}" "${T}" '[{"php":"8.2","typo3":"^13.4"}]'
expect_cell 'partial exclude by typo3' '8.2 ^14.3' lowest-deps "${P}" "${T}" '[{"typo3":"^13.4"}]'
expect_cell 'partial exclude by php' '8.3 ^13.4' lowest-deps "${P}" "${T}" '[{"php":"8.2"}]'
expect_cell 'everything excluded' 'exit 1' lowest-deps "${P}" "${T}" '[{"php":"8.2"},{"php":"8.3"}]'
expect_cell 'no exclude' '8.3 ^14.3' phpstan-unpinned "${P}" "${T}" '[]'
expect_cell 'partial exclude by typo3' '8.3 ^13.4' phpstan-unpinned "${P}" "${T}" '[{"typo3":"^14.3"}]'
expect_cell 'partial exclude by php' '8.2 ^14.3' phpstan-unpinned "${P}" "${T}" '[{"php":"8.3"}]'

# --- Install --------------------------------------------------------------

INSTALL="$(step_run lowest-deps install)"

# Runs the install block in a fixture checkout with a composer that records its
# arguments one call per line. Prints the exit status; the call log and the
# output land in ${TMP}/case/.
run_install() { # composer.json, typo3-version, lowest-deps, pin-packages
    local dir="${TMP}/case"
    rm -rf "${dir}"
    mkdir -p "${dir}/work/a"
    printf '%s\n' "${1}" > "${dir}/work/composer.json"
    # A file the glob `a/b:*` would match, were it expanded.
    : > "${dir}/work/a/b:GLOBBED"
    {
        printf 'composer() { printf "%%s\\n" "$*" >> %q; }\n' "${dir}/calls"
        printf 'php() { printf "8.2.0"; }\n'
        cat <<'EOF'
COMPOSER_RETRY='composer_retry() { composer "$@"; }'
EOF
        printf '%s\n' "${INSTALL}"
    } > "${dir}/script.sh"
    : > "${dir}/calls"
    (
        cd "${dir}/work" || exit 99
        TYPO3_VERSION="${2}" TYPO3_PACKAGES='["typo3/cms-core"]' LOWEST_DEPS="${3}" \
            PIN_PACKAGES="${4}" GITHUB_STEP_SUMMARY="${dir}/summary" \
            bash -e "${dir}/script.sh"
    ) > "${dir}/out" 2>&1
    printf '%s' "$?"
}

CJ='{"require":{"typo3/cms-core":"^13.4 || ^14.3","guzzlehttp/guzzle":"^7.10 || ^8.0"},"require-dev":{"mikey179/vfsstream":"^1.6"}}'

status="$(run_install "${CJ}" '^13.4' false '-dother/x:y')"
if [[ "${status}" -ne 0 ]] && ! grep -q -- 'other/x' "${TMP}/case/calls" && grep -q '::error::' "${TMP}/case/out"; then
    pass 'a pin starting with "-" is rejected before composer sees it'
else
    fail "a pin starting with \"-\" reached composer (exit ${status}): $(tr '\n' '|' < "${TMP}/case/calls")"
fi

status="$(run_install "${CJ}" '^13.4' false '   ')"
if [[ "${status}" -ne 0 ]] && grep -q 'pin-packages contains no pins' "${TMP}/case/out"; then
    pass 'whitespace-only pin-packages without lowest-deps fails'
else
    fail "whitespace-only pin-packages exited ${status} without the no-pins error"
fi

status="$(run_install "${CJ}" '^13.4' true '')"
if [[ "${status}" -eq 0 ]] && grep -qx 'update --prefer-lowest --prefer-stable --prefer-dist --no-progress' "${TMP}/case/calls"; then
    pass 'lowest-deps without pins resolves with --prefer-lowest'
else
    fail "lowest-deps without pins: exit ${status}, calls $(tr '\n' '|' < "${TMP}/case/calls")"
fi

status="$(run_install "${CJ}" '^13.4' false 'guzzlehttp/guzzle:^7.10 typo3/cms-dashboard:>=13.4,<14 a/b:* mikey179/vfsstream:^1.6.12')"
calls="${TMP}/case/calls"
if [[ "${status}" -eq 0 ]] \
    && grep -qx 'require --no-update -- guzzlehttp/guzzle:^7.10' "${calls}" \
    && grep -qx 'require --no-update -- typo3/cms-dashboard:>=13.4,<14' "${calls}" \
    && grep -qxF 'require --no-update -- a/b:*' "${calls}" \
    && grep -qx 'require --dev --no-update -- mikey179/vfsstream:^1.6.12' "${calls}" \
    && ! grep -q 'GLOBBED' "${calls}" \
    && grep -qx 'install --prefer-dist --no-progress' "${calls}"; then
    pass 'pins reach composer after --, unglobbed, require-dev ones with --dev'
else
    fail "pins: exit ${status}, calls $(tr '\n' '|' < "${calls}")"
fi

# The extension's own floor survives: every disjunct of composer.json's
# constraint is ANDed with the matrix line, so ^13.4 cannot undercut ^13.4.21.
status="$(run_install '{"require":{"typo3/cms-core":"^13.4.21 || ^14.3"}}' '^13.4' true '')"
if [[ "${status}" -eq 0 ]] && grep -qxF 'require --no-update -- typo3/cms-core:^13.4, ^13.4.21 || ^13.4, ^14.3' "${TMP}/case/calls"; then
    pass 'the matrix line is intersected with the composer.json floor'
else
    fail "TYPO3 floor: exit ${status}, calls $(tr '\n' '|' < "${TMP}/case/calls")"
fi

status="$(run_install '{"require":{}}' '^13.4' true '')"
if [[ "${status}" -eq 0 ]] && grep -qxF 'require --no-update -- typo3/cms-core:^13.4' "${TMP}/case/calls"; then
    pass 'a package composer.json does not name gets the matrix line alone'
else
    fail "TYPO3 without floor: exit ${status}, calls $(tr '\n' '|' < "${TMP}/case/calls")"
fi

# --- Functional database --------------------------------------------------

FUNCTIONAL="$(step_run lowest-deps 'Run functional tests')"
driver_for() { # functional-test-db
    # The block under test is eval'd, so shellcheck cannot see that it calls
    # composer and reads these two variables.
    # shellcheck disable=SC2034,SC2329
    (
        cd "${TMP}" || exit 99
        composer() {
            case "$1" in
                run-script) printf 'ci:test:php:functional\n' ;;
                *) printf 'DRIVER=%s\n' "${typo3DatabaseDriver:-unset}" ;;
            esac
        }
        FUNCTIONAL_TEST_COMMAND='' FUNCTIONAL_TEST_DB="${1}"
        eval "${FUNCTIONAL}"
    ) 2>/dev/null | sed -n 's/^DRIVER=//p'
}
for pair in 'sqlite pdo_sqlite' 'postgres pdo_pgsql' 'mysql mysqli' 'mariadb mysqli' "'' mysqli"; do
    db="${pair% *}"; want="${pair#* }"
    [[ "${db}" == "''" ]] && db=''
    got="$(driver_for "${db}")"
    if [[ "${got}" == "${want}" ]]; then
        pass "functional-test-db '${db}' -> ${got}, as in the matrix"
    else
        fail "functional-test-db '${db}': expected ${want}, got '${got}'"
    fi
done

# --- Coverage driver ------------------------------------------------------

matrix_cov="$(yq -r '.jobs["unit-tests"].steps[] | select(.name == "Setup PHP") | .with.coverage' "${WORKFLOW}")"
cell_cov="$(yq -r '.jobs["lowest-deps"].steps[] | select(.name == "Setup PHP") | .with.coverage' "${WORKFLOW}")"
if [[ "${cell_cov}" == "${matrix_cov}" ]]; then
    pass "coverage driver matches the matrix cells (${cell_cov})"
else
    fail "coverage driver '${cell_cov}' differs from the matrix cells' '${matrix_cov}'"
fi

exit "${FAILED}"
