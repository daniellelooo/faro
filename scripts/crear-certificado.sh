#!/bin/sh
# Crea un certificado de firma de código autofirmado "Dicta Dev" en tu llavero de inicio de sesión.
# Sirve para que macOS no te pida otra vez los permisos de Dicta cada vez que se recompila.
# No necesita cuenta de desarrollador de Apple. Se corre una sola vez.
set -e
if security find-identity -p codesigning | grep -q "Dicta Dev"; then
  echo "El certificado «Dicta Dev» ya existe. No hay nada que hacer."
  exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Dicta Dev
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "Dicta Dev" \
  -out "$TMP/dicta.p12" -passout pass:dicta 2>/dev/null
security import "$TMP/dicta.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P dicta -T /usr/bin/codesign
echo "Listo: certificado «Dicta Dev» creado."
