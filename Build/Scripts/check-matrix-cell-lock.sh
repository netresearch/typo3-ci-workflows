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
#   - with a lock built on a newer PHP (exit 2, and `php` the only failing
#     requirement of `check-platform-reqs --lock`): the same fallback;
#   - with a missing ext-*, alone or beside a PHP mismatch: fail, no update;
#   - with config.platform.php set: no fallback at all, the install fails;
#   - with a lock out of sync with the committed composer.json (content-hash),
#     or one that cannot be checked (also: anything but 32 hex digits from
#     the hash computation): no fallback, an ::error:: naming it;
#   - on any other install failure: fail, without falling back to update;
#   - on a network error: retry the install through composer_retry.
#
# The stub answers `install --dry-run` with DRY_STATUS, `check-platform-reqs`
# with PLATFORM_JSON and PLATFORM_STATUS (shapes as Composer 2.10.3 prints
# them), and a real install with INSTALL_STATUS (or with a transport error on
# its first call when INSTALL_FLAKY is set), and `config platform.php` with
# CASE_PLATFORM_PHP. The fixture is a git repository with composer.json
# committed; its composer.lock carries the content-hash Composer's own
# Locker::getContentHash() gives for it (CASE_LOCK_HASH overrides it, and
# CASE_NO_GIT leaves the repository out). The freshness check therefore needs
# a real `php` and a composer phar on PATH. Every block runs under the runner's own shell flags
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

if ! command -v php > /dev/null || ! type -P composer > /dev/null || ! command -v git > /dev/null; then
    fail 'the cases need php, git and a composer phar on PATH'
    exit 1
fi

FIXTURE_JSON='{"require":{"typo3/cms-core":"^13.4 || ^14.3"}}'
# shellcheck disable=SC2016 # the $ belong to PHP, not to the shell
FRESH_HASH="$(printf '%s\n' "${FIXTURE_JSON}" | php -r '
    Phar::loadPhar($argv[1], "composer.phar");
    require "phar://composer.phar/vendor/autoload.php";
    echo Composer\Package\Locker::getContentHash(stream_get_contents(STDIN));
' -- "$(type -P composer)")"
if [[ ! "${FRESH_HASH}" =~ ^[0-9a-f]{32}$ ]]; then
    fail "could not compute the fixture's content-hash: '${FRESH_HASH}'"
    exit 1
fi

COMPOSER_RETRY_SNIPPET="$(yq -o json '.env' "${WORKFLOW}" | jq -r '.COMPOSER_RETRY // empty')"
INSTALL_CELL_SNIPPET="$(yq -o json '.env' "${WORKFLOW}" | jq -r '.COMPOSER_INSTALL_CELL // empty')"
if [[ -z "${COMPOSER_RETRY_SNIPPET}" ]]; then
    fail 'ci.yml defines no COMPOSER_RETRY in its env'
    exit 1
fi

# Runs a job's install block in a fixture checkout. Prints the exit status; the
# composer call log (one call per line) and the output land in ${TMP}/case/.
run_install() { # job, with-lock (yes|no), dry-run status, install status, [typo3 line], [flaky], [platform json], [platform status]
    local dir="${TMP}/case" block
    rm -rf "${dir}"
    mkdir -p "${dir}/work"
    printf '%s\n' "${FIXTURE_JSON}" > "${dir}/work/composer.json"
    [[ "${2}" == yes ]] \
        && printf '{"content-hash":"%s"}\n' "${CASE_LOCK_HASH:-${FRESH_HASH}}" > "${dir}/work/composer.lock"
    if [[ -z "${CASE_NO_GIT:-}" ]] && ! { git -C "${dir}/work" init -q \
        && git -C "${dir}/work" add composer.json \
        && git -C "${dir}/work" -c user.name=check -c user.email=check@example.invalid \
            -c commit.gpgsign=false commit -q -m fixture; }; then
        printf 'gitfail'
        return
    fi
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
        'require '*)
            # Changes composer.json as the real require does, so that a check
            # reading the working copy instead of the committed file differs.
            jq '.require["check/marker"] = "*"' composer.json > composer.json.tmp \
                && mv composer.json.tmp composer.json
            return 0 ;;
        'install --dry-run'*)
            printf 'dry-run output\n'
            # What Composer adds for a solver problem when GITHUB_ACTIONS is set.
            [[ "$DRY_STATUS" != 2 ]] || printf '::error ::Your lock file does not contain a compatible set of packages. Please run composer update.%%0A%%0A  Problem 1\n'
            return "$DRY_STATUS" ;;
        'config platform.php')
            [[ -n "${PLATFORM_PHP:-}" ]] || return 1
            printf '%s\n' "$PLATFORM_PHP"
            return 0 ;;
        'check-platform-reqs --lock --format=json')
            printf '%s\n' "$PLATFORM_JSON"
            return "$PLATFORM_STATUS" ;;
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
# PHP_NOISE: the content-hash computation prints a notice to stdout first, as
# Composer 2.2 does on PHP 8.4 with display_errors on.
php() {
    if [[ -n "${PHP_NOISE:-}" && "$*" == *getContentHash* ]]; then
        printf 'Deprecated: Return type of Composer\\Repository\\ArrayRepository::count() should be compatible\n'
    fi
    command php "$@"
}
EOF
        printf '%s\n' "${block}"
    } > "${dir}/script.sh"
    : > "${dir}/calls"
    (
        cd "${dir}/work" || exit 99
        COMPOSER_RETRY="${COMPOSER_RETRY_SNIPPET}" COMPOSER_INSTALL_CELL="${INSTALL_CELL_SNIPPET}" \
            DRY_STATUS="${3}" INSTALL_STATUS="${4}" INSTALL_FLAKY="${6:-}" GITHUB_JOB="${1}" \
            PLATFORM_JSON="${7:-[]}" PLATFORM_STATUS="${8:-0}" PLATFORM_PHP="${CASE_PLATFORM_PHP:-}" \
            PHP_NOISE="${CASE_PHP_NOISE:-}" \
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

# The composer call a real install is logged as, and the fallback's.
INSTALL_CALL='install --prefer-dist --no-progress'
UPDATE_CALL='update --with-all-dependencies --prefer-dist --no-progress'
# Any composer update, partial or full.
ANY_UPDATE='^update'
# A notice annotation, anywhere in the output.
NOTICE='::notice::'

# check-platform-reqs --lock --format=json as Composer 2.10.3 prints it, one
# passing entry plus the failing ones.
OK_ENTRY='{"name":"composer-plugin-api","version":"2.9.0","status":"success","failed_requirement":null,"provider":null}'
PHP_ENTRY='{"name":"php","version":"8.2.33","status":"failed","failed_requirement":{"source":"phpunit/php-code-coverage","type":"requires","target":"php","constraint":">=8.3"},"provider":null}'
EXT_ENTRY='{"name":"ext-intl","version":"n/a","status":"missing","failed_requirement":{"source":"typo3/cms-core","type":"requires","target":"ext-intl","constraint":"*"},"provider":null}'

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
        && ! grep -q "${ANY_UPDATE}" "${calls}" \
        && ! grep -q '::notice::\|::error::' "${out}"; then
        pass "${job}: a composer.lock that fits the cell is installed, not updated"
    else
        fail "${job} with a fitting composer.lock: $(show "${status}")"
    fi

    status="$(run_install "${job}" yes 4 0)"
    if [[ "${status}" == 0 ]] \
        && grep -qxF "${UPDATE_CALL}" "${calls}" \
        && ! grep -qxF "${INSTALL_CALL}" "${calls}" \
        && grep -q "^::notice::composer.lock cannot be installed in this cell (${job}, PHP [^,]*, TYPO3 ^13.4)\. composer install exits 4: the lock does not satisfy the constraints of this cell\. " "${out}" \
        && grep -qxF 'dry-run output' "${out}" \
        && ! grep -q '^::error' "${out}"; then
        pass "${job}: a composer.lock composer refuses (exit 4) falls back to update, with a notice"
    else
        fail "${job} with a refused composer.lock: $(show "${status}")"
    fi

    status="$(run_install "${job}" yes 2 2)"
    if [[ "${status}" == 2 ]] \
        && grep -qxF "${INSTALL_CALL}" "${calls}" \
        && ! grep -q "${ANY_UPDATE}" "${calls}" \
        && ! grep -q "${NOTICE}" "${out}"; then
        pass "${job}: any other install failure fails the step, without an update"
    else
        fail "${job} with another install failure: $(show "${status}")"
    fi

    status="$(run_install "${job}" yes 2 2 '^13.4' '' "[${OK_ENTRY},${PHP_ENTRY}]" 1)"
    if [[ "${status}" == 0 ]] \
        && grep -qxF 'check-platform-reqs --lock --format=json' "${calls}" \
        && grep -qxF "${UPDATE_CALL}" "${calls}" \
        && ! grep -qxF "${INSTALL_CALL}" "${calls}" \
        && grep -qF "::notice::composer.lock cannot be installed in this cell (${job}, PHP " "${out}" \
        && grep -qF 'composer install exits 2: the locked packages need another PHP version (phpunit/php-code-coverage requires php >=8.3).' "${out}" \
        && grep -qxF 'dry-run output' "${out}" \
        && ! grep -q '^::error' "${out}"; then
        pass "${job}: a composer.lock built on a newer PHP falls back to update, with a notice"
    else
        fail "${job} with a PHP-only platform mismatch: $(show "${status}")"
    fi

    status="$(run_install "${job}" yes 2 2 '^13.4' '' "[${OK_ENTRY},${EXT_ENTRY}]" 2)"
    if [[ "${status}" == 2 ]] \
        && grep -qxF "${INSTALL_CALL}" "${calls}" \
        && ! grep -q "${ANY_UPDATE}" "${calls}" \
        && ! grep -q "${NOTICE}" "${out}"; then
        pass "${job}: a missing ext-* fails the step, without an update"
    else
        fail "${job} with a missing extension: $(show "${status}")"
    fi

    status="$(run_install "${job}" yes 2 2 '^13.4' '' "[${OK_ENTRY},${EXT_ENTRY},${PHP_ENTRY}]" 2)"
    if [[ "${status}" == 2 ]] \
        && grep -qxF "${INSTALL_CALL}" "${calls}" \
        && ! grep -q "${ANY_UPDATE}" "${calls}" \
        && ! grep -q "${NOTICE}" "${out}"; then
        pass "${job}: a missing ext-* beside a PHP mismatch fails the step, without an update"
    else
        fail "${job} with a missing extension and a PHP mismatch: $(show "${status}")"
    fi

    for dry in 2 4; do
        status="$(CASE_PLATFORM_PHP=8.3.0 run_install "${job}" yes "${dry}" "${dry}" '^13.4' '' "[${OK_ENTRY},${PHP_ENTRY}]" 1)"
        if [[ "${status}" == "${dry}" ]] \
            && grep -qxF 'config platform.php' "${calls}" \
            && grep -qxF "${INSTALL_CALL}" "${calls}" \
            && ! grep -q "${ANY_UPDATE}" "${calls}" \
            && grep -qxF '::notice::composer.json sets config.platform.php, so this cell does not re-resolve a composer.lock that does not install.' "${out}" \
            && [[ "$(grep -c "${NOTICE}" "${out}")" == 1 ]]; then
            pass "${job}: with config.platform.php set, dry run exit ${dry} fails the step, without an update"
        else
            fail "${job} with config.platform.php, dry run exit ${dry}: $(show "${status}")"
        fi
    done

    for dry in 4 2; do
        status="$(CASE_LOCK_HASH=0123456789abcdef0123456789abcdef run_install "${job}" yes "${dry}" 0 '^13.4' '' "[${OK_ENTRY},${PHP_ENTRY}]" 1)"
        if [[ "${status}" == 1 ]] \
            && ! grep -q "${ANY_UPDATE}" "${calls}" \
            && ! grep -qxF "${INSTALL_CALL}" "${calls}" \
            && ! grep -q "${NOTICE}" "${out}" \
            && grep -qF "::error::composer.lock is out of sync with the committed composer.json (content-hash 0123456789abcdef0123456789abcdef, composer.json gives ${FRESH_HASH}). Run composer update and commit composer.lock. In this cell (${job}, PHP " "${out}"; then
            pass "${job}: a stale composer.lock (dry run exit ${dry}) fails with an error naming it, without an update"
        else
            fail "${job} with a stale composer.lock, dry run exit ${dry}: $(show "${status}")"
        fi
    done
done

# Without a git repository the committed composer.json cannot be read: no
# fallback, and an error that says the lock could not be checked.
status="$(CASE_NO_GIT=yes run_install unit-tests yes 4 0)"
if [[ "${status}" == 1 ]] \
    && ! grep -q "${ANY_UPDATE}" "${calls}" \
    && grep -qF "::error::Could not check composer.lock against the committed composer.json (lock content-hash '${FRESH_HASH}', composer.json '')" "${out}"; then
    pass 'a lock that cannot be checked against the committed composer.json fails, without an update'
else
    fail "unverifiable lock: $(show "${status}")"
fi

# Output around the hash is "could not check", never "stale": a notice before
# a correct hash must not be read as a different hash.
status="$(CASE_PHP_NOISE=yes run_install unit-tests yes 4 0)"
if [[ "${status}" == 1 ]] \
    && ! grep -q "${ANY_UPDATE}" "${calls}" \
    && ! grep -qF 'out of sync' "${out}" \
    && grep -qF "::error::Could not check composer.lock against the committed composer.json (lock content-hash '${FRESH_HASH}', composer.json 'Deprecated: " "${out}"; then
    pass 'a notice printed before the content-hash is reported as unverifiable, not as stale'
else
    fail "notice before the content-hash: $(show "${status}")"
fi

# A network error in the install is retried by composer_retry, as before, and
# is no reason to update.
status="$(run_install unit-tests yes 100 0 '^13.4' yes)"
if [[ "${status}" == 0 ]] \
    && [[ "$(grep -cxF "${INSTALL_CALL}" "${calls}")" == 2 ]] \
    && ! grep -q "${ANY_UPDATE}" "${calls}"; then
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
