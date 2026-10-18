#!/usr/bin/env bash
#
# Runs the "Install Opengrep" and "Run Opengrep scan" steps of security.yml with
# the workflow's own default `opengrep-config` against fixture trees and asserts
# how the scan step treats PHP command execution.
#
# Since semgrep/semgrep-rules#4081 the registry rule
# php.lang.security.exec-use.exec-use matches every callee whose name starts
# with a sink name in any case, so `ExecutionIdentity::interactive()` failed the
# job. The scan step excludes that rule and runs a replacement whose regex matches the
# whole callee name. This check asserts that the misfire passes, that every sink
# still fails the job, and that a `nosemgrep` comment naming the registry id
# still suppresses the replacement.
#
# `--config auto` downloads the registry rule set; the check swaps it for a
# stand-in holding the registry rule as of semgrep-rules 430e442 under its
# registry id. The stand-in lies in the scanned directory, because Opengrep
# prefixes the id of a rule file elsewhere with its path, and a registry rule
# carries no prefix. Before the cases, the stand-in alone must fail on the
# misfire tree, so a stand-in that cannot reproduce the defect fails the check.
#
# Usage: check-opengrep-exec-use.sh security.yml

set -uo pipefail

[[ $# -eq 1 ]] || { printf 'usage: %s security.yml\n' "${0}" >&2; exit 2; }
WORKFLOW="${1}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FAILED=0
CASES=0
PASSED=0
REGISTRY_ID='php.lang.security.exec-use.exec-use'
SINKS=(exec passthru proc_open popen shell_exec system pcntl_exec)

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

step 'Install Opengrep' "${TMP}/install.sh"
step 'Run Opengrep scan' "${TMP}/scan.sh"

VERSION="$(yq -r '.jobs.opengrep.env.OPENGREP_VERSION' "${WORKFLOW}")"
SHA256="$(yq -r '.jobs.opengrep.env.OPENGREP_SHA256' "${WORKFLOW}")"
DEFAULT="$(yq -r '.on.workflow_call.inputs.opengrep-config.default' "${WORKFLOW}")"
[[ -n "${VERSION}" && "${VERSION}" != null ]] || die "${WORKFLOW}: no OPENGREP_VERSION"
[[ -n "${SHA256}" && "${SHA256}" != null ]] || die "${WORKFLOW}: no OPENGREP_SHA256"
[[ -n "${DEFAULT}" && "${DEFAULT}" != null ]] || die "${WORKFLOW}: no default for opengrep-config"

# Replace the value of `--config` with the stand-in, keep the rest.
read -r -a DEFAULT_ARGS <<< "${DEFAULT}"
ARGS=()
CONFIGS=0
for (( i = 0; i < ${#DEFAULT_ARGS[@]}; i++ )); do
    if [[ "${DEFAULT_ARGS[i]}" == "--config" ]]; then
        ARGS+=("--config" "registry.yml")
        i=$((i + 1))
        CONFIGS=$((CONFIGS + 1))
    else
        ARGS+=("${DEFAULT_ARGS[i]}")
    fi
done
[[ "${CONFIGS}" -eq 1 ]] || die "${WORKFLOW}: expected one --config in the default '${DEFAULT}', found ${CONFIGS}"

cat > "${TMP}/registry.yml" <<RULES
rules:
  - id: ${REGISTRY_ID}
    patterns:
      - pattern: \$FUNC(...);
      - pattern-not: \$FUNC('...', ...);
      - metavariable-regex:
          metavariable: \$FUNC
          regex: (?i)exec|passthru|proc_open|popen|shell_exec|system|pcntl_exec
    message: stand-in for the registry rule as of semgrep-rules 430e442
    languages: [php]
    severity: ERROR
RULES

# tree NAME LINE...: a fixture directory with a.php holding the lines, and the
# stand-in rule file.
tree() {
    local name="${1}"
    shift
    mkdir -p "${TMP}/fx/${name}"
    printf '<?php\n' > "${TMP}/fx/${name}/a.php"
    printf '%s\n' "$@" >> "${TMP}/fx/${name}/a.php"
    cp "${TMP}/registry.yml" "${TMP}/fx/${name}/registry.yml"
    return 0
}

# call NAME: a call of NAME with a non-constant argument.
# shellcheck disable=SC2016 # the $ belong to PHP, not to the shell
call() { printf '%s($_GET["x"], [], $pipes);' "${1}"; return 0; }

# shellcheck disable=SC2016 # the $ belong to PHP, not to the shell
tree misfire 'ExecutionIdentity::interactive();' 'ExecuteTaskRequest::fromRequest($request);'
tree prefixed "$(call execute)" "$(call executeQuery)" "$(call systemInfo)"
# shellcheck disable=SC2016 # the $ belong to PHP, not to the shell
tree method '$runner->exec($cmd);'
tree constant "$(printf "%s('ls -l');" exec)"
tree suppressed \
    "// nosemgrep: ${REGISTRY_ID}" \
    "$(call proc_open)" \
    "$(call shell_exec) // nosemgrep: ${REGISTRY_ID}"
for sink in "${SINKS[@]}"; do
    tree "sink-${sink}" "$(call "${sink}")"
done
tree sink-uppercase "$(call EXEC)"
tree sink-qualified "$(call '\exec')"

printf 'Installing Opengrep %s with the workflow step\n' "${VERSION}"
mkdir -p "${TMP}/home" "${TMP}/runner_temp"
: > "${TMP}/github_path"
(HOME="${TMP}/home" GITHUB_PATH="${TMP}/github_path" OPENGREP_VERSION="${VERSION}" OPENGREP_SHA256="${SHA256}" \
    bash -e "${TMP}/install.sh") || die "the install step failed"
BIN_DIR="$(head -n 1 "${TMP}/github_path")"
[[ -x "${BIN_DIR}/opengrep" ]] || die "the install step did not leave an opengrep binary in '${BIN_DIR}'"

# The stand-in must reproduce the defect on its own, or the cases prove nothing.
if (cd "${TMP}/fx/misfire" && HOME="${TMP}/home" "${BIN_DIR}/opengrep" scan --config registry.yml --error \
        --quiet . > /dev/null 2>&1); then
    die "the stand-in registry rule does not fail on the misfire tree; it no longer reproduces the defect"
fi

CONFIG="${ARGS[*]}"
printf 'default %s, run as: %s\n' "${DEFAULT}" "${CONFIG}"

# run_case TREE: prints the scan's output, returns the step's exit code.
run_case() {
    local status=0
    (cd "${TMP}/fx/${1}" && HOME="${TMP}/home" PATH="${BIN_DIR}:${PATH}" OPENGREP_CONFIG="${CONFIG}" \
        RUNNER_TEMP="${TMP}/runner_temp" bash -e "${TMP}/scan.sh" 2>&1) || status=$?
    return "${status}"
}

# expect TREE fail|pass
expect() {
    local out status sarif leaked
    CASES=$((CASES + 1))
    out="$(run_case "${1}")"
    status=$?
    sarif="${TMP}/fx/${1}/opengrep.sarif"
    if [[ ! -s "${sarif}" ]]; then
        fail "${1}: no SARIF written (exit ${status}) — ${out}"
        return 0
    fi
    # The excluded registry rule must not report anything.
    leaked="$(jq --arg id "${REGISTRY_ID}" '[.runs[].results[] | select(.ruleId == $id)] | length' "${sarif}")"
    if [[ "${leaked}" != 0 ]]; then
        fail "${1}: ${leaked} result(s) from the excluded registry rule"
    elif [[ "${2}" == fail && "${status}" -eq 0 ]]; then
        fail "${1}: exit 0, expected the scan to fail the job"
    elif [[ "${2}" == pass && "${status}" -ne 0 ]]; then
        fail "${1}: exit ${status}, expected 0 — ${out}"
    else
        pass "${1}: exit ${status}"
    fi
    return 0
}

expect misfire pass
expect prefixed pass
expect method pass
expect constant pass
expect suppressed pass
for sink in "${SINKS[@]}" uppercase qualified; do
    expect "sink-${sink}" fail
done

printf '%d cases, %d ok\n' "${CASES}" "${PASSED}"
exit "${FAILED}"
