#!/usr/bin/env bash
# A create step for Orca's SSH mode: a connection block, and no pairing code.
echo "create" >> "${RECIPE_TEST_DIR:?}/calls"
printf '{"schemaVersion":1,"connection":{"type":"ssh","projectRoot":"/srv/app","target":{"label":"box","host":"192.0.2.10","port":22,"username":"ubuntu"}},"userData":{"resourceId":"box-%s"}}\n' "$ORCA_VM_INSTANCE_ID"
