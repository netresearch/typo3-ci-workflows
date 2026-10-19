#!/usr/bin/env bash
#
# Assert how e2e provisioning probes a page of the instance.
#
# The probe asked once and aborted on the first answer that was not 200. On
# GitHub's runners a name lookup inside the podman network can fail with
# "Try again" just after the containers came up, and Apache can answer
# nothing yet, so a page gave 500 or 000 once and 200 on a later request. In a
# measurement over 34 E2E cells of t3x-rte_ckeditor_image and
# t3x-nr-passkeys-fe, one attempt failed 18 setups. The probe now asks again,
# and still fails for a page that keeps failing.
#
# This sources the provisioner and calls e2e_probe_status with a stand-in
# container binary that answers from a list of status codes. No container.

set -euo pipefail

PROVISION="${1:-assets/Build/Scripts/e2e-provision.sh}"
[[ -f "${PROVISION}" ]] || {
    echo "check-e2e-provision-probe: no provisioner at ${PROVISION}" >&2
    exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# The stand-in prints the next code from ${WORK}/codes and counts its calls.
cat > "${WORK}/container" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "${STUB_DIR}/calls") + 1 ))
echo "${n}" > "${STUB_DIR}/calls"
code=$(sed -n "${n}p" "${STUB_DIR}/codes")
printf '%s' "${code:-$(tail -n 1 "${STUB_DIR}/codes")}"
STUB
chmod +x "${WORK}/container"

# shellcheck source=/dev/null
source "${PROVISION}"

# What the provisioner reads from runTests.sh, exported because only the
# sourced function reads it.
export CONTAINER_BIN="${WORK}/container"
export CI_PARAMS=""
export NETWORK="probe-net"
export SUFFIX="probe"
export IMAGE_PHP="php-image"
export E2E_PROBE_ATTEMPTS=4
export E2E_PROBE_DELAY=0
export STUB_DIR="${WORK}"

STATUS=0

# expect <case> <codes, space-separated> <final code> <calls>
expect() {
    local name="${1}" codes="${2}" want_code="${3}" want_calls="${4}"
    tr ' ' '\n' <<< "${codes}" > "${WORK}/codes"
    echo 0 > "${WORK}/calls"
    local got_code got_calls
    got_code=$(e2e_probe_status curl-check "http://apache:80/" 2>"${WORK}/stderr")
    got_calls=$(cat "${WORK}/calls")
    if [[ "${got_code}" != "${want_code}" || "${got_calls}" != "${want_calls}" ]]; then
        echo "check-e2e-provision-probe: ${name}: got status ${got_code:-none} after ${got_calls} request(s), want ${want_code} after ${want_calls}" >&2
        STATUS=1
    fi
}

expect "first answer 200" "200" 200 1
expect "500 once, then 200" "500 200" 200 2
expect "no reply, then 200" "000 500 200" 200 3
expect "always 500" "500" 500 4

# A failed attempt has to say so: it is the only trace of the transient.
tr ' ' '\n' <<< "500 200" > "${WORK}/codes"
echo 0 > "${WORK}/calls"
e2e_probe_status curl-check "http://apache:80/" >/dev/null 2>"${WORK}/stderr"
if ! grep -qF 'answered 500 (attempt 1 of 4)' "${WORK}/stderr"; then
    echo "check-e2e-provision-probe: a failed attempt printed no line naming its status" >&2
    STATUS=1
fi

if [[ "${STATUS}" -eq 0 ]]; then
    echo "check-e2e-provision-probe: the page probe asks again and gives up after ${E2E_PROBE_ATTEMPTS} attempts."
fi

exit "${STATUS}"
