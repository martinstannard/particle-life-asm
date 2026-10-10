#!/bin/sh
# Runs pl-box's own code: the rule generators (RuleMatrix::from_preset,
# default, -> tests/plbox_ref.txt) or with BIN=spawns the spawn layouts
# (-> tests/plbox_spawns.txt). pl-box is not modified: its pl-core crate is
# copied into a temporary workspace next to this dump program, built offline.
#   usage: [BIN=spawns] tools/plbox_dump/run.sh [~/code/pl-box] > tests/plbox_ref.txt
set -e
PLBOX=${1:-$HOME/code/pl-box}
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/crates/dump/src"
cp -r "$PLBOX/crates/pl-core" "$TMP/crates/"
rm -rf "$TMP/crates/pl-core/benches"
sed -i '/\[dev-dependencies\]/,$d' "$TMP/crates/pl-core/Cargo.toml"
cp "$PLBOX/Cargo.lock" "$TMP/"
cp "$HERE/Cargo.toml" "$TMP/crates/dump/"
cp -r "$HERE/src/." "$TMP/crates/dump/src/"
sed -n '/^\[workspace.package\]/,$p' "$PLBOX/Cargo.toml" > "$TMP/ws.toml"
printf '[workspace]\nresolver = "2"\nmembers = ["crates/pl-core", "crates/dump"]\n\n' | cat - "$TMP/ws.toml" > "$TMP/Cargo.toml"
cd "$TMP" && CARGO_TARGET_DIR="$TMP/target" cargo run --offline --release -q -p dump --bin "${BIN:-dump}"
