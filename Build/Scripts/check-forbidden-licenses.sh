#!/usr/bin/env bash
#
# Runs the "Check licenses" step of license-check.yml, with the workflow's own
# default `forbidden-licenses` pattern, against fixture outputs of
# `composer licenses --format=json` and asserts the step's exit code.
#
# The default used to be `"(SSPL|BSL)"`. The quotes are part of the pattern, so
# it matched only a licence string that is exactly "SSPL" or "BSL"; the SPDX
# identifiers packages declare, SSPL-1.0 and BUSL-1.1, passed (#267). BSL-1.0 is
# the Boost Software License, a permissive licence, and must keep passing.
#
# The step's own bash is executed, not grepped, under `bash -e` (what the
# runner uses for a `run:` without `shell:`), with a stand-in `composer` on PATH
# that prints the fixture. The fixtures use the layout Composer writes
# (JsonFile::encode, four-space indent, one licence string per line).
#
# Usage: check-forbidden-licenses.sh license-check.yml

set -uo pipefail

STEP='Check licenses'

[[ $# -eq 1 ]] || { printf 'usage: %s license-check.yml\n' "${0}" >&2; exit 2; }
WORKFLOW="${1}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FAILED=0
CASES=0
PASSED=0

fail() { printf '  FAIL: %s\n' "${1}" >&2; FAILED=1; return 0; }
pass() { printf '  ok: %s\n' "${1}"; PASSED=$((PASSED + 1)); return 0; }

if [[ ! -f "${WORKFLOW}" ]]; then
    printf '%s: not found\n' "${WORKFLOW}" >&2
    exit 1
fi

PATTERN="$(yq -r '.on.workflow_call.inputs.forbidden-licenses.default' "${WORKFLOW}")"
if [[ -z "${PATTERN}" || "${PATTERN}" == "null" ]]; then
    printf '%s: no default for the forbidden-licenses input\n' "${WORKFLOW}" >&2
    exit 1
fi

BODY="${TMP}/step.sh"
yq -o json '.jobs' "${WORKFLOW}" \
    | jq -r --arg s "${STEP}" '[.[].steps[]? | select(.name == $s) | .run] | if length == 1 then .[0] else error("expected exactly one step named \($s), found \(length)") end' \
    > "${BODY}"
if [[ ! -s "${BODY}" ]]; then
    printf '%s: no single step named %s\n' "${WORKFLOW}" "${STEP}" >&2
    exit 1
fi

mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/composer" <<'STUB'
#!/usr/bin/env bash
cat "${FIXTURE}"
STUB
chmod +x "${TMP}/bin/composer"

# fixture NAME LICENCE...: composer's JSON for a root package licensed MIT with
# one dependency that declares the given licence strings.
fixture() {
    local name="${1}" first=1 licence
    shift
    {
        printf '{\n    "name": "vendor/demo",\n    "version": "dev-main",\n    "license": [\n        "MIT"\n    ],\n'
        printf '    "dependencies": {\n        "vendor/dependency": {\n            "version": "1.0.0",\n            "license": [\n'
        for licence in "$@"; do
            [[ "${first}" -eq 1 ]] || printf ',\n'
            printf '                "%s"' "${licence}"
            first=0
        done
        printf '\n            ]\n        }\n    }\n}\n'
    } > "${TMP}/${name}.json"
    return 0
}

# run_case NAME: prints the step's output, returns its exit code.
run_case() {
    local status=0 work="${TMP}/work-${1}"
    mkdir -p "${work}"
    (cd "${work}" \
        && PATH="${TMP}/bin:${PATH}" FIXTURE="${TMP}/${1}.json" FORBIDDEN_PATTERN="${PATTERN}" \
           GITHUB_STEP_SUMMARY="${work}/summary.md" bash -e "${BODY}" 2>&1) || status=$?
    return "${status}"
}

expect_pass() {
    local out status
    CASES=$((CASES + 1))
    out="$(run_case "${1}")"
    status=$?
    if [[ "${status}" -ne 0 ]]; then
        fail "${1}: exit ${status}, expected 0 — ${out}"
    else
        pass "${1}: passes"
    fi
    return 0
}

expect_refused() {
    local out status
    CASES=$((CASES + 1))
    out="$(run_case "${1}")"
    status=$?
    if [[ "${status}" -eq 0 ]]; then
        fail "${1}: exit 0, expected the audit to refuse it"
    elif [[ "${out}" != *"::error::Found forbidden licenses"* ]]; then
        fail "${1}: exit ${status} without the forbidden-licence ::error — ${out}"
    else
        pass "${1}: refused (exit ${status})"
    fi
    return 0
}

fixture mit 'MIT'
fixture gpl 'GPL-2.0-or-later'
fixture boost 'BSL-1.0'
fixture lgpl-or-mit 'LGPL-3.0-or-later' 'MIT'
fixture sspl-spdx 'SSPL-1.0'
fixture busl-spdx 'BUSL-1.1'
fixture sspl-bare 'SSPL'
fixture bsl-bare 'BSL'
fixture busl-second 'MIT' 'BUSL-1.1'
fixture sspl-expression '(MIT or SSPL-1.0)'

printf 'forbidden-licenses default %s (%s)\n' "${PATTERN}" "${WORKFLOW}"
expect_pass mit
expect_pass gpl
expect_pass boost
expect_pass lgpl-or-mit
expect_refused sspl-spdx
expect_refused busl-spdx
expect_refused sspl-bare
expect_refused bsl-bare
expect_refused busl-second
expect_refused sspl-expression

printf '%d cases, %d ok\n' "${CASES}" "${PASSED}"
exit "${FAILED}"
