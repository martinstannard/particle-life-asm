#!/bin/sh
# Runs the real SDL window for SECONDS and prints its title once a second,
# read from the compositor (niri). Only the window this run created is read
# (window ids present before the launch are ignored), so another
# particle_life window that is already open cannot be mistaken for it.
#   usage: tools/window_titles.sh SECONDS [particle_life options...]
set -e
SECS=${1:-20}; shift || true
BIN=${BIN:-./build/particle_life}
export NIRI_SOCKET=${NIRI_SOCKET:-$(ls /run/user/$(id -u)/niri*.sock | head -1)}
ids() { niri msg -j windows | python3 -c 'import json,sys; print(" ".join(str(w["id"]) for w in json.load(sys.stdin)))'; }
before=" $(ids) "
timeout "$SECS" "$BIN" "$@" > /dev/null &
pid=$!
start=$(date +%s.%N)
id=""
while kill -0 "$pid" 2> /dev/null; do
    sleep 1
    if [ -z "$id" ]; then
        for w in $(ids); do
            case "$before" in *" $w "*) ;; *) id=$w ;; esac
        done
    fi
    [ -n "$id" ] || continue
    t=$(niri msg -j windows | python3 -c "import json,sys
for w in json.load(sys.stdin):
    if w['id'] == $id: print(w['title'])")
    [ -n "$t" ] && printf '%5.1f s  window %s  %s\n' "$(echo "$(date +%s.%N) - $start" | bc)" "$id" "$t"
done
wait "$pid" 2> /dev/null || true
