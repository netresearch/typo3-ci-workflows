#!/usr/bin/env bash
#
# Runs the steps "Fetch the pinned Opengrep rules" and "Run Opengrep scan" of
# security.yml as written, and asserts:
#
# - the fetch step assembles the pinned rule set and accepts its digest;
# - it fails when a listed file is missing, when a listed file is dropped, and
#   when RULES_DIGEST does not match, so a moved pin cannot shrink the rule
#   set unnoticed;
# - with the input's default `opengrep-config`, whose `--config auto` the scan
#   step maps to the pinned set, registry rules report under their registry
#   ids, the exec-use misfire passes, a sink fails, and a nosemgrep comment
#   naming the registry id suppresses;
# - `--config auto` without the pinned set fails the scan step;
# - a commit that cannot be fetched fails the fetch step after its retries,
#   and a config without `--config auto` skips the fetch.
#
# The fetch step downloads both pinned commits, so this check needs network
# access to github.com.
#
# Usage: check-opengrep-pinned-rules.sh security.yml

set -uo pipefail

[[ $# -eq 1 ]] || { printf 'usage: %s security.yml\n' "${0}" >&2; exit 2; }
WORKFLOW="${1}"
FETCH_STEP='Fetch the pinned Opengrep rules'

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FAILED=0
CASES=0
PASSED=0

fail() { printf '  FAIL: %s\n' "${1}" >&2; FAILED=1; return 0; }
pass() { printf '  ok: %s\n' "${1}"; PASSED=$((PASSED + 1)); return 0; }
die() { printf '%s\n' "${1}" >&2; exit 1; }

[[ -f "${WORKFLOW}" ]] || die "${WORKFLOW}: not found"

# step NAME FILE: writes the run: body of the one opengrep step named NAME.
step() {
    yq -o json '.jobs.opengrep.steps' "${WORKFLOW}" \
        | jq -r --arg s "${1}" '[.[] | select(.name == $s) | .run] | if length == 1 then .[0] else error("expected exactly one step named \($s), found \(length)") end' \
        > "${2}"
    [[ -s "${2}" ]] || die "${WORKFLOW}: no single opengrep step named '${1}'"
    return 0
}
fetch_env() {
    yq -r ".jobs.opengrep.steps[] | select(.name == \"${FETCH_STEP}\") | .env.${1}" "${WORKFLOW}"
    return $?
}

step 'Install Opengrep' "${TMP}/install.sh"
step "${FETCH_STEP}" "${TMP}/fetch.sh"
step 'Run Opengrep scan' "${TMP}/scan.sh"

VERSION="$(yq -r '.jobs.opengrep.env.OPENGREP_VERSION' "${WORKFLOW}")"
SHA256="$(yq -r '.jobs.opengrep.env.OPENGREP_SHA256' "${WORKFLOW}")"
DEFAULT="$(yq -r '.on.workflow_call.inputs.opengrep-config.default' "${WORKFLOW}")"
SEMGREP_SHA="$(fetch_env SEMGREP_RULES_SHA)"
TOB_SHA="$(fetch_env TRAILOFBITS_RULES_SHA)"
DIGEST="$(fetch_env RULES_DIGEST)"
[[ "${DEFAULT}" == *"--config auto"* ]] || die "${WORKFLOW}: the default '${DEFAULT}' has no --config auto"
[[ "${SEMGREP_SHA}" =~ ^[0-9a-f]{40}$ && "${TOB_SHA}" =~ ^[0-9a-f]{40}$ ]] || die "${WORKFLOW}: pins are not full commit ids"
[[ "${DIGEST}" =~ ^[0-9a-f]{64}$ ]] || die "${WORKFLOW}: RULES_DIGEST is not a sha256"

# run_fetch NAME SCRIPT [DIGEST] [CONFIG] [SEMGREP-SHA]: runs a fetch step body
# in a fresh RUNNER_TEMP named NAME, with the input's default as
# OPENGREP_CONFIG unless CONFIG is given; returns its exit code.
run_fetch() {
    local status=0
    mkdir -p "${TMP}/rt-${1}"
    (RUNNER_TEMP="${TMP}/rt-${1}" SEMGREP_RULES_SHA="${5:-${SEMGREP_SHA}}" TRAILOFBITS_RULES_SHA="${TOB_SHA}" \
        RULES_DIGEST="${3:-${DIGEST}}" OPENGREP_CONFIG="${4:-${DEFAULT}}" \
        bash -e "${2}" > "${TMP}/fetch-${1}.log" 2>&1) || status=$?
    return "${status}"
}

# expect_fetch NAME pass|fail SCRIPT [DIGEST] [CONFIG] [SEMGREP-SHA]
expect_fetch() {
    local status=0
    CASES=$((CASES + 1))
    run_fetch "${1}" "${3}" "${4:-}" "${5:-}" "${6:-}" || status=$?
    if [[ "${2}" == pass && "${status}" -ne 0 ]]; then
        fail "fetch ${1}: exit ${status}, expected 0 — $(tail -n 3 "${TMP}/fetch-${1}.log")"
    elif [[ "${2}" == fail && "${status}" -eq 0 ]]; then
        fail "fetch ${1}: exit 0, expected the step to fail"
    else
        pass "fetch ${1}: exit ${status}"
    fi
    return 0
}

# The listed files, as the step writes them.
mapfile -t LISTED < <(sed -n '/# BEGIN pinned rule files/,/# END pinned rule files/p' "${TMP}/fetch.sh" | grep -v '^#')
[[ "${#LISTED[@]}" -gt 0 ]] || die "${WORKFLOW}: '${FETCH_STEP}' lists no rule files"
FIRST="${LISTED[0]}"

expect_fetch pinned pass "${TMP}/fetch.sh"
RULES="${TMP}/rt-pinned/opengrep-pinned/rules.yaml"
if [[ -s "${RULES}" ]]; then
    printf '  pinned set: %s rules from %s files\n' "$(jq '.rules | length' "${RULES}")" "${#LISTED[@]}"
fi

# A listed file the pinned commit does not have (upstream renamed or deleted it).
sed "s#^${FIRST}\$#${FIRST%.*}-renamed.yaml#" "${TMP}/fetch.sh" > "${TMP}/fetch-missing.sh"
cmp -s "${TMP}/fetch.sh" "${TMP}/fetch-missing.sh" && die "could not rename '${FIRST}' in the step"
expect_fetch missing-file fail "${TMP}/fetch-missing.sh"

# A listed file dropped from FILES (fewer rules than the digest describes).
grep -v -x -F -- "${FIRST}" "${TMP}/fetch.sh" > "${TMP}/fetch-dropped.sh"
cmp -s "${TMP}/fetch.sh" "${TMP}/fetch-dropped.sh" && die "could not drop '${FIRST}' from the step"
expect_fetch dropped-file fail "${TMP}/fetch-dropped.sh"

# A digest that does not describe the rule set (a rule added, renamed or removed).
expect_fetch wrong-digest fail "${TMP}/fetch.sh" "$(printf '%064d' 0)"

# A pinned commit the network cannot deliver (here: one that does not exist)
# fails after the step's retries, rather than scanning with nothing.
CASES=$((CASES + 1))
if run_fetch unreachable "${TMP}/fetch.sh" '' '' "$(printf '%040d' 1)"; then
    fail "fetch unreachable: exit 0, expected the step to fail"
elif grep -q 'failed on all 3 attempts' "${TMP}/fetch-unreachable.log"; then
    pass "fetch unreachable: fails after 3 attempts"
else
    fail "fetch unreachable: failed for another reason — $(tail -n 3 "${TMP}/fetch-unreachable.log")"
fi

# A config without --config auto does not need the pinned set: the step
# fetches nothing and succeeds.
CASES=$((CASES + 1))
if ! run_fetch no-auto "${TMP}/fetch.sh" '' '--config p/php --error'; then
    fail "fetch no-auto: exit non-zero — $(tail -n 3 "${TMP}/fetch-no-auto.log")"
elif [[ -e "${TMP}/rt-no-auto/opengrep-pinned" ]]; then
    fail "fetch no-auto: fetched the pinned set although the config has no --config auto"
else
    pass "fetch no-auto: exit 0, nothing fetched"
fi

[[ -s "${RULES}" ]] || die "no pinned rule set to scan with; the pinned fetch failed"

printf 'Installing Opengrep %s with the workflow step\n' "${VERSION}"
mkdir -p "${TMP}/home"
: > "${TMP}/github_path"
(HOME="${TMP}/home" GITHUB_PATH="${TMP}/github_path" OPENGREP_VERSION="${VERSION}" OPENGREP_SHA256="${SHA256}" \
    bash -e "${TMP}/install.sh") || die "the install step failed"
BIN_DIR="$(head -n 1 "${TMP}/github_path")"
[[ -x "${BIN_DIR}/opengrep" ]] || die "the install step did not leave an opengrep binary in '${BIN_DIR}'"

# tree NAME LINE...: a fixture directory with a.php holding the lines.
tree() {
    local name="${1}"
    shift
    mkdir -p "${TMP}/fx/${name}"
    printf '<?php\n' > "${TMP}/fx/${name}/a.php"
    printf '%s\n' "$@" >> "${TMP}/fx/${name}/a.php"
    return 0
}
# shellcheck disable=SC2016 # the $ belong to PHP, not to the shell
tree misfire 'ExecutionIdentity::interactive();' 'ExecuteTaskRequest::fromRequest($request);'
# shellcheck disable=SC2016 # the $ belong to PHP, not to the shell
tree tainted "$(printf '%s($_GET["x"]);' exec)"
# shellcheck disable=SC2016 # the $ belong to PHP, not to the shell
tree untainted 'function f(string $c): void' '{' "$(printf '    %s($c);' exec)" '}'
# shellcheck disable=SC2016 # the $ belong to PHP, not to the shell
tree suppressed 'function f(string $c): void' '{' \
    "$(printf '    %s($c); // nosemgrep: php.lang.security.exec-use.exec-use' shell_exec)" '}'

# scan_case TREE RUNNER_TEMP: runs the scan step with the input's default.
scan_case() {
    local status=0
    (cd "${TMP}/fx/${1}" && HOME="${TMP}/home" PATH="${BIN_DIR}:${PATH}" OPENGREP_CONFIG="${DEFAULT}" \
        RUNNER_TEMP="${2}" bash -e "${TMP}/scan.sh" > "${TMP}/scan-${1}.log" 2>&1) || status=$?
    return "${status}"
}

# expect_scan TREE pass|fail [RULE-ID-THAT-MUST-REPORT]
expect_scan() {
    local status=0 sarif ids
    CASES=$((CASES + 1))
    scan_case "${1}" "${TMP}/rt-pinned" || status=$?
    sarif="${TMP}/fx/${1}/opengrep.sarif"
    if [[ ! -s "${sarif}" ]]; then
        fail "scan ${1}: no SARIF written (exit ${status}) — $(tail -n 3 "${TMP}/scan-${1}.log")"
        return 0
    fi
    ids="$(jq -r '[.runs[].results[] | select((.suppressions // []) | length == 0) | .ruleId] | unique | join(" ")' "${sarif}")"
    if [[ "${2}" == fail && "${status}" -eq 0 ]]; then
        fail "scan ${1}: exit 0, expected the scan to fail the job"
    elif [[ "${2}" == pass && "${status}" -ne 0 ]]; then
        fail "scan ${1}: exit ${status}, expected 0 — blocking: ${ids}"
    elif [[ -n "${3:-}" && " ${ids} " != *" ${3} "* ]]; then
        fail "scan ${1}: no unsuppressed finding of ${3}; got: ${ids:-none}"
    elif [[ " ${ids} " == *" php.lang.security.exec-use.exec-use "* ]]; then
        fail "scan ${1}: the excluded registry rule php.lang.security.exec-use.exec-use reported"
    else
        pass "scan ${1}: exit ${status}${3:+, ${3} reported}"
    fi
    return 0
}

expect_scan misfire pass
expect_scan tainted fail php.lang.security.tainted-exec.tainted-exec
expect_scan untainted fail netresearch.php.lang.security.exec-use.exec-use
expect_scan suppressed pass

# --config auto with no pinned set must not silently scan with nothing.
CASES=$((CASES + 1))
mkdir -p "${TMP}/rt-empty"
if scan_case misfire "${TMP}/rt-empty"; then
    fail "scan without the pinned set: exit 0, expected the step to fail"
elif grep -q 'needs the rule set' "${TMP}/scan-misfire.log"; then
    pass "scan without the pinned set: fails and names the missing rule set"
else
    fail "scan without the pinned set: failed for another reason — $(tail -n 3 "${TMP}/scan-misfire.log")"
fi

printf '%d cases, %d ok\n' "${CASES}" "${PASSED}"
exit "${FAILED}"
