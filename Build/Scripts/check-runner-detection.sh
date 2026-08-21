#!/usr/bin/env bash
#
# Checks what the shared runner derives, against fixture extensions built for
# the cases that broke it. Each case below shipped once.
#
#   1. runTests.conf was sourced AFTER detection, so pointing
#      PHPUNIT_FUNCTIONAL_CONFIG at another file still derived testsuite names
#      and shard directories from the file detection had found.
#   2. The testsuites block was delimited with `</testsuites?>`, which also
#      matches `</testsuite>` — a testsuite written on one line yielded zero
#      directories and fell back to Tests/Functional, putting whole suites in
#      no job while the run still read as covered.
#   3. The sharded run had no --exclude-group, so a test marked not-sqlite ran
#      on sqlite. Adding it alone is not the fix twice over: the sharded path
#      runs one file per phpunit call, and a fully excluded file exits 1 — and
#      the group cannot come from ${DBMS}, because this path pins pdo_sqlite
#      whatever -d said.
#
# Usage: check-runner-detection.sh [path/to/runTests.sh]

set -uo pipefail

RUNNER="${1:-assets/Build/Scripts/runTests.sh}"
[[ -f "${RUNNER}" ]] || { printf 'not found: %s\n' "${RUNNER}" >&2; exit 2; }
RUNNER="$(realpath "${RUNNER}")"

FIXTURES="$(mktemp -d)"
trap 'rm -rf "${FIXTURES}"' EXIT

FAILED=0

fail() { printf '  FAIL: %s\n' "${1}" >&2; FAILED=1; }
pass() { printf '  ok: %s\n' "${1}"; }

# Builds an extension whose functional config lives at ${2} and declares two
# testsuites, written multi-line (${3} = multi) or on one line (${3} = inline).
make_fixture() {
    local root="${FIXTURES}/${1}" config="${2}" shape="${3}" depth
    mkdir -p "${root}/$(dirname "${config}")" "${root}/Build/Scripts"
    printf '{"name":"netresearch/fixture-%s","require":{"php":"^8.2"},"extra":{"typo3/cms":{"extension-key":"fixture"}}}\n' \
        "${1}" > "${root}/composer.json"

    # ../ per path segment, so the config points back at the extension root.
    depth="$(printf '%s' "$(dirname "${config}")" | tr -cd '/' | wc -c)"
    local up="" i
    for ((i = 0; i <= depth; i++)); do up+="../"; done

    {
        printf '<phpunit>\n  <testsuites>\n'
        if [[ "${shape}" == inline ]]; then
            printf '    <testsuite name="functional"><directory>%sTests/Functional</directory></testsuite>\n' "${up}"
            printf '    <testsuite name="e2e-tca"><directory>%sTests/E2E/TCA</directory></testsuite>\n' "${up}"
        else
            printf '    <testsuite name="functional">\n      <directory>%sTests/Functional</directory>\n    </testsuite>\n' "${up}"
            printf '    <testsuite name="e2e-tca">\n      <directory>%sTests/E2E/TCA</directory>\n    </testsuite>\n' "${up}"
        fi
        printf '  </testsuites>\n</phpunit>\n'
    } > "${root}/${config}"
    printf '%s' "${root}"
}

# Sources the runner's detection block — everything above `# Option defaults`,
# which is the last line that cannot start a container — inside the fixture and
# echoes one variable.
derive() {
    local root="${1}" var="${2}" line head
    line="$(grep -n '^# Option defaults' "${RUNNER}" | head -n1 | cut -d: -f1)"
    head="${FIXTURES}/head.sh"
    head -n "$((line - 1))" "${RUNNER}" > "${head}"
    (
        cd "${root}" || exit 1
        # shellcheck disable=SC1090  # generated above from the runner under test
        source "${head}" >/dev/null 2>&1
        printf '%s' "${!var:-}"
    )
}

# Same as derive, but returns what the block said rather than what it resolved.
derive_stderr() {
    local root="${1}" line head
    line="$(grep -n '^# Option defaults' "${RUNNER}" | head -n1 | cut -d: -f1)"
    head="${FIXTURES}/head.sh"
    head -n "$((line - 1))" "${RUNNER}" > "${head}"
    (
        cd "${root}" || exit 1
        # shellcheck disable=SC1090  # generated above from the runner under test
        source "${head}" 2>&1 >/dev/null | grep 'runTests.sh:' || true
    )
}

printf 'Detection fixtures (%s)\n' "${RUNNER#"$(pwd)/"}"

# 1. The conf decides which file is read out of, not just which file is named.
root="$(make_fixture conf-order Build/custom/Functional.xml multi)"
printf 'PHPUNIT_FUNCTIONAL_CONFIG="Build/custom/Functional.xml"\n' > "${root}/Build/Scripts/runTests.conf"
got="$(derive "${root}" FUNCTIONAL_PARALLEL_PATHS)"
if [[ "${got}" == "Tests/E2E/TCA Tests/Functional" ]]; then
    pass "conf override drives the shard directories (${got})"
else
    fail "conf override ignored: shards=${got:-<empty>}, expected 'Tests/E2E/TCA Tests/Functional'"
fi

# 2. A testsuite on one line still yields its directories.
root="$(make_fixture inline-suite Build/FunctionalTests.xml inline)"
got="$(derive "${root}" FUNCTIONAL_PARALLEL_PATHS)"
if [[ "${got}" == "Tests/E2E/TCA Tests/Functional" ]]; then
    pass "single-line <testsuite> yields its directories (${got})"
else
    fail "single-line <testsuite> lost: shards=${got:-<empty>}, expected 'Tests/E2E/TCA Tests/Functional'"
fi

# 3. The notices: a shadowed config, a non-standard location, and silence at
#    the reference. They go to stderr, because these functions are read through
#    command substitution and stdout is the value.
root="$(make_fixture shadowed Build/phpunit/FunctionalTests.xml multi)"
cp "${root}/Build/phpunit/FunctionalTests.xml" "${root}/Build/FunctionalTests.xml"
notices="$(derive_stderr "${root}")"
if [[ "${notices}" == *"also present and ignored: Build/FunctionalTests.xml"* ]]; then
    pass "a second config is named as ignored"
else
    fail "a shadowed config produced no notice: ${notices:-<silence>}"
fi
if [[ "${notices}" == *"is not the standard location"* ]]; then
    pass "a non-standard location is named"
else
    fail "no notice for the non-standard location"
fi
value="$(derive "${root}" PHPUNIT_FUNCTIONAL_CONFIG)"
if [[ "${value}" == "Build/phpunit/FunctionalTests.xml" ]]; then
    pass "the notices stayed off stdout (value is ${value})"
else
    fail "stdout carries more than the value: ${value}"
fi

# The reference layout says nothing. A checker that only proves noise exists
# would pass on a runner that warns about everything.
root="$(make_fixture reference Build/FunctionalTests.xml multi)"
printf '<phpunit><testsuites><testsuite name="unit"><directory>../Tests/Unit</directory></testsuite></testsuites></phpunit>\n' \
    > "${root}/Build/phpunit.xml"
mkdir -p "${root}/Build/phpstan" "${root}/Build/rector"
printf 'parameters:\n' > "${root}/Build/phpstan/phpstan.neon"
printf '<?php\n' > "${root}/Build/rector/rector.php"
notices="$(derive_stderr "${root}")"
if [[ -z "${notices}" ]]; then
    pass "the reference layout produces no notice"
else
    fail "the reference layout is noisy: ${notices}"
fi

# 4. Both flags on the sharded command, and neither on the serial one.
# shellcheck disable=SC2016  # these are the runner's own literals, not expansions
shard_cmd="$(grep -n 'COMMAND="find \${FUNCTIONAL_PARALLEL_PATHS}' "${RUNNER}" | head -n1)"
# shellcheck disable=SC2016
serial_cmd="$(grep -n 'COMMAND=(php \${PHP_FUNCTIONAL_OPTS}' "${RUNNER}" | head -n1)"
SHARD_FLAGS=('--exclude-group not-sqlite' '--do-not-fail-on-empty-test-suite')
for flag in "${SHARD_FLAGS[@]}"; do
    if [[ "${shard_cmd}" == *"${flag}"* ]]; then
        pass "sharded run passes ${flag}"
    else
        fail "sharded run is missing ${flag}"
    fi
done
# The group is hardcoded on purpose: this path pins pdo_sqlite regardless of -d,
# so deriving it from ${DBMS} excludes the wrong tests on `-d mariadb`.
# shellcheck disable=SC2016  # searching for the runner's own literal
if [[ "${shard_cmd}" == *'not-${DBMS}'* ]]; then
    fail "sharded run derives the excluded group from \${DBMS} while pinning sqlite"
else
    pass "sharded run does not derive the excluded group from \${DBMS}"
fi
if [[ "${serial_cmd}" == *'--exclude-group'* ]]; then
    pass "serial run passes --exclude-group"
else
    fail "serial run is missing --exclude-group"
fi
if [[ "${serial_cmd}" == *'--do-not-fail-on-empty-test-suite'* ]]; then
    fail "serial run must NOT hide an empty suite — it runs the whole suite at once"
else
    pass "serial run keeps failing on an empty suite"
fi

exit "${FAILED}"
