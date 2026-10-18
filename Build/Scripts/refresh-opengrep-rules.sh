#!/usr/bin/env bash
#
# Rebuilds FILES and RULES_DIGEST of the step "Fetch the pinned Opengrep rules"
# in security.yml from the registry's current p/default rule set (what
# `--config auto` loads) and the two commits the step pins.
#
# For every rule of p/default it finds the one file at the pinned commits that
# defines it. It refuses to write when a rule is found in no file or in more
# than one, when a file it would list also defines rules outside p/default (the
# step selects whole files), or when p/default contains a rule from a source
# other than the two pinned repositories.
#
# Run it after Renovate moves SEMGREP_RULES_SHA or TRAILOFBITS_RULES_SHA, and to
# take up rules the registry has added to p/default. The diff of FILES shows
# which rule files enter or leave the gate; the script's last lines list the
# listed files whose content changed since the pins on origin/main, which no
# diff in this repository shows.
#
# Usage: refresh-opengrep-rules.sh .github/workflows/security.yml

set -euo pipefail

[[ $# -eq 1 ]] || { printf 'usage: %s security.yml\n' "${0}" >&2; exit 2; }
WORKFLOW="${1}"
STEP='Fetch the pinned Opengrep rules'
BEGIN='# BEGIN pinned rule files'
END='# END pinned rule files'
BUNDLE_URL='https://semgrep.dev/c/p/default'

die() { printf '%s\n' "${1}" >&2; exit 1; }
[[ -f "${WORKFLOW}" ]] || die "${WORKFLOW}: not found"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

env_of() {
    yq -r ".jobs.opengrep.steps[] | select(.name == \"${STEP}\") | .env.${1}" "${WORKFLOW}"
}
SEMGREP_SHA="$(env_of SEMGREP_RULES_SHA)"
TOB_SHA="$(env_of TRAILOFBITS_RULES_SHA)"
[[ "${SEMGREP_SHA}" =~ ^[0-9a-f]{40}$ ]] || die "${WORKFLOW}: no SEMGREP_RULES_SHA in '${STEP}'"
[[ "${TOB_SHA}" =~ ^[0-9a-f]{40}$ ]] || die "${WORKFLOW}: no TRAILOFBITS_RULES_SHA in '${STEP}'"
[[ "$(grep -c -F -- "${BEGIN}" "${WORKFLOW}")" == 1 && "$(grep -c -F -- "${END}" "${WORKFLOW}")" == 1 ]] \
    || die "${WORKFLOW}: expected one '${BEGIN}' and one '${END}' line"

printf 'Downloading %s\n' "${BUNDLE_URL}"
curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -D "${TMP}/bundle.headers" \
    -o "${TMP}/bundle.yaml" "${BUNDLE_URL}"
yq -r '.rules[].id' "${TMP}/bundle.yaml" | LC_ALL=C sort > "${TMP}/bundle.ids"
[[ -s "${TMP}/bundle.ids" ]] || die "${BUNDLE_URL}: no rules in the response"
[[ "$(uniq -d "${TMP}/bundle.ids" | wc -l)" == 0 ]] || die "${BUNDLE_URL}: duplicate rule ids"

fetch() {
    mkdir -p "${1}"
    git -C "${1}" init -q
    git -C "${1}" fetch -q --depth 1 "https://github.com/${2}.git" "${3}"
    git -C "${1}" -c advice.detachedHead=false checkout -q FETCH_HEAD
}

# on_branch KEY REPO SHA: the pin must be a commit of the branch its Renovate
# comment names (`currentValue=`), not just any object GitHub serves for the
# repository, which includes commits of forks.
on_branch() {
    local comment branch dir="${TMP}/branch-${1}"
    comment="$(grep -B 1 -E "^ +${1}: " "${WORKFLOW}" | head -n 1)"
    [[ "${comment}" == *"depName=https://github.com/${2} "* ]] \
        || die "${WORKFLOW}: the Renovate comment above ${1} does not name https://github.com/${2}"
    branch="$(printf '%s\n' "${comment}" | sed -n 's/.*currentValue=\([^ ]*\).*/\1/p')"
    [[ -n "${branch}" ]] || die "${WORKFLOW}: the Renovate comment above ${1} names no currentValue branch"
    git init -q "${dir}"
    git -C "${dir}" fetch -q --filter=tree:0 "https://github.com/${2}.git" "refs/heads/${branch}"
    git -C "${dir}" merge-base --is-ancestor "${3}" FETCH_HEAD 2>/dev/null \
        || die "${1} ${3} is not on branch ${branch} of ${2}"
    printf '%s %s is on branch %s of %s\n' "${1}" "${3}" "${branch}" "${2}"
    return 0
}
on_branch SEMGREP_RULES_SHA semgrep/semgrep-rules "${SEMGREP_SHA}"
on_branch TRAILOFBITS_RULES_SHA trailofbits/semgrep-rules "${TOB_SHA}"
printf 'Fetching semgrep/semgrep-rules %s and trailofbits/semgrep-rules %s\n' "${SEMGREP_SHA}" "${TOB_SHA}"
fetch "${TMP}/tree" semgrep/semgrep-rules "${SEMGREP_SHA}"
fetch "${TMP}/tree/trailofbits" trailofbits/semgrep-rules "${TOB_SHA}"

# Index every YAML file: one JSON line per file with its registry-style ids.
# Files that are not rule files (or not YAML yq can read) yield no ids.
# shellcheck disable=SC2016 # the $1 belongs to the inner sh, not to this shell
(cd "${TMP}/tree" && find . -path '*/.git' -prune -o -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 \
    | sed -z 's#^\./##' \
    | xargs -0 -n 1 -P 8 sh -c 'yq e -o json -I0 "{\"file\": filename, \"ids\": [(.rules // [])[] | select(has(\"id\")) | .id]}" "$1" 2>/dev/null || :' _) \
    > "${TMP}/index.ndjson"

jq -s --rawfile wanted "${TMP}/bundle.ids" '
    ($wanted | split("\n") | map(select(length > 0))) as $want
    | ($want | map({key: ., value: true}) | from_entries) as $in
    | [.[] | select(.ids | length > 0)
        | (.file | sub("\\.ya?ml$"; "") | split("/")) as $p
        | (($p[:-1] + [$p[-1] | ascii_downcase]) | join(".")) as $prefix
        | {file, ids: [.ids[] | $prefix + "." + .]}] as $files
    | ([$files[] | .file as $f | .ids[] | {id: ., file: $f}] | group_by(.id)
        | map({key: .[0].id, value: map(.file)}) | from_entries) as $where
    | ([$want[] | $where[.] // [] | select(length == 1) | .[0]] | unique) as $sel
    | {
        missing: [$want[] | select($where[.] == null)],
        ambiguous: [$want[] | select(($where[.] // []) | length > 1) | {id: ., files: $where[.]}],
        extra: [$files[] | select(.file | IN($sel[])) | {file, ids: [.ids[] | select($in[.] | not)]}
                | select(.ids | length > 0)],
        files: $sel
      }
' "${TMP}/index.ndjson" > "${TMP}/selection.json"

problems=0
report() {
    local n
    n="$(jq "${1} | length" "${TMP}/selection.json")"
    if [[ "${n}" != 0 ]]; then
        printf '%s (%s):\n' "${2}" "${n}" >&2
        jq -r "${1}[] | tostring" "${TMP}/selection.json" | sed 's/^/  /' >&2
        problems=1
    fi
    return 0
}
report '.missing' 'rules of p/default defined in no file at the pinned commits'
report '.ambiguous' 'rules of p/default defined in more than one file'
report '.extra' 'listed files that also define rules outside p/default'
[[ "${problems}" == 0 ]] || die "not written: the pinned commits do not reproduce p/default"

jq -r '.files[]' "${TMP}/selection.json" | LC_ALL=C sort > "${TMP}/files.txt"
COUNT="$(wc -l < "${TMP}/bundle.ids")"
DIGEST="$(sha256sum < "${TMP}/bundle.ids" | cut -d ' ' -f 1)"
ETAG="$(grep -i '^etag:' "${TMP}/bundle.headers" | tail -n 1 | tr -d '\r' | cut -d ' ' -f 2-)"

# Write FILES between the markers, with the markers' indentation, and the
# digest into RULES_DIGEST. Line-precise, so the rest of the file is unchanged.
INDENT="$(grep -F -- "${BEGIN}" "${WORKFLOW}" | sed 's/#.*//')"
awk -v begin="${BEGIN}" -v end="${END}" -v indent="${INDENT}" -v list="${TMP}/files.txt" '
    index($0, begin) { print; while ((getline line < list) > 0) print indent line; skip = 1; next }
    index($0, end) { skip = 0 }
    !skip { print }
' "${WORKFLOW}" > "${TMP}/workflow.yml"
sed -i -E "s/^( +RULES_DIGEST: ).*/\\1${DIGEST}/" "${TMP}/workflow.yml"
[[ "$(grep -c -E "^ +RULES_DIGEST: ${DIGEST}$" "${TMP}/workflow.yml")" == 1 ]] \
    || die "${WORKFLOW}: expected exactly one RULES_DIGEST line"
cat "${TMP}/workflow.yml" > "${WORKFLOW}"

printf 'p/default (ETag %s): %s rules in %s files, id digest %s\n' \
    "${ETAG:-none}" "${COUNT}" "$(wc -l < "${TMP}/files.txt")" "${DIGEST}"

# A changed rule keeps its id, so neither FILES nor RULES_DIGEST shows it, and
# the pull request's diff shows only the new commit id. List the listed rule
# files whose content differs between the previous pins (from PREVIOUS_REF,
# default origin/main; or PREVIOUS_SEMGREP_RULES_SHA and
# PREVIOUS_TRAILOFBITS_RULES_SHA) and the new ones, for the reviewer.
PREVIOUS_REF="${PREVIOUS_REF:-origin/main}"
previous_env() {
    git show "${PREVIOUS_REF}:${WORKFLOW}" 2>/dev/null \
        | yq -r ".jobs.opengrep.steps[] | select(.name == \"${STEP}\") | .env.${1}" 2>/dev/null
    return 0
}
OLD_SEMGREP_SHA="${PREVIOUS_SEMGREP_RULES_SHA:-$(previous_env SEMGREP_RULES_SHA)}"
OLD_TOB_SHA="${PREVIOUS_TRAILOFBITS_RULES_SHA:-$(previous_env TRAILOFBITS_RULES_SHA)}"

# changed_files LABEL DIR REPO OLD NEW PATH-PREFIX: the listed files of one
# repository whose content differs between OLD and NEW.
changed_files() {
    local label="${1}" dir="${2}" repo="${3}" old="${4}" new="${5}" prefix="${6}"
    if [[ ! "${old}" =~ ^[0-9a-f]{40}$ ]]; then
        printf '%s: no previous pin found at %s; content changes not listed\n' "${label}" "${PREVIOUS_REF}"
        return 0
    fi
    if [[ "${old}" == "${new}" ]]; then
        printf '%s: pin unchanged (%s)\n' "${label}" "${new}"
        return 0
    fi
    git -C "${dir}" fetch -q --depth 1 "https://github.com/${repo}.git" "${old}"
    printf '%s: listed rule files changed from %s to %s:\n' "${label}" "${old}" "${new}"
    if [[ -n "${prefix}" ]]; then
        { grep "^${prefix}" "${TMP}/files.txt" || :; } | sed "s#^${prefix}##" > "${TMP}/listed.${label}"
    else
        grep -v '^trailofbits/' "${TMP}/files.txt" > "${TMP}/listed.${label}" || :
    fi
    xargs -a "${TMP}/listed.${label}" git -C "${dir}" diff --stat=200 "${old}" "${new}" -- \
        | sed 's/^/  /'
    return 0
}
changed_files semgrep-rules "${TMP}/tree" semgrep/semgrep-rules "${OLD_SEMGREP_SHA}" "${SEMGREP_SHA}" ''
changed_files trailofbits "${TMP}/tree/trailofbits" trailofbits/semgrep-rules "${OLD_TOB_SHA}" "${TOB_SHA}" 'trailofbits/'
