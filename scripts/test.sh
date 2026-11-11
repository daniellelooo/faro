#!/bin/sh
# La clave sale del Llavero con `security`, que la guardó: así no aparece la ventana de contraseña.
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$(security find-generic-password -s dicta-anthropic -w 2>/dev/null)}"
# Con Xcode, swift test encuentra Swift Testing solo. Con solo Command Line Tools hay que indicar dónde está el
# framework (y forzarlo con Xcode seleccionado rompe la compilación: son versiones distintas).
case "$(xcode-select -p 2>/dev/null)" in
  */CommandLineTools)
    F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
    exec swift test -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L "$@" ;;
  *) exec swift test "$@" ;;
esac
