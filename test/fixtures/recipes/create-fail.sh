#!/usr/bin/env bash
# A create step that fails after saying why.
echo "create" >> "${RECIPE_TEST_DIR:?}/calls"
echo "no capacity in the region" >&2
exit 3
