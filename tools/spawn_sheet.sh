#!/bin/sh
# Contact sheet of every spawn layout: one frame at step 0 and one after
# STEPS steps, same preset (curated SkipPursuit, K = 7), palette and seed;
# labels burned in. -> docs/spawns.png
#   usage: tools/spawn_sheet.sh [STEPS] [OUT]
set -e
BIN=./build/particle_life
STEPS=${1:-300}
OUT=${2:-docs/spawns.png}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
$BIN --list-spawns | while read -r idx name rest; do
    for s in 0 "$STEPS"; do
        f=$(printf '%s/%02d_%04d.ppm' "$TMP" "$idx" "$s")
        $BIN --preset SkipPursuit --spawn "$name" --palette neon-spectrum --particles 6000 \
             --width 800 --height 450 --seed 3 --threads 4 --steps "$s" --dump-frame "$f" > /dev/null
        magick "$f" -resize 320x180 -set label "$name, step $s" "${f%.ppm}.png"
    done
done
montage "$TMP"/*.png -tile 6x -geometry +3+3 -background '#202020' -fill '#e0e0e0' \
        -font DejaVu-Sans -pointsize 13 -depth 8 -colors 256 "PNG8:$OUT"
echo "wrote $OUT (18 layouts, step 0 and step $STEPS)"
