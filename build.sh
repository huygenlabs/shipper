#!/bin/sh
# Builds build.noindex/Shipper.app (universal, Developer ID signed, hardened runtime) and a notarized Shipper.dmg.
set -e
cd "$(dirname "$0")"
ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS
APP="build.noindex/Shipper.app"  # .noindex: Spotlight skips it, so only the installed copy shows up in search
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release $ARCHS --show-bin-path)/Shipper" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"
# Developer ID so Gatekeeper accepts it once notarized. Keychain and the updater trust the team, not one certificate,
# so renewing the certificate keeps both working.
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Lovepreet Singh (47QKUD5PBL)}"  # SIGN_IDENTITY=- for ad hoc
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
echo "Built $APP"

# Drag-to-install disk image: the app next to an Applications shortcut.
STAGE="build.noindex/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Shipper -srcfolder "$STAGE" -ov -format UDZO Shipper.dmg >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" Shipper.dmg
# Notary credentials, stored once with: xcrun notarytool store-credentials shipper-notary
# SKIP_NOTARIZE=1 for a quick local build; never release one, since other Macs will block it.
if [ "${SKIP_NOTARIZE:-0}" != 1 ]; then
  xcrun notarytool submit Shipper.dmg --keychain-profile shipper-notary --wait
  xcrun stapler staple Shipper.dmg
fi
echo "Built Shipper.dmg"
