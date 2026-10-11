#!/bin/sh
# Contact sheet of the presets as the window shows them: each curated preset
# with its own type count, a spawn layout from pl-box's weighted chooser and
# a palette pick (whatever the seed gives), then a row of generated presets
# at other type counts; STEPS steps each, labels burned in.
#   usage: tools/contact_sheet.sh [STEPS] [OUT]
set -e
BIN=./build/particle_life
STEPS=${1:-600}
OUT=${2:-docs/presets.png}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
shot() {   # file label-prefix options...
    f=$1; shift
    info=$($BIN --particles 6000 --width 800 --height 450 --threads 4 --steps "$STEPS" \
                --dump-frame "$f" "$@")
    # "wrote F (WxH, after S steps, N particles, K types, NAME, spawn X, palette Y)"
    lbl=$(echo "$info" | sed 's/.*particles, \([0-9]*\) types, \(.*\), spawn \(.*\), palette \(.*\))/\2 K=\1\n\3 | \4/')
    magick "$f" -resize 320x180 -set label "$lbl" "${f%.ppm}.png"
}
i=0
$BIN --list-presets | awk '$3 == "curated" { print $1, $2 }' | while read -r idx name; do
    shot "$(printf '%s/a%02d.ppm' "$TMP" "$idx")" --preset "c:$name" --seed $((idx + 1))
done
n=0
for spec in "g:RPS 3 fire" "g:Snake 5 aurora" "g:Chains2 12 neon-spectrum" "g:RingRoad 16 tropical-punch" \
            "g:TriSpiral 4 ocean-blues" "g:BiasedWave 10 candy-neon" "g:PrimeHop 14 rainbow-bold"; do
    set -- $spec
    shot "$(printf '%s/b%02d.ppm' "$TMP" "$n")" --preset "$1" --types "$2" --palette "$3" --seed $((n + 40))
    n=$((n + 1))
done
montage "$TMP"/*.png -tile 6x -geometry +3+3 -background '#202020' -fill '#e0e0e0' \
        -font DejaVu-Sans -pointsize 13 -depth 8 -colors 256 "PNG8:$OUT"
echo "wrote $OUT ($STEPS steps per preset)"
