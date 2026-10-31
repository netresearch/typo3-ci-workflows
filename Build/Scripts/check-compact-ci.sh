#!/usr/bin/env bash
# Execute the compact CI planner, commands and verdicts in deterministic fixtures.
# This verifies our orchestration, not GitHub's scheduler. The native pilot is
# still required before a consumer adopts the opt-in execution graph.
# Codecov vendor preparation may download pinned inputs; the collection probe
# itself rejects network access and uploads. Prepared inputs support offline use.
set -euo pipefail

resolve_codecov_fixture_resources() {
    local resource resolved
    for resource in CODECOV_FIXTURE_PYTHON CODECOV_FIXTURE_ACTION_DIR; do
        if [[ -n "${!resource:-}" ]]; then
            if [[ ! -e "${!resource}" ]]; then
                printf '%s must name an existing prepared resource: %s\n' "$resource" "${!resource}" >&2
                return 1
            fi
            # Keep venv interpreter symlinks within their environment path.
            resolved="$(realpath --canonicalize-existing --no-symlinks -- "${!resource}")" || return
            printf -v "$resource" '%s' "$resolved"
            export "${resource?}"
        fi
    done
}
resolve_codecov_fixture_resources

WORKFLOW="$(realpath "${1:-.github/workflows/ci.yml}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WORKFLOW_JSON="$(yq -o=json '.' "$WORKFLOW")"
CASES=0

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { CASES=$((CASES + 1)); printf 'ok: %s\n' "$1"; }
assert_yaml() {
    local expression="$1" description="$2"
    jq -e "$expression" <<< "$WORKFLOW_JSON" > /dev/null || fail "$description"
    pass "$description"
}
step() {
    local job="$1" name="$2"
    jq -er --arg j "$job" --arg n "$name" \
        '.jobs[$j].steps[] | select(.name == $n) | .run' <<< "$WORKFLOW_JSON"
}
assert_status() {
    local expected="$1" name="$2" actual=0
    shift 2
    "$@" > "$TMP/out" 2>&1 || actual=$?
    if [[ "$actual" != "$expected" ]]; then
        cat "$TMP/out" >&2
        fail "$name: expected exit $expected, got $actual"
    fi
    pass "$name"
}

mkdir -p "$TMP/prepared-env/bin" "$TMP/relative-caller/action"
touch "$TMP/prepared-env/bin/python"
ln -s "$TMP/prepared-env" "$TMP/relative-caller/.venv"
if (
    cd "$TMP/relative-caller" || exit 1
    export CODECOV_FIXTURE_PYTHON=.venv/bin/python CODECOV_FIXTURE_ACTION_DIR=action
    resolve_codecov_fixture_resources || exit 1
    [[ "$CODECOV_FIXTURE_PYTHON" == "$TMP/relative-caller/.venv/bin/python" ]] || exit 1
    [[ "$CODECOV_FIXTURE_ACTION_DIR" == "$TMP/relative-caller/action" ]] || exit 1
    resolve_codecov_fixture_resources || exit 1
    [[ "$CODECOV_FIXTURE_PYTHON" == "$TMP/relative-caller/.venv/bin/python" ]] || exit 1
    [[ "$CODECOV_FIXTURE_ACTION_DIR" == "$TMP/relative-caller/action" ]] || exit 1
    unset CODECOV_FIXTURE_PYTHON CODECOV_FIXTURE_ACTION_DIR
    resolve_codecov_fixture_resources || exit 1
    [[ ! -v CODECOV_FIXTURE_PYTHON && ! -v CODECOV_FIXTURE_ACTION_DIR ]] || exit 1
); then
    pass 'prepared paths preserve relative, absolute, venv-symlink and unset behavior'
else
    fail 'prepared resource paths changed meaning before the cwd change'
fi

for resource in CODECOV_FIXTURE_PYTHON CODECOV_FIXTURE_ACTION_DIR; do
    if (
        cd "$TMP/relative-caller" || exit 1
        export CODECOV_FIXTURE_PYTHON=.venv/bin/python CODECOV_FIXTURE_ACTION_DIR=action
        printf -v "$resource" '%s' missing-parent/deeper/resource
        if resolve_codecov_fixture_resources 2>/dev/null; then
            exit 1
        fi
        [[ "${!resource}" == missing-parent/deeper/resource ]] || exit 1
    ); then
        pass "$resource rejects an invalid parent without erasing the configured value"
    else
        fail "$resource did not reject an invalid prepared resource"
    fi
done

if (
    export CODECOV_FIXTURE_PYTHON="$TMP/prepared-env/bin/python" CODECOV_FIXTURE_ACTION_DIR="$TMP/relative-caller/action"
    realpath() { return 57; }
    status=0
    resolve_codecov_fixture_resources || status=$?
    [[ "$status" == 57 ]] || exit 1
    [[ "$CODECOV_FIXTURE_PYTHON" == "$TMP/prepared-env/bin/python" ]] || exit 1
); then
    pass 'canonicalizer failure propagates without erasing the configured value'
else
    fail 'canonicalizer failure was masked or erased the prepared resource'
fi

assert_yaml '.on.workflow_call.inputs["compact-jobs"].default == false' 'compact execution is opt-in'
assert_yaml '.on.workflow_call.inputs["upload-docs-artifact"].default == false' 'docs artifact remains opt-in'
assert_yaml '.jobs.gate.steps[] | select(.name == "Fail unless every job succeeded or was skipped") | .env.INPUTS == ("$" + "{{ toJSON(inputs) }}")' 'the native gate receives its complete input context'
for job in compact-quality compact-tests; do
    assert_yaml ".jobs | has(\"$job\")" "$job exists"
done

step preflight 'Build compact matrix' > "$TMP/plan.sh"
step compact-tests 'Evaluate test results' > "$TMP/test-verdict.sh"
step compact-quality 'Evaluate quality results' > "$TMP/quality-verdict.sh"
step compact-tests 'Verify test reports' > "$TMP/reports.sh"
step gate 'Fail unless every job succeeded or was skipped' > "$TMP/gate.sh"

export PHP_VERSIONS='["8.2","8.3","8.4","8.5"]' TYPO3_VERSIONS='["^13.4","^14.3"]'
export MATRIX_EXCLUDE='[]' CGL_PHP_VERSION='' RECTOR_PHP_VERSION=''
export RUN_UNIT=true RUN_FUNCTIONAL=true FUNCTIONAL_DB=sqlite UNIT_TIMEOUT=15 FUNCTIONAL_TIMEOUT=30
export GITHUB_OUTPUT="$TMP/plan-output"
assert_status 0 'the full matrix plans successfully' bash -eo pipefail "$TMP/plan.sh"
MATRIX="$(jq -Rn '[inputs | select(startswith("matrix=")) | ltrimstr("matrix=") | fromjson][0]' < "$GITHUB_OUTPUT")"
jq -e 'length == 8 and ([.[] | select(.lint)] | length) == 4
    and ([.[] | select(.primary)] | length) == 1
    and ([.[] | select(.lint) | .php] | unique) == ["8.2","8.3","8.4","8.5"]
    and (map([.php,.typo3]) | sort) == [["8.2","^13.4"],["8.2","^14.3"],["8.3","^13.4"],["8.3","^14.3"],["8.4","^13.4"],["8.4","^14.3"],["8.5","^13.4"],["8.5","^14.3"]]' <<< "$MATRIX" > /dev/null \
    || fail 'eight complete cells and four distinct lint carriers'
pass 'eight complete cells and four distinct lint carriers'
jq -Rn -e '[inputs] | index("tooling-php=8.2") != null and index("test-timeout=45") != null' < "$GITHUB_OUTPUT" > /dev/null \
    || fail 'tooling PHP and combined timeout preserve the input contract'
pass 'tooling PHP and combined timeout preserve the input contract'
# shellcheck disable=SC2016 # GitHub expressions are literal expected values.
assert_yaml '.jobs.phpstan.strategy.matrix.php == "${{ fromJSON(inputs.php-versions) }}" and .jobs.phpstan.strategy.matrix.typo3 == "${{ fromJSON(inputs.typo3-versions) }}"' 'PHPStan retains its independent complete matrix'

export MATRIX_EXCLUDE='[{"php":"8.2","typo3":"^13.4"}]'
: > "$GITHUB_OUTPUT"
assert_status 0 'an excluded first TYPO3 cell gets another lint carrier' bash -eo pipefail "$TMP/plan.sh"
MATRIX="$(jq -Rn '[inputs | select(startswith("matrix=")) | ltrimstr("matrix=") | fromjson][0]' < "$GITHUB_OUTPUT")"
jq -e 'length == 7 and ([.[] | select(.php == "8.2" and .lint and .primary and .typo3 == "^14.3")] | length) == 1' \
    <<< "$MATRIX" > /dev/null || fail 'lint carrier follows the retained cells'
pass 'lint carrier follows the retained cells'
export MATRIX_EXCLUDE='[{"typo3":"^13.4"}]'
assert_status 0 'a partial exclusion preserves one cell per PHP' bash -eo pipefail "$TMP/plan.sh"
export MATRIX_EXCLUDE='[{"php":"8.2"}]'
assert_status 1 'excluding every cell of a linted PHP fails' bash -eo pipefail "$TMP/plan.sh"
export MATRIX_EXCLUDE='[]'
for invalid in '[]' '["8.2","8.2"]' '[8.2]' 'not-json'; do
    assert_status 1 "invalid PHP matrix fails: $invalid" env PHP_VERSIONS="$invalid" bash -eo pipefail "$TMP/plan.sh"
done
assert_status 1 'different tooling PHP versions fail' env CGL_PHP_VERSION=8.2 RECTOR_PHP_VERSION=8.3 bash -eo pipefail "$TMP/plan.sh"
assert_status 1 'service-database compact configuration fails' env FUNCTIONAL_DB=mysql bash -eo pipefail "$TMP/plan.sh"
assert_status 1 'a disabled unit suite cannot erase the lint carriers' env RUN_UNIT=false bash -eo pipefail "$TMP/plan.sh"
assert_status 1 'a disabled functional suite cannot silently narrow compact CI' env RUN_FUNCTIONAL=false bash -eo pipefail "$TMP/plan.sh"
assert_status 1 'a combined timeout beyond the job bound fails' env UNIT_TIMEOUT=360 bash -eo pipefail "$TMP/plan.sh"

# Original job commands remain the source used by the compact aliases.
for pair in 'unit-tests:Run unit tests' 'functional-tests-sqlite:Run functional tests'; do
    original="${pair%%:*}"
    name="${pair#*:}"
    [[ "$(step "$original" "$name")" == "$(step compact-tests "$name")" ]] || fail "$name command drift"
    pass "$name reuses the original command"
done
assert_yaml '.jobs["compact-tests"].strategy["fail-fast"] == false' 'all compact matrix cells run after a failure'
# shellcheck disable=SC2016 # GitHub expressions are intentional literal data.
assert_yaml '(.jobs["compact-tests"].steps[] | select(.name == "Run functional tests") | .if) == "${{ !cancelled() && steps.install.outcome == '\''success'\'' }}"' 'functional eligibility is independent of unit success'
assert_yaml '(.jobs["compact-tests"].steps[] | select(.name == "Run unit tests") | .["continue-on-error"]) == true' 'unit findings do not suppress functional diagnostics'
assert_yaml '(.jobs["compact-tests"].steps[] | select(.name == "Run functional tests") | .["continue-on-error"]) == true' 'functional outcome reaches the explicit verdict'
for name in 'Run code style check' 'Run Rector'; do
    jq -e --arg n "$name" '.jobs["compact-quality"].steps[] | select(.name == $n) | .["continue-on-error"] == true and (.if | contains("steps.install.outcome")) and (.if | contains("steps.cgl") | not)' \
        <<< "$WORKFLOW_JSON" > /dev/null || fail "$name must not suppress another quality check"
    pass "$name leaves independent diagnostics eligible"
done
assert_yaml '[.jobs["compact-tests"].steps[] | select(.uses != null and (.uses | startswith("codecov/"))) | .with.files] | sort == ["coverage-functional.xml","coverage-unit.xml","junit-functional.xml","junit-unit.xml"]' 'four report paths remain distinct'
# shellcheck disable=SC2016 # Compare the literal GitHub expression.
assert_yaml '(.jobs.docs.with["upload-artifact"]) == "${{ inputs.upload-docs-artifact }}"' 'the authoritative renderer can publish its existing PR artifact'

# Execute both suite bodies; composer is only the external boundary stub.
mkdir -p "$TMP/bin" "$TMP/work"
cat > "$TMP/bin/composer" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"
if [[ "$1" == run-script ]]; then
    if [[ "${MISSING_SCRIPTS:-false}" != true ]]; then
        printf '%s\n' ci:test:php:unit ci:test:php:functional ci:test:php:cgl ci:test:php:rector ci:test:repo
    fi
    exit 0
fi
case "$1" in
    ci:test:php:unit) exit "${UNIT_STATUS:-0}" ;;
    ci:test:php:functional) exit "${FUNCTIONAL_STATUS:-0}" ;;
    ci:test:php:cgl) exit "${CGL_STATUS:-0}" ;;
    ci:test:php:rector) exit "${RECTOR_STATUS:-0}" ;;
esac
STUB
chmod +x "$TMP/bin/composer"
cd "$TMP/work"
export PATH="$TMP/bin:$PATH" CALL_LOG="$TMP/calls"
export UNIT_TEST_COMMAND='' FUNCTIONAL_TEST_COMMAND='' UPLOAD_COVERAGE=true UPLOAD_TEST_RESULTS=true PATH_COVERAGE=true
step compact-tests 'Run unit tests' > "$TMP/unit.sh"
step compact-tests 'Run functional tests' > "$TMP/functional.sh"
assert_status 1 'the actual unit body returns a test failure' env UNIT_STATUS=1 bash -eo pipefail "$TMP/unit.sh"
assert_status 0 'the actual functional body still runs independently' bash -eo pipefail "$TMP/functional.sh"
for suite in unit functional; do
    if ! grep -q -- "ci:test:php:$suite -- --coverage-clover=coverage-$suite.xml --path-coverage --log-junit=junit-$suite.xml" "$CALL_LOG"; then
        fail "$suite coverage and JUnit arguments are preserved"
    fi
    pass "$suite coverage and JUnit arguments are preserved"
done
assert_status 1 'missing unit script is a real failure' env MISSING_SCRIPTS=true bash -eo pipefail "$TMP/unit.sh"
assert_status 1 'missing functional script is a real failure' env MISSING_SCRIPTS=true bash -eo pipefail "$TMP/functional.sh"
export UPLOAD_COVERAGE=false UPLOAD_TEST_RESULTS=false PATH_COVERAGE=false
: > "$CALL_LOG"
assert_status 0 'no-coverage unit mode still runs the suite' bash -eo pipefail "$TMP/unit.sh"
grep -q -- '^ci:test:php:unit -- --no-coverage$' "$CALL_LOG" || fail 'no-coverage arguments'
pass 'no-coverage arguments are preserved'
assert_status 0 'custom unit commands still execute unchanged' env UNIT_TEST_COMMAND='printf custom > override.txt' bash -eo pipefail "$TMP/unit.sh"
[[ "$(cat override.txt)" == custom ]] || fail 'custom command did not run'
pass 'custom command result is preserved'
export CGL_COMMAND='' RECTOR_COMMAND='' REPO_CHECKS_COMMAND=''
step compact-quality 'Run code style check' > "$TMP/cgl.sh"
step compact-quality 'Run Rector' > "$TMP/rector.sh"
step compact-quality 'Run repository checks' > "$TMP/repo.sh"
assert_status 1 'the CGL command returns its actual finding' env CGL_STATUS=1 bash -eo pipefail "$TMP/cgl.sh"
assert_status 0 'the Rector command remains independently executable' bash -eo pipefail "$TMP/rector.sh"
assert_status 0 'file-only repo checks remain independently executable' bash -eo pipefail "$TMP/repo.sh"
step compact-quality 'Detect Documentation' > "$TMP/docs.sh"
mkdir Documentation
printf '<guides/>\n' > Documentation/guides.xml
: > "$GITHUB_OUTPUT"
assert_status 0 'documentation present is explicitly detected' bash -eo pipefail "$TMP/docs.sh"
[[ "$(cat "$GITHUB_OUTPUT")" == present=true ]] || fail 'docs presence output'
rm Documentation/guides.xml
: > "$GITHUB_OUTPUT"
assert_status 0 'documentation absent is explicitly detected' bash -eo pipefail "$TMP/docs.sh"
[[ "$(cat "$GITHUB_OUTPUT")" == present=false ]] || fail 'docs absence output'
assert_status 1 'documentation output errors are actual failures' env GITHUB_OUTPUT="$TMP/missing-dir/out" bash -eo pipefail "$TMP/docs.sh"

export INSTALL_RESULT=success LINT_RESULT=success METADATA_RESULT=success UNIT_RESULT=success FUNCTIONAL_RESULT=success
export REPORT_RESULT=success RUN_REPORTS=true
export RUN_LINT=true LINT_CELL=true PRIMARY_CELL=true
assert_status 0 'complete successful test results pass' bash -eo pipefail "$TMP/test-verdict.sh"
for result in failure cancelled skipped ''; do
    assert_status 1 "unit outcome '$result' blocks" env UNIT_RESULT="$result" bash -eo pipefail "$TMP/test-verdict.sh"
    assert_status 1 "functional outcome '$result' blocks" env FUNCTIONAL_RESULT="$result" bash -eo pipefail "$TMP/test-verdict.sh"
done
assert_status 1 'a lint failure blocks the cell' env LINT_RESULT=failure bash -eo pipefail "$TMP/test-verdict.sh"
assert_status 1 'metadata validation failure blocks the primary cell' env METADATA_RESULT=failure bash -eo pipefail "$TMP/test-verdict.sh"
assert_status 1 'dependency installation failure blocks' env INSTALL_RESULT=failure bash -eo pipefail "$TMP/test-verdict.sh"
assert_status 1 'missing or failed reports block the cell' env REPORT_RESULT=failure bash -eo pipefail "$TMP/test-verdict.sh"
assert_status 0 'only declared non-carriers may skip lint' env LINT_CELL=false PRIMARY_CELL=false LINT_RESULT=skipped METADATA_RESULT=skipped bash -eo pipefail "$TMP/test-verdict.sh"
export UPLOAD_COVERAGE=true UPLOAD_TEST_RESULTS=true
for report in coverage-unit.xml junit-unit.xml coverage-functional.xml junit-functional.xml; do
    printf '<report/>\n' > "$report"
done
assert_status 0 'successful suites produce all four nonempty reports' bash -eo pipefail "$TMP/reports.sh"
: > coverage-functional.xml
assert_status 1 'empty functional coverage is not a green upload' bash -eo pipefail "$TMP/reports.sh"
printf '<report/>\n' > coverage-functional.xml
rm junit-unit.xml
assert_status 1 'missing unit JUnit is not a green upload' bash -eo pipefail "$TMP/reports.sh"

export CHECKOUT_RESULT=success CGL_RESULT=success RECTOR_RESULT=success REPO_RESULT=success DOCS_RESULT=success
export RUN_CGL=true RUN_RECTOR=true RUN_REPO=true RUN_DOCS=true
assert_status 0 'complete quality outcomes pass' bash -eo pipefail "$TMP/quality-verdict.sh"
for check in CGL RECTOR REPO DOCS; do
    for result in failure cancelled skipped ''; do
        assert_status 1 "quality $check outcome '$result' blocks" env "${check}_RESULT=$result" bash -eo pipefail "$TMP/quality-verdict.sh"
    done
done
assert_status 0 'only disabled quality commands may skip' env RUN_CGL=false RUN_RECTOR=false INSTALL_RESULT=skipped CGL_RESULT=skipped RECTOR_RESULT=skipped bash -eo pipefail "$TMP/quality-verdict.sh"

export INPUTS='{"compact-jobs":true,"run-lint":true,"run-cgl":true,"run-phpstan":true,"run-phpstan-unpinned":true,"run-rector":true,"run-fractor":false,"run-repo-checks":true,"run-unit-tests":true,"run-functional-tests":true,"run-acceptance-tests":false,"run-docs":true,"lowest-deps":false,"pin-packages":""}'
export RESULTS='{"preflight":{"result":"success","outputs":{"run":"true"}},"lint":{"result":"skipped"},"cgl":{"result":"skipped"},"phpstan":{"result":"success"},"phpstan-unpinned":{"result":"success"},"rector":{"result":"skipped"},"fractor":{"result":"skipped"},"repo-checks":{"result":"skipped"},"unit-tests":{"result":"skipped"},"acceptance-tests":{"result":"skipped"},"functional-tests":{"result":"skipped"},"functional-tests-sqlite":{"result":"skipped"},"lowest-deps":{"result":"skipped"},"detect-docs":{"result":"skipped"},"compact-quality":{"result":"success","outputs":{"docs-present":"true"}},"compact-tests":{"result":"success"},"docs":{"result":"success"}}'
BASE_RESULTS="$RESULTS"
assert_status 0 'the complete compact workflow passes the stable gate' bash -eo pipefail "$TMP/gate.sh"
for job in preflight compact-quality compact-tests phpstan phpstan-unpinned docs; do
    for result in failure cancelled skipped ''; do
        changed="$(jq --arg j "$job" --arg r "$result" '.[$j].result=$r' <<< "$BASE_RESULTS")"
        assert_status 1 "required family $job '$result' blocks" env RESULTS="$changed" bash -eo pipefail "$TMP/gate.sh"
    done
    changed="$(jq --arg j "$job" 'del(.[$j])' <<< "$BASE_RESULTS")"
    assert_status 1 "missing required family $job blocks" env RESULTS="$changed" bash -eo pipefail "$TMP/gate.sh"
done
assert_status 1 'unknown preflight state blocks' env RESULTS="$(jq '.preflight.outputs.run=""' <<< "$BASE_RESULTS")" bash -eo pipefail "$TMP/gate.sh"
assert_status 1 'missing docs detection cannot masquerade as no docs' env RESULTS="$(jq '."compact-quality".outputs={}' <<< "$BASE_RESULTS")" bash -eo pipefail "$TMP/gate.sh"
assert_status 0 'an explicit absent manual disables docs only' env RESULTS="$(jq '."compact-quality".outputs["docs-present"]="false" | .docs.result="skipped"' <<< "$BASE_RESULTS")" bash -eo pipefail "$TMP/gate.sh"
assert_status 1 'malformed results fail closed' env RESULTS='{' bash -eo pipefail "$TMP/gate.sh"
assert_status 1 'malformed mode inputs fail closed' env INPUTS='{' bash -eo pipefail "$TMP/gate.sh"
assert_status 1 'missing execution mode fails closed' env INPUTS='{}' bash -eo pipefail "$TMP/gate.sh"
DEDUP_RESULTS="$(jq 'with_entries(.value.result="skipped") | .preflight={result:"success",outputs:{run:"false"}}' <<< "$BASE_RESULTS")"
assert_status 0 'the existing explicit dedup skip starts no compact work' env RESULTS="$DEDUP_RESULTS" bash -eo pipefail "$TMP/gate.sh"
assert_status 1 'dedup does not allow a missing family' env RESULTS="$(jq 'del(."compact-tests")' <<< "$DEDUP_RESULTS")" bash -eo pipefail "$TMP/gate.sh"
assert_status 1 'dedup cannot hide an unexpected execution' env RESULTS="$(jq '."compact-tests".result="success"' <<< "$DEDUP_RESULTS")" bash -eo pipefail "$TMP/gate.sh"
STANDARD_RESULTS="$(jq 'with_entries(.value.result="success") | ."compact-quality".result="skipped" | ."compact-tests".result="skipped"' <<< "$BASE_RESULTS")"
assert_status 0 'the default legacy graph retains its successful verdict' env INPUTS='{"compact-jobs":false}' RESULTS="$STANDARD_RESULTS" bash -eo pipefail "$TMP/gate.sh"
assert_status 1 'default mode still blocks a cancelled old family' env INPUTS='{"compact-jobs":false}' RESULTS="$(jq '."unit-tests".result="cancelled"' <<< "$STANDARD_RESULTS")" bash -eo pipefail "$TMP/gate.sh"

bash "$SCRIPT_DIR/check-codecov-collection.sh" "$WORKFLOW"
pass 'pinned Codecov arguments and real collection preserve report membership'

printf 'Compact CI: %s checks passed.\n' "$CASES"
