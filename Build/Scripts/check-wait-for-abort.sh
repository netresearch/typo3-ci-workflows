#!/usr/bin/env bash
#
# Assert that wait_for and wait_for_http stop the runner when the service never
# answers, and continue when it does.
#
# Both sent SIGINT to the process group named after the script's own PID. A
# script started by CI or by another script does not lead a group, so the
# signal failed ("No such process"), the function returned 0 and the suite ran
# without the service.
#
# This runs the two functions of the given runner in a script of their own,
# with a stand-in container binary that exits with a given status. No container.

set -euo pipefail

RUNNER="${1:-assets/Build/Scripts/runTests.sh}"
[[ -f "${RUNNER}" ]] || {
    echo "check-wait-for-abort: no runner at ${RUNNER}" >&2
    exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

cat > "${WORK}/container" <<'STUB'
#!/usr/bin/env bash
exit "${STUB_STATUS}"
STUB
chmod +x "${WORK}/container"

{
    echo "trap 'echo cleaned-up' EXIT"
    sed -n '/^wait_for() {/,/^}/p; /^wait_for_http() {/,/^}/p' "${RUNNER}"
    # The positional parameters belong to the generated script.
    # shellcheck disable=SC2016
    echo '"${1}" host 80'
    echo 'echo continued'
} > "${WORK}/script.sh"

export CONTAINER_BIN="${WORK}/container"
STATUS=0

# expect <function> <container status> <exit: zero|nonzero> <continued: yes|no>
expect() {
    local name="${1}" stub="${2}" want_exit="${3}" want_continued="${4}"
    local rc=0 out exit_word=zero continued=no
    out=$(STUB_STATUS="${stub}" bash "${WORK}/script.sh" "${name}" 2>&1) || rc=$?
    [[ "${rc}" -eq 0 ]] || exit_word=nonzero
    grep -qx continued <<< "${out}" && continued=yes
    if [[ "${exit_word}" != "${want_exit}" || "${continued}" != "${want_continued}" ]]; then
        echo "check-wait-for-abort: ${name} with container status ${stub}: exit ${rc}, continued=${continued}; want ${want_exit} exit, continued=${want_continued}" >&2
        STATUS=1
    fi
    if ! grep -qx cleaned-up <<< "${out}"; then
        echo "check-wait-for-abort: ${name} with container status ${stub}: the EXIT trap did not run" >&2
        STATUS=1
    fi
}

for name in wait_for wait_for_http; do
    expect "${name}" 0 zero yes
    expect "${name}" 1 nonzero no
done

if [[ "${STATUS}" -eq 0 ]]; then
    echo "check-wait-for-abort: an unreachable service stops the runner, a reachable one does not."
fi

exit "${STATUS}"
