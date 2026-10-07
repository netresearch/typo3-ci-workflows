#!/usr/bin/env bash
#
# Checks that every way out of the shared runner removes the container network
# the run created. Only the end of the script and SIGINT used to remove it, so
# an invalid -s, a failed early step or a conf suite that called exit left one
# network behind per run — and each holds a subnet until the daemon's address
# pool runs out, at which point `network create` fails for every run.
#
# The runner is executed end to end against a fixture extension, with a
# stand-in `docker` first on PATH that records the network calls and starts
# nothing. The real binary is never called.
#
# Usage: check-runner-network-cleanup.sh [path/to/runTests.sh]

set -uo pipefail

RUNNER="${1:-assets/Build/Scripts/runTests.sh}"
[[ -f "${RUNNER}" ]] || { printf 'not found: %s\n' "${RUNNER}" >&2; exit 2; }
RUNNER="$(realpath "${RUNNER}")"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

FAILED=0

fail() { printf '  FAIL: %s\n' "${1}" >&2; FAILED=1; return 0; }
pass() { printf '  ok: %s\n' "${1}"; return 0; }

# The stand-in runtime. `run` exits with STUB_RUN_EXIT so a failing container
# step can be simulated; `ps` lists no attached containers.
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_LOG}"
case "${1:-}" in
    run) exit "${STUB_RUN_EXIT:-0}" ;;
    *) exit 0 ;;
esac
STUB
chmod +x "${TMP}/bin/docker"

ROOT="${TMP}/ext"
mkdir -p "${ROOT}/Build/Scripts"
printf '{"name":"netresearch/fixture-network","require":{"php":"^8.2"},"extra":{"typo3/cms":{"extension-key":"fixture"}}}\n' \
    > "${ROOT}/composer.json"
# Conf suites cover the three ways a suite can end: success, a failure code
# returned to the runner, and an exit that leaves the runner from inside.
cat > "${ROOT}/Build/Scripts/runTests.conf" <<'CONF'
suite_ok() { return 0; }
suite_fail() { return 3; }
suite_bail() { exit 4; }
# Writes a marker once the suite runs, i.e. after the network exists and the
# EXIT trap is armed, so the SIGTERM case below never signals before that.
suite_hang() { echo 'suite ready' >> "${STUB_LOG}"; sleep 30; }
CONF

# $1 label, $2 expected exit code, rest: runner arguments. -b docker, because
# the runner prefers podman when both are installed, and CI runners have both.
check_case() {
    local label="${1}" expected="${2}" log status created removed name missing=""
    shift 2
    log="${TMP}/${label}.log"
    : > "${log}"
    (
        cd "${ROOT}" || exit 1
        PATH="${TMP}/bin:${PATH}" STUB_LOG="${log}" "${RUNNER}" -b docker "$@" </dev/null >/dev/null 2>&1
    )
    status=$?
    created="$(awk '$1 == "network" && $2 == "create" { print $3 }' "${log}")"
    removed="$(awk '$1 == "network" && $2 == "rm" { print $3 }' "${log}")"

    if [[ "${status}" -ne "${expected}" ]]; then
        fail "${label}: exit ${status}, expected ${expected}"
    fi
    # Without a create the check below passes on a runner that never got this
    # far, which proves nothing about cleanup.
    if [[ -z "${created}" ]]; then
        fail "${label}: no network was created — the case never reached the point under test"
        return 0
    fi
    for name in ${created}; do
        grep -qxF "${name}" <<< "${removed}" || missing+="${name} "
    done
    if [[ -n "${missing}" ]]; then
        fail "${label}: network left behind: ${missing% }"
    else
        pass "${label}: exit ${status}, network removed"
    fi
    return 0
}

printf 'Network cleanup (%s)\n' "${RUNNER#"$(pwd)/"}"

check_case suite-succeeds 0 -s ok
check_case suite-fails 3 -s fail
check_case suite-exits 4 -s bail
check_case invalid-suite 1 -s doesnotexist
# A failing step before the suite: `-t` requires a TYPO3 version in a
# container, and that container fails.
STUB_RUN_EXIT=1 check_case failed-early-step 1 -t 13 -s unit

# A cancelled run: CI cancellation and `timeout` send SIGTERM. The runner gets
# its own process group so the signal reaches the suite's child as well, which
# is what a cancelled job does.
term_log="${TMP}/sigterm.log"
: > "${term_log}"
(
    cd "${ROOT}" || exit 1
    PATH="${TMP}/bin:${PATH}" STUB_LOG="${term_log}" setsid "${RUNNER}" -b docker -s hang </dev/null >/dev/null 2>&1 &
    pid=$!
    for _ in $(seq 1 50); do
        grep -q '^suite ready' "${term_log}" && break
        sleep 0.1
    done
    kill -TERM -- "-${pid}" 2>/dev/null
    wait "${pid}"
)
term_status=$?
term_created="$(awk '$1 == "network" && $2 == "create" { print $3 }' "${term_log}")"
term_removed="$(awk '$1 == "network" && $2 == "rm" { print $3 }' "${term_log}")"
if [[ -z "${term_created}" ]]; then
    fail "sigterm: no network was created — the case never reached the point under test"
elif [[ "${term_removed}" == "${term_created}" ]]; then
    pass "sigterm: exit ${term_status}, network removed"
else
    fail "sigterm: exit ${term_status}, network left behind: ${term_created}"
fi

# An inherited NETWORK must not be taken for the run's own. The runner exits
# before creating anything here (-h), so nothing may be removed.
env_log="${TMP}/inherited.log"
: > "${env_log}"
(
    cd "${ROOT}" || exit 1
    PATH="${TMP}/bin:${PATH}" STUB_LOG="${env_log}" NETWORK=someone-elses-network "${RUNNER}" -b docker -h </dev/null >/dev/null 2>&1
)
if grep -qE '^(network rm|rm -f|ps )' "${env_log}"; then
    fail "an inherited NETWORK was cleaned up: $(tr '\n' ';' < "${env_log}")"
else
    pass "an inherited NETWORK is left alone"
fi

exit "${FAILED}"
