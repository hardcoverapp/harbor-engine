#!/usr/bin/env bash
# A destroy step that works: the lifecycle JSON it read is written down.
set -euo pipefail
dir="${RECIPE_TEST_DIR:?}"
echo "destroy" >> "$dir/calls"
cat > "$dir/destroy.json"
env | grep '^ORCA_' | sort > "$dir/destroy.env"
echo "removing ${ORCA_VM_INSTANCE_ID}" >&2
