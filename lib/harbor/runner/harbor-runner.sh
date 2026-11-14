# Runs one command for a Harbor run, wherever the run was placed, and reports
# back: what the command prints is posted to Harbor about once a second, and
# its exit status when it ends. POSIX sh, curl and the usual base utilities
# (mktemp, tail, head, wc, ps, awk, date) are all it needs.
#
# Harbor may be away for a while (a deploy, a restart, a network that drops).
# The command is not disturbed by that: what it prints is kept here and sent
# when Harbor answers again, and a command that ends in the meantime keeps its
# output and its result until Harbor is back to take them.
#
#   $1                     the command, run with sh -c
#   HARBOR_RUNNER_URL      the run's address on Harbor (…/harbor/runner/runs/<id>)
#   HARBOR_RUNNER_TOKEN    the run's token; the command is not given it
#   HARBOR_RUNNER_BUNDLE   the run's files to fetch first, by name ("prompt env")
#   HARBOR_RUNNER_ATTEMPT  which start of the run this is, when it has several
#   HARBOR_RUNNER_GRACE    seconds a stopped command gets between TERM and KILL (5)
#   HARBOR_RUNNER_HEARTBEAT  seconds of printing nothing before Harbor is told
#                          the command is still there (30)
#   HARBOR_RUNNER_PATIENCE seconds to keep trying to deliver the output and the
#                          result while Harbor gives no answer (43200: 12 hours)
#   HARBOR_RUNNER_START_PATIENCE  the same, for fetching the run's files before
#                          the command starts (300)
#   HARBOR_RUNNER_PAUSE    the longest wait between two such tries, in seconds (15)
#
# The command finds the fetched files in HARBOR_RUN_DIR, a private folder that
# is removed at the end. A file named `env` there is sourced before the
# command starts: that is how secrets reach it without being on a command line.
HARBOR_RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/harbor-run.XXXXXX") || exit 70
chmod 700 "$HARBOR_RUN_DIR"
export HARBOR_RUN_DIR
out="$HARBOR_RUN_DIR/.output"
part="$HARBOR_RUN_DIR/.part"
reply="$HARBOR_RUN_DIR/.reply"
: > "$out"

sent=0        # bytes of $out Harbor has accepted
size=0
closed=0      # 1 once Harbor says the run is over and wants no more
signalled=false
pid=
viewer=
# One post never carries more than this, so a backlog drains in pieces
# instead of being refused whole for its size.
max=1048576
grace=${HARBOR_RUNNER_GRACE:-5}
heartbeat=${HARBOR_RUNNER_HEARTBEAT:-30}
patience=${HARBOR_RUNNER_PATIENCE:-43200}
start_patience=${HARBOR_RUNNER_START_PATIENCE:-300}
longest_pause=${HARBOR_RUNNER_PAUSE:-15}
reached=1     # 0 when the last request got no answer from Harbor at all
away_since=   # when Harbor stopped answering, in seconds since the epoch
nap=1
quiet=0       # seconds since anything was sent
attempt=${HARBOR_RUNNER_ATTEMPT:+attempt=$HARBOR_RUNNER_ATTEMPT}

# POSTs to Harbor and prints the HTTP status ("000" when there was no
# answer). The answer's body is left in $reply.
request() {
  curl -sS -m 30 --retry 2 -X POST -H "Authorization: Bearer $HARBOR_RUNNER_TOKEN" -o "$reply" -w '%{http_code}' "$@" 2>/dev/null
}

# Whether a status is no answer from Harbor itself: nothing came back, or
# whatever stands in front of it said it is down. Harbor is then taken to be
# away, not to have refused.
no_answer() {
  case "$1" in
    000|5??|'') return 0 ;;
  esac
  return 1
}

# Notes whether Harbor answered, and since when it hasn't.
heard() {
  if no_answer "$1"; then
    reached=0
    [ -n "$away_since" ] || away_since=$(date +%s)
  else
    reached=1
    away_since=
    nap=1
  fi
}

# Whether Harbor has been away for longer than `$1` seconds.
out_of_patience() {
  [ -n "$away_since" ] || return 1
  [ $(($(date +%s) - away_since)) -ge "$1" ]
}

# Waits before the next try while Harbor is away: a little longer each time.
pause() {
  sleep "$nap"
  nap=$((nap * 2))
  [ "$nap" -le "$longest_pause" ] || nap=$longest_pause
}

# Posts `$1` bytes of what has been printed, from where Harbor's copy ends
# (none: only to say the command is still there). Harbor appends only what it
# doesn't have, so a post that is repeated adds nothing twice. The position
# moves only when Harbor says it took the piece; when Harbor says it has less
# than that (409 and its own count), sending resumes from its count. Succeeds
# when Harbor took the piece or gave its count.
post_piece() {
  tail -c "+$((sent + 1))" "$out" | head -c "$1" > "$part"
  status=$(request -H 'Content-Type: application/octet-stream' --data-binary "@$part" \
    "$HARBOR_RUNNER_URL/log?offset=$sent${attempt:+&$attempt}")
  heard "$status"
  case "$status" in
    2??) sent=$((sent + $1)); quiet=0; return 0 ;;
    409)
      answer=$(head -c 20 "$reply" 2>/dev/null | tr -d ' \n\r')
      case "$answer" in
        ''|*[!0-9]*) closed=1 ;;
        *) sent=$answer; return 0 ;;
      esac ;;
  esac
  return 1
}

# Sends the next piece of what has been printed. Succeeds when the position
# moved.
flush() {
  [ "$closed" = 0 ] || return 1
  size=$(wc -c < "$out" | tr -d ' ')
  [ "$size" -gt "$sent" ] || return 1
  count=$((size - sent))
  [ "$count" -le "$max" ] || count=$max
  post_piece "$count"
}

# A command can print nothing for a long time. Harbor is told every so often
# that it is still there, so that a runner that has gone can be told from one
# whose command is only busy.
beat() {
  quiet=$((quiet + 1))
  [ "$closed" = 0 ] && [ "$quiet" -ge "$heartbeat" ] || return 0
  quiet=0
  post_piece 0
  return 0
}

# Sends everything left. While Harbor gives no answer it keeps trying, for as
# long as its patience lasts; when Harbor answers and still takes nothing, it
# gives up after five passes in a row.
drain() {
  stuck=0
  while [ "$closed" = 0 ] && [ "$stuck" -lt 5 ]; do
    size=$(wc -c < "$out" | tr -d ' ')
    [ "$size" -gt "$sent" ] || break
    if flush; then
      stuck=0
    elif [ "$reached" = 0 ]; then
      ! out_of_patience "$patience" || break
      pause
    else
      stuck=$((stuck + 1))
      sleep 1
    fi
  done
}

# The command's process and everything descended from it, one pid per line.
family() {
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
    { parent[$1] = $2 }
    END {
      keep[root] = 1
      do {
        grew = 0
        for (p in parent) if (!(p in keep) && (parent[p] in keep)) { keep[p] = 1; grew = 1 }
      } while (grew)
      for (p in keep) print p
    }'
}

still_running() {
  kill -0 -- "-$pid" 2>/dev/null && return 0
  for member in "$@"; do
    kill -0 "$member" 2>/dev/null && return 0
  done
  return 1
}

# Stops the command and whatever it started: an agent's tools and the agents
# it delegated to would otherwise keep working, and spending, after it. The
# command leads a process group where the system allows one; its descendants
# are signalled by pid as well, for where it doesn't. TERM first, then KILL
# for anything that ignored it.
stop_command() {
  [ -n "$pid" ] || return 0
  members=$(family "$pid")
  kill -TERM -- "-$pid" 2>/dev/null
  # shellcheck disable=SC2086
  kill -TERM $members 2>/dev/null
  waited=0
  # shellcheck disable=SC2086
  while [ "$waited" -lt "$grace" ] && still_running $members; do
    sleep 1
    waited=$((waited + 1))
  done
  kill -KILL -- "-$pid" 2>/dev/null
  # shellcheck disable=SC2086
  kill -KILL $members 2>/dev/null
  return 0
}

# A closed terminal (HUP), a stop (TERM) or ctrl-c (INT): stop the command.
# The script then carries on to its usual ending, so the output and a result
# still reach Harbor and nothing is left behind.
on_signal() {
  signalled=true
  stop_command
}
trap on_signal TERM HUP INT

# Fetches the run's files into HARBOR_RUN_DIR. They are never printed. A
# Harbor that gives no answer (it may be starting) is asked again for a while.
fetch_bundle() {
  for name in $HARBOR_RUNNER_BUNDLE; do
    while :; do
      status=$(curl -sS -m 60 --retry 2 -X POST -H "Authorization: Bearer $HARBOR_RUNNER_TOKEN" \
        -o "$HARBOR_RUN_DIR/$name" -w '%{http_code}' "$HARBOR_RUNNER_URL/bundle/$name${attempt:+?$attempt}" 2>/dev/null)
      heard "$status"
      [ "$reached" = 0 ] && [ "$signalled" = false ] && ! out_of_patience "$start_patience" || break
      pause
    done
    case "$status" in
      2??) ;;
      *)
        # A refusal's body is Harbor's reason, never the file.
        reason=$(head -c 300 "$HARBOR_RUN_DIR/$name" 2>/dev/null | tr '\n' ' ')
        rm -f "$HARBOR_RUN_DIR/$name"
        echo "harbor-runner: could not fetch this run's $name from Harbor (HTTP ${status:-none}) $reason" >> "$out"
        return 1 ;;
    esac
  done
}

# What the command's own shell does first: drop the run's token, take the
# environment Harbor sent, then become the command.
launch='unset HARBOR_RUNNER_TOKEN; if [ -f "$HARBOR_RUN_DIR/env" ]; then . "$HARBOR_RUN_DIR/env"; fi; exec sh -c "$1"'

if ! fetch_bundle; then
  cat "$out"
  code=70
elif [ "$signalled" = true ]; then
  code=143
else
  # The command gets a process group of its own, so all of it can be stopped
  # at once: through setsid where there is one, else the shell's job control.
  if command -v setsid >/dev/null 2>&1; then
    setsid sh -c "$launch" harbor-command "$1" < /dev/null > "$out" 2>&1 &
    pid=$!
  else
    set -m 2>/dev/null
    sh -c "$launch" harbor-command "$1" < /dev/null > "$out" 2>&1 &
    pid=$!
    set +m 2>/dev/null
  fi
  # Whoever has the terminal open sees the output too.
  tail -f "$out" 2>/dev/null &
  viewer=$!

  while kill -0 "$pid" 2>/dev/null; do
    # A backlog larger than one post goes out without waiting in between.
    while flush && [ "$size" -gt "$sent" ]; do :; done
    beat
    # Harbor finished the run itself (a stop, a timeout), or started it again
    # somewhere else: nothing is wanted from this command any more.
    [ "$closed" = 0 ] || stop_command
    sleep 1
  done
  wait "$pid"
  code=$?
fi

# The command is over, so what was fetched for it (its prompt, its secrets)
# goes now: delivering the output can take as long as Harbor is away. Only
# this script's own files, whose names start with a dot, are still needed.
rm -rf "$HARBOR_RUN_DIR"/*
drain
[ -z "$viewer" ] || kill "$viewer" 2>/dev/null
# The run's folder goes before the result does. Harbor closes the terminal as
# soon as it has the result, and a script stopped there would leave it.
rm -rf "$HARBOR_RUN_DIR"
# The result is what ends the run on Harbor, so it is offered for as long as
# Harbor gives no answer and patience lasts. Any answer at all settles it.
while :; do
  status=$(curl -sS -m 30 --retry 2 -X POST -H "Authorization: Bearer $HARBOR_RUNNER_TOKEN" -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' --data "{\"exit_status\":$code,\"signalled\":$signalled}" \
    "$HARBOR_RUNNER_URL/result${attempt:+?$attempt}" 2>/dev/null)
  heard "$status"
  [ "$reached" = 0 ] && ! out_of_patience "$patience" || break
  pause
done
exit "$code"
