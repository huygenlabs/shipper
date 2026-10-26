#!/bin/sh
# Builds build/Shipper.app (universal, ad-hoc signed, hardened runtime) and Shipper.dmg from the Swift package.
set -e
cd "$(dirname "$0")"
ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS
APP="build/Shipper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release $ARCHS --show-bin-path)/Shipper" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"
# Sign with a stable self-signed identity rather than ad hoc. An ad-hoc signature changes on every build, and the
# Keychain (which trusts the app that saved the password) would ask for the Mac password after each one.
# The identity lives in its own keychain outside the repo, created on first run with a random password kept next to
# it (owner-only). Anything already running as you on this Mac could use the key through codesign regardless;
# the point is that no shared secret is published and the key file alone is useless.
SIGN_DIR="$HOME/Library/Application Support/Shipper/signing"
KC="$SIGN_DIR/signing.keychain-db"
PASS_FILE="$SIGN_DIR/keychain-password"
TMP=""
trap 'rm -rf "$TMP"; [ -f "$KC" ] && security lock-keychain "$KC" 2>/dev/null; true' EXIT
if [ ! -f "$PASS_FILE" ] || ! security find-certificate -c "Shipper Self-Signed" "$KC" >/dev/null 2>&1; then
  # First run, or a setup that stopped halfway: start the identity over.
  rm -f "$KC"
  mkdir -p "$SIGN_DIR" && chmod 700 "$SIGN_DIR"
  (umask 077 && /usr/bin/openssl rand -base64 32 > "$PASS_FILE")
  KC_PASS="$(cat "$PASS_FILE")"
  TMP="$(mktemp -d)"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Shipper Self-Signed" \
    -addext "extendedKeyUsage=codeSigning" -addext "keyUsage=critical,digitalSignature" \
    -addext "basicConstraints=critical,CA:false" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:"$KC_PASS"
  security create-keychain -p "$KC_PASS" "$KC"
  security import "$TMP/id.p12" -k "$KC" -P "$KC_PASS" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null
fi
security unlock-keychain -p "$(cat "$PASS_FILE")" "$KC"
codesign --force --options runtime --keychain "$KC" --sign "Shipper Self-Signed" "$APP"
echo "Built $APP"

# Drag-to-install disk image: the app next to an Applications shortcut.
STAGE="build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Shipper -srcfolder "$STAGE" -ov -format UDZO Shipper.dmg >/dev/null
rm -rf "$STAGE"
echo "Built Shipper.dmg"
