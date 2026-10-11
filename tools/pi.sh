#!/bin/sh
# Build, test and benchmark the AArch64 version on the Raspberry Pi from this
# machine, in one command, once SSH access to the Pi works (key-based login
# recommended: ssh-copy-id user@host).
#
#   tools/pi.sh [user@host] [check|test|bench|panel|present|all]
#
#   check    build only (make -j4 on the Pi), print the toolchain versions
#   test     check, then make test (all suites + the 4-thread stress test)
#   bench    check, then make bench (10k/50k/200k at 1 and 4 threads, the
#            1080x1920 panel pass, the renderer at 1080x1920) and the kernel
#            variants NEWTON=1 and KPIPE=0 at 50k particles
#   present  time the window's texture upload and present at 1080x1920 on
#            the Pi's display (needs a logged-in desktop or KMS console)
#   all      test, bench and present (default)
#
# The repository is copied to ~/particle_life_asm on the Pi (override with
# PI_DIR=...). Output is also saved to pi-<what>-<date>.log here.
set -e
PI=${1:-${PI:-pi@raspberrypi.local}}
WHAT=${2:-all}
DIR=${PI_DIR:-particle_life_asm}
cd "$(dirname "$0")/.."
LOG=pi-$WHAT-$(date +%Y%m%d-%H%M%S).log

rsync -az --delete --exclude build --exclude 'build-arm64*' --exclude .git \
    --exclude 'pi-*.log' ./ "$PI:$DIR/"

remote() {
    ssh "$PI" "cd $DIR && $1" 2>&1 | tee -a "$LOG"
}

check() {
    remote 'uname -a; gcc --version | head -1; as --version | head -1;
            sdl2-config --version 2>/dev/null || echo "libsdl2-dev missing: sudo apt install build-essential libsdl2-dev";
            grep -m1 -i "model name\|^Model" /proc/cpuinfo; grep -m1 Features /proc/cpuinfo;
            nproc; free -m | head -2;
            make -j4 ARCH=aarch64 all build-arm64/test_step build-arm64/test_threads'
}
tests() {
    remote 'make ARCH=aarch64 test'
}
bench() {
    remote 'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null; vcgencmd measure_temp 2>/dev/null || true;
            make ARCH=aarch64 bench'
    for v in newton1:NEWTON=1 plain:KPIPE=0; do
        name=${v%%:*} var=${v#*:}
        remote "make -j4 ARCH=aarch64 $var BUILD=build-arm64-$name build-arm64-$name/particle_life >/dev/null &&
                echo '--- kernel variant $var' &&
                for t in 1 4; do ./build-arm64-$name/particle_life --bench 200 --warmup 100 \\
                  --particles 50000 --width 4293 --height 2415 --types 6 --seed 1 --threads \$t; done"
    done
    remote 'echo "--- C reference (gcc -O3 -mcpu=cortex-a72)"; make ARCH=aarch64 bench-ref'
}
present() {
    # the window needs the Pi's display: Wayland desktop, X11, or KMS console
    remote 'export XDG_RUNTIME_DIR=/run/user/$(id -u);
            if [ -S "$XDG_RUNTIME_DIR/wayland-0" ]; then export WAYLAND_DISPLAY=wayland-0;
            elif [ -e /tmp/.X11-unix/X0 ]; then export DISPLAY=:0;
            else export SDL_VIDEODRIVER=kmsdrm; fi;
            for p in "--present texture" "--present texture --rotate 90" "--present surface"; do
              ./build-arm64/particle_life --width 1080 --height 1920 --fullscreen --particles 20000 \
                --no-vsync --bench-present 300 $p || true;
            done'
}

case $WHAT in
    check) check ;;
    test) check; tests ;;
    bench) check; bench ;;
    panel|present) check; present ;;
    all) check; tests; bench; present ;;
    *) echo "unknown action $WHAT"; exit 2 ;;
esac
echo "log: $LOG"
