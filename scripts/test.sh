#!/bin/sh
# Swift Testing con solo Command Line Tools: hay que indicar dónde está el framework.
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
# La clave sale del Llavero con `security`, que la guardó: así no aparece la ventana de contraseña.
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$(security find-generic-password -s dicta-anthropic -w 2>/dev/null)}"
exec swift test -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L "$@"
