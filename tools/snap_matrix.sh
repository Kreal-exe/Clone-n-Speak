#!/bin/bash
# Snapshots of every page for theme x palette x window size, into /tmp/cns-snap-matrix/<size>/<theme>/<palette>/<page>[-N].png
# Cold start per run (-theme, -OVPalette). Needs a built app: CI=1 INSTALL_DIR=/tmp/cns-5.7-app ./build.sh
#
#   tools/snap_matrix.sh                                                    the full matrix
#   THEMES="dark" PALETTES="applio" SIZES="default" tools/snap_matrix.sh    a slice
#   PAGES=synth,models  restricts the pages; FLIP=sunset adds <page>-flip.png (palette switched on the fly);
#   SNAP_LOG=<file> keeps the app's stderr.
#   EXTRA_ARGS="-OVA11yDump YES" adds launch arguments.
#   APP=<path to .app> and OUT=<dir> override the build and the output folder.
set -euo pipefail
APP="${APP:-/tmp/cns-5.7-app/Clone'n'Speak.app}"
OUT="${OUT:-/tmp/cns-snap-matrix}"
THEMES="${THEMES:-dark light}"
PALETTES="${PALETTES:-applio emerald midnight}"
SIZES="${SIZES:-default 1100x624 820x560}"
BIN="$APP/Contents/MacOS/Clone'n'Speak"
for size in $SIZES; do
  for theme in $THEMES; do
    for pal in $PALETTES; do
      dir="$OUT/$size/$theme/$pal"
      rm -rf "$dir"; mkdir -p "$dir"
      export OV_SNAPSHOT_DIR="$dir"
      if [ "$size" = default ]; then unset OV_SNAPSHOT_SIZE; else export OV_SNAPSHOT_SIZE="$size"; fi
      if [ -n "${PAGES:-}" ]; then export OV_SNAPSHOT_PAGES="$PAGES"; fi
      if [ -n "${FLIP:-}" ]; then export OV_SNAPSHOT_FLIP="$FLIP"; fi
      # -OVPalette on the command line pins the palette (a live OVTheme setPaletteId: cannot override it), so FLIP runs use PALETTES=stored
      palarg=(-OVPalette "$pal"); if [ "$pal" = stored ]; then palarg=(); fi
      "$BIN" -autoSetup NO -disableLegacyMigration YES -migratedFromOmniVoiceUA YES -theme "$theme" ${EXTRA_ARGS:-} ${palarg[@]+"${palarg[@]}"} >/dev/null 2>>"${SNAP_LOG:-/dev/null}" || true
      echo "$dir: $(ls "$dir" | wc -l | tr -d ' ') files"
    done
  done
done
