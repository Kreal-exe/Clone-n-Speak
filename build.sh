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
APP="$BUILD/obj/stage/$NAME.app"   # built here, swapped into place at the end (safe while the app is running)
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$SRC/Info.plist")
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
FRAMEWORKS=(-framework Cocoa -framework AVFAudio -framework AVFoundation -framework UniformTypeIdentifiers -framework NaturalLanguage)

rm -rf "$BUILD/obj"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/obj"

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
clang -fobjc-arc -mmacosx-version-min=13.0 -framework Cocoa tools/make_icon.m -o "$BUILD/obj/make_icon"
"$BUILD/obj/make_icon" "$BUILD/obj/icon_1024.png"
ICONSET="$BUILD/obj/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/obj/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BUILD/obj/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▶ Sign (${SIGN_IDENTITY})"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - --entitlements "$SRC/CloneNSpeak.entitlements" "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    --entitlements "$SRC/CloneNSpeak.entitlements" "$APP"
fi
codesign --verify --strict "$APP"
rm -rf "$FINAL"
mv "$APP" "$FINAL"
APP="$FINAL"
echo "✔ $APP"

if [[ " $* " == *" --dmg "* ]]; then
  mkdir -p dist
  DMG="dist/$SLUG-$VERSION.dmg"
  STAGE="$BUILD/obj/dmg"
  rm -rf "$STAGE" "$DMG"
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

if [[ " $* " == *" --run "* ]]; then
  open "$APP"
fi
