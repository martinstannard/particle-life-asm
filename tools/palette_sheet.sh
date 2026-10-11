#!/bin/sh
# docs/palettes.png: every palette at K = 4, 8, 16 as the program builds it
# (a dark line through a set = it does not qualify for that K)
set -e
make -s build/sim.o build/threads.o build/presets.o build/spawn.o build/palettes.o \
        build/palettes_data.o build/render.o build/font.o
gcc -O2 -o build/palette_sheet tools/palette_sheet.c build/palettes.o build/palettes_data.o \
    build/render.o build/font.o build/sim.o build/threads.o build/presets.o build/spawn.o -lm -lpthread
./build/palette_sheet build/palettes.ppm
magick build/palettes.ppm PNG24:docs/palettes.png
echo "wrote docs/palettes.png"
