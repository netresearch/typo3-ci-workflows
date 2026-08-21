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
    local test_command="
        COUNT=0;
        while ! nc -z ${host} ${port}; do
            if [ \"\${COUNT}\" -gt 10 ]; then
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
        Dry-run mode (for cgl, rector)

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
    # $1 label, $2 the standard location, rest: candidates in order
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
    if [[ "${found}" != "${standard}" ]]; then
        notice "${label}: ${found} is not the standard location (${standard})"
    fi
}

PHPUNIT_CONFIG="${PHPUNIT_CONFIG:-$(detect_config 'unit config' Build/phpunit.xml Build/phpunit/UnitTests.xml Build/phpunit.xml Build/UnitTests.xml phpunit.xml phpunit.xml.dist)}"
PHPUNIT_FUNCTIONAL_CONFIG="${PHPUNIT_FUNCTIONAL_CONFIG:-$(detect_config 'functional config' Build/FunctionalTests.xml Build/phpunit/FunctionalTests.xml Build/FunctionalTests.xml phpunit.functional.xml)}"
# One config carrying several testsuites is a layout, not a mistake: fall back
# to the unit config and let the testsuite name do the selecting.
PHPUNIT_FUNCTIONAL_CONFIG="${PHPUNIT_FUNCTIONAL_CONFIG:-${PHPUNIT_CONFIG}}"
PHPSTAN_CONFIG="${PHPSTAN_CONFIG:-$(detect_config 'phpstan config' Build/phpstan/phpstan.neon Build/phpstan/phpstan.neon Build/phpstan.neon phpstan.neon phpstan.neon.dist)}"
RECTOR_CONFIG="${RECTOR_CONFIG:-$(detect_config 'rector config' Build/rector/rector.php Build/rector/rector.php Build/rector.php rector.php)}"
INFECTION_CONFIG="${INFECTION_CONFIG:-$(detect_config 'infection config' infection.json.dist infection.json.dist infection.json infection.json5)}"
# php-cs-fixer discovers only .php-cs-fixer.php / .php-cs-fixer.dist.php next to
# the working directory. Three extensions keep theirs under Build/ and one keeps
# two, so leaving the flag off does not mean "use the extension's rules" — it
# means "use php-cs-fixer's defaults", and `-s cgl` then rewrites files against
# rules the extension never agreed to while CI stays green (netresearch/contexts:
# 12 files rewritten, 0 reported by composer ci:test:php:cgl on the same tree).
CGL_CONFIG="${CGL_CONFIG:-$(detect_config 'cgl config' .php-cs-fixer.dist.php .php-cs-fixer.php .php-cs-fixer.dist.php Build/php-cs-fixer.php Build/.php-cs-fixer.php Build/php-cs-fixer.dist.php)}"

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
INTEGRATION_TESTSUITE="${INTEGRATION_TESTSUITE-$(phpunit_testsuite "${PHPUNIT_CONFIG}" 'integration')}"
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

        COMMAND="npm ci && npx playwright test $*"
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} ${E2E_EXTRA_ARGS} --name e2e-${SUFFIX} \
            -e TYPO3_BASE_URL="${TYPO3_BASE_URL}" \
            -e CI="${CI:-}" \
            -e npm_config_cache="${ROOT_DIR}/.Build/.cache/npm" \
            ${IMAGE_PLAYWRIGHT} /bin/bash -c "${COMMAND}"
        SUITE_EXIT_CODE=$?
        ;;
    functional)
        COMMAND=(php ${PHP_FUNCTIONAL_OPTS} -dxdebug.mode=off ${BIN_DIR}/phpunit -c ${PHPUNIT_FUNCTIONAL_CONFIG} ${FUNCTIONAL_TESTSUITE:+--testsuite "${FUNCTIONAL_TESTSUITE}"} --exclude-group not-${DBMS} "$@")

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
        COMMAND=(php ${PHP_OPCACHE_OPTS} -dxdebug.mode=off ${BIN_DIR}/phpunit -c ${PHPUNIT_CONFIG} ${INTEGRATION_TESTSUITE:+--testsuite "${INTEGRATION_TESTSUITE}"} "$@")
        ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name integration-${SUFFIX} ${XDEBUG_MODE} -e XDEBUG_CONFIG="${XDEBUG_CONFIG}" ${IMAGE_PHP} "${COMMAND[@]}"
        SUITE_EXIT_CODE=$?
        ;;
    lint)
        COMMAND="find Classes Configuration Tests -name \\*.php -print0 | xargs -0 -n1 -P\$(nproc) php -dxdebug.mode=off -l >/dev/null"
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
    unit)
        COMMAND=(php ${PHP_OPCACHE_OPTS} -dxdebug.mode=off ${BIN_DIR}/phpunit -c ${PHPUNIT_CONFIG} ${UNIT_TESTSUITE:+--testsuite "${UNIT_TESTSUITE}"} "$@")
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
