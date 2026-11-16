#!/usr/bin/env bash
# An environment recipe's create step, to Orca's contract, that needs no
# cloud: the "machine" is a second, headless Orca server on this machine. It
# is here to try "Orca (per workspace)" end to end and to be adapted: a real
# recipe starts a machine at a provider where this starts a process, and
# everything else (the instance id, stderr for progress, one JSON object on
# stdout, cleaning up on failure) stays.
#
#   LOCAL_ORCA_PROJECT_ROOT   the repository's folder (required)
#   LOCAL_ORCA_STATE_DIR      where each instance keeps its files
#                             (default: $TMPDIR/harbor-local-orca)
#   LOCAL_ORCA_BIN            the orca command (default: orca)
#   LOCAL_ORCA_PAIRING_ADDRESS  the address the pairing code names, when the
#                             server's own is not the one to use
#
# Needs bash, ruby (for JSON and a free port) and orca.
set -euo pipefail

instance="${ORCA_VM_INSTANCE_ID:?ORCA_VM_INSTANCE_ID is not set: this is a recipe step, run by Orca or Harbor}"
root="${LOCAL_ORCA_PROJECT_ROOT:?set LOCAL_ORCA_PROJECT_ROOT to the repository folder the server works in}"
state="${LOCAL_ORCA_STATE_DIR:-${TMPDIR:-/tmp}/harbor-local-orca}/$instance"
orca_bin="${LOCAL_ORCA_BIN:-orca}"

[ -d "$root" ] || { echo "LOCAL_ORCA_PROJECT_ROOT ($root) is not a folder" >&2; exit 1; }

# One JSON object on stdout: what the server printed, with userData added.
emit() {
  ruby -rjson -e 'result = JSON.parse(File.read(ARGV[0]))
    result["schemaVersion"] = 1
    result["userData"] = (result["userData"] || {}).merge("provider" => "local-orca", "resourceId" => ARGV[1], "stateDir" => ARGV[2])
    puts JSON.generate(result)' "$state/recipe.json" "$instance" "$state"
}

running() { [ -f "$state/pid" ] && kill -0 "$(cat "$state/pid")" 2>/dev/null; }
parses() { ruby -rjson -e 'JSON.parse(File.read(ARGV[0])).fetch("pairingCode")' "$state/recipe.json" >/dev/null 2>&1; }

# Idempotent for an instance id: a server already up for it is the answer.
if running && parses; then
  echo "$instance is already up" >&2
  emit
  exit 0
fi

mkdir -p "$state/data"
cleanup_on_error() {
  status=$?
  if [ "$status" -ne 0 ]; then
    running && kill -TERM -- "-$(cat "$state/pid")" 2>/dev/null || true
    rm -rf "$state"
  fi
  exit "$status"
}
trap cleanup_on_error EXIT

port="$(ruby -rsocket -e 'server = TCPServer.new("127.0.0.1", 0); puts server.addr[1]')"
echo "starting an Orca server for $instance on 127.0.0.1:$port, working in $root" >&2

# A profile of its own, so it is not the desktop Orca's, and a process group
# of its own, so destroy can stop everything it starts.
pairing=()
[ -n "${LOCAL_ORCA_PAIRING_ADDRESS:-}" ] && pairing=(--pairing-address "$LOCAL_ORCA_PAIRING_ADDRESS")
ORCA_SERVE_RUNTIME=orcad ORCA_USER_DATA_PATH="$state/data" ruby -e '
  out, err, *command = ARGV
  pid = Process.spawn(*command, pgroup: true, in: File::NULL, out: out, err: err)
  Process.detach(pid)
  puts pid' "$state/recipe.json" "$state/serve.log" \
  "$orca_bin" serve --port "$port" --bind 127.0.0.1 --project-root "$root" ${pairing[@]+"${pairing[@]}"} --recipe-json > "$state/pid"

# The server keeps running; its recipe JSON appears when it is ready.
for _ in $(seq 1 240); do
  parses && break
  running || { echo "orca serve stopped before it was ready:" >&2; cat "$state/serve.log" >&2; exit 1; }
  sleep 0.25
done
parses || { echo "orca serve printed no recipe JSON within a minute:" >&2; cat "$state/serve.log" >&2; exit 1; }

echo "$instance is up (pid $(cat "$state/pid"))" >&2
emit
trap - EXIT
