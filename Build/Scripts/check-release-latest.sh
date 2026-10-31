#!/usr/bin/env bash
#
# Checks "Decide whether this release becomes Latest", the step that keeps a
# maintenance release of an older major line from taking the repository's
# "Latest" badge. It runs in release-typo3-extension.yml (job create-release)
# and in release.yml (job release); both copies must be identical, and both
# release calls must read its output rather than the make-latest input.
#
# The step's own bash runs against a stand-in gh whose `api` subcommand applies
# the step's --jq filter to a fixture release list, so the draft and
# prerelease filter is exercised too.
#
# Usage: check-release-latest.sh [release-typo3-extension.yml] [release.yml]

set -uo pipefail

EXTENSION_WORKFLOW="${1:-.github/workflows/release-typo3-extension.yml}"
GENERIC_WORKFLOW="${2:-.github/workflows/release.yml}"
STEP='Decide whether this release becomes Latest'
for f in "${EXTENSION_WORKFLOW}" "${GENERIC_WORKFLOW}"; do
  [[ -f "${f}" ]] || { printf 'not found: %s\n' "${f}" >&2; exit 2; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FAILED=0

fail() { printf '  FAIL: %s\n' "${1}" >&2; FAILED=1; return 0; }
pass() { printf '  ok: %s\n' "${1}"; return 0; }
check() { # description, got, want
  if [[ "${2}" == "${3}" ]]; then pass "${1}"; else fail "${1}: got '${2}', want '${3}'"; fi
  return 0
}
step_field() { # workflow, job, field
  yq ".jobs.\"${2}\".steps[] | select(.name == \"${STEP}\") | ${3}" "${1}"
}

step_field "${EXTENSION_WORKFLOW}" create-release .run > "${TMP}/latest.sh"
step_field "${GENERIC_WORKFLOW}" release .run > "${TMP}/generic.sh"
[[ -s "${TMP}/latest.sh" ]] || { printf 'step not found in %s\n' "${EXTENSION_WORKFLOW}" >&2; exit 2; }
[[ -s "${TMP}/generic.sh" ]] || { printf 'step not found in %s\n' "${GENERIC_WORKFLOW}" >&2; exit 2; }

mkdir "${TMP}/bin"
cat > "${TMP}/bin/gh" <<'GH'
#!/usr/bin/env bash
# Stand-in for `gh api --paginate <path> --jq <filter>`: applies the filter to
# ${RELEASES} (a JSON array), or fails like an API error when MODE=error.
[[ "$1" == api ]] || { echo "unexpected: gh $*" >&2; exit 2; }
echo called >> "${CALLS}"
[[ "${MODE:-ok}" == error ]] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
filter=""
while [[ $# -gt 0 ]]; do [[ "$1" == --jq ]] && filter="$2"; shift; done
[[ -n "${filter}" ]] || { echo "no --jq filter" >&2; exit 2; }
jq -r "${filter}" <<< "${RELEASES}"
GH
chmod +x "${TMP}/bin/gh"

# releases: space-separated entries tag[:draft|:pre]
releases_json() {
  local entry tag kind out="[]"
  for entry in ${1}; do
    tag="${entry%%:*}"
    kind=""
    [[ "${entry}" == *:* ]] && kind="${entry#*:}"
    out="$(jq -c --arg t "${tag}" --arg k "${kind}" \
      '. + [{tag_name: $t, draft: ($k == "draft"), prerelease: ($k == "pre")}]' <<< "${out}")"
  done
  printf '%s' "${out}"
}

decide() { # script, tag, make-latest, releases, [mode] -> "<exit> <latest> <api calls>"
  : > "${TMP}/out"
  : > "${TMP}/calls"
  (cd "${TMP}" && PATH="${TMP}/bin:${PATH}" GITHUB_OUTPUT="${TMP}/out" CALLS="${TMP}/calls" \
    RELEASES="$(releases_json "${4}")" MODE="${5:-ok}" REPO=o/r TAG="${2}" MAKE_LATEST="${3}" \
    bash -e "${1}" > /dev/null 2>&1)
  local rc=$?
  printf '%s %s %s' "${rc}" "$(sed -n 's/^latest=//p' "${TMP}/out")" "$(wc -l < "${TMP}/calls")"
  return 0
}

# GitHub expressions, compared as literal text.
# shellcheck disable=SC2016
WANT_INPUT='${{ inputs.make-latest }}'
# shellcheck disable=SC2016
WANT_TAG='${{ github.ref_name }}'
# shellcheck disable=SC2016
WANT_DECISION='${{ steps.latest.outputs.latest }}'

printf 'Both copies of the step (%s, %s)\n' "${EXTENSION_WORKFLOW}" "${GENERIC_WORKFLOW}"
if cmp -s "${TMP}/latest.sh" "${TMP}/generic.sh"; then
  pass "the run scripts are identical"
else
  fail "the run scripts differ:"
  diff "${TMP}/latest.sh" "${TMP}/generic.sh" >&2
fi
for f in "${EXTENSION_WORKFLOW}:create-release" "${GENERIC_WORKFLOW}:release"; do
  wf="${f%:*}"
  job="${f##*:}"
  check "${wf}: the step's output is named latest" "$(step_field "${wf}" "${job}" .id)" latest
  check "${wf}: the step reads the make-latest input" \
    "$(step_field "${wf}" "${job}" .env.MAKE_LATEST)" "${WANT_INPUT}"
  check "${wf}: the step reads the pushed tag" "$(step_field "${wf}" "${job}" .env.TAG)" "${WANT_TAG}"
  check "${wf}: the release call takes the step's decision" \
    "$(yq ".jobs.\"${job}\".steps[] | select(.uses == \"softprops/action-gh-release*\") | .with.make_latest" "${wf}")" \
    "${WANT_DECISION}"
done
check "${EXTENSION_WORKFLOW}: the draft completion takes the step's decision" \
  "$(yq '.jobs."create-release".steps[] | select(.name == "Complete and publish the release") | .env.MAKE_LATEST' "${EXTENSION_WORKFLOW}")" \
  "${WANT_DECISION}"
# The completion step runs for absent and draft, so the decision must too.
check "${EXTENSION_WORKFLOW}: the step runs whenever the completion step runs" \
  "$(step_field "${EXTENSION_WORKFLOW}" create-release .if)" \
  "$(yq '.jobs."create-release".steps[] | select(.name == "Complete and publish the release") | .if' "${EXTENSION_WORKFLOW}")"
if grep -qF "make_latest: ${WANT_INPUT}" "${EXTENSION_WORKFLOW}" "${GENERIC_WORKFLOW}"; then
  fail "a release call still reads the make-latest input directly"
else
  pass "no release call reads the make-latest input directly"
fi

printf 'Decisions (%s)\n' "${EXTENSION_WORKFLOW}"
S="${TMP}/latest.sh"
TEXTDB='v4.1.0 v4.0.2 v4.0.1 v3.0.5 v2.0.12 v4.0.0 v3.0.4 3.0.0 2.0.0'
# description | tag | make-latest | releases | mode | want "<exit> <latest> <api calls>"
while IFS='|' read -r what tag input rel mode want; do
  [[ -n "${what}" ]] || continue
  check "${what}" "$(decide "${S}" "${tag}" "${input}" "${rel}" "${mode}")" "${want}"
done <<CASES
maintenance release below the main line (textdb v3.0.6)|v3.0.6|true|${TEXTDB}|ok|0 false 1
next release of the main line|v4.1.1|true|${TEXTDB}|ok|0 true 1
new major|v5.0.0|true|${TEXTDB}|ok|0 true 1
oldest line still maintained|v2.0.13|true|${TEXTDB}|ok|0 false 1
first release of a repository|v1.0.0|true||ok|0 true 1
single line, next patch|v1.2.4|true|v1.2.3 v1.2.2 v1.1.0|ok|0 true 1
tag without v below a higher v tag|3.0.6|true|v4.0.0 3.0.5|ok|0 false 1
v tag above higher-looking tags without v|v4.0.1|true|4.0.0 3.9.9|ok|0 true 1
v tag below a higher tag without v|v3.0.6|true|4.0.0 v3.0.5|ok|0 false 1
numeric, not lexical: 10 above 9|v10.0.0|true|v9.9.9 v9.10.0|ok|0 true 1
numeric, not lexical: 9.9.10 below 10.0.0|v9.9.10|true|v10.0.0 v9.9.9|ok|0 false 1
minor and patch compared numerically|v13.10.4|true|v13.9.1 v13.10.3 v12.0.14|ok|0 true 1
a higher draft does not count|v4.1.1|true|v5.0.0:draft v4.1.0|ok|0 true 1
a higher prerelease does not count|v4.1.1|true|v5.0.0:pre v4.1.0|ok|0 true 1
non-version release tags are ignored|v1.0.1|true|nightly v1.0.0 latest|ok|0 true 1
a re-run on a version already published|v4.1.0|true|${TEXTDB}|ok|0 true 1
make-latest false: never Latest, no API call|v5.0.0|false|${TEXTDB}|ok|0 false 0
make-latest false wins over an API error|v5.0.0|false|${TEXTDB}|error|0 false 0
API error: not Latest, release not failed|v5.0.0|true|${TEXTDB}|error|0 false 1
tag that is not X.Y.Z: not Latest, no API call|v5.0.0-rc1|true|${TEXTDB}|ok|0 false 0
CASES

exit "${FAILED}"
