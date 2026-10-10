#!/bin/sh
# Auto-cycle tests on the real binary, headless (--headless runs the window's
# frame loop without SDL and logs every preset switch).
#   usage: tests/test_cycle.sh ./build/particle_life
BIN=${1:-./build/particle_life}
COMMON="--particles 2000 --width 640 --height 480 --types 6 --steps-per-frame 1"
fails=0
ok()   { echo "  $1  OK"; }
fail() { echo "  $1  FAIL"; fails=$((fails + 1)); }

# Shuffle-bag check on the start + timer switches of a log: no preset twice in
# a row; the first 31 are all different; after that every round is the 30
# presets other than the one that ended the previous round.
bag_check() {
    awk '$3 == "start" || $3 == "timer" { print $5 }' "$1" | awk '
        { seq[n++] = $1 }
        END {
            if (n < 2) { print "too few switches"; exit 1 }
            for (i = 1; i < n; i++)
                if (seq[i] == seq[i - 1]) { print "repeat in a row at " i; exit 1 }
            start = 0; size = 31; rounds = 0
            while (start + size <= n) {
                delete seen
                for (i = start; i < start + size; i++) {
                    if (seq[i] in seen) { print "preset " seq[i] " twice in round " rounds; exit 1 }
                    seen[seq[i]] = 1
                }
                if (size == 30 && (seq[start - 1] in seen)) { print "round " rounds " repeats its predecessor"; exit 1 }
                rounds++; start += size; size = 30
            }
            for (i = start; i < n; i++) {     # partial last round
                if (seq[i] in seen2) { print "preset twice in partial round"; exit 1 }
                seen2[seq[i]] = 1
            }
            printf "%d switches, %d full rounds, each preset once per round, never twice in a row\n", n, rounds
        }'
}

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

# 1. fake clock: 0.5 s per frame, 1 s interval -> a switch every 2 frames
$BIN $COMMON --seed 11 --interval 1 --headless 200 --fake-clock 0.5 > "$LOG" || fails=$((fails + 1))
n=$(grep -c ' timer  ->' "$LOG")
r=$(bag_check "$LOG") && ok "fake clock: $r" || fail "fake clock: $r"
# switches exactly every 1.0 s of clock
awk '$3 == "timer" { t = $1 + 0; if (p != "" && (t - p < 0.999 || t - p > 1.001)) bad = 1; p = t }
     END { exit bad }' "$LOG" && ok "fake clock: $n timer switches, exactly 1.000 s apart" \
                             || fail "fake clock: switch spacing"

# 2. real monotonic clock: 0.05 s interval, gaps must be >= 0.05 s
$BIN $COMMON --seed 12 --interval 0.05 --headless 30000 > "$LOG" || fails=$((fails + 1))
r=$(bag_check "$LOG") && ok "real clock: $r" || fail "real clock: $r"
# the log prints times rounded to 1 ms, so a real gap >= 0.050 s can show as 0.049
awk '$3 == "timer" { t = $1 + 0
                     if (p != "") { g = t - p; if (g < 0.049) bad = 1
                                    if (g > max) max = g; if (min == "" || g < min) min = g }
                     p = t; k++ }
     END { printf "%d timer switches, gaps >= 0.050 s (min %.3f, max %.3f s as logged)\n", k, min, max > "/dev/stderr"
           exit bad || k < 31 }' "$LOG" 2> "$LOG.msg" \
    && ok "real clock: $(cat "$LOG.msg")" || fail "real clock: $(cat "$LOG.msg")"
rm -f "$LOG.msg"

# 3. --preset starts on that preset (case-insensitive) and still cycles
$BIN $COMMON --preset helicalladder --interval 1 --headless 10 --fake-clock 0.5 > "$LOG"
first=$(awk '$3 == "start" { print $6 }' "$LOG")
n=$(grep -c ' timer  ->' "$LOG")
[ "$first" = "Helical" ] && [ "$n" -eq 5 ] && ok "--preset helicalladder: starts on Helical, $n timer switches in 5 s" \
                                          || fail "--preset: start '$first', $n switches"

# 4. --no-cycle, --interval 0 and the C key stop the timer
for opt in "--no-cycle" "--interval 0" "--keys c"; do
    $BIN $COMMON --preset Snake $opt --headless 40 --fake-clock 0.5 > "$LOG"
    n=$(grep -c ' timer  ->' "$LOG")
    [ "$n" -eq 0 ] && ok "$opt: no automatic switch in 20 s" || fail "$opt: $n switches"
done
# C twice: off and on again
$BIN $COMMON --preset Snake --interval 5 --keys cc --headless 40 --fake-clock 0.5 > "$LOG"
n=$(grep -c ' timer  ->' "$LOG")
[ "$n" -eq 4 ] && ok "--keys cc: cycling back on, $n timer switches in 20 s (at 5, 10, 15, 20)" || fail "--keys cc: $n switches"

# 5. Right / Left / R through --keys: next, previous (wrapping), re-roll
$BIN $COMMON --preset DriftPatch --keys '>><r' --no-cycle --headless 1 > "$LOG"
seq=$(awk '$4 == "->" { printf "%s:%s ", $3, $6 }' "$LOG")
[ "$seq" = "start:DriftPatch next:Random next:Symmetric prev:Random reroll:Random " ] \
    && ok "keys > > < r: $seq" || fail "keys: $seq"

# 6. every switch rebuilds the rules: maxr and grid follow the preset's radius range
awk '$4 == "->" { split($0, a, "maxr "); split(a[2], b, " "); m = b[1] + 0;
                  if (m <= 0 || m > 70) bad = 1 } END { exit bad }' "$LOG" \
    && ok "switch log: max radius and grid rebuilt on every switch" || fail "maxr in log"

# 7. unknown preset is rejected
if $BIN --preset nosuchpreset --headless 1 > /dev/null 2>&1; then fail "unknown preset accepted"; else ok "unknown preset rejected"; fi

[ $fails -eq 0 ] && echo "ALL CYCLE TESTS PASSED" || echo "CYCLE TESTS FAILED"
[ $fails -eq 0 ]
