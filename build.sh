#!/bin/bash
# Builds Clone'n'Speak and installs it into /Applications, then opens it. Only the Command Line Tools are needed.
#
#   ./build.sh          build, install into /Applications and open the app
#   ./build.sh --test   run the Python tests first
#   ./build.sh --zip    also write dist/CloneNSpeak-v<version>.zip for a release
#   ./build.sh --dmg    also write dist/CloneNSpeak-v<version>.dmg (app, Applications link and an
#                       "Allow Clone'n'Speak to open" script that clears the quarantine flag)
#
# INSTALL_DIR=~/Applications ./build.sh installs somewhere else.
# SIGN_IDENTITY="Developer ID Application: …" signs for distribution (default: ad-hoc);
# with NOTARY_PROFILE=<notarytool keychain profile> the --zip and --dmg are notarized and stapled too.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="Clone'n'Speak"
BUNDLE_ID="com.clonenspeak.mac"
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ROOT/Sources/Info.plist")"
DEST="${INSTALL_DIR:-/Applications}"
SIGN="${SIGN_IDENTITY:--}"
TEST=0; ZIP=0; DMG=0
for arg in "$@"; do
  case "$arg" in
    --test) TEST=1 ;;
    --zip)  ZIP=1 ;;
    --dmg)  DMG=1 ;;
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
  -framework NaturalLanguage -framework QuartzCore -framework CoreMedia -framework Security \
  "$ROOT"/Sources/*.m -o "$APP/Contents/MacOS/$NAME"

cp "$ROOT/Sources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$RES/py"
cp "$ROOT"/Sources/*.py "$RES/py/"   # worker.py and the cns_* modules; the app copies them into its Python runtime
for lproj in "$ROOT"/Resources/*.lproj; do
  mkdir -p "$RES/$(basename "$lproj")"
  cp "$lproj"/*.strings "$RES/$(basename "$lproj")/"
done
cp "$ROOT/Resources/themes.json" "$RES/themes.json"
cp "$ROOT/Resources/bridge-pin.json" "$RES/bridge-pin.json"   # Bridge: pinned address and checksums of the tunnel program
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

if [ "$DMG" = 1 ]; then
  # The app next to a link to Applications: open the image, drag one onto the other. The script next to them clears
  # the quarantine flag a download puts on an unnotarized app (copying it to Applications first if needed) and opens it.
  STAGE="$OUT/dmg"
  mkdir -p "$STAGE" "$ROOT/dist"
  ditto "$APP" "$STAGE/$NAME.app"
  ln -s /Applications "$STAGE/Applications"
  ALLOW="$STAGE/Allow $NAME to open.command"
  cat > "$ALLOW" <<'SCRIPT'
#!/bin/bash
# Clears the quarantine flag from Clone'n'Speak in Applications so it opens with a double-click.
# Copies it there from this disk image first when it is not installed yet.
APP="/Applications/Clone'n'Speak.app"
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ ! -d "$APP" ]; then
  echo "Copying Clone'n'Speak to Applications..."
  ditto "$HERE/Clone'n'Speak.app" "$APP" || { echo "Could not copy it. Drag Clone'n'Speak onto Applications, then run this again."; exit 1; }
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || sudo xattr -dr com.apple.quarantine "$APP"
echo "Done: Clone'n'Speak is allowed to open."
open "$APP"
SCRIPT
  chmod +x "$ALLOW"
  DMGFILE="$ROOT/dist/CloneNSpeak-v$VERSION.dmg"
  rm -f "$DMGFILE"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMGFILE" >/dev/null
  if [ "$SIGN" != "-" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    codesign --force --timestamp --sign "$SIGN" "$DMGFILE"
    xcrun notarytool submit "$DMGFILE" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMGFILE"
  fi
  echo "Release disk image: $DMGFILE"
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
# A copy that came through a browser or AirDrop carries the quarantine flag; Gatekeeper would refuse the
# unnotarized app. Clearing it here makes the installed copy open with a double-click.
xattr -dr com.apple.quarantine "$DEST/$NAME.app" 2>/dev/null || true
echo "Installed: $DEST/$NAME.app"

# Opened right away, except on a CI runner.
[ -n "${CI:-}" ] || open "$DEST/$NAME.app"
exit 0
