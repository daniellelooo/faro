#!/bin/sh
# Corre el banco de pruebas con la clave del Llavero (leída con `security`, sin ventana de contraseña).
set -e
cd "$(dirname "$0")/.."
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$(security find-generic-password -s dicta-anthropic -w)}"
swift build -c release --product dicta-bench
exec .build/release/dicta-bench "$@"
