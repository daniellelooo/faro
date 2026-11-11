#!/bin/sh
# Abre Faro al iniciar sesión con un LaunchAgent que apunta a la ruta de la app. A diferencia del ítem de inicio
# clásico, no se pierde cuando build-app.sh borra y vuelve a copiar /Applications/Faro.app.
# El nombre del agente sale del identificador de la app instalada, como en build-app.sh.
# Para quitarlo: launchctl bootout gui/$(id -u)/<identificador>.abrir && rm ~/Library/LaunchAgents/<identificador>.abrir.plist
set -e
BUNDLE_ID="${FARO_BUNDLE_ID:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/Faro.app/Contents/Info.plist 2>/dev/null || echo com.daniellelooo.faro)}"
LABEL="$BUNDLE_ID.abrir"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>/Applications/Faro.app</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Faro se abrirá al iniciar sesión ($LABEL)."
