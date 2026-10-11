#!/bin/sh
# Auto-cycle and key tests on the real binary, headless (--headless runs the
# window's frame loop without SDL and logs every switch).
#   usage: tests/test_cycle.sh ./build/particle_life
#
# Switch log fields: $1 time, $3 reason, $5 entry, $6 name, $7 list,
# $8 K=n, $10 spawn, $12 palette. Other events (S, N, K keys): $3 reason,
# $6 spawn, $8 palette, $9 K=n.
BIN=${1:-./build/particle_life}
COMMON="--particles 2000 --width 640 --height 480 --steps-per-frame 1"
fails=0
ok()   { echo "  $1  OK"; }
fail() { echo "  $1  FAIL"; fails=$((fails + 1)); }
LOG=$(mktemp)
trap 'rm -f "$LOG" "$LOG.msg"' EXIT

# Shuffle-bag check on the start + timer switches of a log, for a pool of
# $2 entries: no entry twice in a row; the first $2 all different; after
# that every round is the other entries than the one that ended the
# previous round.
bag_check() {
    awk '$3 == "start" || $3 == "timer" { print $5 }' "$1" | awk -v size="$2" '
        { seq[n++] = $1 }
        END {
            if (n < 2) { print "too few switches"; exit 1 }
            for (i = 1; i < n; i++)
                if (seq[i] == seq[i - 1]) { print "repeat in a row at " i; exit 1 }
            start = 0; sz = size; rounds = 0
            while (start + sz <= n) {
                delete seen
                for (i = start; i < start + sz; i++) {
                    if (seq[i] in seen) { print "repeat inside round " rounds; exit 1 }
                    seen[seq[i]] = 1
                }
                if (rounds > 0 && (seq[start - 1] in seen)) { print "round includes previous last"; exit 1 }
                rounds++; start += sz; sz = size - 1
            }
            printf "%d switches, %d full rounds of %d, never twice in a row\n", n, rounds, size
        }'
}

# 1. fake clock, each pool: shuffle bag, spacing, K, spawn and palette per switch
for spec in "curated 17" "generated 31" "all 48"; do
    set -- $spec
    $BIN $COMMON --pool $1 --seed 11 --interval 1 --headless 400 --fake-clock 0.5 > "$LOG" || fails=$((fails + 1))
    r=$(bag_check "$LOG" $2) && ok "pool $1, fake clock: $r" || fail "pool $1 bag: $r"
    awk '$3 == "timer" { t = $1 + 0; if (p != "" && (t - p < 0.999 || t - p > 1.001)) bad = 1; p = t; n++ }
         END { exit bad || n < 2 * '"$2"' }' "$LOG" \
        && ok "pool $1: timer switches exactly 1.000 s apart" || fail "pool $1: switch spacing"
done

# 2. per switch: curated presets bring their own K, generated draw 2..16;
#    spawn from pl-box's weighted spawn_pattern set; palette never repeated
#    in a row
$BIN $COMMON --pool all --seed 5 --interval 1 --headless 400 --fake-clock 0.5 > "$LOG"
$BIN --list-presets > "$LOG.msg"
awk 'NR == FNR { k[$1] = $4; next }
     $3 == "start" || $3 == "timer" {
         sub("K=", "", $8)
         if ($7 == "curated" && "K=" $8 != k[$5]) bad = "curated K " $8 " for " $6
         if ($7 == "generated") { if ($8 + 0 < 2 || $8 + 0 > 16) bad = "generated K " $8; gk[$8] = 1 }
         if ($10 == "ring" || $10 == "spiral" || $10 == "line_mixed" || $10 == "random" || $10 == "star") bad = "spawn " $10
         sp[$10]++
         if ($12 == last) bad = "palette twice in a row"
         last = $12; n++
     }
     END { for (x in gk) ng++; for (x in sp) ns++
           if (bad) { print bad; exit 1 }
           printf "%d switches: curated K as listed, %d different generated K in 2..16, %d spawn layouts (soft_clusters %d), palette never twice in a row\n", n, ng, ns, sp["soft_clusters"]
           exit ng < 8 || ns < 10 }' "$LOG.msg" "$LOG" > "$LOG.msg2" 2>&1 \
    && ok "$(cat "$LOG.msg2")" || fail "per-switch scene: $(cat "$LOG.msg2")"
rm -f "$LOG.msg2"

# 3. real monotonic clock: 0.05 s interval, gaps must be >= 0.05 s
$BIN $COMMON --seed 12 --interval 0.05 --headless 30000 > "$LOG" || fails=$((fails + 1))
r=$(bag_check "$LOG" 17) && ok "real clock: $r" || fail "real clock: $r"
# the log prints times rounded to 1 ms, so a real gap >= 0.050 s can show as 0.049
awk '$3 == "timer" { t = $1 + 0
                     if (p != "") { g = t - p; if (g < 0.049) bad = 1
                                    if (g > max) max = g; if (min == "" || g < min) min = g }
                     p = t; k++ }
     END { printf "%d timer switches, gaps >= 0.050 s (min %.3f, max %.3f s as logged)\n", k, min, max > "/dev/stderr"
           exit bad || k < 17 }' "$LOG" 2> "$LOG.msg" \
    && ok "real clock: $(cat "$LOG.msg")" || fail "real clock: $(cat "$LOG.msg")"

# 4. --preset starts on that preset (case-insensitive) and still cycles;
#    g: picks the generated one
$BIN $COMMON --preset helicalladder --interval 1 --headless 10 --fake-clock 0.5 > "$LOG"
first=$(awk '$3 == "start" { print $6, $7 }' "$LOG")
n=$(grep -c ' timer  ->' "$LOG")
[ "$first" = "Helical generated" ] && [ "$n" -eq 5 ] && ok "--preset helicalladder: starts on Helical (generated), $n timer switches in 5 s" \
                                                    || fail "--preset: start '$first', $n switches"
$BIN $COMMON --preset g:SkipPursuit --no-cycle --headless 1 > "$LOG"
a=$(awk '$3 == "start" { print $6, $7 }' "$LOG")
$BIN $COMMON --preset skippursuit --no-cycle --headless 1 > "$LOG"
b=$(awk '$3 == "start" { print $6, $7, $8 }' "$LOG")
[ "$a" = "SkipPursuit generated" ] && [ "$b" = "SkipPursuit curated K=7" ] \
    && ok "--preset g:SkipPursuit -> generated; skippursuit -> curated with K=7" || fail "--preset lists: '$a' / '$b'"

# 5. --no-cycle, --interval 0 and the C key stop the timer
for opt in "--no-cycle" "--interval 0" "--keys c"; do
    $BIN $COMMON --preset Shells $opt --headless 40 --fake-clock 0.5 > "$LOG"
    n=$(grep -c ' timer  ->' "$LOG")
    [ "$n" -eq 0 ] && ok "$opt: no automatic switch in 20 s" || fail "$opt: $n switches"
done
$BIN $COMMON --preset Shells --interval 5 --keys cc --headless 40 --fake-clock 0.5 > "$LOG"
n=$(grep -c ' timer  ->' "$LOG")
[ "$n" -eq 4 ] && ok "--keys cc: cycling back on, $n timer switches in 20 s (at 5, 10, 15, 20)" || fail "--keys cc: $n switches"

# 6. Right / Left / R in the curated pool: next (wrapping), previous, re-roll
$BIN $COMMON --preset Bipartite --keys '>><r' --no-cycle --headless 1 > "$LOG"
seq=$(awk '$4 == "->" && $5 != "spawn" { printf "%s:%s ", $3, $6 }' "$LOG")
[ "$seq" = "start:Bipartite next:SkipPursuit next:Conveyor prev:SkipPursuit reroll:SkipPursuit " ] \
    && ok "keys > > < r: $seq" || fail "keys: $seq"
# ... and in the generated pool
$BIN $COMMON --pool generated --preset DriftPatch --keys '>><' --no-cycle --headless 1 > "$LOG"
seq=$(awk '$4 == "->" { printf "%s:%s ", $3, $6 }' "$LOG")
[ "$seq" = "start:DriftPatch next:Random next:Symmetric prev:Random " ] \
    && ok "generated pool, keys > > <: $seq" || fail "generated keys: $seq"

# 7. P cycles the pool and switches into it
$BIN $COMMON --preset Shells --keys 'ppp' --no-cycle --headless 1 > "$LOG"
seq=$(awk '$3 == "pool" { printf "%s ", $7 }' "$LOG")
[ "$seq" = "generated curated curated " ] || [ "$seq" = "generated generated curated " ] \
    && ok "keys p p p: pool generated -> all -> curated, presets from: $seq" || fail "P key: '$seq'"

# 8. S / Shift+S / N: spawn layouts; K: palette; F: overlay
$BIN $COMMON --preset Shells --spawn pie --keys 'sssSnkkf' --no-cycle --headless 1 > "$LOG"
seq=$(awk '$3 == "spawn" || $3 == "respawn" { printf "%s ", $6 } $3 == "start" { printf "%s ", $10 }' "$LOG")
pals=$(awk '$3 == "palette" { print $8 }' "$LOG" | sort -u | wc -l)
ovl=$(grep -c 'overlay off' "$LOG")
[ "$seq" = "pie line ring rainbow_ring ring ring " ] && [ "$pals" -eq 2 ] && [ "$ovl" -eq 1 ] \
    && ok "keys s s s S n k k f: spawn $seq| 2 new palettes, overlay off" || fail "S/N/K/F keys: '$seq' $pals $ovl"

# 9. [ ] and digits change K live, keeping preset and spawn
$BIN $COMMON --preset Shells --spawn stripes --keys ']]][[3' --no-cycle --headless 1 > "$LOG"
seq=$(awk '$3 == "start" || $3 == "types" { sub("K=", "", $8); printf "%s ", $8; if ($6 != "Shells" || $10 != "stripes") bad = 1 }
           END { exit bad }' "$LOG") \
    && [ "$seq" = "7 8 9 10 9 8 3 " ] && ok "keys ] ] ] [ [ 3: K $seq(same preset and spawn)" || fail "[ ] keys: '$seq'"

# 10. --spawn, --palette and --types pin through every switch
$BIN $COMMON --pool all --spawn heart --palette aurora --types 12 --seed 3 --interval 1 --headless 40 --fake-clock 0.5 > "$LOG"
awk '$3 == "start" || $3 == "timer" { n++; if ($10 != "heart" || $12 != "aurora" || $8 != "K=12") bad = 1 }
     END { exit bad || n < 10 }' "$LOG" \
    && ok "--spawn heart --palette aurora --types 12: pinned on all $(grep -c '\-> ' "$LOG") switches" || fail "pins"

# 11. every switch rebuilds the rules: maxr and grid follow the preset's radius range
$BIN $COMMON --pool all --seed 8 --interval 1 --headless 200 --fake-clock 0.5 > "$LOG"
awk '$3 == "start" || $3 == "timer" { split($0, a, "maxr "); split(a[2], b, " "); m = b[1] + 0;
                  split(b[3], g, "x"); if (m <= 0 || m > 70 || g[1] < 3 || g[2] < 3) bad = 1; n++ }
     END { exit bad || n < 50 }' "$LOG" \
    && ok "switch log: max radius and grid rebuilt on every switch" || fail "maxr in log"

# 11b. Space = next scene now: each press switches (reason "space"), never the
# same preset twice in a row, and Z (pause) does not switch
$BIN $COMMON --preset Shells --keys '      ' --no-cycle --headless 4 > "$LOG"
n=$(grep -c ' space  ->' "$LOG")
rep=$(awk '$3 == "space" { if ($5 == last) r++; last = $5 } END { print r + 0 }' "$LOG")
[ "$n" -eq 6 ] && [ "$rep" -eq 0 ] && ok "Space: 6 presses -> 6 scene switches, none repeated back to back" || fail "Space: $n switches, $rep repeats"
$BIN $COMMON --preset Shells --keys 'z' --no-cycle --headless 4 > "$LOG"
n=$(grep -c ' space  ->' "$LOG")
[ "$n" -eq 0 ] && ok "Z: pause key does not switch scenes" || fail "Z switched $n times"

# 11c. --mutate: every N seconds 1 or 2 rule values are re-drawn, no scene switch
$BIN $COMMON --preset Shells --interval 1000 --mutate 5 --fake-clock 1 --headless 62 > "$LOG"
m=$(grep -c ' mutate [12] rule' "$LOG")
sw=$(grep -c ' -> ' "$LOG")
[ "$m" -eq 12 ] && [ "$sw" -eq 1 ] && ok "mutate: 12 re-rolls in 60 s at 5 s, each 1 or 2 values, no scene switch" || fail "mutate: $m re-rolls, $sw switches"
$BIN $COMMON --preset Shells --interval 1000 --mutate 0 --fake-clock 1 --headless 62 > "$LOG"
m=$(grep -c ' mutate ' "$LOG")
[ "$m" -eq 0 ] && ok "mutate 0: off" || fail "mutate 0 mutated $m times"

# 12. unknown names are rejected
for opt in "--preset nosuchpreset" "--spawn nosuch" "--palette nosuch" "--pool nosuch"; do
    if $BIN $opt --headless 1 > /dev/null 2>&1; then fail "$opt accepted"; else ok "$opt rejected"; fi
done

[ $fails -eq 0 ] && echo "ALL CYCLE TESTS PASSED" || echo "CYCLE TESTS FAILED"
[ $fails -eq 0 ]
