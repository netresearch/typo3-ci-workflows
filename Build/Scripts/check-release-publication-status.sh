#!/usr/bin/env bash
#
# Checks the steps of release-typo3-extension.yml that make a re-run on the tag
# safe once the GitHub release is created before the publication targets:
#
#   "Read the release state" (create-release) must tell a missing release, a
#   draft and a published release apart, and must fail on any other error
#   rather than report "absent" and create a second release.
#
#   The upload steps of create-release must be gated on that state, so a
#   published (immutable) release is never uploaded to.
#
#   "Complete and publish the release" must replace every asset of a draft
#   left by an earlier run with this build's set, keep the assets of a draft
#   this run created, and publish with the make-latest input.
#
#   "Write the publication status into the release body" (publication-status)
#   must replace only the text between the two markers, not add a second
#   section on a re-run, append the section when both markers were removed,
#   fail on an unpaired marker, insert the status text literally, and fail
#   when the stored body is not the body it sent.
#
# Each step's own bash runs against a stand-in gh that keeps the release in a
# directory: body, draft flag, the latest flag of the last edit, and one line
# per asset naming the build it came from.
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
cat > "${TMP}/bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
exit 0
SLEEP
cat > "${TMP}/bin/gh" <<'GH'
#!/usr/bin/env bash
# Stand-in for the `gh release` subcommands the steps use.
# MODE absent|draft|published|error answers the state step; MODE=store (default)
# answers from the release kept in ${RS}.
[[ "$1" == release ]] || { echo "unexpected: gh $*" >&2; exit 2; }
sub="$2"; shift 2
case "${sub}" in
  view)
    case "${MODE:-store}" in
      absent) echo "release not found" >&2; exit 1 ;;
      draft) echo true; exit 0 ;;
      published) echo false; exit 0 ;;
      error) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
    esac
    field=""
    while [[ $# -gt 0 ]]; do [[ "$1" == --json ]] && field="$2"; shift; done
    case "${field}" in
      body) cat "${RS}/body" ;;
      isDraft) cat "${RS}/draft" ;;
      assets) cut -f1 "${RS}/assets" ;;
      *) echo "unexpected view field: ${field}" >&2; exit 2 ;;
    esac
    ;;
  edit)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --notes-file) [[ "${DROP_EDIT:-0}" == 1 ]] || cp "$2" "${RS}/body" ;;
        --draft=false) echo false > "${RS}/draft" ;;
        --latest=*) echo "${1#--latest=}" > "${RS}/latest" ;;
      esac
      shift
    done
    ;;
  delete-asset)
    name="$2"
    grep -v -P "^\Q${name}\E\t" "${RS}/assets" > "${RS}/assets.new" || true
    mv "${RS}/assets.new" "${RS}/assets"
    ;;
  upload)
    name="$(basename "$2")"
    grep -v -P "^\Q${name}\E\t" "${RS}/assets" > "${RS}/assets.new" || true
    printf '%s\t%s\n' "${name}" "${BUILD}" >> "${RS}/assets.new"
    mv "${RS}/assets.new" "${RS}/assets"
    ;;
  *) echo "unexpected: gh release ${sub} $*" >&2; exit 2 ;;
esac
GH
chmod +x "${TMP}/bin/gh" "${TMP}/bin/sleep"
RS="${TMP}/release"
mkdir "${RS}"

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

printf 'Completing a draft (%s)\n' "${WORKFLOW}"
step_run create-release "Complete and publish the release" "${TMP}/complete.sh"
mkdir -p "${TMP}/dist"
for f in ext-1.0.0.zip ext-1.0.0.zip.sigstore.json ext-1.0.0.sbom.spdx.json checksums.txt; do
  echo "${f}" > "${TMP}/dist/${f}"
done
# complete and fails are called through holds, which shellcheck does not follow.
# shellcheck disable=SC2329
complete() { # state, make-latest
  (cd "${TMP}" && PATH="${TMP}/bin:${PATH}" RS="${RS}" BUILD=current STATE="${1}" \
    MAKE_LATEST="${2}" ATTEMPTS=4 REPO=o/r TAG=v1.0.0 bash -e complete.sh > /dev/null 2> "${TMP}/complete.err")
}
# shellcheck disable=SC2329
fails() { ! "$@"; }
holds() { # description, command...
  local what="${1}"
  shift
  if "$@"; then pass "${what}"; else fail "${what}"; fi
}
expected_assets="$(find "${TMP}/dist" -maxdepth 1 -type f -printf '%f\n' | sort | paste -sd' ')"

# A draft left by an earlier run: two assets from the old build, one stray name.
printf 'ext-1.0.0.zip\told\nchecksums.txt\told\nstray.txt\told\n' > "${RS}/assets"
echo true > "${RS}/draft"
rm -f "${RS}/latest"
holds "earlier draft: completion step exits 0" complete draft false
holds "earlier draft: every asset comes from this build" \
  test "$(cut -f2 "${RS}/assets" | sort -u)" = current
holds "earlier draft: the asset set equals this build's dist/" \
  test "$(cut -f1 "${RS}/assets" | sort | paste -sd' ')" = "${expected_assets}"
holds "earlier draft: published" test "$(cat "${RS}/draft")" = false
holds "earlier draft: make-latest false is passed on" test "$(cat "${RS}/latest" 2> /dev/null)" = false

# A draft this run created (softprops died mid-upload): its assets are kept.
printf 'ext-1.0.0.zip\tsame-run\n' > "${RS}/assets"
echo true > "${RS}/draft"
holds "same-run draft: completion step exits 0" complete absent true
holds "same-run draft: an uploaded asset is not replaced" \
  grep -qP '^ext-1\.0\.0\.zip\tsame-run$' "${RS}/assets"
holds "same-run draft: the missing assets are added" test "$(wc -l < "${RS}/assets")" -eq 4

printf 'Publication status section (%s)\n' "${WORKFLOW}"
step_run publication-status "Write the publication status into the release body" "${TMP}/status.sh"
STORE="${RS}/body"
write_status() { # block [DROP_EDIT]
  (cd "${TMP}" && PATH="${TMP}/bin:${PATH}" RS="${RS}" BLOCK="${1}" DROP_EDIT="${2:-0}" \
    REPO=o/r TAG=v1.0.0 bash -e status.sh > /dev/null 2>&1)
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

# Only the start marker left: matching it to a new end marker would delete
# everything in between. The step must refuse and leave the body alone.
printf '%s\n- old\n\n## Security\nkeep me\n' "${START}" > "${STORE}"
cp "${STORE}" "${TMP}/before.md"
holds "an unpaired marker fails the step" \
  fails write_status "${START}"$'\n- TER: verified\n'"${END}"
holds "an unpaired marker leaves the body unchanged" cmp -s "${STORE}" "${TMP}/before.md"

# An edit the API accepted but did not store must fail the step.
printf 'Notes.\n' > "${STORE}"
holds "a body that was not stored fails the read-back" \
  fails write_status "${START}"$'\n- TER: verified\n'"${END}" 1

exit "${FAILED}"
