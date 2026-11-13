#!/bin/sh
# Stands in for curl in the runner script's tests: a small Harbor that keeps
# what it is sent in files under $FAKE_CURL_DIR instead of on the network.
#
#   log        the bytes accepted so far      posts   one line per log post: "<offset> <bytes>"
#   result     each reported result's body    argv    one line per call: everything it was run with
#   bundle/    the files a run may fetch
#
# A test steers it by leaving a file behind, used once:
#   lose-answer  take the next log post, then fail as if the answer was lost
#   rewind       forget all but this many bytes and say so (409) on the next log post
#   finished     answer every log post with 409 "finished"
dir=$FAKE_CURL_DIR
echo "$*" >> "$dir/argv"
body="" data="" reply=/dev/null url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary) body="${2#@}"; shift ;;
    --data) data="$2"; shift ;;
    -o) reply="$2"; shift ;;
    -H|-m|--retry|-X|-w) shift ;;
    http*) url="$1" ;;
  esac
  shift
done

answer() {
  printf '%s' "$2" > "$reply"
  printf '%s' "$1"
  exit 0
}

case "$url" in
  */log\?*)
    offset=${url#*offset=}
    offset=${offset%%&*}
    touch "$dir/log"
    received=$(wc -c < "$dir/log" | tr -d ' ')
    [ ! -f "$dir/finished" ] || answer 409 finished
    if [ -f "$dir/rewind" ]; then
      keep=$(cat "$dir/rewind")
      rm -f "$dir/rewind"
      head -c "$keep" "$dir/log" > "$dir/log.kept" && mv "$dir/log.kept" "$dir/log"
      answer 409 "$keep"
    fi
    [ "$offset" -le "$received" ] || answer 409 "$received"
    sent=$(wc -c < "$body" | tr -d ' ')
    echo "$offset $sent" >> "$dir/posts"
    tail -c "+$((received - offset + 1))" "$body" >> "$dir/log"
    if [ -f "$dir/lose-answer" ]; then
      rm -f "$dir/lose-answer"
      printf '000'
      exit 28
    fi
    answer 204 "" ;;
  */result*)
    # What the runner still had on disk when it reported.
    ls "$dir/tmp" > "$dir/at_result" 2>/dev/null
    printf '%s\n' "$data" >> "$dir/result"
    answer 204 "" ;;
  */bundle/*)
    name=${url##*/bundle/}
    name=${name%%\?*}
    [ -f "$dir/bundle/$name" ] || answer 404 "no such file"
    cat "$dir/bundle/$name" > "$reply"
    printf '200' ;;
  *) answer 404 "" ;;
esac
