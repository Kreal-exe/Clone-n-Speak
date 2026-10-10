#!/bin/bash
# Builds Clone'n'Speak and installs it into /Applications. Only the Command Line Tools are needed.
#
#   ./build.sh          build and install (relaunches the app if it was running)
#   ./build.sh --test   run the Python tests first
#   ./build.sh --zip    also write dist/CloneNSpeak-v<version>.zip for a release
#
# INSTALL_DIR=~/Applications ./build.sh installs somewhere else.
# SIGN_IDENTITY="Developer ID Application: …" signs for distribution (default: ad-hoc);
# with NOTARY_PROFILE=<notarytool keychain profile> the --zip is notarized and stapled too.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="Clone'n'Speak"
BUNDLE_ID="com.clonenspeak.mac"
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ROOT/Sources/Info.plist")"
DEST="${INSTALL_DIR:-/Applications}"
SIGN="${SIGN_IDENTITY:--}"
TEST=0; ZIP=0
for arg in "$@"; do
  case "$arg" in
    --test) TEST=1 ;;
    --zip)  ZIP=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

python3 "$ROOT/tools/strings.py" check

if [ "$TEST" = 1 ]; then
  # The tests need num2words/numpy/scipy; the app's own runtime has them once it has been set up.
  PY="${PYTHON:-$HOME/Library/Application Support/$NAME/runtime/.venv/bin/python}"
  [ -x "$PY" ] || PY=python3
  (cd "$ROOT" && "$PY" -m unittest discover -s tests)
fi

# Build outside the project: synced folders (iCloud Documents) attach extended
# attributes to everything, and codesign refuses bundles that carry them.
OUT="$(mktemp -d -t clonenspeak)"
trap 'rm -rf "$OUT"' EXIT
APP="$OUT/$NAME.app"
RES="$APP/Contents/Resources"

echo "Building $NAME $VERSION..."
mkdir -p "$APP/Contents/MacOS" "$RES" "$OUT/AppIcon.iconset"

clang -fobjc-arc -O2 -mmacosx-version-min=13.0 -arch arm64 -Wall -Werror \
  -framework Cocoa -framework AVFAudio -framework AVFoundation -framework UniformTypeIdentifiers \
  -framework NaturalLanguage -framework QuartzCore \
  "$ROOT"/Sources/*.m -o "$APP/Contents/MacOS/$NAME"

cp "$ROOT/Sources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/worker.py" "$RES/worker.py"   # the app copies it into its Python runtime
for lproj in "$ROOT"/Resources/*.lproj; do
  mkdir -p "$RES/$(basename "$lproj")"
  cp "$lproj"/*.strings "$RES/$(basename "$lproj")/"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The icon is drawn in code.
clang -fobjc-arc -mmacosx-version-min=13.0 -framework Cocoa "$ROOT/tools/make_icon.m" -o "$OUT/make_icon"
"$OUT/make_icon" "$OUT/icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$OUT/icon.png" --out "$OUT/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$OUT/icon.png" --out "$OUT/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$OUT/AppIcon.iconset" -o "$RES/AppIcon.icns"

# Ad-hoc signature unless a Developer ID is given; the entitlement allows the microphone.
if [ "$SIGN" = "-" ]; then
  codesign --force --sign - --entitlements "$ROOT/Sources/CloneNSpeak.entitlements" "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN" \
    --entitlements "$ROOT/Sources/CloneNSpeak.entitlements" "$APP"
fi
codesign --verify --strict "$APP"

if [ "$ZIP" = 1 ]; then
  mkdir -p "$ROOT/dist"
  ZIPFILE="$ROOT/dist/CloneNSpeak-v$VERSION.zip"
  rm -f "$ZIPFILE"
  ditto -c -k --norsrc --keepParent "$APP" "$ZIPFILE"
  if [ "$SIGN" != "-" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$ZIPFILE" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIPFILE"
    ditto -c -k --norsrc --keepParent "$APP" "$ZIPFILE"
  fi
  echo "Release zip: $ZIPFILE"
fi

# Quit a running copy first (the app may ask to finish a generation; if it stays open, stop).
WAS_RUNNING=0
if pgrep -f "$DEST/$NAME.app/Contents/MacOS/" >/dev/null 2>&1; then
  WAS_RUNNING=1
  echo "Quitting the running $NAME..."
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    pgrep -f "$DEST/$NAME.app/Contents/MacOS/" >/dev/null 2>&1 || break
    sleep 0.2
  done
  if pgrep -f "$DEST/$NAME.app/Contents/MacOS/" >/dev/null 2>&1; then
    echo "$NAME is still running. Quit it and run the build again." >&2
    exit 1
  fi
fi

mkdir -p "$DEST"
rm -rf "$DEST/$NAME.app"
ditto "$APP" "$DEST/$NAME.app"
echo "Installed: $DEST/$NAME.app"

[ "$WAS_RUNNING" = 1 ] && open "$DEST/$NAME.app"
exit 0
