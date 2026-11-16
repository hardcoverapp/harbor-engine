#!/usr/bin/env bash
# A recipe's create step that works: progress on stderr, one JSON object on
# stdout. What it was given is written down for the test to read.
set -euo pipefail
dir="${RECIPE_TEST_DIR:?}"
echo "create" >> "$dir/calls"
env | grep '^ORCA_' | sort > "$dir/create.env"
pwd > "$dir/create.pwd"
code="orca://pair?code=SECRET-${ORCA_VM_INSTANCE_ID}"
echo "booting ${ORCA_VM_INSTANCE_ID}" >&2
echo "orca serve said: ${code}" >&2
printf '{"schemaVersion":1,"pairingCode":"%s","projectRoot":"/srv/app","userData":{"provider":"test","resourceId":"box-%s"}}\n' "$code" "$ORCA_VM_INSTANCE_ID"
