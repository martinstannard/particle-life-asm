#!/bin/sh
# Contact sheet of all presets: one --dump-frame per preset (same seed, size,
# particle count and step count), brightened, labelled and tiled into
# docs/presets.png.
#   usage: tools/contact_sheet.sh [STEPS] [OUT]
set -e
BIN=./build/particle_life
STEPS=${1:-1200}
OUT=${2:-docs/presets.png}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
i=0
$BIN --list-presets | while read -r idx name; do
    f=$(printf '%s/%02d.ppm' "$TMP" "$idx")
    $BIN --preset "$name" --particles 5000 --types 8 --width 960 --height 540 \
         --seed 1 --threads 8 --steps "$STEPS" --dump-frame "$f" > /dev/null
    magick "$f" -resize 400x225 -level 0%,45% -set label "$idx $name" "${f%.ppm}.png"
done
montage "$TMP"/*.png -tile 6x -geometry +3+3 -background '#202020' -fill '#e0e0e0' \
        -font DejaVu-Sans -pointsize 15 -depth 8 -colors 256 "PNG8:$OUT"
echo "wrote $OUT ($STEPS steps per preset)"
