#!/usr/bin/env bash
# A create step with a stray echo on stdout before its result.
echo "create" >> "${RECIPE_TEST_DIR:?}/calls"
echo "Starting the machine: orca://pair?code=SECRET-NOISE"
printf '{"schemaVersion":1,"pairingCode":"orca://pair?code=SECRET-NOISE","projectRoot":"/srv/app"}\n'
