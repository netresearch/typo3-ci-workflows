#!/usr/bin/env bash
#
# Runs the TER upload-comment steps with their own bash against fixtures:
#
#   "Get release comment" (publish-to-ter.yml) must take the CHANGELOG section
#   of the released version under a level-1 or a level-2 heading, keep the
#   subsections of a level-1 section, stop at the next version, and not take
#   the section of a version that only starts with the released one (#274).
#
#   "Check TER accepts the upload comment" (publish-to-ter.yml) must pass a
#   comment the TER API answers with JSON, fail with a named error and set
#   `refused=true` for a comment that only a filter in front of the API
#   refuses, and only warn when even the neutral control text does not reach
#   the API or the answer is not a 403 (#273). A stand-in curl answers like
#   the measured endpoint: JSON for any text, an HTML 403 page for a text
#   containing "(be_user".
#
#   "Compose verification-evidence block" (release-typo3-extension.yml) must
#   not recommend a re-run on the tag when the comment was refused.
#
# Usage: check-ter-comment.sh publish-to-ter.yml release-typo3-extension.yml

set -uo pipefail

[[ $# -eq 2 ]] || { printf 'usage: %s publish-to-ter.yml release-typo3-extension.yml\n' "${0}" >&2; exit 2; }
PUBLISH="${1}"
RELEASE="${2}"
for f in "${PUBLISH}" "${RELEASE}"; do
    [[ -f "${f}" ]] || { printf '%s: not found\n' "${f}" >&2; exit 2; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FAILED=0
CASES=0
PASSED=0

fail() { printf '  FAIL: %s\n' "${1}" >&2; FAILED=1; return 0; }
pass() { printf '  ok: %s\n' "${1}"; PASSED=$((PASSED + 1)); return 0; }

# step_body WORKFLOW STEP FILE: the `run:` of the one step with that name.
step_body() {
    yq -o json '.jobs' "${1}" \
        | jq -r --arg s "${2}" '[.[].steps[]? | select(.name == $s) | .run] | if length == 1 then .[0] else error("expected exactly one step named \($s), found \(length)") end' \
        > "${3}"
    [[ -s "${3}" ]] || { printf '%s: no single step named %s\n' "${1}" "${2}" >&2; exit 2; }
    return 0
}

step_body "${PUBLISH}" 'Get release comment' "${TMP}/comment.sh"
step_body "${PUBLISH}" 'Check TER accepts the upload comment' "${TMP}/check.sh"
step_body "${RELEASE}" 'Compose verification-evidence block' "${TMP}/status.sh"

# output_value FILE NAME: the value of NAME in a GITHUB_OUTPUT file, for both
# the `name=value` and the `name<<DELIM` forms.
output_value() {
    python3 - "${1}" "${2}" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
name = sys.argv[2]
m = re.search(r'^' + re.escape(name) + r'<<(\S+)\n(.*?)\n\1$', text, re.M | re.S)
if m:
    sys.stdout.write(m.group(2))
else:
    m = re.search(r'^' + re.escape(name) + r'=(.*)$', text, re.M)
    if m:
        sys.stdout.write(m.group(1))
PY
}

# --- "Get release comment" -------------------------------------------------

# comment_for NAME VERSION: runs the step in a directory holding the fixture
# CHANGELOG NAME.md, with no tag and no release notes, and prints the comment.
comment_for() {
    local work="${TMP}/c-${1}"
    mkdir -p "${work}"
    cp "${TMP}/${1}.md" "${work}/CHANGELOG.md"
    : > "${work}/out"
    (cd "${work}" \
        && TAG='' VERSION="${2}" SERVER_URL='https://github.com' REPO='vendor/demo' \
           GH_TOKEN='' RELEASE_NOTES='' GITHUB_OUTPUT="${work}/out" \
           bash -e "${TMP}/comment.sh" >/dev/null 2>"${work}/err") \
        || { printf 'STEP FAILED: %s\n' "$(cat "${work}/err")"; return 0; }
    output_value "${work}/out" comment
    return 0
}

# expect_comment NAME VERSION MUST... -- MUST-NOT...
expect_comment() {
    local name="${1}" version="${2}" out needle missing=() unwanted=() mode=must
    shift 2
    CASES=$((CASES + 1))
    out="$(comment_for "${name}" "${version}")"
    for needle in "$@"; do
        if [[ "${needle}" == -- ]]; then mode=mustnot; continue; fi
        if [[ "${mode}" == must && "${out}" != *"${needle}"* ]]; then missing+=("${needle}"); fi
        if [[ "${mode}" == mustnot && "${out}" == *"${needle}"* ]]; then unwanted+=("${needle}"); fi
    done
    if [[ ${#missing[@]} -gt 0 || ${#unwanted[@]} -gt 0 ]]; then
        fail "${name} ${version}: missing [${missing[*]}] unwanted [${unwanted[*]}] in: ${out}"
    else
        pass "${name} ${version}: comment holds the version's section"
    fi
    return 0
}

# expect_source NAME VERSION SOURCE: the step's `source` output.
expect_source() {
    local got
    CASES=$((CASES + 1))
    comment_for "${1}" "${2}" >/dev/null
    got="$(output_value "${TMP}/c-${1}/out" source)"
    if [[ "${got}" == "${3}" ]]; then
        pass "${1} ${2}: source ${got}"
    else
        fail "${1} ${2}: source '${got}', expected '${3}'"
    fi
    return 0
}

cat > "${TMP}/level2.md" <<'MD'
# Changelog

## [Unreleased]

## [1.2.3] - 2026-10-01

### Fixed

- Level-two entry for 1.2.3

## [1.2.2] - 2026-09-01

- Entry for 1.2.2
MD

cat > "${TMP}/level1.md" <<'MD'
# 5.0.3

## Fixed

- Level-one entry for 5.0.3

## Security

- Second subsection of 5.0.3

# 5.0.2

- Entry for 5.0.2
MD

cat > "${TMP}/prefix.md" <<'MD'
## 1.2.30

- Entry for 1.2.30

## 1.2.3-rc1

- Entry for 1.2.3-rc1

## v1.2.3

- Entry for the real 1.2.3
MD

cat > "${TMP}/fence.md" <<'MD'
# 3.0.0

## Changed

```bash
# a shell comment inside a sample
composer update
```

- Entry after the sample

# 2.9.0

- Entry for 2.9.0
MD

cat > "${TMP}/none.md" <<'MD'
# Changelog

## [1.0.0] - 2026-01-01

- Entry for 1.0.0
MD

printf 'Get release comment (%s)\n' "${PUBLISH}"
expect_comment level2 1.2.3 'Level-two entry for 1.2.3' 'Fixed:' -- 'Entry for 1.2.2' 'Unreleased'
expect_comment level1 5.0.3 'Level-one entry for 5.0.3' 'Second subsection of 5.0.3' -- 'Entry for 5.0.2'
expect_comment prefix 1.2.3 'Entry for the real 1.2.3' -- 'Entry for 1.2.30' 'Entry for 1.2.3-rc1'
expect_comment none 2.0.0 'Released version 2.0.0' -- 'Entry for 1.0.0'
expect_comment fence 3.0.0 'a shell comment inside a sample' 'Entry after the sample' -- 'Entry for 2.9.0'
expect_source level2 1.2.3 changelog
expect_source none 2.0.0 default

# --- "Check TER accepts the upload comment" ---------------------------------

mkdir -p "${TMP}/bin"
# Stand-in curl: prints what `-w '%{http_code} %{content_type}'` would. The
# description field is read from the file named after `description=<`.
cat > "${TMP}/bin/curl" <<'CURL'
#!/usr/bin/env bash
desc=""
for arg in "$@"; do
    case "${arg}" in
        description=\<*) desc="$(cat "${arg#description=<}")" ;;
    esac
done
case "${TER_STUB:-api}" in
    down) printf '000 '; exit 7 ;;
    gateway) printf '502 text/html'; exit 0 ;;
esac
if [[ "${desc}" == *"(be_user"* ]]; then
    printf '%s' "${TER_STUB_REFUSED:-403 text/html}"
else
    printf '403 application/json; charset=utf-8'
fi
CURL
chmod +x "${TMP}/bin/curl"

# check_case NAME COMMENT [VAR=VALUE...]: runs the step; leaves status, output
# and GITHUB_OUTPUT in ${TMP}/k-NAME.
check_case() {
    local name="${1}" comment="${2}" work="${TMP}/k-${1}" status=0
    shift 2
    mkdir -p "${work}"
    : > "${work}/out"
    (cd "${work}" \
        && env SOURCE='changelog' "$@" PATH="${TMP}/bin:${PATH}" KEY='demo_ext' VERSION='1.2.3' COMMENT="${comment}" \
           TER_API_URL='https://ter.invalid/api/v1/extension' GITHUB_OUTPUT="${work}/out" \
           bash -e "${TMP}/check.sh" > "${work}/log" 2>&1) || status=$?
    printf '%s' "${status}" > "${work}/status"
    return 0
}

expect_check() { # NAME EXPECTED_STATUS EXPECTED_REFUSED LOG_NEEDLE
    local work="${TMP}/k-${1}" status refused
    CASES=$((CASES + 1))
    status="$(cat "${work}/status")"
    refused="$(output_value "${work}/out" refused)"
    if [[ "${status}" != "${2}" ]]; then
        fail "${1}: exit ${status}, expected ${2} — $(cat "${work}/log")"
    elif [[ "${refused}" != "${3}" ]]; then
        fail "${1}: refused='${refused}', expected '${3}'"
    elif ! grep -qF -- "${4}" "${work}/log"; then
        fail "${1}: log lacks '${4}' — $(cat "${work}/log")"
    else
        pass "${1}: exit ${status}, refused='${refused}'"
    fi
    return 0
}

printf 'Check TER accepts the upload comment (%s)\n' "${PUBLISH}"
check_case accepted 'Fixed: the backend module lists records.'
expect_check accepted 0 '' 'reaches the TER API'
check_case refused 'Restricts the query (be_users only).'
expect_check refused 1 'true' '::error title=TER refused the upload comment::'
check_case refused-at '@not-a-file (be_user'
expect_check refused-at 1 'true' '::error title=TER refused the upload comment::'
expect_check refused 1 'true' 'Reword the section and release a new version.'
check_case refused-body 'Restricts the query (be_users only).' SOURCE=release-body
expect_check refused-body 1 'true' 'Edit the GitHub release body instead and publish to TER again with republish.yml'
check_case refused-notes 'Restricts the query (be_users only).' SOURCE=release-notes
expect_check refused-notes 1 'true' 'Edit the GitHub release body instead and publish to TER again with republish.yml'
check_case unreachable 'Restricts the query (be_users only).' TER_STUB=down
expect_check unreachable 0 '' '::warning title=TER comment check skipped::'
check_case gateway 'Fixed: anything.' TER_STUB=gateway
expect_check gateway 0 '' '::warning title=TER comment check skipped::'
check_case other-status 'Restricts the query (be_users only).' TER_STUB_REFUSED='502 text/html'
expect_check other-status 0 '' '::warning title=TER comment check inconclusive::'

# --- "Compose verification-evidence block" ----------------------------------

status_line() { # TER_COMMENT_REFUSED value -> the TER line of the block
    local work="${TMP}/s-${1:-empty}"
    mkdir -p "${work}"
    : > "${work}/out"
    (cd "${work}" \
        && PACKAGE='vendor/demo' KEY='demo_ext' VERSION='1.2.3' TER_RESULT='failure' \
           TER_COMMENT_REFUSED="${1}" PKGST_RESULT='success' DOCS_RESULT='success' DOCS_DISPATCHED='true' \
           RUN_URL='https://github.com/vendor/demo/actions/runs/1' GITHUB_OUTPUT="${work}/out" \
           bash -e "${TMP}/status.sh" >/dev/null 2>&1) || { printf 'STEP FAILED'; return 0; }
    output_value "${work}/out" block | grep -F -- '- TER:'
    return 0
}

printf 'Compose verification-evidence block (%s)\n' "${RELEASE}"
CASES=$((CASES + 1))
line="$(status_line true)"
if [[ "${line}" == *"refused the upload comment"* && "${line}" == *"says how to correct it"* && "${line}" != *"to retry"* ]]; then
    pass "comment refused: no re-run advice"
else
    fail "comment refused: ${line}"
fi
CASES=$((CASES + 1))
line="$(status_line '')"
if [[ "${line}" == *"re-run the release workflow on the tag to retry"* ]]; then
    pass "other failure: re-run advice kept"
else
    fail "other failure: ${line}"
fi

printf '%d cases, %d ok\n' "${CASES}" "${PASSED}"
exit "${FAILED}"
