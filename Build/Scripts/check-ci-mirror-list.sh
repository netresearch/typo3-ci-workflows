#!/usr/bin/env bash
#
# Compares Build/ci-mirror-images.txt with the images the shared workflows and
# scripts can request, and fails on an image the mirror misses (a job would
# pull a tag that does not exist) or on an entry nothing requests any more.
#
# What is requested, read from the code rather than restated here:
#   - the db-image default of ci.yml and of e2e.yml (yq)
#   - the E2E_MARIADB_IMAGE default of e2e-provision.sh
#   - runTests.sh: the version allow-list of each `-d mariadb|mysql|postgres`
#     case branch (postgres tags carry `-alpine`) and the IMAGE_ALPINE tag
#
# A default must carry one of the two prefixes the mirror replaces or serves,
# public.ecr.aws/docker/library/ or ghcr.io/netresearch/ci-mirror/; anything
# else is reported, so the check cannot pass on a default it did not parse.
#
# Usage: check-ci-mirror-list.sh <list> <ci.yml> <e2e.yml> <e2e-provision.sh> <runTests.sh>

set -uo pipefail

[[ $# -eq 5 ]] || {
    printf 'usage: %s <list> <ci.yml> <e2e.yml> <e2e-provision.sh> <runTests.sh>\n' "${0}" >&2
    exit 2
}
LIST="${1}" CI="${2}" E2E="${3}" PROVISION="${4}" RUNTESTS="${5}"
for f in "$@"; do
    [[ -f "${f}" ]] || { printf '%s: not found\n' "${f}" >&2; exit 1; }
done

FAILED=0
REQUIRED=()

# strip_prefix <origin> <ref>: appends <name>:<tag> to REQUIRED.
strip_prefix() {
    local ref="${2}"
    case "${ref}" in
        public.ecr.aws/docker/library/*) REQUIRED+=("${ref#public.ecr.aws/docker/library/}") ;;
        ghcr.io/netresearch/ci-mirror/*) REQUIRED+=("${ref#ghcr.io/netresearch/ci-mirror/}") ;;
        *)
            printf '::error::%s: default %s is neither public.ecr.aws/docker/library/ nor ghcr.io/netresearch/ci-mirror/\n' "${1}" "${ref:-<empty>}"
            FAILED=1
            ;;
    esac
}

for wf in "${CI}" "${E2E}"; do
    strip_prefix "${wf} db-image" "$(yq -r '.on.workflow_call.inputs.db-image.default' "${wf}")"
done

# shellcheck disable=SC2016 # a literal ${...} in the file is the match target
provision_default="$(sed -n 's/.*\${E2E_MARIADB_IMAGE:-\([^}]*\)}.*/\1/p' "${PROVISION}")"
strip_prefix "${PROVISION} E2E_MARIADB_IMAGE" "${provision_default}"

# One "<dbms> <version>|<version>…" line per case branch that validates
# DBMS_VERSION against an allow-list. A branch runs until the next word-only
# case label (`sqlite)`); `;;` does not end it, because the mariadb branch
# holds a nested case whose lines end in `;;` before its allow-list. The first
# allow-list per DBMS counts.
allow_lists="$(awk '
    /^[[:space:]]+[a-z]+\)[[:space:]]*$/ { dbms = $1; sub(/\)$/, "", dbms); next }
    dbms ~ /^(mariadb|mysql|postgres)$/ && !(dbms in seen) && match($0, /=~ \^\([^)]*\)\$/) {
        list = substr($0, RSTART + 5, RLENGTH - 7)
        print dbms, list
        seen[dbms] = 1
    }
' "${RUNTESTS}")"
for dbms in mariadb mysql postgres; do
    versions="$(awk -v d="${dbms}" '$1 == d { print $2 }' <<<"${allow_lists}")"
    if [[ -z "${versions}" ]]; then
        printf '::error::%s: no version allow-list found for -d %s\n' "${RUNTESTS}" "${dbms}"
        FAILED=1
        continue
    fi
    IFS='|' read -r -a vs <<<"${versions}"
    for v in "${vs[@]}"; do
        if [[ "${dbms}" == postgres ]]; then
            REQUIRED+=("postgres:${v}-alpine")
        else
            REQUIRED+=("${dbms}:${v}")
        fi
    done
done

# shellcheck disable=SC2016 # a literal ${...} in the file is the match target
alpine="$(sed -n 's/^IMAGE_ALPINE="\${LIBRARY_IMAGE_PREFIX}\(alpine:[^"]*\)"$/\1/p' "${RUNTESTS}")"
if [[ -n "${alpine}" ]]; then
    REQUIRED+=("${alpine}")
else
    printf '::error::%s: IMAGE_ALPINE not found\n' "${RUNTESTS}"
    FAILED=1
fi

LISTED=()
while IFS= read -r line; do
    image="${line%%#*}"
    image="${image//[[:space:]]/}"
    [[ -n "${image}" ]] && LISTED+=("${image}")
done <"${LIST}"

required_sorted="$(printf '%s\n' "${REQUIRED[@]}" | sort -u)"
listed_sorted="$(printf '%s\n' "${LISTED[@]}" | sort -u)"

while IFS= read -r image; do
    [[ -n "${image}" ]] || continue
    printf '::error::%s: %s is requested by the code but not mirrored\n' "${LIST}" "${image}"
    FAILED=1
done < <(comm -23 <(printf '%s\n' "${required_sorted}") <(printf '%s\n' "${listed_sorted}"))

while IFS= read -r image; do
    [[ -n "${image}" ]] || continue
    printf '::error::%s: %s is mirrored but nothing requests it\n' "${LIST}" "${image}"
    FAILED=1
done < <(comm -13 <(printf '%s\n' "${required_sorted}") <(printf '%s\n' "${listed_sorted}"))

if [[ "${FAILED}" -eq 0 ]]; then
    printf 'mirror list matches the %d images the code requests\n' "$(wc -l <<<"${required_sorted}")"
fi
exit "${FAILED}"
