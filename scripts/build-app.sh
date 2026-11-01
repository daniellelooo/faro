#!/bin/sh
# Compila Faro en modo release, arma dist/Faro.app, la firma y la copia a /Applications.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product Faro
APP=dist/Faro.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Faro "$APP/Contents/MacOS/Faro"
[ -f Resources/AppIcon.icns ] || ./scripts/make-icns.sh
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Adaptador de "Ahora suena" (se carga dentro de /usr/bin/perl).
clang -dynamiclib -fobjc-arc -framework Foundation -O2 -o "$APP/Contents/Resources/libDictaNowPlaying.dylib" NowPlaying/adapter.m
cp NowPlaying/now-playing.pl "$APP/Contents/Resources/now-playing.pl"
VERSION=$(git rev-list --count HEAD 2>/dev/null || echo 1)
# Identificador de la app: FARO_BUNDLE_ID si se define; si no, el de la copia ya instalada (para no perder los
# permisos de macOS ni los ajustes guardados al reinstalar); si no hay ninguna, uno por defecto.
BUNDLE_ID="${FARO_BUNDLE_ID:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/Faro.app/Contents/Info.plist 2>/dev/null || echo com.daniellelooo.faro)}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Faro</string>
  <key>CFBundleDisplayName</key><string>Faro</string>
  <key>CFBundleExecutable</key><string>Faro</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Faro usa el micrófono solo mientras mantienes la tecla Fn, para transcribir lo que dices en tu Mac.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Faro toma el audio de cada app solo para cambiarle el volumen por separado (el mezclador de volumen). No lo graba ni lo envía a ningún lado.</string>
  <key>NSAppleEventsUsageDescription</key><string>Faro lee la dirección de la pestaña activa del navegador para ajustar el tono del texto (por ejemplo, formal en Gmail).</string>
</dict>
</plist>
PLIST
if security find-identity -p codesigning | grep -q "Dicta Dev"; then
  codesign --force --sign "Dicta Dev" "$APP/Contents/Resources/libDictaNowPlaying.dylib"
  codesign --force --sign "Dicta Dev" "$APP"
  echo "Firmada con «Dicta Dev»."
else
  codesign --force --sign - "$APP/Contents/Resources/libDictaNowPlaying.dylib"
  codesign --force --sign - "$APP"
  echo "AVISO: firmada ad-hoc. Corre scripts/crear-certificado.sh para no perder los permisos al recompilar."
fi
codesign --verify "$APP"
# Nunca cerrar Faro en medio de una grabación (así se perdió el audio de una clase el 23 de octubre).
if grep -ls '"status" *: *"recording"' "$HOME/Library/Application Support/Faro/reuniones"/*/reunion.json >/dev/null 2>&1 && pgrep -x Faro >/dev/null; then
  echo "Faro está grabando una reunión: no se reinstala ahora. Vuelve a intentarlo cuando termine." >&2
  exit 1
fi
pkill -x Faro 2>/dev/null || true
pkill -x Dicta 2>/dev/null || true
rm -rf /Applications/Dicta.app /Applications/Faro.app
ditto "$APP" /Applications/Faro.app
echo "Instalada en /Applications/Faro.app"
