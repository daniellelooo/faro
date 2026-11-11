#!/bin/sh
# Abre Faro al iniciar sesión con un LaunchAgent que apunta a la ruta de la app. A diferencia del ítem de inicio
# clásico, no se pierde cuando build-app.sh borra y vuelve a copiar /Applications/Faro.app.
# Para quitarlo: launchctl bootout gui/$(id -u)/com.eternalgrowth.faro.abrir && rm ~/Library/LaunchAgents/com.eternalgrowth.faro.abrir.plist
set -e
PLIST="$HOME/Library/LaunchAgents/com.eternalgrowth.faro.abrir.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.eternalgrowth.faro.abrir</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>/Applications/Faro.app</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/com.eternalgrowth.faro.abrir" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Faro se abrirá al iniciar sesión."
