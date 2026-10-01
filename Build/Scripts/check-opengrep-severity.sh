#!/usr/bin/env bash
#
# Runs the "Install Opengrep" and "Run Opengrep scan" steps of security.yml with
# the workflow's own default `opengrep-config` against fixture trees, one per
# rule severity, and asserts the scan step's exit code.
#
# The default used to be `--config auto --error --severity WARNING`. Opengrep's
# `--severity` reports findings only from rules of exactly the given level (it
# can be repeated), so a finding from an ERROR rule was neither reported nor
# failing the job (#268). The default must fail on WARNING and ERROR findings
# and pass on INFO.
#
# `--config auto` downloads the registry rule set; the check swaps it for a
# local rule file with one rule per severity and keeps every other argument of
# the default. The pinned binary is installed by the workflow's own install step
# (HOME and GITHUB_PATH point into a scratch directory), so the check follows a
# version bump. Both steps run under `bash -e`, what the runner uses for a
# `run:` without `shell:`.
#
# Usage: check-opengrep-severity.sh security.yml

set -uo pipefail

[[ $# -eq 1 ]] || { printf 'usage: %s security.yml\n' "${0}" >&2; exit 2; }
WORKFLOW="${1}"

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

step 'Install Opengrep' "${TMP}/install.sh"
step 'Run Opengrep scan' "${TMP}/scan.sh"

VERSION="$(yq -r '.jobs.opengrep.env.OPENGREP_VERSION' "${WORKFLOW}")"
SHA256="$(yq -r '.jobs.opengrep.env.OPENGREP_SHA256' "${WORKFLOW}")"
DEFAULT="$(yq -r '.on.workflow_call.inputs.opengrep-config.default' "${WORKFLOW}")"
[[ -n "${VERSION}" && "${VERSION}" != null ]] || die "${WORKFLOW}: no OPENGREP_VERSION"
[[ -n "${SHA256}" && "${SHA256}" != null ]] || die "${WORKFLOW}: no OPENGREP_SHA256"
[[ -n "${DEFAULT}" && "${DEFAULT}" != null ]] || die "${WORKFLOW}: no default for opengrep-config"

# Replace the value of `--config` with the local rule file, keep the rest.
read -r -a DEFAULT_ARGS <<< "${DEFAULT}"
ARGS=()
CONFIGS=0
for (( i = 0; i < ${#DEFAULT_ARGS[@]}; i++ )); do
    if [[ "${DEFAULT_ARGS[i]}" == "--config" ]]; then
        ARGS+=("--config" "${TMP}/rules.yml")
        i=$((i + 1))
        CONFIGS=$((CONFIGS + 1))
    else
        ARGS+=("${DEFAULT_ARGS[i]}")
    fi
done
[[ "${CONFIGS}" -eq 1 ]] || die "${WORKFLOW}: expected one --config in the default '${DEFAULT}', found ${CONFIGS}"

cat > "${TMP}/rules.yml" <<'RULES'
rules:
  - id: fixture-error
    languages: [php]
    severity: ERROR
    message: fixture finding of severity ERROR
    pattern: error_marker()
  - id: fixture-warning
    languages: [php]
    severity: WARNING
    message: fixture finding of severity WARNING
    pattern: warning_marker()
  - id: fixture-info
    languages: [php]
    severity: INFO
    message: fixture finding of severity INFO
    pattern: info_marker()
RULES

for tree in error warning info clean; do
    mkdir -p "${TMP}/fx/${tree}"
    if [[ "${tree}" == clean ]]; then
        printf '<?php\necho 1;\n' > "${TMP}/fx/${tree}/a.php"
    else
        printf '<?php\n%s_marker();\n' "${tree}" > "${TMP}/fx/${tree}/a.php"
    fi
done

printf 'Installing Opengrep %s with the workflow step\n' "${VERSION}"
mkdir -p "${TMP}/home"
: > "${TMP}/github_path"
(HOME="${TMP}/home" GITHUB_PATH="${TMP}/github_path" OPENGREP_VERSION="${VERSION}" OPENGREP_SHA256="${SHA256}" \
    bash -e "${TMP}/install.sh") || die "the install step failed"
BIN_DIR="$(head -n 1 "${TMP}/github_path")"
[[ -x "${BIN_DIR}/opengrep" ]] || die "the install step did not leave an opengrep binary in '${BIN_DIR}'"

CONFIG="${ARGS[*]}"
printf 'default %s, run as: %s\n' "${DEFAULT}" "${CONFIG}"

# run_case TREE: prints the scan's output, returns the step's exit code.
run_case() {
    local status=0
    (cd "${TMP}/fx/${1}" && HOME="${TMP}/home" PATH="${BIN_DIR}:${PATH}" OPENGREP_CONFIG="${CONFIG}" \
        bash -e "${TMP}/scan.sh" 2>&1) || status=$?
    return "${status}"
}

# expect TREE fail|pass
expect() {
    local out status
    CASES=$((CASES + 1))
    out="$(run_case "${1}")"
    status=$?
    if [[ ! -s "${TMP}/fx/${1}/opengrep.sarif" ]]; then
        fail "${1}: no SARIF written (exit ${status}) — ${out}"
    elif [[ "${2}" == fail && "${status}" -eq 0 ]]; then
        fail "${1}: exit 0, expected the scan to fail the job"
    elif [[ "${2}" == pass && "${status}" -ne 0 ]]; then
        fail "${1}: exit ${status}, expected 0 — ${out}"
    else
        pass "${1}: exit ${status}"
    fi
    return 0
}

expect error fail
expect warning fail
expect info pass
expect clean pass

printf '%d cases, %d ok\n' "${CASES}" "${PASSED}"
exit "${FAILED}"
