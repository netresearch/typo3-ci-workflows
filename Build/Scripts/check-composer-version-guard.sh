#!/usr/bin/env bash
#
# Runs the "Check composer.json version matches the release" step of the
# release workflows against fixture composer.json files and asserts its exit
# code and its ::error:: line.
#
# TYPO3 14.3 takes an extension's version from composer.json
# extra.typo3/cms.version, falling back to the top-level version, and no longer
# from ext_emconf.php, once extra.typo3/cms.Package.providesPackages is also
# set. A release that bumps only ext_emconf.php passed the old tag check and
# installed from TER showing the previous number. Each of the two fields that
# is set must therefore equal the release version.
#
# The step's own bash is executed, not grepped: a text probe would confirm an
# `exit 1` that sits in a branch nothing reaches. It runs under `bash -e`,
# which is what the runner uses for a `run:` without `shell:`.
#
# Every workflow given must carry the step, and all copies must be identical,
# so the two release paths cannot drift apart.
#
# Usage: check-composer-version-guard.sh workflow.yml [workflow.yml ...]

set -uo pipefail

STEP='Check composer.json version matches the release'

[[ $# -ge 1 ]] || { printf 'usage: %s workflow.yml [workflow.yml ...]\n' "${0}" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FAILED=0

fail() { printf '  FAIL: %s\n' "${1}" >&2; FAILED=1; }
pass() { printf '  ok: %s\n' "${1}"; }

# fixture NAME JSON: a checkout holding only that composer.json. An empty JSON
# argument means no composer.json at all.
fixture() {
    mkdir -p "${TMP}/fx/${1}"
    if [[ -n "${2}" ]]; then
        printf '%s\n' "${2}" > "${TMP}/fx/${1}/composer.json"
    fi
}

fixture no-file ''
fixture absent '{"extra":{"typo3/cms":{"extension-key":"demo"}}}'
fixture no-extra '{"name":"vendor/demo"}'
fixture null '{"extra":{"typo3/cms":{"extension-key":"demo","version":null}}}'
fixture equal '{"extra":{"typo3/cms":{"extension-key":"demo","version":"1.2.3"}}}'
fixture v-prefix '{"extra":{"typo3/cms":{"extension-key":"demo","version":"v1.2.3"}}}'
fixture providing '{"extra":{"typo3/cms":{"extension-key":"demo","version":"1.2.3","Package":{"providesPackages":{}}}}}'
fixture different '{"extra":{"typo3/cms":{"extension-key":"demo","version":"1.2.4"}}}'
fixture dev '{"extra":{"typo3/cms":{"extension-key":"demo","version":"1.2.3-dev"}}}'
fixture empty-string '{"extra":{"typo3/cms":{"extension-key":"demo","version":""}}}'
fixture trailing-newline '{"extra":{"typo3/cms":{"extension-key":"demo","version":"1.2.3\n"}}}'
fixture percent '{"extra":{"typo3/cms":{"extension-key":"demo","version":"1.2%3"}}}'
fixture crlf '{"extra":{"typo3/cms":{"extension-key":"demo","version":"1.2\r\n::warning::x"}}}'
fixture top-equal '{"version":"1.2.3","extra":{"typo3/cms":{"extension-key":"demo"}}}'
fixture top-different '{"version":"1.2.4","extra":{"typo3/cms":{"extension-key":"demo"}}}'
fixture top-null '{"version":null,"extra":{"typo3/cms":{"extension-key":"demo"}}}'
fixture both-equal '{"version":"v1.2.3","extra":{"typo3/cms":{"extension-key":"demo","version":"1.2.3"}}}'
fixture both-extra-different '{"version":"1.2.3","extra":{"typo3/cms":{"extension-key":"demo","version":"1.2.4"}}}'
fixture both-top-different '{"version":"1.2.2","extra":{"typo3/cms":{"extension-key":"demo","version":"1.2.3"}}}'
fixture both-different '{"version":"1.2.2","extra":{"typo3/cms":{"extension-key":"demo","version":"1.2.4"}}}'

# run_case BODY FIXTURE: prints the step's output, returns its exit code.
run_case() {
    (cd "${TMP}/fx/${2}" && VERSION=1.2.3 bash -e "${1}" 2>&1)
}

# expect_pass BODY FIXTURE
expect_pass() {
    local out status
    out="$(run_case "${1}" "${2}")"
    status=$?
    if [[ "${status}" -ne 0 ]]; then
        fail "${2}: exit ${status}, expected 0 — ${out}"
    elif [[ "${out}" == *"::error"* ]]; then
        fail "${2}: exit 0 but printed an ::error — ${out}"
    else
        pass "${2}: passes"
    fi
}

# expect_fail BODY FIXTURE ERRORS NEEDLE...: exit non-zero; exactly ERRORS
# lines are an ::error for composer.json; every other line is a field's
# "(matches)" report, so a value that broke the ::error across lines shows up
# as a stray line; the output contains every needle.
expect_fail() {
    local body="${1}" name="${2}" errors="${3}" out status needle line count=0 ok=1
    shift 3
    out="$(run_case "${body}" "${name}")"
    status=$?
    if [[ "${status}" -eq 0 ]]; then
        fail "${name}: exit 0, expected a refusal"
        return
    fi
    while IFS= read -r line; do
        if [[ "${line}" == "::error file=composer.json::"* ]]; then
            count=$((count + 1))
        elif [[ "${line}" != "composer.json "*" (matches)" ]]; then
            fail "${name}: stray output line, so an ::error was cut or is missing — ${line}"
            return
        fi
    done <<< "${out}"
    if [[ "${count}" -ne "${errors}" ]]; then
        fail "${name}: ${count} ::error line(s), expected ${errors} — ${out}"
        return
    fi
    for needle in "$@"; do
        if [[ "${out}" != *"${needle}"* ]]; then
            fail "${name}: ::error does not contain '${needle}' — ${out}"
            ok=0
        fi
    done
    [[ "${ok}" -eq 1 ]] && pass "${name}: refused (exit ${status}) naming $*"
}

FIRST_BODY=""
for WORKFLOW in "$@"; do
    printf 'composer.json version guard (%s)\n' "${WORKFLOW}"
    if [[ ! -f "${WORKFLOW}" ]]; then
        fail "${WORKFLOW}: not found"
        continue
    fi

    body="${TMP}/$(basename "${WORKFLOW}").sh"
    yq -o json '.jobs' "${WORKFLOW}" \
        | jq -r --arg s "${STEP}" '[.[].steps[]? | select(.name == $s) | .run] | if length == 1 then .[0] else error("expected exactly one step named \($s), found \(length)") end' \
        > "${body}"
    if [[ ! -s "${body}" ]]; then
        fail "${WORKFLOW}: no single step named '${STEP}'"
        continue
    fi

    if [[ -z "${FIRST_BODY}" ]]; then
        FIRST_BODY="${body}"
    elif ! cmp -s "${FIRST_BODY}" "${body}"; then
        fail "${WORKFLOW}: the step differs from the copy in ${1}"
    fi

    expect_pass "${body}" no-file
    expect_pass "${body}" absent
    expect_pass "${body}" no-extra
    expect_pass "${body}" null
    expect_pass "${body}" equal
    expect_pass "${body}" v-prefix
    expect_pass "${body}" providing
    expect_pass "${body}" top-equal
    expect_pass "${body}" top-null
    expect_pass "${body}" both-equal
    expect_fail "${body}" different 1 '::extra.typo3/cms.version is "1.2.4"' 'released is "1.2.3"'
    expect_fail "${body}" dev 1 '::extra.typo3/cms.version is "1.2.3-dev"' 'released is "1.2.3"'
    expect_fail "${body}" empty-string 1 '::extra.typo3/cms.version is ""'
    expect_fail "${body}" trailing-newline 1 '::extra.typo3/cms.version is "1.2.3%0A"'
    expect_fail "${body}" percent 1 '::extra.typo3/cms.version is "1.2%253"'
    expect_fail "${body}" crlf 1 '::extra.typo3/cms.version is "1.2%0D%0A::warning::x"'
    expect_fail "${body}" top-different 1 '::version is "1.2.4"' 'released is "1.2.3"'
    expect_fail "${body}" both-extra-different 1 '::extra.typo3/cms.version is "1.2.4"' 'composer.json version: 1.2.3 (matches)'
    expect_fail "${body}" both-top-different 1 '::version is "1.2.2"' 'composer.json extra.typo3/cms.version: 1.2.3 (matches)'
    expect_fail "${body}" both-different 2 '::extra.typo3/cms.version is "1.2.4"' '::version is "1.2.2"'
done

exit "${FAILED}"
