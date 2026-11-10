#!/usr/bin/env bash
#
# Checks that the runner makes the git directory resolvable inside its
# containers. In a git worktree `.git` is a file pointing outside the
# extension, and the containers mounted only the extension, so git failed in
# every container: a changelog check reported an existing tag as missing and
# captainhook/hook-installer aborted `composer install` with `invalid .git path`.
#
# The runner is executed against fixture repositories, with a stand-in `docker`
# first on PATH that records its arguments and starts nothing.
#
# Usage: check-runner-git-mount.sh [path/to/runTests.sh]

set -uo pipefail

RUNNER="${1:-assets/Build/Scripts/runTests.sh}"
[[ -f "${RUNNER}" ]] || { printf 'not found: %s\n' "${RUNNER}" >&2; exit 2; }
RUNNER="$(realpath "${RUNNER}")"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
TMP="$(realpath "${TMP}")"

FAILED=0

fail() { printf '  FAIL: %s\n' "${1}" >&2; FAILED=1; return 0; }
pass() { printf '  ok: %s\n' "${1}"; return 0; }

mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_LOG}"
exit 0
STUB
chmod +x "${TMP}/bin/docker"

git_quiet() { git -c init.defaultBranch=main -c user.name=check -c user.email=check@example.invalid -c commit.gpgsign=false "$@" >/dev/null 2>&1; }

# A plain clone, and a bare repository with a worktree — the layout this fleet
# works in.
PLAIN="${TMP}/plain"
mkdir -p "${PLAIN}"
printf '{"name":"netresearch/fixture-git","require":{"php":"^8.2"},"extra":{"typo3/cms":{"extension-key":"fixture"}}}\n' \
    > "${PLAIN}/composer.json"
git_quiet init "${PLAIN}"
git_quiet -C "${PLAIN}" add composer.json
git_quiet -C "${PLAIN}" commit -m fixture
git_quiet clone --bare "${PLAIN}" "${TMP}/layout/.bare"
git_quiet -C "${TMP}/layout/.bare" worktree add "${TMP}/layout/feature" -b feature
WORKTREE="${TMP}/layout/feature"
COMMON="${TMP}/layout/.bare"

[[ -f "${WORKTREE}/.git" ]] || { printf 'fixture: %s/.git is not a file\n' "${WORKTREE}" >&2; exit 2; }

# Prints the arguments of the first `docker run`.
run_args() {
    local root="${1}" log
    log="${TMP}/$(basename "${1}").log"
    : > "${log}"
    (
        cd "${root}" || exit 1
        PATH="${TMP}/bin:${PATH}" STUB_LOG="${log}" "${RUNNER}" -b docker -s composerValidate </dev/null >/dev/null 2>&1
    )
    awk '$1 == "run" { print; exit }' "${log}"
}

printf 'Git directory mounts (%s)\n' "${RUNNER#"$(pwd)/"}"

args="$(run_args "${WORKTREE}")"
if [[ -z "${args}" ]]; then
    fail "worktree: no container was started — the case never reached the point under test"
elif [[ " ${args} " == *" -v ${COMMON}:${COMMON} "* ]]; then
    pass "worktree: the shared git directory is mounted at its own path"
else
    fail "worktree: ${COMMON} is not mounted: ${args}"
fi

args="$(run_args "${PLAIN}")"
if [[ -z "${args}" ]]; then
    fail "plain clone: no container was started — the case never reached the point under test"
elif [[ "$(grep -o -- ' -v ' <<< " ${args} " | wc -l)" -eq 1 ]]; then
    pass "plain clone: only the extension is mounted"
else
    fail "plain clone: unexpected extra mount: ${args}"
fi

exit "${FAILED}"
