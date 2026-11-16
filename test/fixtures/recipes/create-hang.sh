#!/usr/bin/env bash
# A create step that never returns, with a child process of its own.
dir="${RECIPE_TEST_DIR:?}"
echo "create" >> "$dir/calls"
sleep 300 &
echo "$!" > "$dir/child.pid"
echo "waiting for the machine" >&2
wait
