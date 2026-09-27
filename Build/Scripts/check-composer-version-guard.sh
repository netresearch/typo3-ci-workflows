#!/usr/bin/env bash
#
# Runs the "Check composer.json version matches the release" step of the
# release workflows against fixture composer.json files and asserts its exit
# code and its ::error:: line.
#
# TYPO3 14.3 takes an extension's version from composer.json
# extra.typo3/cms.version, not from ext_emconf.php, once
# extra.typo3/cms.Package.providesPackages is also set. A release that bumps
# only ext_emconf.php passed the old tag check and installed from TER showing
# the previous number.
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

# expect_fail BODY FIXTURE NEEDLE...: exit non-zero, exactly one output line,
# which is the ::error for composer.json and contains every needle.
expect_fail() {
    local body="${1}" name="${2}" out status needle ok=1
    shift 2
    out="$(run_case "${body}" "${name}")"
    status=$?
    if [[ "${status}" -eq 0 ]]; then
        fail "${name}: exit 0, expected a refusal"
        return
    fi
    if [[ "${out}" != "::error file=composer.json::"* ]]; then
        fail "${name}: exit ${status} without a leading ::error file=composer.json:: — ${out}"
        return
    fi
    if [[ "$(printf '%s\n' "${out}" | wc -l)" -ne 1 ]]; then
        fail "${name}: the ::error spans several lines, so the runner would cut it — ${out}"
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
    expect_fail "${body}" different '"1.2.4"' '"1.2.3"'
    expect_fail "${body}" dev '"1.2.3-dev"' '"1.2.3"'
    expect_fail "${body}" empty-string 'is ""'
    expect_fail "${body}" trailing-newline '"1.2.3%0A"'
    expect_fail "${body}" percent '"1.2%253"'
    expect_fail "${body}" crlf '"1.2%0D%0A::warning::x"'
done

exit "${FAILED}"
