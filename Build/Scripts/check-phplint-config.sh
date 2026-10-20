#!/usr/bin/env bash
#
# Runs bin/check-phplint-config against the template in config/phplint/ and
# against fixture configurations, and asserts its exit code and the setting
# it names.
#
# The template must pass, so the template and the check cannot drift apart.
# The fixtures cover the two defects the check exists for (an ignored
# "cache" key, an unanchored exclude), an exclude given as a single string,
# a file that is not YAML, a missing file and the usage errors.
#
# Usage: check-phplint-config.sh bin/check-phplint-config

set -uo pipefail

[[ $# -eq 1 ]] || { printf 'usage: %s bin/check-phplint-config\n' "${0}" >&2; exit 2; }
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

TEMPLATE="${ROOT}/config/phplint/.phplint.yml"

expect 'the template passes' 0 '1 phplint configuration(s) pass' "${TEMPLATE}"

sed 's/^cache-dir:/cache:/' "${TEMPLATE}" > "${TMP}/cache.yml"
expect 'a cache key fails' 1 '"cache" is ignored' "${TMP}/cache.yml"

sed "s|'#^vendor/#'|vendor|" "${TEMPLATE}" > "${TMP}/plain.yml"
expect 'a plain-string exclude fails' 1 'exclude "vendor" is not an anchored' "${TMP}/plain.yml"

sed "s|'#^vendor/#'|'#vendor/#'|" "${TEMPLATE}" > "${TMP}/unanchored.yml"
expect 'a regular expression without ^ fails' 1 'exclude "#vendor/#" is not an anchored' "${TMP}/unanchored.yml"

sed "s|'#^vendor/#'|'#^vendor/'|" "${TEMPLATE}" > "${TMP}/unclosed.yml"
expect 'an unclosed regular expression fails' 1 'exclude "#^vendor/" is not an anchored' "${TMP}/unclosed.yml"

sed "s|'#^vendor/#'|'~^vendor/~i'|" "${TEMPLATE}" > "${TMP}/tilde.yml"
expect 'another delimiter with a modifier passes' 0 '1 phplint configuration(s) pass' "${TMP}/tilde.yml"

printf 'path: ./\nexclude: vendor\n' > "${TMP}/scalar.yml"
expect 'a single-string exclude is checked too' 1 'exclude "vendor" is not an anchored' "${TMP}/scalar.yml"

printf 'path: ./\n' > "${TMP}/minimal.yml"
expect 'a configuration without excludes passes' 0 '1 phplint configuration(s) pass' "${TMP}/minimal.yml"

expect 'one failing file among two fails' 1 'cache.yml: "cache" is ignored' "${TEMPLATE}" "${TMP}/cache.yml"

printf 'path: [\n' > "${TMP}/broken.yml"
expect 'a file that is not YAML is a usage error' 2 'not valid YAML' "${TMP}/broken.yml"

printf 'just a string\n' > "${TMP}/scalar-root.yml"
expect 'a top-level scalar is a usage error' 2 'no mapping at the top level' "${TMP}/scalar-root.yml"

expect 'a missing file is a usage error' 2 'cannot read the file' "${TMP}/absent.yml"
expect 'no file is a usage error' 2 'Usage:'
expect 'an unknown option is a usage error' 2 'Unknown option --strict' --strict "${TEMPLATE}"

printf '%d cases passed\n' "${PASSED}"
# A case that stopped running would leave the count short and nothing red.
EXPECTED=14
if [[ "${FAILED}" -eq 0 && "${PASSED}" -ne "${EXPECTED}" ]]; then
    printf '  FAIL: %d cases passed, expected %d\n' "${PASSED}" "${EXPECTED}" >&2
    FAILED=1
fi
exit "${FAILED}"
