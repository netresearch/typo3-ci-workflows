#!/usr/bin/env bash
#
# Runs bin/check-phpunit-config against the two templates in config/phpunit/
# and against fixture configurations, and asserts its exit code and the
# attribute it names.
#
# The templates must carry the baseline profile, and the strict profile must
# name every strict flag they lack, so a template and the check cannot drift
# apart. The fixtures cover a missing flag, a flag set to "false", a file
# that is not a PHPUnit configuration, a missing file and the usage errors.
#
# Usage: check-phpunit-config.sh bin/check-phpunit-config

set -uo pipefail

[[ $# -eq 1 ]] || { printf 'usage: %s bin/check-phpunit-config\n' "${0}" >&2; exit 2; }
CHECK="${1}"
ROOT="$(cd "$(dirname "${CHECK}")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FAILED=0
PASSED=0

fail() { printf '  FAIL: %s\n' "${1}" >&2; FAILED=1; return 0; }
pass() { printf '  ok: %s\n' "${1}"; PASSED=$((PASSED + 1)); return 0; }

# expect <name> <exit code> <text the output must contain, or ''> <args...>
expect() {
    local name="${1}" want="${2}" text="${3}"
    shift 3
    local out rc=0
    out="$(php "${CHECK}" "$@" 2>&1)" || rc=$?
    if [[ "${rc}" -ne "${want}" ]]; then
        fail "${name}: exit ${rc}, expected ${want}: ${out}"
    elif [[ -n "${text}" && "${out}" != *"${text}"* ]]; then
        fail "${name}: output lacks '${text}': ${out}"
    else
        pass "${name}"
    fi
}

UNIT="${ROOT}/config/phpunit/phpunit.xml"
FUNCTIONAL="${ROOT}/config/phpunit/FunctionalTests.xml"

expect 'the templates carry the baseline' 0 '2 PHPUnit configuration(s) carry the baseline profile' "${UNIT}" "${FUNCTIONAL}"
for flag in beStrictAboutOutputDuringTests requireCoverageMetadata beStrictAboutCoverageMetadata failOnDeprecation failOnNotice failOnPhpunitDeprecation failOnEmptyTestSuite; do
    expect "--strict names ${flag} in the template" 1 "${flag}=\"true\" is missing" --strict "${UNIT}"
done

sed 's/ failOnRisky="true"//' "${UNIT}" > "${TMP}/no-risky.xml"
expect 'a missing baseline flag fails' 1 'failOnRisky="true" is missing' "${TMP}/no-risky.xml"

sed 's/failOnWarning="true"/failOnWarning="false"/' "${UNIT}" > "${TMP}/warning-false.xml"
expect 'a baseline flag set to false fails' 1 'failOnWarning is "false", expected "true"' "${TMP}/warning-false.xml"

sed 's/ failOnRisky="true"/ failOnRisky="true" beStrictAboutOutputDuringTests="true" requireCoverageMetadata="true" beStrictAboutCoverageMetadata="true" failOnDeprecation="true" failOnNotice="true" failOnPhpunitDeprecation="true" failOnEmptyTestSuite="true"/' "${UNIT}" > "${TMP}/strict.xml"
expect 'a configuration with every strict flag passes --strict' 0 'carry the strict profile' --strict "${TMP}/strict.xml"

expect 'one failing file among two fails' 1 'no-risky.xml: failOnRisky' "${UNIT}" "${TMP}/no-risky.xml"

printf '<?xml version="1.0"?>\n<phpunitx failOnRisky="true"/>\n' > "${TMP}/other.xml"
expect 'another root element is a usage error' 2 'no <phpunit> root element' "${TMP}/other.xml"

printf 'not xml' > "${TMP}/broken.xml"
expect 'a file that is not XML is a usage error' 2 'no <phpunit> root element' "${TMP}/broken.xml"

expect 'a missing file is a usage error' 2 'cannot read the file' "${TMP}/absent.xml"
expect 'no file is a usage error' 2 'Usage:'
expect 'an unknown option is a usage error' 2 'Unknown option --strcit' --strcit "${UNIT}"

printf '%d cases passed\n' "${PASSED}"
# A case that stopped running would leave the count short and nothing red.
EXPECTED=17
if [[ "${FAILED}" -eq 0 && "${PASSED}" -ne "${EXPECTED}" ]]; then
    printf '  FAIL: %d cases passed, expected %d\n' "${PASSED}" "${EXPECTED}" >&2
    FAILED=1
fi
exit "${FAILED}"
