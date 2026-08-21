#!/usr/bin/env bash
#
# Assert the shipped runner defines every value its suites then use.
#
# It exists because v1.7.0 shipped without IMAGE_PLAYWRIGHT: a block rewrite
# dropped the definition, the reference stayed, and `-s e2e` ran
# `docker run … ""`, dying with "invalid reference format" in every consuming
# extension. Nothing caught it — the file parses, shellcheck is clean at error
# severity, and no self-CI job runs a suite.
#
# Two checks, because the two failure modes are different:
#
#   1. static — a variable the script expands but never assigns. This is the
#      one that shipped, and it needs no container and no PHP to find.
#   2. dynamic — the detection block resolves to something usable against a
#      minimal extension. This is what a wrong default would break.

set -euo pipefail

RUNNER="${1:-assets/Build/Scripts/runTests.sh}"
[[ -f "${RUNNER}" ]] || { echo "check-runner-variables: no runner at ${RUNNER}" >&2; exit 1; }
RUNNER="$(cd "$(dirname "${RUNNER}")" && pwd)/$(basename "${RUNNER}")"

STATUS=0

# ── 1. every expanded variable is assigned somewhere ────────────────────────
# Provided by the shell, the environment, or the caller's command line.
EXTERNAL='^(PWD|HOME|RANDOM|BASH_SOURCE|OPTARG|OPTIND|OPT|CI|PATH|UID|EUID|HOSTNAME|TMPDIR|USER|SHLVL|PIPESTATUS|FUNCNAME|LINENO|IFS|RUNTESTS_PROJECT_ROOT|RUNTESTS_MODE|DBMS_VERSION_EXACT|XDG_[A-Z_]+|DOCKER_BIN|COMPOSER_[A-Z_]+|TYPO3_BASE_URL|E2E_CONTAINER_ARGS|npm_config_cache)$'

USED="$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*' "${RUNNER}" | sed 's/\${//' | sort -u)"
# An assignment counts wherever it stands: inside a case arm, after `local`,
# as the second of two on one line.
ASSIGNED="$(grep -oE '\b[A-Za-z_][A-Za-z0-9_]*=' "${RUNNER}" | sed 's/=$//' | sort -u)"
# `read -r a b` and `for x in …` also bind names.
BOUND="$(grep -oE '(read -r|for)[[:space:]]+[A-Za-z_ ]+' "${RUNNER}" | sed 's/^\(read -r\|for\)[[:space:]]*//' | tr ' ' '\n' | sort -u)"

while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    [[ "${name}" =~ ${EXTERNAL} ]] && continue
    printf '%s\n' "${ASSIGNED}" | grep -qx "${name}" && continue
    printf '%s\n' "${BOUND}" | grep -qx "${name}" && continue
    echo "FAIL: \${${name}} is expanded but never assigned in this script" >&2
    STATUS=1
done <<< "${USED}"

# ── 2. the detection block resolves against a minimal extension ─────────────
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

cat > "${WORK}/composer.json" <<'JSON'
{
    "name": "netresearch/check-runner-variables",
    "require": { "php": "^8.2" },
    "config": { "bin-dir": ".Build/bin", "vendor-dir": ".Build/vendor" },
    "extra": { "typo3/cms": { "extension-key": "check_runner_variables" } }
}
JSON

# Everything above "# Option defaults" is configuration and detection; below it
# lies option parsing, which expects a command line, and the images, which are
# built from the parsed options.
LINE="$(grep -n '^# Option defaults' "${RUNNER}" | head -n1 | cut -d: -f1)"
[[ -n "${LINE}" ]] || { echo "FAIL: the option-defaults marker is gone, so this check cannot bound the block" >&2; exit 1; }
head -n "$((LINE - 1))" "${RUNNER}" > "${WORK}/head.sh"

cd "${WORK}"
# shellcheck disable=SC1091  # generated above
source "${WORK}/head.sh"

require_set() {
    local name="${1}" value="${!1-}"
    if [[ -z "${value}" ]]; then
        echo "FAIL: ${name} ends up empty for a plain extension" >&2
        STATUS=1
    else
        echo "  ok: ${name}=${value}"
    fi
}

require_set BIN_DIR
require_set VENDOR_DIR
require_set DEFAULT_PHP_VERSION
require_set PROJECT_SLUG
require_set PROJECT_LABEL
require_set COMPOSER_ROOT_VERSION
require_set IMAGE_PLAYWRIGHT
require_set SUPPORTED_PHP_VERSIONS

exit "${STATUS}"
