#!/bin/zsh
# Builds "Clone'n'Speak.app" with clang — Xcode is not required, the Command Line Tools are enough.
#
#   ./build.sh                 → build/Clone'n'Speak.app (ad-hoc signed)
#   ./build.sh --run           → build and launch
#   ./build.sh --dmg           → also dist/CloneNSpeak-<version>.dmg for publishing
#
# Publishing with a Developer ID (no Gatekeeper warning for users):
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=notary ./build.sh --dmg
#   (create the profile once: xcrun notarytool store-credentials notary --apple-id … --team-id …)
set -euo pipefail
cd "$(dirname "$0")"

NAME="Clone'n'Speak"
SLUG="CloneNSpeak"
SRC=Sources
BUILD=build
FINAL="$BUILD/$NAME.app"
# Built and signed in a temporary folder, swapped into place at the end (safe while the app is running).
# Not inside the project: in a synced folder (iCloud Drive's Documents, Dropbox…) the file provider tags
# bundles with Finder attributes, and codesign refuses to sign "detritus".
OBJ="$(mktemp -d "${TMPDIR:-/tmp}/clonenspeak.XXXXXX")"
trap 'rm -rf "$OBJ"' EXIT
APP="$OBJ/stage/$NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$SRC/Info.plist")
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
FRAMEWORKS=(-framework Cocoa -framework AVFAudio -framework AVFoundation -framework UniformTypeIdentifiers -framework NaturalLanguage -framework QuartzCore)

rm -rf "$BUILD/obj"   # left by earlier versions of this script
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD"

echo "▶ Translations"
python3 tools/strings.py check

echo "▶ Compile ($VERSION)"
clang -fobjc-arc -O2 -mmacosx-version-min=13.0 -arch arm64 -Wall -Werror "${FRAMEWORKS[@]}" \
  "$SRC"/*.m -o "$APP/Contents/MacOS/$NAME"

echo "▶ Resources"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/worker.py" "$APP/Contents/Resources/worker.py"
for lproj in Resources/*.lproj; do
  mkdir -p "$APP/Contents/Resources/${lproj:t}"
  cp "$lproj"/*.strings "$APP/Contents/Resources/${lproj:t}/"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▶ Icon"
clang -fobjc-arc -mmacosx-version-min=13.0 -framework Cocoa tools/make_icon.m -o "$OBJ/make_icon"
"$OBJ/make_icon" "$OBJ/icon_1024.png"
ICONSET="$OBJ/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$OBJ/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$OBJ/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▶ Sign (${SIGN_IDENTITY})"
xattr -cr "$APP"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - --entitlements "$SRC/CloneNSpeak.entitlements" "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    --entitlements "$SRC/CloneNSpeak.entitlements" "$APP"
fi
codesign --verify --strict "$APP"

if [[ " $* " == *" --dmg "* ]]; then
  mkdir -p dist
  DMG="dist/$SLUG-$VERSION.dmg"
  STAGE="$OBJ/dmg"
  rm -rf "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
      xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
      xcrun stapler staple "$DMG"
    fi
  fi
  echo "✔ $DMG"
fi

rm -rf "$FINAL"
mv "$APP" "$FINAL"
APP="$FINAL"
echo "✔ $APP"

if [[ " $* " == *" --run "* ]]; then
  open "$APP"
fi
