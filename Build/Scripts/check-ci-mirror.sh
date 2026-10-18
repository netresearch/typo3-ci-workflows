#!/usr/bin/env bash
#
# Runs mirror-ci-images.sh against a stand-in `crane` and asserts its exit
# code and the copies it made, one case per failure mode.
#
# ci-mirror.yml runs on a schedule and on workflow_dispatch only, so no pull
# request ever executes the mirror. Its branches that only fire on a bad day
# (a throttled source, a copy that does not match its source, a source that
# lost a platform) would otherwise first run in production. The stand-in keeps
# each "registry" as files: `crane manifest` prints the stored index,
# `crane index filter` writes the amd64 and arm64 entries of the source index
# to the destination and logs the call.
#
# Usage: check-ci-mirror.sh mirror-ci-images.sh

set -uo pipefail

[[ $# -eq 1 ]] || { printf 'usage: %s mirror-ci-images.sh\n' "${0}" >&2; exit 2; }
SCRIPT="${1}"
[[ -f "${SCRIPT}" ]] || { printf '%s: not found\n' "${SCRIPT}" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FAILED=0
PASSED=0

fail() { printf '  FAIL: %s\n' "${1}" >&2; FAILED=1; return 0; }
pass() { printf '  ok: %s\n' "${1}"; PASSED=$((PASSED + 1)); return 0; }

cat >"${TMP}/crane" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
key() { printf '%s' "${1//[\/:]/_}"; }
case "${1:-} ${2:-}" in
    "manifest "*)
        f="${STUB_DIR}/reg/$(key "${2}")"
        [[ -f "${f}" ]] || { echo "MANIFEST_UNKNOWN: ${2}" >&2; exit 1; }
        cat "${f}"
        ;;
    "index filter")
        src="${3}" dst=""
        shift 3
        while [[ $# -gt 0 ]]; do
            [[ "${1}" == "-t" ]] && dst="${2}"
            shift
        done
        printf 'filter %s %s\n' "${src}" "${dst}" >>"${STUB_DIR}/calls"
        [[ -e "${STUB_DIR}/fail-filter-$(key "${src}")" ]] && { echo "toomanyrequests: Data limit exceeded" >&2; exit 1; }
        f="${STUB_DIR}/reg/$(key "${src}")"
        [[ -f "${f}" ]] || exit 1
        filter='.manifests |= [.[] | select(.platform.os == "linux" and (.platform.architecture == "amd64" or .platform.architecture == "arm64"))]'
        [[ -e "${STUB_DIR}/corrupt" ]] && filter="${filter} | .manifests[0].digest = \"sha256:bad\""
        jq "${filter}" "${f}" >"${STUB_DIR}/reg/$(key "${dst}")"
        ;;
    *)
        echo "stand-in crane: unexpected call: $*" >&2
        exit 99
        ;;
esac
STUB
chmod +x "${TMP}/crane"

# A Docker official-image index: two runnable platforms we keep, one we drop,
# and an attestation manifest.
index() {
    jq -n --arg amd "${1}" --arg arm "${2}" '{
        schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json",
        manifests: [
            {digest: $amd, platform: {os: "linux", architecture: "amd64"}},
            {digest: "sha256:att", platform: {os: "unknown", architecture: "unknown"}},
            {digest: $arm, platform: {os: "linux", architecture: "arm64", variant: "v8"}},
            {digest: "sha256:s390x", platform: {os: "linux", architecture: "s390x"}}
        ]}'
    return $?
}

# setup <case>: fresh registry with both sources holding a and b.
setup() {
    export STUB_DIR="${TMP}/${1}"
    mkdir -p "${STUB_DIR}/reg"
    : >"${STUB_DIR}/calls"
    local src
    for src in ecr hub; do
        index sha256:a-amd sha256:a-arm >"${STUB_DIR}/reg/${src}_lib_a_1"
        index sha256:b-amd sha256:b-arm >"${STUB_DIR}/reg/${src}_lib_b_1"
    done
    printf '# comment\na:1\n\nb:1  # trailing comment\n' >"${STUB_DIR}/list"
    return 0
}

run() {
    CRANE="${TMP}/crane" MIRROR_DEST=dst/m \
        MIRROR_SOURCES="ecr/lib hub/lib" bash "${SCRIPT}" "${STUB_DIR}/list" >"${STUB_DIR}/out" 2>&1
    return $?
}

dest_ok() {
    jq -e --arg amd "${2}" --arg arm "${3}" \
        '(.manifests | length) == 2 and .manifests[0].digest == $amd and .manifests[1].digest == $arm' \
        "${STUB_DIR}/reg/dst_m_${1}_1" >/dev/null 2>&1
    return $?
}

calls() { grep -c "${1}" "${STUB_DIR}/calls" || true; return 0; }

echo "case: fresh copy from the primary source"
setup fresh
if run && dest_ok a sha256:a-amd sha256:a-arm && dest_ok b sha256:b-amd sha256:b-arm \
    && [[ "$(calls '^filter ecr/lib/')" -eq 2 && "$(calls '^filter hub/')" -eq 0 ]]; then
    pass "both images copied from ecr, two platforms each"
else
    fail "fresh copy: $(cat "${STUB_DIR}/out")"
fi

echo "case: second run with nothing changed"
: >"${STUB_DIR}/calls"
if run && [[ "$(calls '^filter')" -eq 0 ]] && grep -q 'up to date' "${STUB_DIR}/out"; then
    pass "no copy when the destination already matches"
else
    fail "second run copied again or failed: $(cat "${STUB_DIR}/out")"
fi

echo "case: source moved on"
index sha256:a-amd2 sha256:a-arm2 >"${STUB_DIR}/reg/ecr_lib_a_1"
: >"${STUB_DIR}/calls"
if run && dest_ok a sha256:a-amd2 sha256:a-arm2 && [[ "$(calls '^filter ecr/lib/a:1')" -eq 1 ]]; then
    pass "a changed source index is copied again"
else
    fail "changed source: $(cat "${STUB_DIR}/out")"
fi

echo "case: primary source unreadable"
setup unreadable
rm "${STUB_DIR}/reg/ecr_lib_a_1"
if run && dest_ok a sha256:a-amd sha256:a-arm && [[ "$(calls '^filter hub/lib/a:1')" -eq 1 ]]; then
    pass "falls back to the second source for that image only"
else
    fail "unreadable primary: $(cat "${STUB_DIR}/out")"
fi
if [[ "$(calls '^filter ecr/lib/b:1')" -eq 1 ]]; then
    pass "the other image still comes from the primary"
else
    fail "image b did not come from ecr: $(cat "${STUB_DIR}/calls")"
fi

echo "case: copy from the primary throttled"
setup throttled
touch "${STUB_DIR}/fail-filter-ecr_lib_a_1"
if run && dest_ok a sha256:a-amd sha256:a-arm && [[ "$(calls '^filter hub/lib/a:1')" -eq 1 ]]; then
    pass "a failed copy falls back to the second source"
else
    fail "throttled copy: $(cat "${STUB_DIR}/out")"
fi

echo "case: copy does not match the source"
setup corrupt
touch "${STUB_DIR}/corrupt"
run
status=$?
if [[ "${status}" -eq 1 ]] && grep -q '::error::dst/m/a:1: platform digests differ' "${STUB_DIR}/out"; then
    pass "exit 1 with a digest error"
else
    fail "corrupt copy: exit ${status}: $(cat "${STUB_DIR}/out")"
fi
if [[ "$(calls '^filter ecr/lib/b:1')" -eq 1 ]] && grep -q '2 of 2 images failed' "${STUB_DIR}/out"; then
    pass "one failed image does not stop the next"
else
    fail "failure stopped the run: $(cat "${STUB_DIR}/out")"
fi

echo "case: source lost a platform"
setup noarm
for src in ecr hub; do
    jq '.manifests |= map(select(.platform.architecture != "arm64"))' "${STUB_DIR}/reg/${src}_lib_a_1" >"${STUB_DIR}/x"
    mv "${STUB_DIR}/x" "${STUB_DIR}/reg/${src}_lib_a_1"
done
run
status=$?
if [[ "${status}" -eq 1 ]] && grep -q '1 of 2 images failed: a:1' "${STUB_DIR}/out" \
    && [[ "$(calls '^filter ecr/lib/a:1')" -eq 0 ]]; then
    pass "exit 1, nothing copied for a single-platform source"
else
    fail "missing arm64: exit ${status}: $(cat "${STUB_DIR}/out")"
fi

echo "case: no source works"
setup nosource
rm "${STUB_DIR}/reg/ecr_lib_a_1" "${STUB_DIR}/reg/hub_lib_a_1"
run
status=$?
if [[ "${status}" -eq 1 ]] && grep -q '::error::dst/m/a:1: no source could be copied' "${STUB_DIR}/out"; then
    pass "exit 1 when every source fails"
else
    fail "no source: exit ${status}: $(cat "${STUB_DIR}/out")"
fi

echo "case: empty list"
setup empty
printf '# nothing\n\n' >"${STUB_DIR}/list"
run
status=$?
if [[ "${status}" -eq 1 ]]; then
    pass "exit 1 for a list without images"
else
    fail "empty list: exit ${status}"
fi

printf '%d checks passed\n' "${PASSED}"
[[ "${PASSED}" -eq 11 ]] || fail "expected 11 checks, ${PASSED} passed"
exit "${FAILED}"
