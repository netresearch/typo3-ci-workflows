#!/usr/bin/env bash
#
# Checks the two steps of release-typo3-extension.yml that make a re-run on the
# tag safe once the GitHub release is created before the publication targets:
#
#   "Read the release state" (create-release) must tell a missing release, a
#   draft and a published release apart, and must fail on any other error
#   rather than report "absent" and create a second release.
#
#   "Write the publication status into the release body" (publication-status)
#   must replace only the text between the two markers, not add a second
#   section on a re-run, append the section when the markers were removed, and
#   insert the status text literally.
#
# Each step's own bash runs against a stand-in gh.
#
# Usage: check-release-publication-status.sh [path/to/release-typo3-extension.yml]

set -uo pipefail

WORKFLOW="${1:-.github/workflows/release-typo3-extension.yml}"
[[ -f "${WORKFLOW}" ]] || { printf 'not found: %s\n' "${WORKFLOW}" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FAILED=0

fail() { printf '  FAIL: %s\n' "${1}" >&2; FAILED=1; return 0; }
pass() { printf '  ok: %s\n' "${1}"; return 0; }

step_run() { # job, step name -> file
  yq ".jobs.\"${1}\".steps[] | select(.name == \"${2}\") | .run" "${WORKFLOW}" > "${3}"
  [[ -s "${3}" ]] || { printf 'step not found: %s / %s\n' "${1}" "${2}" >&2; exit 2; }
}

mkdir "${TMP}/bin"
cat > "${TMP}/bin/gh" <<'GH'
#!/usr/bin/env bash
# Stand-in for `gh release view` / `gh release edit`.
if [[ "$1 $2" == "release view" ]]; then
  case "${MODE:-store}" in
    absent) echo "release not found" >&2; exit 1 ;;
    draft) echo true; exit 0 ;;
    published) echo false; exit 0 ;;
    error) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
    store) cat "${STORE}"; exit 0 ;;
  esac
fi
if [[ "$1 $2" == "release edit" ]]; then
  while [[ $# -gt 0 ]]; do
    [[ "$1" == --notes-file ]] && cp "$2" "${STORE}"
    shift
  done
  exit 0
fi
echo "unexpected: gh $*" >&2
exit 2
GH
chmod +x "${TMP}/bin/gh"

printf 'Release state (%s)\n' "${WORKFLOW}"
step_run create-release "Read the release state" "${TMP}/state.sh"
for c in "absent:0:state=absent" "draft:0:state=draft" "published:0:state=published" "error:1:"; do
  IFS=: read -r mode want_rc want_out <<< "${c}"
  : > "${TMP}/out"
  (cd "${TMP}" && PATH="${TMP}/bin:${PATH}" MODE="${mode}" GITHUB_OUTPUT="${TMP}/out" \
    REPO=o/r TAG=v1.0.0 bash -e state.sh > /dev/null 2>&1)
  rc=$?
  got="$(cat "${TMP}/out")"
  if [[ "${rc}" == "${want_rc}" && "${got}" == "${want_out}" ]]; then
    pass "${mode}: exit ${rc}, '${got}'"
  else
    fail "${mode}: exit ${rc}, '${got}' (want exit ${want_rc}, '${want_out}')"
  fi
done

# The state only protects the release if the steps that upload assets read it.
printf 'Steps gated on the release state (%s)\n' "${WORKFLOW}"
for c in "Download dist artifact|steps.state.outputs.state != 'published'" \
         "Create GitHub Release (atomic, all assets)|steps.state.outputs.state == 'absent'" \
         "Complete and publish the release|steps.state.outputs.state != 'published'"; do
  step="${c%%|*}"
  want="${c#*|}"
  got="$(yq ".jobs.\"create-release\".steps[] | select(.name == \"${step}\") | .if" "${WORKFLOW}")"
  if [[ "${got}" == "${want}" ]]; then pass "${step}: if ${got}"; else fail "${step}: if '${got}' (want '${want}')"; fi
done

printf 'Publication status section (%s)\n' "${WORKFLOW}"
step_run publication-status "Write the publication status into the release body" "${TMP}/status.sh"
STORE="${TMP}/store.md"
write_status() {
  (cd "${TMP}" && PATH="${TMP}/bin:${PATH}" STORE="${STORE}" BLOCK="${1}" \
    REPO=o/r TAG=v1.0.0 bash -e status.sh > /dev/null)
}
has() {
  if grep -qF -- "${2}" "${STORE}"; then pass "${1}"; else fail "${1}"; fi
}
count() {
  local n
  n="$(grep -cF -- "${2}" "${STORE}" || true)"
  if [[ "${n}" == "${3}" ]]; then pass "${1} (${n})"; else fail "${1} (got ${n}, want ${3})"; fi
}
START='<!-- publication-status:start -->'
END='<!-- publication-status:end -->'

printf '## Changes\n- x\n\n%s\n## Publication status\n\nPending: ...\n%s\n\n## Security\nkeep me\n' \
  "${START}" "${END}" > "${STORE}"
write_status "${START}"$'\n- TER: failure\n'"${END}"
has "the result replaces the pending line" "- TER: failure"
count "no pending line left" "Pending:" 0
has "text after the section is kept" "keep me"

write_status "${START}"$'\n- TER: verified\n'"${END}"
count "a re-run leaves one section" "${START}" 1
has "a re-run writes the new result" "- TER: verified"
count "a re-run removes the old result" "- TER: failure" 0

printf 'Hand-written notes.\n' > "${STORE}"
write_status "${START}"$'\n- TER: failure\n'"${END}"
has "a body without markers keeps its text" "Hand-written notes."
count "a body without markers gets the section once" "${END}" 1

write_status "${START}"$'\n- a \\1 $& \\g<0>\n'"${END}"
has "the status text is inserted literally" '- a \1 $& \g<0>'

exit "${FAILED}"
