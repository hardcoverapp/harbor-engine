# Runs one command for a Harbor run, wherever the run was placed, and reports
# back: what the command prints is posted to Harbor about once a second, and
# its exit status when it ends. POSIX sh and curl are all it needs.
#
#   $1                   the command, run with sh -c
#   HARBOR_RUNNER_URL    the run's address on Harbor (…/harbor/runner/runs/<id>)
#   HARBOR_RUNNER_TOKEN  the run's token
out=$(mktemp "${TMPDIR:-/tmp}/harbor-run.XXXXXX") || exit 70
part="$out.part"
sent=0

post() {
  curl -fsS -m 30 --retry 2 -X POST -H "Authorization: Bearer $HARBOR_RUNNER_TOKEN" "$@" >/dev/null 2>&1
}

# Send whatever has been printed since the last send. A send that fails is
# tried again on the next pass, so nothing is skipped.
flush() {
  size=$(wc -c < "$out" | tr -d ' ')
  if [ "$size" -gt "$sent" ]; then
    tail -c "+$((sent + 1))" "$out" | head -c "$((size - sent))" > "$part"
    if post -H 'Content-Type: text/plain' --data-binary "@$part" "$HARBOR_RUNNER_URL/log"; then
      sent=$size
    fi
  fi
}

sh -c "$1" > "$out" 2>&1 &
pid=$!
# Whoever has the terminal open sees the output too.
tail -f "$out" 2>/dev/null &
viewer=$!

while kill -0 "$pid" 2>/dev/null; do
  flush
  sleep 1
done
wait "$pid"
code=$?

flush
flush
post -H 'Content-Type: application/json' --data "{\"exit_status\":$code}" "$HARBOR_RUNNER_URL/result"
kill "$viewer" 2>/dev/null
rm -f "$out" "$part"
exit "$code"
