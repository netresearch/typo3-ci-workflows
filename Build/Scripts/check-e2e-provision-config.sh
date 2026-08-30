#!/usr/bin/env bash
#
# Assert that the config files e2e provisioning writes actually take effect.
#
# It exists because `additional.php` shipped as a file that RETURNS an array.
# TYPO3 does not read that return value: ConfigurationManager::exportConfiguration()
# `require`s the file for its side effects and throws the result away. So none
# of the debug settings applied — no devIPmask, no displayErrors, and above all
# neither exception handler — and the first consumer to hit an exception in a
# provisioned run got the production error page instead of the stack trace the
# provisioner is trying to arrange (netresearch/typo3-ci-workflows#229).
#
# The failure is invisible by inspection: the file is valid PHP either way, it
# parses, and shellcheck has nothing to say about a heredoc. So the check runs
# it — require the generated file and look at $GLOBALS afterwards, which is
# exactly what TYPO3 does with it.
#
# No container and no TYPO3: `php` is enough.

set -euo pipefail

PROVISION="${1:-assets/Build/Scripts/e2e-provision.sh}"
[[ -f "${PROVISION}" ]] || {
    echo "check-e2e-provision-config: no provisioner at ${PROVISION}" >&2
    exit 1
}

command -v php >/dev/null 2>&1 || {
    echo "check-e2e-provision-config: php is not on PATH" >&2
    exit 1
}

STATUS=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# The heredoc body, without its delimiters. `awk` rather than `sed -n` so the
# markers stay readable next to the ones in the provisioner.
awk '/<< .ADDITIONAL_EOF.$/{inside=1; next} /^ADDITIONAL_EOF$/{inside=0} inside' \
    "${PROVISION}" > "${WORK}/additional.php"

if [[ ! -s "${WORK}/additional.php" ]]; then
    echo "check-e2e-provision-config: found no ADDITIONAL_EOF heredoc in ${PROVISION}" >&2
    exit 1
fi

php -l "${WORK}/additional.php" >/dev/null || {
    echo "check-e2e-provision-config: the generated additional.php does not parse" >&2
    exit 1
}

# TYPO3 requires the file with TYPO3_CONF_VARS already populated, and keeps
# whatever the file leaves behind in that array. The class constant is not
# resolved here — Core is not loaded — so the assertions look at the keys that
# have to arrive, not at their values.
REQUIRED_KEYS=(
    "['SYS']['trustedHostsPattern']"
    "['SYS']['displayErrors']"
    "['SYS']['devIPmask']"
    "['SYS']['debugExceptionHandler']"
    "['SYS']['productionExceptionHandler']"
    "['BE']['debug']"
    "['FE']['debug']"
)

for key in "${REQUIRED_KEYS[@]}"; do
    if ! php -r "
        \$GLOBALS['TYPO3_CONF_VARS'] = [];
        require '${WORK}/additional.php';
        exit(isset(\$GLOBALS['TYPO3_CONF_VARS']${key}) ? 0 : 1);
    " 2>/dev/null; then
        echo "check-e2e-provision-config: additional.php leaves TYPO3_CONF_VARS${key} unset." >&2
        echo "    TYPO3 discards what this file returns — assign into \$GLOBALS instead." >&2
        STATUS=1
    fi
done

if [[ "${STATUS}" -eq 0 ]]; then
    echo "check-e2e-provision-config: additional.php populates TYPO3_CONF_VARS (${#REQUIRED_KEYS[@]} keys)."
fi

exit "${STATUS}"
