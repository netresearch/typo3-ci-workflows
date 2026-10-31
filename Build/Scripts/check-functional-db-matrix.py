#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise the real server planner, aggregate and command without databases."""
from __future__ import annotations

import argparse
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


SERVER = "functional-tests"
DB_INPUT = "functional-db-matrix"
PREFLIGHT = "preflight"
RESULT = "result"
OUTPUTS = "outputs"
DB_COUNT = "db-count"
SERVER_MATRIX = "server-matrix"
SUCCESS = "success"
SKIPPED = "skipped"
GATE_STEP = "Fail unless every job succeeded or was skipped"
PLAN_STEP = "Build server matrix"
FUNCTIONAL_STEP = "Run functional tests"
TYPO3_LINE = "^14.3"
ROWS = [
    {"php": "8.5", "typo3": TYPO3_LINE, "db": engine, "image": image}
    for engine, image in (
        ("mariadb", "ghcr.io/netresearch/ci-mirror/mariadb:10.11"),
        ("mysql", "ghcr.io/netresearch/ci-mirror/mysql:8.0"),
        ("postgres", "ghcr.io/netresearch/ci-mirror/postgres:16-alpine"),
    )
]


def load_workflow(path: Path) -> dict:
    """Read YAML structurally and keep option-like paths out of yq options."""
    with path.resolve(strict=True).open("rb") as source:
        return json.loads(subprocess.check_output(["yq", "-o=json", ".", "--", "-"], stdin=source))


def step(config: dict, job: str, name: str) -> dict:
    """Find one real named step instead of maintaining a parallel command."""
    return next(item for item in config["jobs"][job]["steps"] if item.get("name") == name)


def execute(script: str, environment: dict[str, str]) -> subprocess.CompletedProcess:
    """Execute an extracted shell body with only explicit fixture context."""
    return subprocess.run(["bash", "-euo", "pipefail", "-c", script], env={"PATH": os.environ["PATH"], **environment}, text=True, capture_output=True, timeout=30)


class Probe:
    """Count only assertions whose actual extracted contract passed."""

    def __init__(self):
        self.count = 0

    def check(self, condition: bool, label: str):
        """Fail with the property label rather than accepting partial evidence."""
        if not condition:
            raise AssertionError(label)
        self.count += 1


def gate_context(config: dict, compact: bool, rows: list | None = None) -> tuple[dict, dict]:
    """Build complete native needs for a minimal enabled SQLite primary."""
    if rows is None:
        rows = ROWS
    inputs = {name: value.get("default") for name, value in config["on"]["workflow_call"]["inputs"].items()}
    inputs.update({"compact-jobs": compact, "run-functional-tests": True, DB_INPUT: json.dumps(rows)})
    for feature in ("run-lint", "run-cgl", "run-phpstan", "run-rector", "run-docs"):
        inputs[feature] = False
    results = {name: {RESULT: SKIPPED} for name in config["jobs"]["gate"]["needs"]}
    results[PREFLIGHT] = {RESULT: SUCCESS, OUTPUTS: {"run": "true", DB_COUNT: str(len(rows)), SERVER_MATRIX: json.dumps({"include": rows})}}
    results[SERVER] = {RESULT: SUCCESS if rows else SKIPPED}
    families = ("compact-quality", "compact-tests") if compact else ("unit-tests", "functional-tests-sqlite")
    for family in families:
        results[family] = {RESULT: SUCCESS}
    return inputs, results


def gate_passes(config: dict, inputs: dict, results: dict) -> bool:
    """Run the actual aggregate with independently supplied input/result JSON."""
    script = step(config, "gate", GATE_STEP)["run"]
    return execute(script, {"INPUTS": json.dumps(inputs), "RESULTS": json.dumps(results)}).returncode == 0


def check_active_gate(config: dict, probe: Probe, inputs: dict, results: dict):
    """Reject incomplete active families, decisions and row-count declarations."""
    probe.check(gate_passes(config, inputs, results), "complete active DB family passes")
    for family in (SERVER, PREFLIGHT):
        for outcome in ("failure", "cancelled", SKIPPED, "", "unknown"):
            changed = copy.deepcopy(results)
            changed[family][RESULT] = outcome
            probe.check(not gate_passes(config, inputs, changed), f"active {family}/{outcome!r} fails")
    for count in (None, "0", "2", "03", "unknown"):
        changed = copy.deepcopy(results)
        changed[PREFLIGHT][OUTPUTS][DB_COUNT] = count
        probe.check(not gate_passes(config, inputs, changed), f"invalid DB count {count!r} fails")
    for decision in (None, "", "unknown"):
        changed = copy.deepcopy(results)
        changed[PREFLIGHT][OUTPUTS]["run"] = decision
        probe.check(not gate_passes(config, inputs, changed), f"invalid run decision {decision!r} fails")


def check_gate_membership(config: dict, probe: Probe, inputs: dict, results: dict):
    """Reject dropped rows, missing needs and inconsistent published matrices."""
    for matrix in (None, "{}", json.dumps({"include": ROWS[:2]})):
        changed = copy.deepcopy(results)
        changed[PREFLIGHT][OUTPUTS][SERVER_MATRIX] = matrix
        probe.check(not gate_passes(config, inputs, changed), "missing or altered server plan fails")
    for family in (PREFLIGHT, SERVER, "docs"):
        changed = copy.deepcopy(results)
        del changed[family]
        probe.check(not gate_passes(config, inputs, changed), f"missing {family} fails")
    changed = copy.deepcopy(results)
    del changed[SERVER][RESULT]
    probe.check(not gate_passes(config, inputs, changed), "missing server outcome fails")


def check_reuse_gate(config: dict, probe: Probe, inputs: dict, results: dict):
    """Allow established whole-graph reuse only with explicit skipped families."""
    reused = copy.deepcopy(results)
    for family, outcome in reused.items():
        if family != PREFLIGHT:
            outcome[RESULT] = SKIPPED
    reused[PREFLIGHT][OUTPUTS]["run"] = "false"
    probe.check(gate_passes(config, inputs, reused), "explicit whole-graph reuse passes")
    for family in (SERVER, "unit-tests"):
        changed = copy.deepcopy(reused)
        changed[family][RESULT] = SUCCESS
        probe.check(not gate_passes(config, inputs, changed), f"unexpected reused {family} execution fails")
    for outcome in ("failure", "cancelled", "", "unknown"):
        changed = copy.deepcopy(reused)
        changed[SERVER][RESULT] = outcome
        probe.check(not gate_passes(config, inputs, changed), f"reused server outcome {outcome!r} fails")
    for family in (PREFLIGHT, SERVER, "docs"):
        changed = copy.deepcopy(reused)
        del changed[family]
        probe.check(not gate_passes(config, inputs, changed), f"missing reused {family} fails")


def planner(config: dict, value: str, **overrides) -> tuple[int, dict]:
    """Execute the real planner, preserving output strings exactly as GitHub does."""
    environment = {
        "FUNCTIONAL_DB_MATRIX": value, "PHP_VERSIONS": '["8.2","8.3"]',
        "TYPO3_VERSIONS": '["^13.4","^14.3"]', "MATRIX_EXCLUDE": '[{"php":"8.2","typo3":"^14.3"}]',
        "FUNCTIONAL_DB": "sqlite", "RUN_FUNCTIONAL": "true", **overrides,
    }
    with tempfile.TemporaryDirectory(prefix="db-matrix-plan-") as directory:
        output = Path(directory) / "outputs"
        result = execute(step(config, PREFLIGHT, PLAN_STEP)["run"], {**environment, "GITHUB_OUTPUT": str(output)})
        values = {key: value for key, value in (line.split("=", 1) for line in output.read_text().splitlines())} if output.exists() else {}
    return result.returncode, values


def check_planner(config: dict, probe: Probe):
    """Preserve default Cartesian axes and require exact include-only opt-in rows."""
    expected = {"php": ["8.2", "8.3"], "typo3": ["^13.4", TYPO3_LINE], "exclude": [{"php": "8.2", "typo3": TYPO3_LINE}]}
    for empty in ("[]", " \n[ ]\t"):
        status, values = planner(config, empty, FUNCTIONAL_DB="mysql", RUN_FUNCTIONAL="false")
        probe.check(status == 0 and values["count"] == "0" and json.loads(values["matrix"]) == expected, "default matrix/disabled server settings retain parity")
    status, values = planner(config, json.dumps(ROWS))
    probe.check(status == 0 and values["count"] == "3" and json.loads(values["matrix"]) == {"include": ROWS}, "three exact rows without Cartesian expansion")
    for key, value in (("FUNCTIONAL_DB", "mysql"), ("RUN_FUNCTIONAL", "false")):
        probe.check(planner(config, json.dumps(ROWS), **{key: value})[0] != 0, "nonempty rows reject incompatible primary/suite")
    maximum = [{**ROWS[0], "image": f"{ROWS[0]['image']}-{index}"} for index in range(256)]
    status, values = planner(config, json.dumps(maximum))
    probe.check(status == 0 and values["count"] == "256" and json.loads(values["matrix"]) == {"include": maximum}, "exact native matrix limit remains accepted")


def check_invalid_rows(config: dict, probe: Probe):
    """Reject malformed, unsafe, duplicate and excessive row declarations."""
    invalid = ["", " ", "null", "{}", "true", "not-json", "[null]", "[1]", json.dumps([ROWS[0], ROWS[0]])]
    for key in ROWS[0]:
        changed = dict(ROWS[0])
        del changed[key]
        invalid.extend((json.dumps([changed]), json.dumps([{**ROWS[0], key: ""}]),
                        json.dumps([{**ROWS[0], key: 1}])))
    invalid.extend(json.dumps([{**ROWS[0], "image": "invalid" + character + "image"}]) for character in (" ", "\t", "\n", "\x00", "\x1b", "\u00a0"))
    invalid.extend((json.dumps([{**ROWS[0], "db": "sqlite"}]), json.dumps([{**ROWS[0], "command": "extra"}]), json.dumps([{**ROWS[0], "image": str(index)} for index in range(257)])))
    for value in invalid:
        probe.check(planner(config, value)[0] != 0, f"invalid server declaration rejected: {value[:70]!r}")


def context_value(reference: str, row: dict, inputs: dict):
    """Resolve only known native contexts, treating absent matrix keys as empty."""
    scope, key = reference.split(".", 1)
    return {"matrix": row, "inputs": inputs}[scope].get(key, "")


def expression_value(expression: str, row: dict, inputs: dict):
    """Interpret the small DB binding grammar; unknown native syntax fails."""
    direct = re.fullmatch(r"(?:matrix|inputs)\.[\w-]+", expression)
    if direct:
        return context_value(expression, row, inputs)
    choice = re.fullmatch(r"\(matrix\.db \|\| inputs\.functional-test-db\) == 'postgres' && '([^']*)' \|\| '([^']*)'", expression)
    if choice:
        return choice[1] if (row.get("db") or inputs["functional-test-db"]) == "postgres" else choice[2]
    fallback = re.fullmatch(r"(matrix\.[\w-]+) \|\| (inputs\.[\w-]+)", expression)
    if fallback:
        return context_value(fallback[1], row, inputs) or context_value(fallback[2], row, inputs)
    if expression == "inputs.upload-coverage && inputs.coverage-tool == 'xdebug' && inputs.path-coverage":
        return inputs["upload-coverage"] and inputs["coverage-tool"] == "xdebug" and inputs["path-coverage"]
    raise AssertionError(f"Unsupported DB fixture expression: {expression}")


def render(value, row: dict, inputs: dict) -> str:
    """Bind real workflow values without executing supplied expressions as code."""
    def replacement(match):
        result = expression_value(match[1].strip(), row, inputs)
        return str(result).lower() if isinstance(result, bool) else str(result)
    return re.sub(r"\$\{\{(.*?)\}\}", replacement, str(value))


def check_service_bindings(config: dict, probe: Probe, row: dict, inputs: dict):
    """Check the actual image/health inputs against the intended row or fallback."""
    service = config["jobs"][SERVER]["services"]["db"]
    engine = row.get("db") or inputs["functional-test-db"]
    expected_image = row.get("image") or inputs["db-image"]
    health = "pg_isready -U postgres" if engine == "postgres" else "mariadb-admin ping --silent || mysqladmin ping --silent"
    expected = f'--health-cmd="{health}" --health-interval=10s --health-timeout=5s --health-retries=5'
    probe.check(render(service["image"], row, inputs) == expected_image, "row image or original image fallback reaches service")
    probe.check(render(service["options"], row, inputs) == expected, "original engine health probes and timings retained")
    probe.check(service["ports"] == ["3306:3306", "5432:5432"], "service ports remain unchanged")
    probe.check(service["env"] == {"MYSQL_ROOT_PASSWORD": "root", "MYSQL_DATABASE": "typo3_test", "POSTGRES_PASSWORD": "root", "POSTGRES_DB": "typo3_test"}, "service fixture credentials/names remain unchanged")


def check_command(config: dict, probe: Probe, row: dict, inputs: dict):
    """Execute the real full-suite command with its rendered engine environment."""
    test = step(config, SERVER, FUNCTIONAL_STEP)
    environment = {key: render(value, row, inputs) for key, value in test["env"].items()}
    engine = row.get("db") or inputs["functional-test-db"]
    expected = ("pdo_pgsql", "5432", "postgres") if engine == "postgres" else ("mysqli", "3306", "root")
    actual = tuple(environment[key] for key in ("typo3DatabaseDriver", "typo3DatabasePort", "typo3DatabaseUsername"))
    probe.check(actual == expected, "row driver, port and username reach full functional command")
    with tempfile.TemporaryDirectory(prefix="db-functional-command-") as directory:
        root = Path(directory)
        recorder = root / "composer"
        recorder.write_text('#!/bin/sh\nif [ "$1" = run-script ]; then\n  [ "${MISSING_SCRIPTS:-false}" = true ] || printf "ci:test:php:functional\\n"\n  exit 0\nfi\nprintf "%s\\n" "$*" > "$CALL_LOG"\nprintf "%s\\n" "$typo3DatabaseDriver|$typo3DatabaseHost|$typo3DatabasePort|$typo3DatabaseUsername|$typo3DatabaseName|$typo3DatabasePassword" >> "$CALL_LOG"\nexit "${FUNCTIONAL_STATUS:-0}"\n')
        recorder.chmod(0o755)
        call = root / "call"
        environment.update({"PATH": str(root) + ":" + os.environ["PATH"], "CALL_LOG": str(call)})
        completed = execute(test["run"], environment)
        probe.check(completed.returncode == 0 and call.exists(), "full functional suite executes")
        lines = call.read_text().splitlines()
        flags = "--coverage-clover=coverage-functional.xml --path-coverage --log-junit=junit-functional.xml" if inputs["upload-coverage"] else "--no-coverage"
        probe.check(lines[0] == "ci:test:php:functional -- " + flags, "functional coverage/path/JUnit flags preserved")
        probe.check(lines[1] == "|".join((expected[0], "127.0.0.1", expected[1], expected[2], "typo3_test", "root")), "database environment forwarded unchanged to Composer")
        probe.check(execute(test["run"], {**environment, "FUNCTIONAL_STATUS": "1"}).returncode != 0, "actual command failure remains a failure")
        probe.check(execute(test["run"], {**environment, "MISSING_SCRIPTS": "true"}).returncode != 0, "missing full functional script remains a failure")


def check_execution(config: dict, probe: Probe):
    """Exercise all explicit engines, legacy fallbacks and existing report flags."""
    inputs, _ = gate_context(config, False)
    inputs["db-image"] = "unused-primary-image:1"
    for row in ROWS:
        check_service_bindings(config, probe, row, inputs)
        check_command(config, probe, row, inputs)
        fallback_inputs = {**inputs, "functional-test-db": row["db"], "db-image": row["image"]}
        check_service_bindings(config, probe, {}, fallback_inputs)
        check_command(config, probe, {}, fallback_inputs)
    coverage_inputs = {**inputs, "upload-coverage": True, "path-coverage": True, "upload-test-results": True, "functional-coverage-php-versions": "[]"}
    check_command(config, probe, ROWS[2], coverage_inputs)


def check_structure(config: dict, probe: Probe):
    """Keep scheduling, service ownership, names and native aggregate bindings."""
    server = config["jobs"][SERVER]
    probe.check(SERVER in config["jobs"]["gate"]["needs"], "aggregate directly depends on server family")
    probe.check(server["strategy"]["matrix"] == "${{ fromJSON(needs.preflight.outputs.server-matrix) }}", "server family consumes the planned matrix")
    probe.check(server["strategy"].get("fail-fast") is False and "max-parallel" not in server["strategy"], "DB rows remain parallel after sibling failure")
    probe.check(server.get("continue-on-error", False) is False and server["needs"] == PREFLIGHT, "all DB rows are blocking and independent of primary jobs")
    probe.check(server["timeout-minutes"] == "${{ inputs.functional-timeout-minutes }}" and server["permissions"] == {"contents": "read"}, "server timeout and permissions preserved")
    probe.check(server["if"] == "${{ inputs.run-functional-tests && (inputs.functional-test-db != 'sqlite' || fromJSON(needs.preflight.outputs.db-count) > 0) && needs.preflight.outputs.run == 'true' }}", "only enabled retained DB rows run under the explicit preflight decision")
    probe.check(server["name"] == "Functional Tests", "original server/skip name retained; GitHub appends actual matrix values")


def verify(config: dict) -> int:
    """Run the contract oracles against one real or deliberately mutated workflow."""
    probe = Probe()
    check_structure(config, probe)
    check_planner(config, probe)
    check_invalid_rows(config, probe)
    for compact in (False, True):
        inputs, results = gate_context(config, compact)
        check_active_gate(config, probe, inputs, results)
        check_gate_membership(config, probe, inputs, results)
        check_reuse_gate(config, probe, inputs, results)
        empty_inputs, empty_results = gate_context(config, compact, [])
        probe.check(gate_passes(config, empty_inputs, empty_results), "default empty declaration preserves the prior gate")
    check_execution(config, probe)
    return probe.count


def with_change(config: dict, path: tuple, value) -> dict:
    """Apply one deliberate mutation without changing the accepted fixture input."""
    changed = copy.deepcopy(config)
    target = changed
    for key in path[:-1]:
        target = target[key]
    target[path[-1]] = value
    return changed


def mutation_cases(config: dict):
    """Identify causal mutations of scheduling, row inventory and DB bindings."""
    server = config["jobs"][SERVER]
    gate_index = config["jobs"]["gate"]["steps"].index(step(config, "gate", GATE_STEP))
    planner_index = config["jobs"][PREFLIGHT]["steps"].index(step(config, PREFLIGHT, PLAN_STEP))
    command_index = server["steps"].index(step(config, SERVER, FUNCTIONAL_STEP))
    gate_script = step(config, "gate", GATE_STEP)["run"]
    planned = step(config, PREFLIGHT, PLAN_STEP)["run"]
    no_strictness = gate_script.replace('if [[ "$db_count" -gt 0 ]]; then', 'if false; then')
    no_postgres = planned.replace('else {include:$rows} end)', 'else {include:($rows | map(select(.db != "postgres")))} end)')
    if no_strictness == gate_script or no_postgres == planned:
        raise AssertionError("A mutation marker no longer reaches the production code")
    return (
        ("removed strict DB verdict", ("jobs", "gate", "steps", gate_index, "run"), no_strictness, "active " + SERVER),
        ("removed server dependency", ("jobs", "gate", "needs"), [name for name in config["jobs"]["gate"]["needs"] if name != SERVER], "directly depends"),
        ("disabled requested server work", ("jobs", SERVER, "if"), "${{ false }}", "enabled retained DB"),
        ("dropped PostgreSQL row", ("jobs", PREFLIGHT, "steps", planner_index, "run"), no_postgres, "three exact rows"),
        ("wrong PostgreSQL driver", ("jobs", SERVER, "steps", command_index, "env", "typo3DatabaseDriver"), step(config, SERVER, FUNCTIONAL_STEP)["env"]["typo3DatabaseDriver"].replace("pdo_pgsql", "mysqli"), "row driver"),
        ("wrong row image", ("jobs", SERVER, "services", "db", "image"), "${{ inputs.db-image }}", "row image"),
        ("wrong PostgreSQL health", ("jobs", SERVER, "services", "db", "options"), server["services"]["db"]["options"].replace("pg_isready -U postgres", "mysqladmin ping"), "engine health"),
        ("fail-fast cancels siblings", ("jobs", SERVER, "strategy", "fail-fast"), True, "remain parallel"),
        ("serialization cap", ("jobs", SERVER, "strategy", "max-parallel"), 1, "remain parallel"),
    )


def check_mutations(config: dict) -> list[str]:
    """Require each mutated workflow to fail its intended independent oracle."""
    rejected = []
    for label, path, value, expected_reason in mutation_cases(config):
        try:
            verify(with_change(config, path, value))
        except AssertionError as error:
            if expected_reason not in str(error):
                raise AssertionError(f"{label} failed an unrelated probe: {error}") from error
            rejected.append(label)
        else:
            raise AssertionError(f"Mutation survived: {label}")
    return rejected


def main() -> int:
    """Validate real planning and verdicts before any server row can be adopted."""
    parser = argparse.ArgumentParser()
    parser.add_argument("workflow", type=Path)
    config = load_workflow(parser.parse_args().workflow)
    count = verify(config)
    rejected = check_mutations(config)
    print(f"Functional DB matrix: {count} checks passed.")
    print("Rejected mutations: " + "; ".join(rejected))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
