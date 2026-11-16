#!/usr/bin/env bash
# A destroy step that fails, and says too much on the way.
dir="${RECIPE_TEST_DIR:?}"
echo "destroy" >> "$dir/calls"
payload="$(cat)"
printf '%s' "$payload" > "$dir/destroy.json"
echo "the provider refused; payload was $payload" >&2
exit 1
