#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Run pinned Codecov argument construction and the real v11.3.2 file finder.

The wrapper receives a recording CLI executable; the real collector is called
directly without an uploader. Network calls are rejected in both processes.

Source: codecov-action@303a32d7a59b442fa8d48b6a1cc6825c09c847a5 and
codecov-cli@2f5121284e3c7c3c2b691a09cb0ea135d226f112 (v11.3.2).
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import inspect
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile


network_attempts: list[str] = []
auth_prefixes = ("CODECOV_", "CC_", "GITHUB_", "GH_", "ACTIONS_", "INPUT_", "SENTRY_")
sanitized_auth_keys = [key for key in os.environ if key.startswith(auth_prefixes)]
for auth_key in sanitized_auth_keys:
    del os.environ[auth_key]
fixture_token = "fixture-not-a-real-token"


def reject_network(*args, **kwargs):
    network_attempts.append(repr(args))
    raise AssertionError("Network is forbidden in the collector fixture")


socket.create_connection = reject_network
socket.socket.connect = reject_network

from codecov_cli.services.upload.file_finder import FileFinder  # noqa: E402


def git_blob(path: Path) -> str:
    data = path.read_bytes()
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def yaml_json(path: Path, query: str):
    return json.loads(subprocess.check_output(["yq", "-o=json", query, str(path)], text=True))


def require(condition: bool, message: str):
    if not condition:
        raise AssertionError(message)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workflow", type=Path, required=True)
    parser.add_argument("--wrapper", type=Path, required=True)
    parser.add_argument("--action", type=Path, required=True)
    args = parser.parse_args()
    wrapper = args.wrapper.resolve()
    action = args.action.resolve()
    finder_path = Path(inspect.getfile(FileFinder))
    require(importlib.metadata.version("codecov-cli") == "11.3.2", "Unexpected collector version")
    require(git_blob(finder_path) == "6c6dda89d17d408dd0d28cc5ffd9c2853d7098d6", "Unexpected collector bytes")
    require(git_blob(wrapper) == "832d2018bfb88f94390da7127fc79880673418df", "Unexpected wrapper bytes")
    require(git_blob(action) == "1dd2688c40ed86489da523e5b834dda2ecbdbceb", "Unexpected action bytes")
    package = finder_path.parents[2]
    require(git_blob(package / "helpers/folder_searcher.py") == "8b7f35dfa32f8c9346cd8b2dec0a5936a1a1df7e", "Unexpected search helper bytes")
    require(git_blob(package / "helpers/upload_type.py") == "fd53942fc25d20dde56ef6bf042da0d3c9012d3f", "Unexpected report-type bytes")
    require(git_blob(package / "types.py") == "2ca6f391beddb6b8f5b168641896e20f10289a6c", "Unexpected collector type bytes")
    definition = yaml_json(action, '{"default":.inputs.disable_search.default,"mapping":(.runs.steps[]|select(.name=="Upload coverage to Codecov")|.env.CC_DISABLE_SEARCH)}')
    require(definition == {"default": "false", "mapping": "${{ inputs.disable_search }}"}, "Unexpected input-to-environment mapping")

    query = '.jobs."compact-tests".steps | map(select(.name == "Upload unit coverage to Codecov" or .name == "Upload functional coverage to Codecov")) | map({"name":.name,"uses":.uses,"with":.with})'
    compact = yaml_json(args.workflow, query)
    legacy = yaml_json(args.workflow, '[.jobs."unit-tests".steps[],.jobs."functional-tests".steps[],.jobs."functional-tests-sqlite".steps[]] | map(select(.name=="Upload coverage to Codecov")) | map({"name":.name,"with":.with})')
    require(len(compact) == 2 and len(legacy) == 3, "Unexpected upload inventory")
    results = []

    def check(name: str, passed: bool, **details):
        results.append({"name": name, "passed": bool(passed), **details})

    with tempfile.TemporaryDirectory(prefix="codecov-interop-") as temporary:
        root = Path(temporary)
        reports = ["coverage-unit.xml", "coverage-functional.xml", "decoy-coverage.xml"]
        for filename in reports:
            (root / filename).write_text('<coverage generated="0"><project timestamp="0"><metrics files="0"/></project></coverage>\n')
        (root / "README.md").write_text("This is not a coverage report.\n")
        commands = root / "commands"
        commands.mkdir()
        network_marker = root / "network-attempt"
        guard = '#!/bin/sh\nprintf network-attempt > "$NETWORK_MARKER"\nexit 97\n'
        for command in ("curl", "wget", "pip", "git", "ssh", "nc", "ncat", "socat", "ftp", "lftp"):
            target = commands / command
            target.write_text(guard)
            target.chmod(0o755)
        recorder = commands / "record-codecov"
        recorder.write_text(f"#!{sys.executable}\nimport json, os, sys\nwith open(os.environ['ARGV_OUTPUT'], 'w') as stream:\n    json.dump(sys.argv[1:], stream)\n")
        recorder.chmod(0o755)

        def invoke(options: dict, label: str) -> list[str]:
            output = root / (label + ".json")
            disable = options.get("disable_search", definition["default"])
            if isinstance(disable, bool):
                disable = str(disable).lower()
            environment = {
                "PATH": str(commands) + ":" + os.defpath,
                "CC_BINARY": str(recorder),
                "CC_RUN_CMD": "upload-coverage",
                "CC_DISABLE_SEARCH": str(disable),
                "CC_FILES": options["files"],
                "CC_FLAGS": options["flags"],
                "CC_FAIL_ON_ERROR": "true",
                "CC_CLEANUP": "false",
                "CC_TOKEN": fixture_token,
                "ARGV_OUTPUT": str(output),
                "NETWORK_MARKER": str(network_marker),
            }
            completed = subprocess.run(["bash", str(wrapper)], cwd=root, env=environment, text=True, capture_output=True, timeout=30)
            require(completed.returncode == 0, completed.stderr + completed.stdout)
            require(not network_marker.exists(), "The wrapper attempted a forbidden network command")
            return json.loads(output.read_text())

        def collect(argv: list[str]) -> list[str]:
            explicit = [root / argv[index + 1] for index, token in enumerate(argv) if token == "--file"]
            selected = FileFinder(search_root=root, explicitly_listed_files=explicit, disable_search="--disable-search" in argv).find_files()
            return sorted(Path(item.get_filename()).name for item in selected)

        for index, step in enumerate(compact):
            options = step["with"]
            tier = "unit" if step["name"] == "Upload unit coverage to Codecov" else "functional"
            report = f"coverage-{tier}.xml"
            require(step["uses"] == "codecov/codecov-action@303a32d7a59b442fa8d48b6a1cc6825c09c847a5", "Unexpected action pin")
            require(options["files"] == report and options["flags"] == tier, "Unexpected report or flag")
            argv = invoke(options, f"compact-{index}")
            selected = collect(argv)
            check(f"compact-{tier}-argument-isolation", "--disable-search" in argv, argv=argv)
            check(f"compact-{tier}-fixture-auth-only", argv.count("-t") == 1 and argv[argv.index("-t") + 1] == fixture_token)
            check(f"compact-{tier}-exact-file-and-flag", argv.count("--file") == 1 and argv[argv.index("--file") + 1] == report and argv.count("--flag") == 1 and argv[argv.index("--flag") + 1] == tier)
            check(f"compact-{tier}-real-collector-isolation", selected == [report], selected=selected, expected=[report])

            # Deliberately remove the proposed workflow option. The actual
            # vendor wrapper omits the flag and the real collector must expose
            # the unrelated reports, so an isolation regression cannot pass.
            mutant = dict(options)
            mutant.pop("disable_search", None)
            mutant_argv = invoke(mutant, f"mutant-{index}")
            mutant_selected = collect(mutant_argv)
            check(f"removed-option-{tier}-negative-control", mutant_selected != [report] and mutant_selected == sorted(reports), selected=mutant_selected, rejected_single_report_contract=True)

        for index, step in enumerate(legacy):
            argv = invoke(step["with"], f"legacy-{index}")
            check(f"legacy-{index}-discovery-remains-enabled", "--disable-search" not in argv and collect(argv) == sorted(reports), argv=argv)

        missing = FileFinder(search_root=root, explicitly_listed_files=[root / "missing-coverage.xml"], disable_search=True).find_files()
        check("missing-explicit-file-does-not-fall-back-to-decoys", missing == [])
        check("no-network-or-upload", not network_attempts and not network_marker.exists())

    result = {
        "workflow": str(args.workflow.resolve()),
        "vendor_action_commit": "303a32d7a59b442fa8d48b6a1cc6825c09c847a5",
        "vendor_wrapper_blob": git_blob(wrapper),
        "real_collector_version": importlib.metadata.version("codecov-cli"),
        "real_collector_blob": git_blob(finder_path),
        "network_calls": len(network_attempts),
        "external_uploads": 0,
        "auth_environment_sanitized": True,
        "sanitized_auth_keys_count": len(sanitized_auth_keys),
        "results": results,
        "passed": all(item["passed"] for item in results),
    }
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
