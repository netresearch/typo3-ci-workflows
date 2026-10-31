#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Prepare immutable vendor inputs, then test collection without network/uploads.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="$(realpath "${1:-.github/workflows/ci.yml}")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Prepared resources support an entirely offline local run. The Python fixture
# always verifies their Git blob hashes and the collector package version.
FIXTURE_PYTHON="${CODECOV_FIXTURE_PYTHON:-}"
ACTION_DIR="${CODECOV_FIXTURE_ACTION_DIR:-}"
if [[ -z "$FIXTURE_PYTHON" ]]; then
    python3 -m venv "$TMP/venv"
    FIXTURE_PYTHON="$TMP/venv/bin/python"
    "$FIXTURE_PYTHON" -m pip install --disable-pip-version-check --no-cache-dir 'codecov-cli==11.3.2'
fi
if [[ -z "$ACTION_DIR" ]]; then
    ACTION_DIR="$TMP/action"
    mkdir -p "$ACTION_DIR"
    for path in action.yml dist/codecov.sh; do
        curl --fail --location --retry 3 --retry-delay 2 --retry-all-errors \
            --connect-timeout 10 --max-time 60 --proto '=https' --proto-redir '=https' \
            "https://raw.githubusercontent.com/codecov/codecov-action/303a32d7a59b442fa8d48b6a1cc6825c09c847a5/$path" \
            --output "$ACTION_DIR/$(basename "$path")"
    done
fi

"$FIXTURE_PYTHON" "$SCRIPT_DIR/check-codecov-collection.py" \
    --workflow "$WORKFLOW" --wrapper "$ACTION_DIR/codecov.sh" --action "$ACTION_DIR/action.yml"
