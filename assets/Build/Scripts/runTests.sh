#!/usr/bin/env bash

#
# TYPO3 Extension Test Runner — netresearch/typo3-ci-workflows
# Docker/podman-based test orchestration following TYPO3 core conventions.
#
# This file is the SHARED runner. Do not fork it into an extension: composer
# links it to ${BIN_DIR}/runTests.sh, and Build/Scripts/runTests.sh in an
# extension is a bootstrap stub that execs it (see the repository README).
#
# Everything an extension may need to differ on is a variable below, and
# Build/Scripts/runTests.conf — sourced if it exists — is where an extension
# sets them. Anything that cannot be expressed that way belongs upstream in
# this file, not in a copy.
#
# Reference: https://github.com/TYPO3BestPractices/tea
#

trap 'clean_up;exit 2' SIGINT

wait_for() {
    local host=${1}
    local port=${2}
    # Third argument: seconds to wait, default 10 as before. A database
    # container initialising its data directory on a cold cache needs more than
    # that, and the caller knows which service it is waiting for.
    local attempts=${3:-10}
    local test_command="
        COUNT=0;
        while ! nc -z ${host} ${port}; do
            if [ \"\${COUNT}\" -gt ${attempts} ]; then
              echo \"Can not connect to ${host} port ${port}. Aborting.\";
              exit 1;
            fi;
            sleep 1;
            COUNT=\$((COUNT + 1));
        done;
    "
    ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name wait-for-${SUFFIX} ${XDEBUG_MODE} -e XDEBUG_CONFIG="${XDEBUG_CONFIG}" ${IMAGE_ALPINE} /bin/sh -c "${test_command}"
    if [[ $? -gt 0 ]]; then
        kill -SIGINT -$$
    fi
    return 0
}

wait_for_http() {
    local url=${1}
    local max_attempts=${2:-30}
    local test_command="
        COUNT=0;
        while ! wget -q --spider ${url} 2>/dev/null; do
            if [ \"\${COUNT}\" -gt ${max_attempts} ]; then
              echo \"HTTP endpoint ${url} not available after ${max_attempts} attempts. Aborting.\";
              exit 1;
            fi;
            sleep 1;
            COUNT=\$((COUNT + 1));
        done;
        echo \"HTTP endpoint ${url} is ready.\";
    "
    ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name wait-for-http-${SUFFIX} ${IMAGE_ALPINE} /bin/sh -c "${test_command}"
    if [[ $? -gt 0 ]]; then
        kill -SIGINT -$$
    fi
    return 0
}

clean_up() {
    if [[ -n "${NETWORK:-}" ]] && [[ -n "${CONTAINER_BIN:-}" ]]; then
        ATTACHED_CONTAINERS=$(${CONTAINER_BIN} ps --filter network=${NETWORK} --format='{{.Names}}' 2>/dev/null)
        for ATTACHED_CONTAINER in ${ATTACHED_CONTAINERS}; do
            ${CONTAINER_BIN} rm -f ${ATTACHED_CONTAINER} >/dev/null 2>&1
        done
        ${CONTAINER_BIN} network rm ${NETWORK} >/dev/null 2>&1
    fi
    return 0
}

clean_cache_files() {
    echo -n "Clean caches ... "
    rm -rf \
        .Build/.cache \
        .Build/cache \
        .php-cs-fixer.cache
    echo "done"
    return 0
}

handle_dbms_options() {
    case ${DBMS} in
        mariadb)
            [[ -z "${DATABASE_DRIVER}" ]] && DATABASE_DRIVER="${MYSQL_DRIVER}"
            if [[ "${DATABASE_DRIVER}" != "${MYSQL_DRIVER}" ]] && [[ "${DATABASE_DRIVER}" != "pdo_mysql" ]]; then
                echo "Invalid combination -d ${DBMS} -a ${DATABASE_DRIVER}" >&2
                exit 1
            fi
            [[ -z "${DBMS_VERSION}" ]] && DBMS_VERSION="11.8"
            # The MariaDB series still in community support (mariadb.org
            # maintenance policy): 10.11 until 2028-02, 11.4 until 2029-05,
            # 11.8 until 2028-06, 12.3 until 2029-06. 10.5, 10.6 and 11.0 are
            # EOL; 12.0-12.2 are rolling releases, not LTS.
            #
            # A version that has left support is mapped onto the LTS of its own
            # series rather than refused: `-i 10.5` sits in Makefiles, READMEs
            # and muscle memory, and failing those calls buys nothing. The
            # substitution is announced on every run, because a suite that
            # silently ran a different engine than it was asked for is worse
            # than a broken call. DBMS_VERSION_EXACT=1 skips mapping and check
            # both, for reproducing a bug on the engine a customer operates.
            if [[ "${DBMS_VERSION_EXACT:-0}" != "1" ]]; then
                case "${DBMS_VERSION}" in
                    10.5|10.6)           DBMS_VERSION_LTS="10.11" ;;
                    11.0|11.1|11.2|11.3) DBMS_VERSION_LTS="11.4" ;;
                    11.5|11.6|11.7)      DBMS_VERSION_LTS="11.8" ;;
                    12.0|12.1|12.2)      DBMS_VERSION_LTS="12.3" ;;
                    *)                   DBMS_VERSION_LTS="" ;;
                esac
                if [[ -n "${DBMS_VERSION_LTS}" ]]; then
                    echo "WARNING: MariaDB ${DBMS_VERSION} is out of support (EOL, or a rolling release)." >&2
                    echo "         Running ${DBMS_VERSION_LTS} instead — the supported series it belongs to." >&2
                    echo "         Set DBMS_VERSION_EXACT=1 to run ${DBMS_VERSION} anyway." >&2
                    DBMS_VERSION="${DBMS_VERSION_LTS}"
                fi
                if ! [[ ${DBMS_VERSION} =~ ^(10.11|11.4|11.8|12.3)$ ]]; then
                    echo "Invalid combination -d ${DBMS} -i ${DBMS_VERSION}" >&2
                    echo "Supported: 10.11, 11.4, 11.8, 12.3. Set DBMS_VERSION_EXACT=1 to run an unsupported version." >&2
                    exit 1
                fi
            fi
            ;;
        mysql)
            [[ -z "${DATABASE_DRIVER}" ]] && DATABASE_DRIVER="${MYSQL_DRIVER}"
            if [[ "${DATABASE_DRIVER}" != "${MYSQL_DRIVER}" ]] && [[ "${DATABASE_DRIVER}" != "pdo_mysql" ]]; then
                echo "Invalid combination -d ${DBMS} -a ${DATABASE_DRIVER}" >&2
                exit 1
            fi
            [[ -z "${DBMS_VERSION}" ]] && DBMS_VERSION="8.4"
            if ! [[ ${DBMS_VERSION} =~ ^(8.0|8.4|9.0)$ ]]; then
                echo "Invalid combination -d ${DBMS} -i ${DBMS_VERSION}" >&2
                exit 1
            fi
            ;;
        postgres)
            if [[ -n "${DATABASE_DRIVER}" ]]; then
                echo "Invalid combination -d ${DBMS} -a ${DATABASE_DRIVER}" >&2
                exit 1
            fi
            [[ -z "${DBMS_VERSION}" ]] && DBMS_VERSION="16"
            if ! [[ ${DBMS_VERSION} =~ ^(12|13|14|15|16|17)$ ]]; then
                echo "Invalid combination -d ${DBMS} -i ${DBMS_VERSION}" >&2
                exit 1
            fi
            ;;
        sqlite)
            if [[ -n "${DATABASE_DRIVER}" ]]; then
                echo "Invalid combination -d ${DBMS} -a ${DATABASE_DRIVER}" >&2
                exit 1
            fi
            ;;
        *)
            echo "Invalid option -d ${DBMS}" >&2
            exit 1
            ;;
    esac
    return 0
}

load_help() {
    read -r -d '' HELP <<'EOF'
@PROJECT_LABEL@ - TYPO3 Extension Test Runner
Execute tests in Docker containers using TYPO3 core-testing images.

Usage: @SCRIPT@ [options] [file]

Options:
    -s <...>
        Specifies which test suite to run
            - cgl: PHP CS Fixer check/fix
            - clean: Clean temporary files
            - composer: Run composer commands
            - composerUpdate: Clean install dependencies (removes vendor/)
            - e2e: Playwright E2E tests (requires running TYPO3)
            - functional: PHP functional tests
            - functionalParallel: Parallel functional tests (faster)
            - functionalCoverage: Functional tests with coverage
            - integration: Integration tests
            - lint: PHP linting
            - phpstan: PHPStan static analysis
            - rector: Rector code upgrades
            - fractor: Fractor upgrades for TypoScript, Fluid, YAML and TCA
            - unit: PHP unit tests (default)
            - unitCoverage: Unit tests with coverage
            - fuzz | fuzzy: Property-based (fuzzy) tests
            - mutation: Mutation testing
            - architecture: Architecture tests (PHPat via PHPStan)
            - unitCoveragePath: Unit tests with path + branch coverage
            - cleanCache: Clean temporary files (alias of clean)
            - composerValidate: composer validate
            - composerNormalize: composer normalize (-n for a dry run)
            - phpstanBaseline: Regenerate the PHPStan baseline

        A suite this list does not name may still exist: an extension defines
        suite_<name>() in Build/Scripts/runTests.conf and -s <name> calls it.

    -d <sqlite|mariadb|mysql|postgres>
        Database for functional tests (default: sqlite)

    -i version
        Database version (mariadb: 11.8, mysql: 8.4, postgres: 16)

    -p <8.2|8.3|8.4|8.5>
        PHP version (default: 8.5)

    -t <13|13.4|14|^13.4|...>
        TYPO3 core version to require before running the suite.
        Runs `composer require typo3/cms-core:CONSTRAINT` + update in a
        short-lived container. A bare major becomes a caret range
        (`-t 14` is `^14`). Skip to use whatever composer.lock resolves to.
        Matches the matrix cell in .github/workflows/ci.yml so local
        runs are reproducible against CI combinations.

    -x
        Enable Xdebug for debugging

    -n
        Dry-run mode (for cgl, rector, fractor)

    -h
        Show this help

Examples:
    # Run unit tests
    ./Build/Scripts/runTests.sh -s unit

    # Run functional tests with MariaDB
    ./Build/Scripts/runTests.sh -s functional -d mariadb

    # Run PHPStan analysis
    ./Build/Scripts/runTests.sh -s phpstan

    # Run E2E tests against a TYPO3 you are already serving
    TYPO3_BASE_URL=https://your-typo3.local ./Build/Scripts/runTests.sh -s e2e

E2E Tests:
    -s e2e drives a browser against a running TYPO3. This script does not
    start one and does not care what does. Give it a URL, per run through
    TYPO3_BASE_URL or once through E2E_BASE_URL in Build/Scripts/runTests.conf.

    If the target is only reachable from another container network, define
    e2e_container_args() in that same conf and print the arguments to add.
EOF
    # Placeholder, not expansion: the heredoc is quoted so that nothing in
    # the help text can be executed or expanded by writing it.
    HELP="${HELP//@PROJECT_LABEL@/${PROJECT_LABEL}}"
    HELP="${HELP//@SCRIPT@/${0}}"
    return 0
}

# Literal constants reused across the script
readonly DOCKER_BIN="docker"
readonly MYSQL_DRIVER="mysqli"

# Check container runtime
if ! type "${DOCKER_BIN}" >/dev/null 2>&1 && ! type "podman" >/dev/null 2>&1; then
    echo "This script requires docker or podman." >&2
    exit 1
fi

# ── Per-extension configuration ────────────────────────────────────────────
# Every value below is a default that holds for a TYPO3 extension laid out the
# way this package's CI expects. An extension that differs sets the variable in
# `Build/Scripts/runTests.conf`, which is sourced here if it exists; the
# environment wins over both, so a one-off run can override without editing a
# file. Nothing else in this script is meant to be per-extension — if you need
# a change that this block cannot express, change the shared script.
# The project root is resolved from the WORKING DIRECTORY, never from this
# file's location: consumed from the composer package, this script lives in
# .Build/vendor/… and ${BIN_DIR}/, neither of which sits above the extension.
# RUNTESTS_PROJECT_ROOT overrides it; the bootstrap stub sets neither, it just
# runs from the root.
resolve_project_root() {
    if [[ -n "${RUNTESTS_PROJECT_ROOT:-}" ]]; then
        printf '%s' "${RUNTESTS_PROJECT_ROOT}"
        return 0
    fi
    local dir="${PWD}"
    while [[ "${dir}" != "/" ]]; do
        if [[ -f "${dir}/composer.json" ]]; then
            printf '%s' "${dir}"
            return 0
        fi
        dir="$(dirname "${dir}")"
    done
    return 1
}

PROJECT_ROOT="$(resolve_project_root)" || {
    echo "runTests.sh: no composer.json above ${PWD} — run this from inside the extension." >&2
    exit 1
}
# The extension already states its name; asking a conf file to repeat it is
# how the two drift apart. `composer.json` is the source: the package name for
# the slug, the TYPO3 extension key for the label. The directory name is only
# the last resort, because in a worktree layout it is the branch, not the
# extension.
composer_value() {
    # $1 jq path, $2 the key for the fallback read
    local file="${PROJECT_ROOT}/composer.json"
    [[ -f "${file}" ]] || return 0
    if type jq >/dev/null 2>&1; then
        jq -r "${1} // empty" "${file}" 2>/dev/null
        return 0
    fi
    # jq is not guaranteed on a machine that only needs a container runtime.
    # Both keys are plain strings, and in a composer-normalised file the first
    # "name" is the package's own.
    sed -n "s/.*\"${2}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${file}" | head -n1
}

PROJECT_SLUG="${PROJECT_SLUG:-$(composer_value '.name' 'name')}"
PROJECT_SLUG="${PROJECT_SLUG##*/}"
PROJECT_SLUG="${PROJECT_SLUG:-$(basename "${PROJECT_ROOT}")}"
PROJECT_LABEL="${PROJECT_LABEL:-$(composer_value '.extra["typo3/cms"]["extension-key"]' 'extension-key')}"
PROJECT_LABEL="${PROJECT_LABEL:-${PROJECT_SLUG//-/_}}"
# The conf is read BEFORE anything is detected, not after. Sourced afterwards,
# an extension that pointed PHPUNIT_FUNCTIONAL_CONFIG at another file still got
# its testsuite names and its sharded-run directories derived from the file the
# detection had found — a config the run then did not use. Overriding a path
# has to override what is read out of it.
RUNTESTS_CONF="${PROJECT_ROOT}/Build/Scripts/runTests.conf"
if [[ -f "${RUNTESTS_CONF}" ]]; then
    # shellcheck disable=SC1090  # path is computed; the file is the extension's own
    source "${RUNTESTS_CONF}"
fi

# Where composer puts binaries. Hardcoding .Build/bin was wrong for every
# extension that does not set config.bin-dir — netresearch/contexts installs
# into vendor/bin, and every phpunit invocation here would have missed it.
BIN_DIR="${BIN_DIR:-$(composer_value '.config["bin-dir"]' 'bin-dir')}"
BIN_DIR="${BIN_DIR:-$(composer_value '.config["vendor-dir"]' 'vendor-dir')}"
[[ "${BIN_DIR}" == */bin ]] || BIN_DIR="${BIN_DIR:+${BIN_DIR}/bin}"
BIN_DIR="${BIN_DIR:-vendor/bin}"
VENDOR_DIR="${VENDOR_DIR:-$(composer_value '.config["vendor-dir"]' 'vendor-dir')}"
VENDOR_DIR="${VENDOR_DIR:-vendor}"
# Where TYPO3 is installed. Hardcoding .Build/Web was wrong for 21 of the 28
# extensions here: ten use .Build/public, two .Build/web, one .build/public and
# eight leave it at the composer-installers default. The functional suites
# mount a tmpfs over this path for the sqlite databases — "to avoid permission
# issues", as the forks that got it right put it — and a tmpfs on a directory
# nobody writes to is a mount that does nothing.
WEB_DIR="${WEB_DIR:-$(composer_value '.extra["typo3/cms"]["web-dir"]' 'web-dir')}"
WEB_DIR="${WEB_DIR:-.Build/Web}"

# Config locations differ per extension and are all in a small set of known
# places, so they are looked for rather than asked for. First hit wins; a conf
# entry still overrides. `first_existing` prints nothing when none exists,
# which leaves the variable empty and the suite's own error to explain it.
first_existing() {
    local candidate
    for candidate in "$@"; do
        if [[ -e "${PROJECT_ROOT}/${candidate}" ]]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 0
}

# Notices go to stderr, never stdout: these functions are read through command
# substitution and anything on stdout becomes the value.
notice() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        printf '::notice::runTests.sh: %s\n' "${1}" >&2
    else
        printf 'runTests.sh: %s\n' "${1}" >&2
    fi
}

# Same as first_existing, and it says what it did when that is worth knowing.
# Two cases, and they are different problems:
#
#   - The file found is not the standard location. Silence there means an
#     extension can stay non-standard forever without anyone noticing, which is
#     how the fleet ended up with three layouts.
#   - Several candidates exist and only the first is read. That one is a trap
#     during a migration: create the config at the standard location, leave the
#     old one, and every suite keeps running from the old file while the
#     repository looks migrated — in both directions invisible.
detect_config() {
    # $1 label, $2 the standard location(s), rest: candidates in order.
    # Several standards separated by | where a tool defines more than one name
    # itself: php-cs-fixer reads .php-cs-fixer.php and .php-cs-fixer.dist.php
    # alike, so calling either non-standard would be wrong.
    local label="${1}" standard="${2}" found others candidate
    shift 2
    found="$(first_existing "$@")"
    [[ -n "${found}" ]] || return 0
    printf '%s' "${found}"

    others=""
    for candidate in "$@"; do
        [[ "${candidate}" == "${found}" ]] && continue
        [[ -e "${PROJECT_ROOT}/${candidate}" ]] && others+="${candidate} "
    done

    if [[ -n "${others}" ]]; then
        notice "${label}: using ${found}; also present and ignored: ${others% }"
    fi
    if [[ "|${standard}|" != *"|${found}|"* ]]; then
        notice "${label}: ${found} is not the standard location (${standard//|/ or })"
    fi
}

PHPUNIT_CONFIG="${PHPUNIT_CONFIG:-$(detect_config 'unit config' Build/phpunit.xml Build/phpunit/UnitTests.xml Build/phpunit.xml Build/UnitTests.xml phpunit.xml phpunit.xml.dist)}"
# Build/phpunit.functional.xml is the layout the passkeys extensions use. It
# matters more than the count suggests: t3x-nr-passkeys-be also has a
# Build/phpunit.xml, so without this candidate detection falls back to it —
# and that file carries only the unit and fuzz suites, so the functional run
# asks for a testsuite the file it was handed does not contain.
PHPUNIT_FUNCTIONAL_CONFIG="${PHPUNIT_FUNCTIONAL_CONFIG:-$(detect_config 'functional config' Build/FunctionalTests.xml Build/phpunit/FunctionalTests.xml Build/FunctionalTests.xml Build/phpunit.functional.xml phpunit.functional.xml)}"
# One config carrying several testsuites is a layout, not a mistake: fall back
# to the unit config and let the testsuite name do the selecting.
PHPUNIT_FUNCTIONAL_CONFIG="${PHPUNIT_FUNCTIONAL_CONFIG:-${PHPUNIT_CONFIG}}"

# An integration config of its own, detected the way functional is. Without
# this, -s integration on an extension that keeps its integration tests in a
# separate config re-ran the UNIT config and reported success — 614 green unit
# tests standing in for five integration classes that were never opened (#212).
# The fallback to the unit config stays, but the suite refuses below when that
# fallback would select nothing.
PHPUNIT_INTEGRATION_CONFIG="${PHPUNIT_INTEGRATION_CONFIG:-$(detect_config 'integration config' Build/phpunit/IntegrationTests.xml Build/phpunit/IntegrationTests.xml Build/IntegrationTests.xml Build/phpunit.integration.xml phpunit.integration.xml)}"
PHPUNIT_INTEGRATION_CONFIG="${PHPUNIT_INTEGRATION_CONFIG:-${PHPUNIT_CONFIG}}"
PHPSTAN_CONFIG="${PHPSTAN_CONFIG:-$(detect_config 'phpstan config' Build/phpstan/phpstan.neon Build/phpstan/phpstan.neon Build/phpstan.neon phpstan.neon phpstan.neon.dist)}"
RECTOR_CONFIG="${RECTOR_CONFIG:-$(detect_config 'rector config' Build/rector/rector.php Build/rector/rector.php Build/rector.php rector.php)}"
# Fractor is rector's sibling for the file types rector does not read — TypoScript,
# Fluid, YAML, TCA. Six extensions on this runner carry a fractor script and had to
# leave the shell for it. Same candidate order and the same standard shape as
# rector above; the two are configured side by side and should not need two
# different layouts to be remembered.
FRACTOR_CONFIG="${FRACTOR_CONFIG:-$(detect_config 'fractor config' Build/fractor/fractor.php Build/fractor/fractor.php Build/fractor.php fractor.php)}"
INFECTION_CONFIG="${INFECTION_CONFIG:-$(detect_config 'infection config' infection.json.dist infection.json.dist infection.json infection.json5)}"
# php-cs-fixer discovers only .php-cs-fixer.php / .php-cs-fixer.dist.php next to
# the working directory. Thirteen extensions keep theirs under Build/ and two
# keep two, so leaving the flag off does not mean "use the extension's rules" — it
# means "use php-cs-fixer's defaults", and `-s cgl` then rewrites files against
# rules the extension never agreed to while CI stays green (netresearch/contexts:
# 12 files rewritten, 0 reported by composer ci:test:php:cgl on the same tree).
CGL_CONFIG="${CGL_CONFIG:-$(detect_config 'cgl config' '.php-cs-fixer.php|.php-cs-fixer.dist.php' .php-cs-fixer.php .php-cs-fixer.dist.php Build/.php-cs-fixer.dist.php Build/.php-cs-fixer.php Build/php-cs-fixer.php Build/php-cs-fixer/.php-cs-fixer.php)}"

# A PHPUnit config carrying <coverage><report> makes coverage mandatory: PHPUnit
# refuses to run at all without a driver. The suites otherwise pass
# -dxdebug.mode=off, which is the right default — coverage is slow — so a run
# against such a config used to end at "No tests executed!" with the driver
# switched off underneath it. Read the demand from the config instead of asking
# the caller to know about it.
xdebug_arg_for() {
    local config="${1:-}"
    if [[ -n "${config}" ]] && [[ -f "${PROJECT_ROOT}/${config}" ]] \
       && grep -qE '<report[ >]' "${PROJECT_ROOT}/${config}"; then
        printf -- '-dxdebug.mode=coverage'
    else
        printf -- '-dxdebug.mode=off'
    fi
}
PHPUNIT_XDEBUG_ARG="$(xdebug_arg_for "${PHPUNIT_CONFIG}")"
PHPUNIT_FUNCTIONAL_XDEBUG_ARG="$(xdebug_arg_for "${PHPUNIT_FUNCTIONAL_CONFIG}")"

# Which testsuite to select inside those configs. The fleet writes the same
# suite as "unit", "Unit", "Unit Tests" and "Unit tests", so the name is read
# out of the config and matched loosely rather than configured. A config with
# a single suite needs no selection at all — the file already is one.
phpunit_testsuite() {
    # $1 config path, $2 an extended regex the wanted suite name starts with
    local file="${PROJECT_ROOT}/${1}" want="${2}" names count
    [[ -n "${1}" && -f "${file}" ]] || return 0
    # One attribute out of an element phpunit writes on a single line. xmllint
    # is not guaranteed on a machine that only needs a container runtime.
    names="$(grep -oE '<testsuite[[:space:]]+name="[^"]*"' "${file}" | sed 's/.*name="//; s/"$//')"
    [[ -n "${names}" ]] || return 0
    count="$(printf '%s\n' "${names}" | grep -c .)"
    if [[ "${count}" -le 1 ]]; then
        # Selecting the only suite is the same run as selecting nothing, and
        # naming it wrongly is a failure — so say nothing.
        return 0
    fi
    printf '%s\n' "${names}" | grep -iE "^${want}" | head -n1
}

UNIT_TESTSUITE="${UNIT_TESTSUITE-$(phpunit_testsuite "${PHPUNIT_CONFIG}" 'unit')}"
FUZZY_TESTSUITE="${FUZZY_TESTSUITE-$(phpunit_testsuite "${PHPUNIT_CONFIG}" 'fuzz')}"
if [[ "${PHPUNIT_INTEGRATION_CONFIG}" == "${PHPUNIT_CONFIG}" ]]; then
    INTEGRATION_TESTSUITE="${INTEGRATION_TESTSUITE-$(phpunit_testsuite "${PHPUNIT_CONFIG}" 'integration')}"
else
    # A separate integration config IS the selection; narrowing it to one suite
    # would drop the others — the same reasoning as functional below.
    INTEGRATION_TESTSUITE="${INTEGRATION_TESTSUITE:-}"
fi
if [[ "${PHPUNIT_FUNCTIONAL_CONFIG}" == "${PHPUNIT_CONFIG}" ]]; then
    FUNCTIONAL_TESTSUITE="${FUNCTIONAL_TESTSUITE-$(phpunit_testsuite "${PHPUNIT_FUNCTIONAL_CONFIG}" 'functional')}"
else
    # A separate functional config is the selection; narrowing it to one suite
    # would drop the others, which is how a suite ends up running nowhere.
    FUNCTIONAL_TESTSUITE="${FUNCTIONAL_TESTSUITE:-}"
fi

# Paths the sharded functional run walks. They must cover every directory the
# functional config's testsuites list — a directory in the config but not here
# runs in no job and still reads as covered (#272, #658) — so they are read
# out of that config. Only <directory> inside <testsuite> counts: the same
# element under <source>/<coverage> names the code being measured, not tests,
# and paths are relative to the config file, not to the extension root.
phpunit_testsuite_directories() {
    local file="${PROJECT_ROOT}/${1}" base
    [[ -n "${1}" && -f "${file}" ]] || return 0
    base="$(dirname "${1}")"
    # The closing tag is matched WITHOUT the optional s: `</testsuites?>` also
    # matches `</testsuite>`, so a testsuite written on one line switched the
    # block off before its own <directory> was read — zero directories, silent
    # fallback, and a suite that runs in no job.
    awk '/<testsuites[ >]/{inside=1} /<\/testsuites>/{inside=0} inside' "${file}" \
        | grep -oE '<directory[^>]*>[^<]+</directory>' \
        | sed 's|.*<directory[^>]*>||; s|</directory>||' \
        | while IFS= read -r dir; do
            [[ -n "${dir}" ]] || continue
            # Resolve against the config's own directory, then normalise.
            local resolved="${base}/${dir}"
            resolved="$(cd "${PROJECT_ROOT}" 2>/dev/null && realpath -m --relative-to=. "${resolved}" 2>/dev/null || printf '%s' "${resolved}")"
            printf '%s\n' "${resolved%/}"
        done | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

if [[ -z "${FUNCTIONAL_PARALLEL_PATHS+x}" ]]; then
    FUNCTIONAL_PARALLEL_PATHS="$(phpunit_testsuite_directories "${PHPUNIT_FUNCTIONAL_CONFIG}")"
    FUNCTIONAL_PARALLEL_PATHS="${FUNCTIONAL_PARALLEL_PATHS:-Tests/Functional}"
fi

# Where `-s e2e` points its browser when TYPO3_BASE_URL is not in the
# environment, and the image that drives it. Both were lost when this block
# was rewritten in v1.7.0, which left `-s e2e` running `docker run … ""` and
# failing with "invalid reference format" for every consumer.
E2E_BASE_URL="${E2E_BASE_URL:-}"
# Set to 1 in runTests.conf to have -s e2e build a TYPO3 instance even when
# the extension defines none of the e2e_provision_* hooks — a bare instance
# with no site and no content, which is useful for a suite that creates its
# own fixtures through the backend.
E2E_PROVISION="${E2E_PROVISION:-}"

# Directory holding the e2e suite's package.json, lockfile and Playwright
# config, relative to the repository root. Empty means the root, which is where
# most consumers keep it; t3x-rte_ckeditor_image keeps it in Tests/E2E. Both the
# lockfile probe below and the container working directory follow this, so a
# suite in a subdirectory resolves its own Playwright version instead of
# falling back to this script's pin.
E2E_TEST_DIR="${E2E_TEST_DIR:-}"

# Both are filled in by e2e-provision.sh when it builds an instance, and are
# declared here because this script expands them: the backend password it
# generated, and the TYPO3 major it settled on. Empty when nothing was
# provisioned, in which case the environment supplies them or the suite does
# without.
E2E_ADMIN_PASSWORD="${E2E_ADMIN_PASSWORD:-}"
E2E_TYPO3_VERSION="${E2E_TYPO3_VERSION:-}"

# The image tag follows the CONSUMER's Playwright, not a version pinned here.
# The container runs `npm ci`, so it installs whatever package-lock.json
# resolves — and the image ships browsers for exactly one release. A fixed
# default drifts the moment a consumer's lockfile moves and then fails with
#
#   Error: browserType.launch: Executable doesn't exist at
#   /ms-playwright/chromium_headless_shell-####/chrome-headless-shell-linux64/…
#
# which reads as a broken image rather than as a version skew. package.json is
# not enough: a caret range says ^1.61.1 while the lockfile resolves 1.62.1,
# and it is the resolved one npm installs.
#
# jq rather than node: the host running this has no node (that is what the
# container is for), and jq is already a dependency of this script.
# PROJECT_ROOT rather than ROOT_DIR: ROOT_DIR is assigned further down, so
# reading it here silently resolves /package-lock.json and finds nothing.
E2E_LOCKFILE="${PROJECT_ROOT}${E2E_TEST_DIR:+/${E2E_TEST_DIR}}/package-lock.json"
if [[ -z "${IMAGE_PLAYWRIGHT:-}" ]] && [[ -f "${E2E_LOCKFILE}" ]] && type jq >/dev/null 2>&1; then
    PLAYWRIGHT_VERSION="$(jq -r '.packages["node_modules/@playwright/test"].version // empty' "${E2E_LOCKFILE}" 2>/dev/null)"
    [[ -n "${PLAYWRIGHT_VERSION}" ]] && IMAGE_PLAYWRIGHT="mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble"
fi

# Fallback for a consumer with no lockfile, and the explicit-override path.
IMAGE_PLAYWRIGHT="${IMAGE_PLAYWRIGHT:-mcr.microsoft.com/playwright:v1.60.0-noble}"

SUPPORTED_PHP_VERSIONS="${SUPPORTED_PHP_VERSIONS:-8.2 8.3 8.4 8.5}"

php_constraint_bounds() {
    # Prints "floor ceiling" for require.php, either possibly empty. Handles
    # the shapes composer.json actually carries in this fleet — ^X.Y, ~X.Y,
    # >=X.Y, <X.Y, <=X.Y — and prints nothing it cannot read rather than
    # guessing, in which case the ceiling stays at the newest supported.
    local constraint floor="" ceiling=""
    constraint="$(composer_value '.require.php' 'php')"
    [[ -n "${constraint}" ]] || return 0

    floor="$(printf '%s' "${constraint}" | sed -n 's/.*[\^~>=]\{1,2\}[[:space:]]*\([0-9]\+\.[0-9]\+\).*/\1/p' | head -n1)"

    if printf '%s' "${constraint}" | grep -qE '<=?[[:space:]]*[0-9]+\.[0-9]+'; then
        ceiling="$(printf '%s' "${constraint}" | sed -n 's/.*<=\?[[:space:]]*\([0-9]\+\.[0-9]\+\).*/\1/p' | head -n1)"
        # `<8.5` excludes 8.5 itself; `<=8.5` does not. Only the exclusive form
        # needs the step down, and the caller compares as a plain string.
        if printf '%s' "${constraint}" | grep -qE '<[[:space:]]*[0-9]+\.[0-9]+' && \
           ! printf '%s' "${constraint}" | grep -qE '<=[[:space:]]*[0-9]+\.[0-9]+'; then
            local minor="${ceiling#*.}"
            [[ "${minor}" -gt 0 ]] && ceiling="${ceiling%%.*}.$((minor - 1))"
        fi
    fi
    printf '%s %s' "${floor}" "${ceiling}"
}

if [[ -z "${DEFAULT_PHP_VERSION:-}" ]]; then
    read -r PHP_FLOOR PHP_CEILING <<< "$(php_constraint_bounds)"
    DEFAULT_PHP_VERSION=""
    for candidate in ${SUPPORTED_PHP_VERSIONS}; do
        [[ -n "${PHP_FLOOR}" ]] && [[ "$(printf '%s\n%s\n' "${PHP_FLOOR}" "${candidate}" | sort -V | head -n1)" != "${PHP_FLOOR}" ]] && continue
        [[ -n "${PHP_CEILING}" ]] && [[ "$(printf '%s\n%s\n' "${candidate}" "${PHP_CEILING}" | sort -V | head -n1)" != "${candidate}" ]] && continue
        DEFAULT_PHP_VERSION="${candidate}"
    done
    if [[ -z "${DEFAULT_PHP_VERSION}" ]]; then
        DEFAULT_PHP_VERSION="${SUPPORTED_PHP_VERSIONS##* }"
        echo "runTests.sh: composer.json requires php ${PHP_FLOOR:-?}..${PHP_CEILING:-?}, which no supported version satisfies — using ${DEFAULT_PHP_VERSION}." >&2
    fi
fi
COMPOSER_ROOT_VERSION="${COMPOSER_ROOT_VERSION:-0.1.x-dev}"

# Already inside the container this script starts? Then starting another one is
# wrong, and the reason it used to happen is worth naming: every composer script
# in the fleet guards itself with `[ -f /.dockerenv ]`, which answers "some
# container" — a dev shell, an unrelated service, the runner's own image all
# look identical to it. The runner marks its own container instead (-e
# RUNTESTS_IN_CONTAINER=1 on every invocation), so this test is exact.
#
# The suites are not run in-process here: all 30 container invocations would
# need a second path, with the database environment and the bootstrap that the
# image currently provides. That is its own change (#189). Until then this at
# least fails with the reason instead of nesting containers.
if [[ -n "${RUNTESTS_IN_CONTAINER:-}" ]]; then
    echo "runTests.sh: already inside the runner's container — call the tool directly" >&2
    echo "runTests.sh: e.g. \`\${BIN_DIR}/phpunit -c \${PHPUNIT_CONFIG}\` instead of \`runTests.sh -s unit\`" >&2
    exit 1
fi

# Option defaults
TEST_SUITE="unit"
DATABASE_DRIVER=""
DBMS="sqlite"
DBMS_VERSION=""
PHP_VERSION="${DEFAULT_PHP_VERSION}"
# TYPO3 core version constraint. Empty = use what's already installed
# (whatever composer.json / composer.lock resolves to). Set via -t to
# require a specific major, e.g. `-t 13.4` runs the suite against
# typo3/cms-core:^13.4. Matches the CI matrix in .github/workflows/ci.yml.
TYPO3_VERSION=""
PHP_XDEBUG_ON=0
PHP_XDEBUG_PORT=9003
CGLCHECK_DRY_RUN=0
CI_PARAMS="${CI_PARAMS:-}"
CONTAINER_BIN=""
CONTAINER_HOST="host.docker.internal"
SUITE_EXIT_CODE=0

# Parse options
OPTIND=1
while getopts "a:b:d:i:s:p:t:xy:nhu" OPT; do
    case ${OPT} in
        a) DATABASE_DRIVER=${OPTARG} ;;
        s) TEST_SUITE=${OPTARG} ;;
        b) CONTAINER_BIN=${OPTARG} ;;
        d) DBMS=${OPTARG} ;;
        i) DBMS_VERSION=${OPTARG} ;;
        p) PHP_VERSION=${OPTARG} ;;
        t) TYPO3_VERSION=${OPTARG} ;;
        x) PHP_XDEBUG_ON=1 ;;
        y) PHP_XDEBUG_PORT=${OPTARG} ;;
        n) CGLCHECK_DRY_RUN=1 ;;
        h) load_help; echo "${HELP}"; exit 0 ;;
        u) TEST_SUITE=update ;;
        \?) exit 1 ;;
        *) exit 1 ;;
    esac
done

handle_dbms_options

# Extension version for Composer

HOST_UID=$(id -u)
USERSET=""
if [[ $(uname) != "Darwin" ]]; then
    USERSET="--user $HOST_UID"
fi

# Everything below runs from the extension root, resolved above.
cd "${PROJECT_ROOT}" || exit 1
ROOT_DIR="${PROJECT_ROOT}"

# Create cache directories
mkdir -p .Build/.cache
mkdir -p ${WEB_DIR}/typo3temp/var/tests

IMAGE_PREFIX="docker.io/"
TYPO3_IMAGE_PREFIX="ghcr.io/typo3/"
CONTAINER_INTERACTIVE="-it --init"

IS_CORE_CI=0
if [[ "${CI}" == "true" ]] || ! [[ -t 0 ]]; then
    IS_CORE_CI=1
    IMAGE_PREFIX=""
    CONTAINER_INTERACTIVE=""
fi

# Determine container binary
if [[ -z "${CONTAINER_BIN}" ]]; then
    if type "podman" >/dev/null 2>&1; then
        CONTAINER_BIN="podman"
    elif type "${DOCKER_BIN}" >/dev/null 2>&1; then
        CONTAINER_BIN="${DOCKER_BIN}"
    fi
fi

# Container images
# Overridable, because an extension can need a PHP image the core-testing ones
# do not provide. t3x-nr-image-optimize is the case that surfaced it: its
# Processor requires imagick, the upstream images ship GD only, and CI supplies
# it through setup-php's php-extensions — so the repository carried a 463-line
# runner fork whose entire job was building `core-testing-phpXY + imagick` for
# local runs. A conf line or an environment variable is enough for that.
# A conf can define php_image() when the image name depends on the PHP version
# — which it does whenever an extension derives its own image per version. The
# conf is read before -p is parsed, so a plain variable cannot interpolate
# ${PHP_VERSION}; a function called here can. Same shape as e2e_target().
if declare -f php_image >/dev/null 2>&1; then
    IMAGE_PHP="$(php_image "${PHP_VERSION}")"
fi
IMAGE_PHP="${IMAGE_PHP:-${TYPO3_IMAGE_PREFIX}core-testing-$(echo "php${PHP_VERSION}" | sed -e 's/\.//'):latest}"
IMAGE_ALPINE="${IMAGE_PREFIX}alpine:3.20"
IMAGE_APACHE="${IMAGE_APACHE:-${TYPO3_IMAGE_PREFIX}core-testing-apache24:1.7}"
IMAGE_MARIADB="docker.io/mariadb:${DBMS_VERSION}"
IMAGE_MYSQL="docker.io/mysql:${DBMS_VERSION}"
IMAGE_POSTGRES="docker.io/postgres:${DBMS_VERSION}-alpine"

shift $((OPTIND - 1))

SUFFIX="$(date +%s)-${RANDOM}"
NETWORK="${PROJECT_SLUG}-${SUFFIX}"
if ! ${CONTAINER_BIN} network create ${NETWORK} >/dev/null 2>&1; then
    echo "Failed to create container network '${NETWORK}'. Ensure ${CONTAINER_BIN} daemon is running." >&2
    exit 1
fi

if [[ ${CONTAINER_BIN} = "${DOCKER_BIN}" ]]; then
    CONTAINER_COMMON_PARAMS="${CONTAINER_INTERACTIVE} --rm --network ${NETWORK} --add-host "${CONTAINER_HOST}:host-gateway" ${USERSET} -e RUNTESTS_IN_CONTAINER=1 -v ${ROOT_DIR}:${ROOT_DIR} -w ${ROOT_DIR}"
else
    CONTAINER_HOST="host.containers.internal"
    CONTAINER_COMMON_PARAMS="${CONTAINER_INTERACTIVE} ${CI_PARAMS} --rm --network ${NETWORK} -e RUNTESTS_IN_CONTAINER=1 -v ${ROOT_DIR}:${ROOT_DIR} -w ${ROOT_DIR}"
fi

if [[ ${PHP_XDEBUG_ON} -eq 0 ]]; then
    XDEBUG_MODE="-e XDEBUG_MODE=off"
    XDEBUG_CONFIG=" "
else
    XDEBUG_MODE="-e XDEBUG_MODE=debug -e XDEBUG_TRIGGER=foo"
    XDEBUG_CONFIG="client_port=${PHP_XDEBUG_PORT} client_host=${CONTAINER_HOST}"
fi

# Xdebug 3 lets the XDEBUG_MODE environment variable win over the ini setting,
# so -dxdebug.mode=coverage alone is not enough — the container is handed
# XDEBUG_MODE=off right next to it and that is what takes effect. Both have to
# agree, which is why this sits after the block above rather than with the
# detection.
if [[ "${PHPUNIT_XDEBUG_ARG}" == *coverage ]] || [[ "${PHPUNIT_FUNCTIONAL_XDEBUG_ARG}" == *coverage ]]; then
    XDEBUG_MODE="-e XDEBUG_MODE=coverage"
    notice "coverage: the PHPUnit config asks for a report, so the driver stays on (slower)"
fi

# If -t <major> was given, require that TYPO3 core version before running
# the suite. Runs inside the same PHP image / user mapping / COMPOSER cache
# as the rest of the script so the resolved composer.lock and .Build/vendor
# match the PHP version of the suite container.
if [[ -n "${TYPO3_VERSION}" ]]; then
    # Normalise bare majors/"major.minor" to caret ranges; keep explicit
    # constraint strings (e.g. "^14.0", ">=13.4 <15") verbatim.
    if [[ "${TYPO3_VERSION}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        TYPO3_CONSTRAINT="^${TYPO3_VERSION}"
    else
        TYPO3_CONSTRAINT="${TYPO3_VERSION}"
    fi
    echo "⟳ Requiring typo3/cms-core:${TYPO3_CONSTRAINT} (matches -t ${TYPO3_VERSION})"
    ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name typo3-require-${SUFFIX} \
        -e COMPOSER_CACHE_DIR=.Build/.cache/composer \
        -e COMPOSER_ROOT_VERSION=${COMPOSER_ROOT_VERSION} \
        -e CAPTAINHOOK_DISABLE=true \
        ${IMAGE_PHP} composer require \
            --no-interaction --no-progress --no-scripts --no-update \
            "typo3/cms-core:${TYPO3_CONSTRAINT}" \
        || { echo "typo3/cms-core require failed for ${TYPO3_CONSTRAINT}"; exit 1; }
    ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name typo3-update-${SUFFIX} \
        -e COMPOSER_CACHE_DIR=.Build/.cache/composer \
        -e COMPOSER_ROOT_VERSION=${COMPOSER_ROOT_VERSION} \
        -e CAPTAINHOOK_DISABLE=true \
        ${IMAGE_PHP} composer update \
            --no-interaction --no-progress --no-scripts --with-all-dependencies \
            typo3/cms-core \
        || { echo "typo3/cms-core update failed for ${TYPO3_CONSTRAINT}"; exit 1; }
fi

# PHP performance options
PHP_OPCACHE_OPTS="-d opcache.enable_cli=1 -d opcache.jit=1255 -d opcache.jit_buffer_size=128M"
# Functional/e2e-backend suites run WITHOUT the JIT: the tracing JIT in the
# container PHP builds (reproduced on 8.3 and 8.5) segfaults silently during
# suite bootstrap for certain — perfectly valid — source shapes (adding a
# plain property+getter+setter to an entity flipped it). Identical runs with
# opcache.jit=off pass; the functionalCoverage path below already ran without
# the JIT. Functional tests are IO-bound, so the JIT buys nothing here anyway.
PHP_FUNCTIONAL_OPTS="-d opcache.enable_cli=1"

# Suite execution
case ${TEST_SUITE} in
    architecture)
        # Architecture tests are run via PHPStan with phpat extension
        COMMAND="php ${PHP_OPCACHE_OPTS} -dxdebug.mode=off ${BIN_DIR}/phpstan analyse -c ${PHPSTAN_CONFIG}"
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name architecture-${SUFFIX} -e COMPOSER_ROOT_VERSION=${COMPOSER_ROOT_VERSION} ${IMAGE_PHP} /bin/sh -c "${COMMAND}"
        SUITE_EXIT_CODE=$?
        ;;
    cgl)
        if [[ "${CGLCHECK_DRY_RUN}" -eq 1 ]]; then
            COMMAND="php ${PHP_OPCACHE_OPTS} -dxdebug.mode=off ${BIN_DIR}/php-cs-fixer fix -v ${CGL_CONFIG:+--config=${CGL_CONFIG}} --dry-run --diff"
        else
            COMMAND="php ${PHP_OPCACHE_OPTS} -dxdebug.mode=off ${BIN_DIR}/php-cs-fixer fix -v ${CGL_CONFIG:+--config=${CGL_CONFIG}}"
        fi
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name cgl-${SUFFIX} -e COMPOSER_CACHE_DIR=.Build/.cache/composer -e COMPOSER_ROOT_VERSION=${COMPOSER_ROOT_VERSION} ${IMAGE_PHP} /bin/sh -c "${COMMAND}"
        SUITE_EXIT_CODE=$?
        ;;
    clean)
        clean_cache_files
        SUITE_EXIT_CODE=0
        ;;
    cleanCache)
        clean_cache_files
        SUITE_EXIT_CODE=0
        ;;
    composer)
        COMMAND=(composer "$@")
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name composer-${SUFFIX} -e COMPOSER_CACHE_DIR=.Build/.cache/composer -e COMPOSER_ROOT_VERSION=${COMPOSER_ROOT_VERSION} -e CAPTAINHOOK_DISABLE=true ${IMAGE_PHP} "${COMMAND[@]}"
        SUITE_EXIT_CODE=$?
        ;;
    composerNormalize)
        if [[ "${CGLCHECK_DRY_RUN}" -eq 1 ]]; then
            COMMAND=(composer normalize --dry-run)
        else
            COMMAND=(composer normalize)
        fi
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name composer-normalize-${SUFFIX} -e COMPOSER_CACHE_DIR=.Build/.cache/composer -e COMPOSER_ROOT_VERSION=${COMPOSER_ROOT_VERSION} -e CAPTAINHOOK_DISABLE=true ${IMAGE_PHP} "${COMMAND[@]}"
        SUITE_EXIT_CODE=$?
        ;;
    composerValidate)
        COMMAND=(composer validate "$@")
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name composer-validate-${SUFFIX} -e COMPOSER_CACHE_DIR=.Build/.cache/composer -e COMPOSER_ROOT_VERSION=${COMPOSER_ROOT_VERSION} -e CAPTAINHOOK_DISABLE=true ${IMAGE_PHP} "${COMMAND[@]}"
        SUITE_EXIT_CODE=$?
        ;;
    composerUpdate)
        rm -rf "${BIN_DIR}" "${VENDOR_DIR}" ./composer.lock
        COMMAND=(composer install --no-ansi --no-interaction --no-progress)
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name composer-${SUFFIX} -e COMPOSER_CACHE_DIR=.Build/.cache/composer -e COMPOSER_ROOT_VERSION=${COMPOSER_ROOT_VERSION} -e CAPTAINHOOK_DISABLE=true ${IMAGE_PHP} "${COMMAND[@]}"
        SUITE_EXIT_CODE=$?
        ;;
    e2e)
        # Three ways to name the target, in this order, because all three exist
        # in the fleet today:
        #   1. TYPO3_BASE_URL from the environment — the shared e2e workflow in
        #      default mode serves TYPO3 itself and passes it in.
        #   2. e2e_target() from the conf — for a target that does not exist
        #      until the run creates it. t3x-rte_ckeditor_image starts its own
        #      Apache container per run and reaches it under a name carrying
        #      that run's suffix, which no static setting can express.
        #   3. E2E_BASE_URL from the conf — a target that is always at the same
        #      address, typically a local stack.
        # No fourth way: with none of them set the run stops rather than
        # guessing a host and testing against whatever answers.
        # 0. e2e_provision from e2e-provision.sh — for an extension that owns
        #    no environment at all and wants the runner to build one: MariaDB,
        #    a composer-installed TYPO3, PHP-FPM and Apache. Opted into by
        #    defining any of the e2e_provision_* hooks in the conf, so an
        #    extension that only needs the address of a running instance is
        #    unaffected.
        E2E_PROVISIONED=0
        if [[ -z "${TYPO3_BASE_URL:-}" ]] \
           && ! declare -F e2e_target >/dev/null 2>&1 \
           && [[ -z "${E2E_BASE_URL}" ]] \
           && { declare -F e2e_provision_packages >/dev/null 2>&1 \
                || declare -F e2e_provision_typoscript >/dev/null 2>&1 \
                || declare -F e2e_provision_seed >/dev/null 2>&1 \
                || declare -F e2e_provision_site_dependencies >/dev/null 2>&1 \
                || [[ "${E2E_PROVISION:-}" == "1" ]]; }; then
            PROVISION_LIB="$(cd "$(dirname "$(realpath "$0")")" && pwd)/e2e-provision.sh"
            if [[ ! -f "${PROVISION_LIB}" ]]; then
                echo "runTests.sh: ${PROVISION_LIB} is missing — the package is" >&2
                echo "             installed incompletely." >&2
                clean_up
                exit 1
            fi
            # shellcheck source=/dev/null
            source "${PROVISION_LIB}"
            if ! e2e_provision; then
                clean_up
                exit 1
            fi
            E2E_PROVISIONED=1
        fi

        if [[ -z "${TYPO3_BASE_URL:-}" ]] && declare -F e2e_target >/dev/null 2>&1; then
            TYPO3_BASE_URL="$(e2e_target)"
        fi
        TYPO3_BASE_URL="${TYPO3_BASE_URL:-${E2E_BASE_URL}}"
        if [[ -z "${TYPO3_BASE_URL}" ]]; then
            echo "runTests.sh: -s e2e needs the URL of a running TYPO3 to test against." >&2
            echo "             Per run:      TYPO3_BASE_URL=https://your-typo3.local $0 -s e2e" >&2
            echo "             Per extension: E2E_BASE_URL in Build/Scripts/runTests.conf," >&2
            echo "                            or e2e_target() there when the run creates its own." >&2
            clean_up
            exit 1
        fi
        echo "E2E target: ${TYPO3_BASE_URL}"

        mkdir -p .Build/.cache/npm
        mkdir -p node_modules

        # Check for permission issues (root-owned files from previous container runs)
        if [[ -d "node_modules" ]] && [[ -n "$(find node_modules -maxdepth 1 -user root 2>/dev/null | head -1)" ]]; then
            echo "Error: node_modules contains root-owned files." >&2
            echo "Please remove and retry: sudo rm -rf node_modules" >&2
            exit 1
        fi

        # The target may sit on a network this container cannot reach — a local
        # stack behind its own router, a name that resolves nowhere else. That
        # is a property of the developer's machine, not of the fleet, so the
        # runner knows no environment by name: an extension whose target needs
        # extra container arguments defines e2e_container_args() in
        # Build/Scripts/runTests.conf and prints them. Nothing to configure for
        # a target the container can already reach, which is every CI run.
        # Either as a value from the environment — glue that lives outside the
        # repository, a ddev command for instance, computes it and exports it —
        # or from a conf function when the extension itself has to compute it.
        E2E_EXTRA_ARGS="${E2E_CONTAINER_ARGS:-}"
        if [[ -z "${E2E_EXTRA_ARGS}" ]] && declare -F e2e_container_args >/dev/null 2>&1; then
            E2E_EXTRA_ARGS="$(e2e_container_args)"
        fi
        [[ -n "${E2E_EXTRA_ARGS}" ]] && echo "e2e container arguments: ${E2E_EXTRA_ARGS}"

        # `npm ci` needs a lockfile and refuses without one. A consumer that
        # gitignores it (several here do) would get EUSAGE and no tests, so fall
        # back to `npm install --no-save` and say so — the browsers in the image
        # are pinned to one release, and without a lockfile the resolved
        # Playwright can drift away from them.
        E2E_WORK_DIR="${ROOT_DIR}${E2E_TEST_DIR:+/${E2E_TEST_DIR}}"
        if [[ -f "${E2E_WORK_DIR}/package-lock.json" ]]; then
            COMMAND="npm ci && npx playwright test $*"
        else
            notice "e2e: no package-lock.json in ${E2E_TEST_DIR:-the repository root}, using npm install; the Playwright version is not pinned against ${IMAGE_PLAYWRIGHT}"
            COMMAND="npm install --no-save && npx playwright test $*"
        fi
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} ${E2E_EXTRA_ARGS} --name e2e-${SUFFIX} \
            -w "${E2E_WORK_DIR}" \
            -e TYPO3_BASE_URL="${TYPO3_BASE_URL}" \
            `# BASE_URL as well: TYPO3_BASE_URL is this script's contract, but a` \
            `# Playwright config conventionally reads BASE_URL, and requiring every` \
            `# consumer to rename it in playwright.config.ts buys nothing.` \
            -e BASE_URL="${TYPO3_BASE_URL}" \
            `# A backend test has to log in, and when this run provisioned the` \
            `# instance the password is only known here. TYPO3_BACKEND_PASSWORD from` \
            `# the environment wins, so a suite pointed at an existing instance keeps` \
            `# using its own credential.` \
            -e TYPO3_BACKEND_PASSWORD="${TYPO3_BACKEND_PASSWORD:-${E2E_ADMIN_PASSWORD:-}}" \
            `# The variant and the effective TYPO3 major: a suite skips or adapts` \
            `# assertions by them, and both are decided here, not in the test.` \
            -e E2E_VARIANT="${E2E_VARIANT:-}" \
            -e TYPO3_VERSION="${E2E_TYPO3_VERSION:-${TYPO3_VERSION}}" \
            -e CI="${CI:-}" \
            -e npm_config_cache="${ROOT_DIR}/.Build/.cache/npm" \
            ${IMAGE_PLAYWRIGHT} /bin/bash -c "${COMMAND}"
        SUITE_EXIT_CODE=$?

        # An extension that built its own environment in e2e_target() gets to
        # take it down here, with the result in hand. Containers do not need
        # this — clean_up removes everything attached to ${NETWORK}, whoever
        # started it. Run-scoped FILES do: a TYPO3 instance directory is worth
        # keeping when the suite failed and worth deleting when it passed, and
        # only this point knows which happened.
        if declare -F e2e_teardown >/dev/null 2>&1; then
            e2e_teardown
        fi
        if [[ "${E2E_PROVISIONED}" == "1" ]]; then
            e2e_provision_teardown "${SUITE_EXIT_CODE}"
        fi
        ;;
    functional)
        COMMAND=(php ${PHP_FUNCTIONAL_OPTS} ${PHPUNIT_FUNCTIONAL_XDEBUG_ARG} ${BIN_DIR}/phpunit -c ${PHPUNIT_FUNCTIONAL_CONFIG} ${FUNCTIONAL_TESTSUITE:+--testsuite "${FUNCTIONAL_TESTSUITE}"} --exclude-group not-${DBMS} "$@")

        case ${DBMS} in
            mariadb)
                echo "Using driver: ${DATABASE_DRIVER}"
                ${CONTAINER_BIN} run --rm ${CI_PARAMS} --name mariadb-func-${SUFFIX} --network ${NETWORK} -d -e MYSQL_ROOT_PASSWORD=funcp --tmpfs /var/lib/mysql/:rw,noexec,nosuid ${IMAGE_MARIADB} >/dev/null
                wait_for mariadb-func-${SUFFIX} 3306
                CONTAINERPARAMS="-e typo3DatabaseDriver=${DATABASE_DRIVER} -e typo3DatabaseName=func_test -e typo3DatabaseUsername=root -e typo3DatabaseHost=mariadb-func-${SUFFIX} -e typo3DatabasePassword=funcp"
                ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name functional-${SUFFIX} ${XDEBUG_MODE} -e XDEBUG_CONFIG="${XDEBUG_CONFIG}" ${CONTAINERPARAMS} ${IMAGE_PHP} "${COMMAND[@]}"
                SUITE_EXIT_CODE=$?
                ;;
            mysql)
                echo "Using driver: ${DATABASE_DRIVER}"
                ${CONTAINER_BIN} run --rm ${CI_PARAMS} --name mysql-func-${SUFFIX} --network ${NETWORK} -d -e MYSQL_ROOT_PASSWORD=funcp --tmpfs /var/lib/mysql/:rw,noexec,nosuid ${IMAGE_MYSQL} >/dev/null
                wait_for mysql-func-${SUFFIX} 3306
                CONTAINERPARAMS="-e typo3DatabaseDriver=${DATABASE_DRIVER} -e typo3DatabaseName=func_test -e typo3DatabaseUsername=root -e typo3DatabaseHost=mysql-func-${SUFFIX} -e typo3DatabasePassword=funcp"
                ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name functional-${SUFFIX} ${XDEBUG_MODE} -e XDEBUG_CONFIG="${XDEBUG_CONFIG}" ${CONTAINERPARAMS} ${IMAGE_PHP} "${COMMAND[@]}"
                SUITE_EXIT_CODE=$?
                ;;
            postgres)
                ${CONTAINER_BIN} run --rm ${CI_PARAMS} --name postgres-func-${SUFFIX} --network ${NETWORK} -d -e POSTGRES_PASSWORD=funcp -e POSTGRES_USER=funcu --tmpfs /var/lib/postgresql/data:rw,noexec,nosuid ${IMAGE_POSTGRES} >/dev/null
                wait_for postgres-func-${SUFFIX} 5432
                CONTAINERPARAMS="-e typo3DatabaseDriver=pdo_pgsql -e typo3DatabaseName=bamboo -e typo3DatabaseUsername=funcu -e typo3DatabaseHost=postgres-func-${SUFFIX} -e typo3DatabasePassword=funcp"
                ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name functional-${SUFFIX} ${XDEBUG_MODE} -e XDEBUG_CONFIG="${XDEBUG_CONFIG}" ${CONTAINERPARAMS} ${IMAGE_PHP} "${COMMAND[@]}"
                SUITE_EXIT_CODE=$?
                ;;
            sqlite)
                mkdir -p "${ROOT_DIR}/${WEB_DIR}/typo3temp/var/tests/functional-sqlite-dbs/"
                CONTAINERPARAMS="-e typo3DatabaseDriver=pdo_sqlite --tmpfs ${ROOT_DIR}/${WEB_DIR}/typo3temp/var/tests/functional-sqlite-dbs/:rw,noexec,nosuid,mode=1777"
                ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name functional-${SUFFIX} ${XDEBUG_MODE} -e XDEBUG_CONFIG="${XDEBUG_CONFIG}" ${CONTAINERPARAMS} ${IMAGE_PHP} "${COMMAND[@]}"
                SUITE_EXIT_CODE=$?
                ;;
            *)
                echo "Unsupported DBMS for functional tests: ${DBMS}" >&2
                exit 1
                ;;
        esac
        ;;
    functionalParallel)
        mkdir -p "${ROOT_DIR}/${WEB_DIR}/typo3temp/var/tests/functional-sqlite-dbs/"

        if [[ "${CI}" == "true" ]]; then
            PARALLEL_JOBS=4
        else
            # Use half of available CPUs for local runs
            PARALLEL_JOBS=$(( ($(nproc) + 1) / 2 ))
        fi

        # All three globs are required: Build/FunctionalTests.xml runs the
        # `functional`, `e2e-backend` AND `e2e-tca` suites. Globbing fewer silently
        # dropped all 8 Tests/E2E/Backend classes here — the same rot as #272,
        # where the suite was skipped wholesale and nobody noticed.
        if [[ "${DBMS}" != "sqlite" ]]; then
            echo "runTests.sh: -s functionalParallel always runs on sqlite; ignoring -d ${DBMS}." >&2
        fi
        # --exclude-group not-sqlite, hardcoded rather than ${DBMS}: this path
        # pins typo3DatabaseDriver=pdo_sqlite below and mounts a sqlite tmpfs,
        # so it runs on sqlite whatever -d asked for. Deriving the group from
        # ${DBMS} would exclude not-mariadb on `-d mariadb` while the tests run
        # against sqlite — excluding the wrong tests AND running the ones the
        # marker exists to keep off sqlite. -d is answered with a warning below
        # instead of silently meaning something else.
        #
        # --do-not-fail-on-empty-test-suite belongs with it and only here. This
        # path hands phpunit ONE file at a time, so a class whose every test is
        # excluded leaves phpunit with nothing to run, and "No tests executed!"
        # exits 1 by default (measured: PHPUnit 13.3.1, and the option exists
        # back to 10.5). Without it, excluding a test would turn its shard red —
        # the opposite of skipping it. The serial run keeps the default: a whole
        # suite that matches nothing is a defect worth failing on.
        COMMAND="find ${FUNCTIONAL_PARALLEL_PATHS} -name '*Test.php' | xargs -P${PARALLEL_JOBS} -I{} php ${PHP_FUNCTIONAL_OPTS} -dxdebug.mode=off ${BIN_DIR}/phpunit -c ${PHPUNIT_FUNCTIONAL_CONFIG} --exclude-group not-sqlite --do-not-fail-on-empty-test-suite {}"
        CONTAINERPARAMS="-e typo3DatabaseDriver=pdo_sqlite --tmpfs ${ROOT_DIR}/${WEB_DIR}/typo3temp/var/tests/functional-sqlite-dbs/:rw,noexec,nosuid,mode=1777"
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name functional-parallel-${SUFFIX} ${XDEBUG_MODE} -e XDEBUG_CONFIG="${XDEBUG_CONFIG}" ${CONTAINERPARAMS} ${IMAGE_PHP} /bin/sh -c "${COMMAND}"
        SUITE_EXIT_CODE=$?
        ;;
    functionalCoverage)
        mkdir -p .Build/coverage
        COMMAND=(php -d opcache.enable_cli=1 ${BIN_DIR}/phpunit -c ${PHPUNIT_FUNCTIONAL_CONFIG} --coverage-clover=.Build/coverage/functional.xml --coverage-html=.Build/coverage/html-functional --coverage-text "$@")
        mkdir -p "${ROOT_DIR}/${WEB_DIR}/typo3temp/var/tests/functional-sqlite-dbs/"
        CONTAINERPARAMS="-e typo3DatabaseDriver=pdo_sqlite --tmpfs ${ROOT_DIR}/${WEB_DIR}/typo3temp/var/tests/functional-sqlite-dbs/:rw,noexec,nosuid,mode=1777"
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name functional-coverage-${SUFFIX} -e XDEBUG_MODE=coverage ${CONTAINERPARAMS} ${IMAGE_PHP} "${COMMAND[@]}"
        SUITE_EXIT_CODE=$?
        ;;
    fuzz|fuzzy)
        COMMAND=(php ${PHP_OPCACHE_OPTS} -dxdebug.mode=off ${BIN_DIR}/phpunit -c ${PHPUNIT_CONFIG} ${FUZZY_TESTSUITE:+--testsuite "${FUZZY_TESTSUITE}"} "$@")
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name fuzzy-${SUFFIX} ${XDEBUG_MODE} -e XDEBUG_CONFIG="${XDEBUG_CONFIG}" ${IMAGE_PHP} "${COMMAND[@]}"
        SUITE_EXIT_CODE=$?
        ;;
    integration)
        # Refuse to re-run the unit config dressed up as integration. Without a
        # config of its own and without an integration testsuite in the detected
        # one, this suite used to run the unit tests and report success — a
        # green result for a suite that never ran is worse than an error (#212).
        if [[ "${PHPUNIT_INTEGRATION_CONFIG}" == "${PHPUNIT_CONFIG}" ]] && [[ -z "${INTEGRATION_TESTSUITE}" ]] \
           && ! grep -oE '<testsuite[[:space:]]+name="[^"]*"' "${PROJECT_ROOT}/${PHPUNIT_CONFIG}" 2>/dev/null | grep -qiE 'name="integration'; then
            echo "runTests.sh: -s integration found neither an integration config nor an" >&2
            echo "             'integration' testsuite in ${PHPUNIT_CONFIG:-<none>}." >&2
            echo "             Looked for a config at: Build/phpunit/IntegrationTests.xml," >&2
            echo "             Build/IntegrationTests.xml, Build/phpunit.integration.xml," >&2
            echo "             phpunit.integration.xml — or set PHPUNIT_INTEGRATION_CONFIG" >&2
            echo "             in Build/Scripts/runTests.conf." >&2
            clean_up
            exit 1
        fi
        COMMAND=(php ${PHP_OPCACHE_OPTS} -dxdebug.mode=off ${BIN_DIR}/phpunit -c ${PHPUNIT_INTEGRATION_CONFIG} ${INTEGRATION_TESTSUITE:+--testsuite "${INTEGRATION_TESTSUITE}"} "$@")
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name integration-${SUFFIX} ${XDEBUG_MODE} -e XDEBUG_CONFIG="${XDEBUG_CONFIG}" ${IMAGE_PHP} "${COMMAND[@]}"
        SUITE_EXIT_CODE=$?
        ;;
    lint)
        # Lint what the repository ships, by pruning what it generates — rather
        # than naming three directories and hoping they are the right three.
        #
        # The previous command was `find Classes Configuration Tests …`, which
        # had two holes. A repository missing one of those directories got a
        # find error on stderr, an exit status the pipe discarded, and a green
        # suite that had opened two paths out of three:
        #
        #   $ find Classes Nonexistent -name \*.php -print0 | xargs -0 php -l; echo $?
        #   bfs: error: Nonexistent: No such file or directory.
        #   0
        #
        # And root-level PHP was never seen at all — ext_localconf.php,
        # ext_tables.php, ext_emconf.php, anything under Build/ — though a
        # syntax error in ext_localconf.php takes down the whole installation.
        #
        # Pruning instead of naming closes both: there is no path left to be
        # missing, and a new source directory is covered the day it appears.
        # The count is printed because a lint that says nothing is
        # indistinguishable from a lint that looked at nothing.
        LINT_PRUNE="-path ./.git -o -path ./vendor -o -path ./.Build -o -path ./.build -o -path ./node_modules -o -path ./var -o -path ./public -o -path ./Documentation-GENERATED-temp"
        COMMAND="set -e
            COUNT=\$(find . \\( ${LINT_PRUNE} \\) -prune -o -type f -name '*.php' -print | wc -l)
            echo \"lint: \${COUNT} PHP files\"
            if [ \"\${COUNT}\" -eq 0 ]; then
                echo 'lint: no PHP files found — every candidate path was pruned' >&2
                exit 1
            fi
            find . \\( ${LINT_PRUNE} \\) -prune -o -type f -name '*.php' -print0 \
                | xargs -0 -r -n1 -P\$(nproc) php -dxdebug.mode=off -l >/dev/null"
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name lint-${SUFFIX} ${IMAGE_PHP} /bin/sh -c "${COMMAND}"
        SUITE_EXIT_CODE=$?
        ;;
    mutation)
        COMMAND=(php -d opcache.enable_cli=1 ${BIN_DIR}/infection --configuration=${INFECTION_CONFIG} --threads=4 "$@")
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name mutation-${SUFFIX} -e XDEBUG_MODE=coverage ${IMAGE_PHP} "${COMMAND[@]}"
        SUITE_EXIT_CODE=$?
        ;;
    phpstan)
        COMMAND="php ${PHP_OPCACHE_OPTS} -dxdebug.mode=off ${BIN_DIR}/phpstan analyse -c ${PHPSTAN_CONFIG}"
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name phpstan-${SUFFIX} -e COMPOSER_ROOT_VERSION=${COMPOSER_ROOT_VERSION} ${IMAGE_PHP} /bin/sh -c "${COMMAND}"
        SUITE_EXIT_CODE=$?
        ;;
    phpstanBaseline)
        # Regenerating the baseline is the one command that must never be
        # chained into a verification run: it rewrites what `-s phpstan`
        # checks against.
        COMMAND="php ${PHP_OPCACHE_OPTS} -dxdebug.mode=off ${BIN_DIR}/phpstan analyse -c ${PHPSTAN_CONFIG} --generate-baseline -v"
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name phpstan-baseline-${SUFFIX} -e COMPOSER_ROOT_VERSION=${COMPOSER_ROOT_VERSION} ${IMAGE_PHP} /bin/sh -c "${COMMAND}"
        SUITE_EXIT_CODE=$?
        ;;
    rector)
        if [[ "${CGLCHECK_DRY_RUN}" -eq 1 ]]; then
            COMMAND="php ${PHP_OPCACHE_OPTS} -dxdebug.mode=off ${BIN_DIR}/rector process --config ${RECTOR_CONFIG} --dry-run"
        else
            COMMAND="php ${PHP_OPCACHE_OPTS} -dxdebug.mode=off ${BIN_DIR}/rector process --config ${RECTOR_CONFIG}"
        fi
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name rector-${SUFFIX} -e COMPOSER_ROOT_VERSION=${COMPOSER_ROOT_VERSION} ${IMAGE_PHP} /bin/sh -c "${COMMAND}"
        SUITE_EXIT_CODE=$?
        ;;
    fractor)
        # Writes by default, checks with -n, exactly like cgl and rector. An
        # absent config is refused rather than passed on as an empty --config,
        # which fractor reports as a parse error about the current directory and
        # sends the reader looking in the wrong place. The other suites here
        # share that gap; fixing them is a separate change.
        if [[ -z "${FRACTOR_CONFIG}" ]]; then
            echo "runTests.sh: -s fractor found no fractor config." >&2
            echo "             Looked for: Build/fractor/fractor.php, Build/fractor.php, fractor.php" >&2
            echo "             Set FRACTOR_CONFIG in Build/Scripts/runTests.conf to point elsewhere." >&2
            clean_up
            exit 1
        fi
        if [[ "${CGLCHECK_DRY_RUN}" -eq 1 ]]; then
            # fractor's dry run reports pending changes and then exits 0, unlike
            # rector, which exits 2. Measured on t3x-nr-llm with a9f/fractor
            # v1.0.0: "[OK] 46 files would have been changed (dry-run)" and exit
            # status 0, where `rector process --dry-run` on the same tree gives 2.
            #
            # --output-format=json is not a way out: on the same invocation, same
            # cache state, it reports "changed_files": 0 while the console line
            # says 46. Its reporter does not count dry-run changes, so the JSON is
            # not merely a different shape of the same answer — it is the wrong
            # answer. That leaves the console line as the only signal that tells
            # the truth, which is why this parses text rather than a status code.
            #
            # Without this the check would pass on every repository with pending
            # fractor changes, which is worse than having no check.
            COMMAND="OUT=\$(php ${PHP_OPCACHE_OPTS} -dxdebug.mode=off ${BIN_DIR}/fractor process --config ${FRACTOR_CONFIG} --dry-run --no-progress-bar 2>&1); RC=\$?
                printf '%s\\n' \"\${OUT}\"
                [ \"\${RC}\" -eq 0 ] || exit \"\${RC}\"
                CHANGED=\$(printf '%s' \"\${OUT}\" | sed -n 's/.*\\[OK\\] \\([0-9][0-9]*\\) files\\{0,1\\} would have been changed.*/\\1/p' | tail -n1)
                if [ -n \"\${CHANGED}\" ] && [ \"\${CHANGED}\" -gt 0 ]; then
                    echo \"runTests.sh: fractor would change \${CHANGED} file(s) — run without -n to apply\" >&2
                    exit 1
                fi"
        else
            COMMAND="php ${PHP_OPCACHE_OPTS} -dxdebug.mode=off ${BIN_DIR}/fractor process --config ${FRACTOR_CONFIG}"
        fi
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name fractor-${SUFFIX} -e COMPOSER_ROOT_VERSION=${COMPOSER_ROOT_VERSION} ${IMAGE_PHP} /bin/sh -c "${COMMAND}"
        SUITE_EXIT_CODE=$?
        ;;
    unit)
        COMMAND=(php ${PHP_OPCACHE_OPTS} ${PHPUNIT_XDEBUG_ARG} ${BIN_DIR}/phpunit -c ${PHPUNIT_CONFIG} ${UNIT_TESTSUITE:+--testsuite "${UNIT_TESTSUITE}"} "$@")
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name unit-${SUFFIX} ${XDEBUG_MODE} -e XDEBUG_CONFIG="${XDEBUG_CONFIG}" ${IMAGE_PHP} "${COMMAND[@]}"
        SUITE_EXIT_CODE=$?
        ;;
    unitCoverage)
        mkdir -p .Build/coverage
        COMMAND=(php -d opcache.enable_cli=1 ${BIN_DIR}/phpunit -c ${PHPUNIT_CONFIG} ${UNIT_TESTSUITE:+--testsuite "${UNIT_TESTSUITE}"} --coverage-clover=.Build/coverage/unit.xml --coverage-html=.Build/coverage/html-unit --coverage-text "$@")
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name unit-coverage-${SUFFIX} -e XDEBUG_MODE=coverage ${IMAGE_PHP} "${COMMAND[@]}"
        SUITE_EXIT_CODE=$?
        ;;
    unitCoveragePath)
        mkdir -p .Build/coverage
        # Path and branch coverage need xdebug; pcov cannot produce them, and
        # is disabled explicitly because an image carrying both would win.
        COMMAND=(php -d opcache.enable_cli=1 -d pcov.enabled=0 ${BIN_DIR}/phpunit -c ${PHPUNIT_CONFIG} ${UNIT_TESTSUITE:+--testsuite "${UNIT_TESTSUITE}"} --path-coverage --coverage-clover=.Build/coverage/unit-path.xml --coverage-html=.Build/coverage/html-unit-path --coverage-text "$@")
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name unit-coverage-path-${SUFFIX} -e XDEBUG_MODE=coverage ${IMAGE_PHP} "${COMMAND[@]}"
        SUITE_EXIT_CODE=$?
        ;;
    update)
        echo "> Updating ${TYPO3_IMAGE_PREFIX}core-testing-* images..."
        ${CONTAINER_BIN} images "${TYPO3_IMAGE_PREFIX}core-testing-*" --format "{{.Repository}}:{{.Tag}}" | xargs -I {} ${CONTAINER_BIN} pull {}
        SUITE_EXIT_CODE=$?
        ;;
    *)
        # A suite this runner does not know may still be the extension's own:
        # rendering its documentation, publishing coverage, installing the
        # lowest supported dependency set. Those are nobody else's business, so
        # the conf defines suite_<name>() and gets called here with the
        # remaining arguments — instead of the extension forking 600 lines to
        # add twenty.
        if declare -F "suite_${TEST_SUITE}" >/dev/null 2>&1; then
            "suite_${TEST_SUITE}" "$@"
            SUITE_EXIT_CODE=$?
        else
            load_help
            echo "Invalid -s option: ${TEST_SUITE}" >&2
            echo "${HELP}" >&2
            exit 1
        fi
        ;;
esac

clean_up

# Print summary
echo "" >&2
echo "###########################################################################" >&2
echo "Result of ${TEST_SUITE}" >&2
echo "Container runtime: ${CONTAINER_BIN}" >&2
if [[ ${IS_CORE_CI} -eq 1 ]]; then
    echo "Environment: CI" >&2
else
    echo "Environment: local" >&2
fi
echo "PHP: ${PHP_VERSION}" >&2
if [[ ${TEST_SUITE} =~ ^functional ]]; then
    echo "DBMS: ${DBMS}" >&2
fi
if [[ ${SUITE_EXIT_CODE} -eq 0 ]]; then
    echo "SUCCESS" >&2
else
    echo "FAILURE" >&2
fi
echo "###########################################################################" >&2
echo "" >&2

exit $SUITE_EXIT_CODE
