#!/usr/bin/env bash
#
# Copies the images named in a list file to a registry we control, as a
# two-platform index (linux/amd64, linux/arm64), and verifies the copy.
#
# The database images used to come from Docker Hub and then from ECR Public,
# and both throttle anonymous pulls per source IP: Docker Hub by pull count
# (2026-10-09), ECR Public by a data quota that shared GitHub runner IPs
# exhaust (`toomanyrequests: Data limit exceeded`, 2026-10-18). One scheduled
# job copying each image once a week stays far below either limit.
#
# Per image, the sources in MIRROR_SOURCES are tried in order. The first
# source whose index can be read and copied wins; the destination is then
# verified against that same source. An image is left alone when the
# destination already holds the source's platform manifests. A failed image
# does not stop the others; the script exits 1 at the end if any failed.
#
# Verification: the destination index must hold exactly two manifests, one
# linux/amd64 and one linux/arm64, and each digest must equal the source's
# platform manifest digest. The index digest itself differs from the source by
# construction, because the source index lists more platforms and the
# attestation manifests.
#
# Usage: mirror-ci-images.sh <list-file>
#
# Environment:
#   MIRROR_DEST     destination prefix (default ghcr.io/netresearch/ci-mirror)
#   MIRROR_SOURCES  space-separated source prefixes, tried in order
#                   (default "public.ecr.aws/docker/library docker.io/library")
#   CRANE           crane binary (default crane)

set -uo pipefail

[[ $# -eq 1 ]] || { printf 'usage: %s <list-file>\n' "${0}" >&2; exit 2; }
LIST="${1}"
[[ -f "${LIST}" ]] || { printf '%s: not found\n' "${LIST}" >&2; exit 2; }

MIRROR_DEST="${MIRROR_DEST:-ghcr.io/netresearch/ci-mirror}"
MIRROR_SOURCES="${MIRROR_SOURCES:-public.ecr.aws/docker/library docker.io/library}"
CRANE="${CRANE:-crane}"

# Prints "amd64 <digest>" and "arm64 <digest>" for an index, or fails when the
# reference cannot be read, is not an index, or does not list exactly one
# manifest per platform. With "exact" as second argument the index must list
# no other manifest either.
platform_digests() {
    local manifest
    manifest="$("${CRANE}" manifest "${1}")" || return 1
    jq -r --arg exact "${2:-}" '
        if (.manifests | type) != "array" then error("not an index") else . end
        | if $exact == "exact" and (.manifests | length) != 2
          then error("\(.manifests | length) manifests, expected 2") else . end
        | ("amd64", "arm64") as $arch
        | [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch)] as $m
        | if ($m | length) != 1
          then error("linux/\($arch): \($m | length) manifests, expected 1")
          else "\($arch) \($m[0].digest)" end
    ' <<<"${manifest}"
}

# Returns 0 when the image is mirrored and verified, 1 otherwise.
mirror_one() {
    local image="${1}" dest="${MIRROR_DEST}/${1}" prefix src want have
    for prefix in ${MIRROR_SOURCES}; do
        src="${prefix}/${image}"
        if ! want="$(platform_digests "${src}")"; then
            printf '::warning::%s: cannot read the source index; trying the next source\n' "${src}"
            continue
        fi
        if have="$(platform_digests "${dest}" exact 2>/dev/null)" && [[ "${have}" == "${want}" ]]; then
            printf '%s: up to date with %s\n' "${dest}" "${src}"
            return 0
        fi
        if ! "${CRANE}" index filter "${src}" --platform linux/amd64 --platform linux/arm64 -t "${dest}"; then
            printf '::warning::%s: copy from %s failed; trying the next source\n' "${dest}" "${src}"
            continue
        fi
        if ! have="$(platform_digests "${dest}" exact)"; then
            printf '::error::%s: the copy from %s is not a two-platform index\n' "${dest}" "${src}"
            return 1
        fi
        if [[ "${have}" != "${want}" ]]; then
            printf '::error::%s: platform digests differ from %s\n  source:      %s\n  destination: %s\n' \
                "${dest}" "${src}" "${want//$'\n'/, }" "${have//$'\n'/, }"
            return 1
        fi
        printf '%s: copied from %s and verified (%s)\n' "${dest}" "${src}" "${have//$'\n'/, }"
        return 0
    done
    printf '::error::%s: no source could be copied (%s)\n' "${dest}" "${MIRROR_SOURCES}"
    return 1
}

FAILED=()
COUNT=0
while IFS= read -r line <&3; do
    image="${line%%#*}"
    image="${image//[[:space:]]/}"
    [[ -n "${image}" ]] || continue
    COUNT=$((COUNT + 1))
    mirror_one "${image}" || FAILED+=("${image}")
done 3<"${LIST}"

if [[ "${COUNT}" -eq 0 ]]; then
    printf '::error::%s lists no image\n' "${LIST}"
    exit 1
fi
if [[ "${#FAILED[@]}" -gt 0 ]]; then
    printf '::error::%d of %d images failed: %s\n' "${#FAILED[@]}" "${COUNT}" "${FAILED[*]}"
    exit 1
fi
printf '%d images mirrored to %s\n' "${COUNT}" "${MIRROR_DEST}"
