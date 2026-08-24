#!/usr/bin/env bash
#
# Checks what the shared runner derives, against fixture extensions built for
# the cases that broke it. Each case below shipped once.
#
#   1. runTests.conf was sourced AFTER detection, so pointing
#      PHPUNIT_FUNCTIONAL_CONFIG at another file still derived testsuite names
#      and shard directories from the file detection had found.
#   2. The testsuites block was delimited with `</testsuites?>`, which also
#      matches `</testsuite>` — a testsuite written on one line yielded zero
#      directories and fell back to Tests/Functional, putting whole suites in
#      no job while the run still read as covered.
#   3. The sharded run had no --exclude-group, so a test marked not-sqlite ran
#      on sqlite. Adding it alone is not the fix twice over: the sharded path
#      runs one file per phpunit call, and a fully excluded file exits 1 — and
#      the group cannot come from ${DBMS}, because this path pins pdo_sqlite
#      whatever -d said.
#
# Usage: check-runner-detection.sh [path/to/runTests.sh]

set -uo pipefail

RUNNER="${1:-assets/Build/Scripts/runTests.sh}"
[[ -f "${RUNNER}" ]] || { printf 'not found: %s\n' "${RUNNER}" >&2; exit 2; }
RUNNER="$(realpath "${RUNNER}")"

FIXTURES="$(mktemp -d)"
trap 'rm -rf "${FIXTURES}"' EXIT

FAILED=0

fail() { printf '  FAIL: %s\n' "${1}" >&2; FAILED=1; }
pass() { printf '  ok: %s\n' "${1}"; }

# Builds an extension whose functional config lives at ${2} and declares two
# testsuites, written multi-line (${3} = multi) or on one line (${3} = inline).
make_fixture() {
    local root="${FIXTURES}/${1}" config="${2}" shape="${3}" depth
    mkdir -p "${root}/$(dirname "${config}")" "${root}/Build/Scripts"
    printf '{"name":"netresearch/fixture-%s","require":{"php":"^8.2"},"extra":{"typo3/cms":{"extension-key":"fixture"}}}\n' \
        "${1}" > "${root}/composer.json"

    # ../ per path segment, so the config points back at the extension root.
    depth="$(printf '%s' "$(dirname "${config}")" | tr -cd '/' | wc -c)"
    local up="" i
    for ((i = 0; i <= depth; i++)); do up+="../"; done

    {
        printf '<phpunit>\n  <testsuites>\n'
        if [[ "${shape}" == inline ]]; then
            printf '    <testsuite name="functional"><directory>%sTests/Functional</directory></testsuite>\n' "${up}"
            printf '    <testsuite name="e2e-tca"><directory>%sTests/E2E/TCA</directory></testsuite>\n' "${up}"
        else
            printf '    <testsuite name="functional">\n      <directory>%sTests/Functional</directory>\n    </testsuite>\n' "${up}"
            printf '    <testsuite name="e2e-tca">\n      <directory>%sTests/E2E/TCA</directory>\n    </testsuite>\n' "${up}"
        fi
        printf '  </testsuites>\n</phpunit>\n'
    } > "${root}/${config}"
    printf '%s' "${root}"
}

# Sources the runner's detection block — everything above `# Option defaults`,
# which is the last line that cannot start a container — inside the fixture and
# echoes one variable.
derive() {
    local root="${1}" var="${2}" line head
    line="$(grep -n '^# Option defaults' "${RUNNER}" | head -n1 | cut -d: -f1)"
    head="${FIXTURES}/head.sh"
    head -n "$((line - 1))" "${RUNNER}" > "${head}"
    (
        cd "${root}" || exit 1
        # shellcheck disable=SC1090  # generated above from the runner under test
        source "${head}" >/dev/null 2>&1
        printf '%s' "${!var:-}"
    )
}

# Same as derive, but returns what the block said rather than what it resolved.
derive_stderr() {
    local root="${1}" line head
    line="$(grep -n '^# Option defaults' "${RUNNER}" | head -n1 | cut -d: -f1)"
    head="${FIXTURES}/head.sh"
    head -n "$((line - 1))" "${RUNNER}" > "${head}"
    (
        cd "${root}" || exit 1
        # shellcheck disable=SC1090  # generated above from the runner under test
        source "${head}" 2>&1 >/dev/null | grep 'runTests.sh:' || true
    )
}

printf 'Detection fixtures (%s)\n' "${RUNNER#"$(pwd)/"}"

# 1. The conf decides which file is read out of, not just which file is named.
root="$(make_fixture conf-order Build/custom/Functional.xml multi)"
printf 'PHPUNIT_FUNCTIONAL_CONFIG="Build/custom/Functional.xml"\n' > "${root}/Build/Scripts/runTests.conf"
got="$(derive "${root}" FUNCTIONAL_PARALLEL_PATHS)"
if [[ "${got}" == "Tests/E2E/TCA Tests/Functional" ]]; then
    pass "conf override drives the shard directories (${got})"
else
    fail "conf override ignored: shards=${got:-<empty>}, expected 'Tests/E2E/TCA Tests/Functional'"
fi

# 2. A testsuite on one line still yields its directories.
root="$(make_fixture inline-suite Build/FunctionalTests.xml inline)"
got="$(derive "${root}" FUNCTIONAL_PARALLEL_PATHS)"
if [[ "${got}" == "Tests/E2E/TCA Tests/Functional" ]]; then
    pass "single-line <testsuite> yields its directories (${got})"
else
    fail "single-line <testsuite> lost: shards=${got:-<empty>}, expected 'Tests/E2E/TCA Tests/Functional'"
fi

# 3. The notices: a shadowed config, a non-standard location, and silence at
#    the reference. They go to stderr, because these functions are read through
#    command substitution and stdout is the value.
root="$(make_fixture shadowed Build/phpunit/FunctionalTests.xml multi)"
cp "${root}/Build/phpunit/FunctionalTests.xml" "${root}/Build/FunctionalTests.xml"
notices="$(derive_stderr "${root}")"
if [[ "${notices}" == *"also present and ignored: Build/FunctionalTests.xml"* ]]; then
    pass "a second config is named as ignored"
else
    fail "a shadowed config produced no notice: ${notices:-<silence>}"
fi
if [[ "${notices}" == *"is not the standard location"* ]]; then
    pass "a non-standard location is named"
else
    fail "no notice for the non-standard location"
fi
value="$(derive "${root}" PHPUNIT_FUNCTIONAL_CONFIG)"
if [[ "${value}" == "Build/phpunit/FunctionalTests.xml" ]]; then
    pass "the notices stayed off stdout (value is ${value})"
else
    fail "stdout carries more than the value: ${value}"
fi

# The reference layout says nothing. A checker that only proves noise exists
# would pass on a runner that warns about everything.
root="$(make_fixture reference Build/FunctionalTests.xml multi)"
printf '<phpunit><testsuites><testsuite name="unit"><directory>../Tests/Unit</directory></testsuite></testsuites></phpunit>\n' \
    > "${root}/Build/phpunit.xml"
mkdir -p "${root}/Build/phpstan" "${root}/Build/rector"
printf 'parameters:\n' > "${root}/Build/phpstan/phpstan.neon"
printf '<?php\n' > "${root}/Build/rector/rector.php"
notices="$(derive_stderr "${root}")"
if [[ -z "${notices}" ]]; then
    pass "the reference layout produces no notice"
else
    fail "the reference layout is noisy: ${notices}"
fi

# 4. The runner marks its own container and refuses to nest inside it.
marks="$(grep -c 'RUNTESTS_IN_CONTAINER=1' "${RUNNER}" || true)"
if [[ "${marks}" -ge 3 ]]; then
    pass "the container marker is set on both runtimes and tested for (${marks} mentions)"
else
    fail "expected the marker on docker, podman and in the guard; found ${marks} mentions"
fi

root="$(make_fixture nested Build/FunctionalTests.xml multi)"
out="$( cd "${root}" && RUNTESTS_IN_CONTAINER=1 bash "${RUNNER}" -s unit 2>&1 )"
status=$?
if [[ "${status}" -ne 0 && "${out}" == *"already inside the runner's container"* ]]; then
    pass "a nested call exits ${status} and says why"
else
    fail "a nested call exited ${status}: ${out:-<silence>}"
fi

# 5. The web directory comes from composer.json, not from a constant.
root="$(make_fixture webdir Build/FunctionalTests.xml multi)"
python3 - "${root}" <<'PYEOF'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "composer.json"
d = json.loads(p.read_text())
d.setdefault("extra", {}).setdefault("typo3/cms", {})["web-dir"] = ".Build/public"
p.write_text(json.dumps(d, indent=4) + "\n")
PYEOF
got="$(derive "${root}" WEB_DIR)"
if [[ "${got}" == ".Build/public" ]]; then
    pass "web-dir is read from composer.json (${got})"
else
    fail "web-dir ignored: WEB_DIR=${got:-<empty>}, expected .Build/public"
fi

root="$(make_fixture webdir-default Build/FunctionalTests.xml multi)"
got="$(derive "${root}" WEB_DIR)"
if [[ "${got}" == ".Build/Web" ]]; then
    pass "without the key the default stays .Build/Web"
else
    fail "default web-dir lost: ${got:-<empty>}"
fi

# 6. The PHP image is overridable, by environment and by conf function.
#
#    Checked as text, not by executing: IMAGE_PHP is assigned ~90 lines below
#    `# Option defaults`, past the getopts loop, and sourcing that far under
#    `set -e` inside a subshell aborts before anything can be read back. The
#    effect is proven in the pull request instead, with real numbers from
#    t3x-nr-image-optimize: default image 241 assertions with 1 skipped,
#    IMAGE_PHP set to its imagick image 245 assertions with none.
image_line="$(grep -n '^IMAGE_PHP=' "${RUNNER}" | head -n1 | cut -d: -f2-)"
# shellcheck disable=SC2016  # the runner's own literal, not an expansion
if [[ "${image_line}" == *'${IMAGE_PHP:-'* ]]; then
    pass "IMAGE_PHP keeps an environment override"
else
    fail "IMAGE_PHP is assigned unconditionally: ${image_line:-<absent>}"
fi
if grep -q 'declare -f php_image' "${RUNNER}"; then
    pass "a conf php_image() is consulted"
else
    fail "no php_image() hook — a conf cannot name an image per PHP version"
fi
if [[ "${image_line}" == *core-testing-* ]]; then
    pass "the default is still a core-testing image"
else
    fail "default image lost: ${image_line:-<absent>}"
fi

# 7. Both flags on the sharded command, and neither on the serial one.
# shellcheck disable=SC2016  # these are the runner's own literals, not expansions
shard_cmd="$(grep -n 'COMMAND="find \${FUNCTIONAL_PARALLEL_PATHS}' "${RUNNER}" | head -n1)"
# shellcheck disable=SC2016
serial_cmd="$(grep -n 'COMMAND=(php \${PHP_FUNCTIONAL_OPTS}' "${RUNNER}" | head -n1)"
SHARD_FLAGS=('--exclude-group not-sqlite' '--do-not-fail-on-empty-test-suite')
for flag in "${SHARD_FLAGS[@]}"; do
    if [[ "${shard_cmd}" == *"${flag}"* ]]; then
        pass "sharded run passes ${flag}"
    else
        fail "sharded run is missing ${flag}"
    fi
done
# The group is hardcoded on purpose: this path pins pdo_sqlite regardless of -d,
# so deriving it from ${DBMS} excludes the wrong tests on `-d mariadb`.
# shellcheck disable=SC2016  # searching for the runner's own literal
if [[ "${shard_cmd}" == *'not-${DBMS}'* ]]; then
    fail "sharded run derives the excluded group from \${DBMS} while pinning sqlite"
else
    pass "sharded run does not derive the excluded group from \${DBMS}"
fi
if [[ "${serial_cmd}" == *'--exclude-group'* ]]; then
    pass "serial run passes --exclude-group"
else
    fail "serial run is missing --exclude-group"
fi
if [[ "${serial_cmd}" == *'--do-not-fail-on-empty-test-suite'* ]]; then
    fail "serial run must NOT hide an empty suite — it runs the whole suite at once"
else
    pass "serial run keeps failing on an empty suite"
fi

# 8. The cgl suite passes the extension's own php-cs-fixer config. php-cs-fixer
#    discovers only .php-cs-fixer.php / .php-cs-fixer.dist.php beside the working
#    directory, so an extension keeping it under Build/ silently gets
#    php-cs-fixer's defaults — and `-s cgl` then REWRITES files against rules the
#    extension never agreed to, while CI, which passes --config, stays green.
#    Measured on netresearch/contexts: 12 files rewritten by the runner, 0
#    reported by composer ci:test:php:cgl on the same tree.
printf 'cgl config\n'
# One fixture per layout the fleet actually uses, read off the git trees rather
# than guessed: guessing is what left Build/.php-cs-fixer.dist.php — ten of the
# twenty-five extensions — out of the first version of this list.
declare -a CGL_LAYOUTS=(
    "Build/.php-cs-fixer.dist.php"
    "Build/.php-cs-fixer.php"
    "Build/php-cs-fixer.php"
    "Build/php-cs-fixer/.php-cs-fixer.php"
)
for layout in "${CGL_LAYOUTS[@]}"; do
    root="${FIXTURES}/cgl-$(printf '%s' "${layout}" | tr '/.' '--')"
    mkdir -p "${root}/$(dirname "${layout}")"
    printf '{"name":"netresearch/fixture-cgl","require":{"php":"^8.2"},"extra":{"typo3/cms":{"extension-key":"fixture"}}}\n' \
        > "${root}/composer.json"
    printf '<?php\n' > "${root}/${layout}"
    got="$(derive "${root}" CGL_CONFIG)"
    if [[ "${got}" == "${layout}" ]]; then
        pass "${layout} is found"
    else
        fail "${layout} not found: got '${got:-<empty>}'"
    fi
done

# Both root names are php-cs-fixer's own, so neither may be called non-standard.
cgl_root_alt="${FIXTURES}/cgl-root-nondist"
mkdir -p "${cgl_root_alt}"
printf '{"name":"netresearch/fixture-cgl2","require":{"php":"^8.2"},"extra":{"typo3/cms":{"extension-key":"fixture"}}}\n' \
    > "${cgl_root_alt}/composer.json"
printf '<?php\n' > "${cgl_root_alt}/.php-cs-fixer.php"
said="$(derive_stderr "${cgl_root_alt}" | grep 'cgl config' || true)"
if [[ "${said}" == *"not the standard location"* ]]; then
    fail ".php-cs-fixer.php reported as non-standard: ${said}"
else
    pass ".php-cs-fixer.php is accepted as a standard location"
fi

cgl_none="${FIXTURES}/cgl-absent"
mkdir -p "${cgl_none}"
printf '{"name":"netresearch/fixture-nocgl","require":{"php":"^8.2"},"extra":{"typo3/cms":{"extension-key":"fixture"}}}\n' \
    > "${cgl_none}/composer.json"
got="$(derive "${cgl_none}" CGL_CONFIG)"
if [[ -z "${got}" ]]; then
    pass "no config present leaves CGL_CONFIG empty"
else
    fail "CGL_CONFIG invented a path with no config present: ${got}"
fi

# Both branches must carry the flag, and it must be the conditional form: an
# unconditional --config= with an empty value makes php-cs-fixer read the
# directory it is pointed at and fail with an unrelated message.
# shellcheck disable=SC2016  # searching for the runner's own literal, not an expansion
cgl_lines="$(grep -c 'php-cs-fixer fix -v \${CGL_CONFIG:+--config=\${CGL_CONFIG}}' "${RUNNER}")"
if [[ "${cgl_lines}" -eq 2 ]]; then
    pass "both cgl branches pass --config conditionally"
else
    fail "expected 2 conditional --config invocations, found ${cgl_lines}"
fi

# 9. The functional config is found where the extension keeps it.
#    The passkeys layout: a functional config at Build/phpunit.functional.xml next
# to a Build/phpunit.xml that carries only unit and fuzz. Falling back to the
# latter does not fail loudly — it runs phpunit against a file whose testsuite
# list has no functional entry, which reads as a configuration error in the
# extension rather than a detection miss here.
printf 'phpunit config layouts\n'
pk="${FIXTURES}/phpunit-dot-functional"
mkdir -p "${pk}/Build"
printf '{"name":"netresearch/fixture-pk","require":{"php":"^8.2"},"extra":{"typo3/cms":{"extension-key":"fixture"}}}\n' \
    > "${pk}/composer.json"
printf '<phpunit>\n  <testsuites>\n    <testsuite name="unit"><directory>../Tests/Unit</directory></testsuite>\n  </testsuites>\n</phpunit>\n' \
    > "${pk}/Build/phpunit.xml"
printf '<phpunit>\n  <testsuites>\n    <testsuite name="functional"><directory>../Tests/Functional</directory></testsuite>\n  </testsuites>\n</phpunit>\n' \
    > "${pk}/Build/phpunit.functional.xml"
got="$(derive "${pk}" PHPUNIT_FUNCTIONAL_CONFIG)"
if [[ "${got}" == "Build/phpunit.functional.xml" ]]; then
    pass "Build/phpunit.functional.xml wins over the unit config"
else
    fail "functional config: got '${got:-<empty>}', expected Build/phpunit.functional.xml"
fi
got="$(derive "${pk}" PHPUNIT_CONFIG)"
if [[ "${got}" == "Build/phpunit.xml" ]]; then
    pass "the unit config is still Build/phpunit.xml"
else
    fail "unit config: got '${got:-<empty>}'"
fi

# 10. The e2e suite calls e2e_teardown() when the conf defines one, and the
#     suite's exit code is readable there. Without the call, an extension that
#     builds its own environment in e2e_target() can only always keep or always
#     delete what it created — the runner collects containers on its network,
#     but not files.
printf 'e2e teardown\n'
e2e_line="$(grep -n 'declare -F e2e_teardown' "${RUNNER}" | head -n1)"
if [[ -n "${e2e_line}" ]]; then
    pass "the e2e suite consults e2e_teardown()"
else
    fail "no e2e_teardown() call — a conf-built environment cannot clean up after itself"
fi
# It has to sit after the exit code is captured AND inside the same case branch.
# "Some assignment appears earlier in the file" is not the same claim: the runner
# has one per suite, so a hook dropped into the wrong branch would still satisfy
# it. The test is that no `;;` separates the two.
if [[ -n "${e2e_line}" ]]; then
    between="$(awk -F: -v t="${e2e_line%%:*}" '
        NR < t { if ($0 ~ /SUITE_EXIT_CODE=\$\?/) last = NR; if ($0 ~ /^[[:space:]]*;;[[:space:]]*$/) sep = NR }
        END { print last "|" sep }' "${RUNNER}")"
    exit_line="${between%%|*}"
    sep_line="${between##*|}"
    if [[ -n "${exit_line}" ]] && { [[ -z "${sep_line}" ]] || [[ "${sep_line}" -lt "${exit_line}" ]]; }; then
        pass "e2e_teardown() runs after SUITE_EXIT_CODE in the same branch (${exit_line} -> ${e2e_line%%:*})"
    else
        fail "e2e_teardown() is not in the branch that sets SUITE_EXIT_CODE (assignment ${exit_line:-none}, ;; at ${sep_line:-none})"
    fi
fi

exit "${FAILED}"
