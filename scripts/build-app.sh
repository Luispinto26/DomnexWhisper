#!/bin/bash
# Builds ~/Applications/DomnexWhisper.app and signs it.
# Signing with the same certificate every time keeps the Accessibility and microphone
# permissions across rebuilds. Override the identity with DOMNEXWHISPER_SIGN_IDENTITY.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN_DIR=$(swift build -c release --arch arm64 --show-bin-path)

# Not inside the project: the Desktop syncs to iCloud, which re-adds Finder xattrs and breaks the signature.
APP_DIR="${DOMNEXWHISPER_APP_DIR:-$HOME/Applications}"
mkdir -p "$APP_DIR"
APP="$APP_DIR/DomnexWhisper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DomnexWhisper" "$APP/Contents/MacOS/DomnexWhisper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/Symbol.svg "$APP/Contents/Resources/"

IDENTITY="${DOMNEXWHISPER_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
fi
if [ -z "$IDENTITY" ]; then
  echo "Nenhum certificado 'Apple Development' encontrado; a assinar ad hoc (as permissões vão ser pedidas de novo a cada compilação)."
  IDENTITY="-"
fi
# Extended attributes (Finder info, provenance) make codesign fail.
xattr -cr "$APP"
codesign --force --options runtime --entitlements Resources/DomnexWhisper.entitlements --sign "$IDENTITY" "$APP"
echo "Pronto: $APP (assinado com $IDENTITY)"
