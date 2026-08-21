#!/usr/bin/env bash
#
# Ein Test-Job ohne auszufuehrendes Testskript muss fehlschlagen, nicht Erfolg
# melden. Bis v1.7.2 endete die Fallback-Kette in ci.yml mit einem ::notice::
# und einem gruenen Job — Abdeckung, die es nicht gibt (#188).
#
# Der Wächter nimmt die `run:`-Bloecke der vier Test-Schritte aus ci.yml, setzt
# die Umgebung so, wie ein Repo ohne Testskripte sie erzeugt, und prueft den
# Exit-Code. Damit wird die Kette selbst ausgefuehrt, nicht nur ihr Text
# durchsucht: eine Textprobe wuerde ein `exit 1` auch dann bestaetigen, wenn es
# in einem Zweig steht, den nichts erreicht.
#
# Usage: check-empty-suite-fails.sh [path/to/ci.yml]

set -uo pipefail

WORKFLOW="${1:-.github/workflows/ci.yml}"
[[ -f "${WORKFLOW}" ]] || { printf 'not found: %s\n' "${WORKFLOW}" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FAILED=0

fail() { printf '  FAIL: %s\n' "${1}" >&2; FAILED=1; }
pass() { printf '  ok: %s\n' "${1}"; }

printf 'Empty-suite gate (%s)\n' "${WORKFLOW}"

# Jeder Test-Schritt einzeln: Job, Schrittname, die Variable, die den Befehl
# aus dem Aufruf traegt, und der Suite-Name fuer die Meldung.
while IFS=$'\t' read -r job step; do
    [[ -n "${job}" ]] || continue

    body="${TMP}/${job}.sh"
    yq -o json '.jobs' "${WORKFLOW}" \
        | jq -r --arg j "${job}" --arg s "${step}" \
            '.[$j].steps[] | select(.name == $s) | .run' > "${body}"

    # Was der Runner sonst liefert. Leere Befehls-Variablen und eine leere
    # Skriptliste sind genau der Fall aus #188.
    script="${TMP}/${job}-run.sh"
    {
        printf 'set -uo pipefail\n'
        printf 'composer() { :; }\n'          # `composer run-script --list` liefert nichts
        printf 'UNIT_TEST_COMMAND=""\n'
        printf 'FUNCTIONAL_TEST_COMMAND=""\n'
        printf 'ACCEPTANCE_TEST_COMMAND=""\n'
        printf 'UPLOAD_COVERAGE="false"\n'
        printf 'UPLOAD_TEST_RESULTS="false"\n'
        cat "${body}"
    } > "${script}"

    out="$(bash "${script}" 2>&1)"
    status=$?

    if [[ "${status}" -eq 0 ]]; then
        fail "${job} / ${step}: exit 0 with no test script — this is the green empty job"
    elif [[ "${out}" == *"::error::"* ]]; then
        pass "${job} / ${step}: exit ${status} and an ::error:: naming the fix"
    else
        fail "${job} / ${step}: exit ${status} but no ::error:: — the log would not say why"
    fi
done < <(
    yq -o json '.jobs' "${WORKFLOW}" \
        | jq -r 'to_entries[] | .key as $j
                 | (.value.steps[]? | select((.run // "") | test("test script found"))
                    | [$j, .name] | @tsv)'
)

exit "${FAILED}"
