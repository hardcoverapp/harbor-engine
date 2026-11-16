#!/usr/bin/env bash
# The destroy step that goes with local-orca-create.sh: stops the instance's
# Orca server and removes its files. It reads the lifecycle JSON on stdin and
# finds the instance by `instanceId`, so it also works when create never
# returned a result (there is then no `recipeResult`).
#
# It exits 0 when the instance is gone, including when there was nothing to
# find: nothing of it can be running. A recipe for a provider should exit
# non-zero whenever it cannot tell.
set -euo pipefail

payload="$(cat)"
instance="$(ruby -rjson -e 'print JSON.parse(ARGV[0])["instanceId"].to_s' "$payload")"
[ -n "$instance" ] || { echo "no instanceId in the lifecycle payload" >&2; exit 1; }
case "$instance" in */*|.*) echo "instanceId $instance is not one this recipe made" >&2; exit 1 ;; esac
state="${LOCAL_ORCA_STATE_DIR:-${TMPDIR:-/tmp}/harbor-local-orca}/$instance"

if [ ! -d "$state" ]; then
  echo "nothing to remove for $instance" >&2
  exit 0
fi

if [ -f "$state/pid" ]; then
  pid="$(cat "$state/pid")"
  if kill -0 "$pid" 2>/dev/null; then
    echo "stopping the Orca server of $instance (pid $pid)" >&2
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      sleep 0.5
    fi
    kill -0 "$pid" 2>/dev/null && { echo "the Orca server of $instance (pid $pid) would not stop" >&2; exit 1; }
  fi
fi
rm -rf "$state"
echo "$instance removed" >&2
