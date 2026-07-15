#!/usr/bin/env bash
# Legt eine STABILE, selbst-signierte Code-Signing-Identität „TypeLess Dev" im Login-Schlüsselbund
# an — einmalig auszuführen.
#
# Warum: macOS bindet Mikrofon-/Bedienungshilfen-/Eingabeüberwachungs-Rechte an die Signatur-
# Identität einer App. Eine Ad-hoc-Signatur wechselt bei jedem Neubau die Identität, also gehen
# die Rechte jedes Mal verloren (der Schalter in den Einstellungen sieht noch „an" aus, zeigt aber
# auf die alte Identität). Mit einer stabilen Identität werden die Rechte nur EINMAL erteilt und
# bleiben über alle Neubauten erhalten.
#
# Kein Apple-Entwicklerkonto, keine Kosten. Das Zertifikat ist nur für den lokalen Gebrauch auf
# diesem Mac — es taugt NICHT zur Weitergabe der App an andere (dafür braucht es ein echtes
# Apple-Zertifikat, s. M8). `codesign` akzeptiert die Identität trotz „NOT_TRUSTED", weil lokales
# Signieren kein Vertrauen in die Zertifikatskette verlangt.
set -euo pipefail

NAME="TypeLess Dev"
PW="typeless-transient"   # nur der Transport-Schutz des p12 beim Import; danach bedeutungslos

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Identität '$NAME' existiert bereits — nichts zu tun."
  security find-identity -p codesigning | grep "$NAME"
  exit 0
fi

# LibreSSL unter /usr/bin/openssl erzeugt ein p12, das `security import` lesen kann. Das per
# Homebrew installierte OpenSSL 3 nutzt ein neueres Format, das macOS beim Import ablehnt.
OSSL=/usr/bin/openssl

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = codesign_ext
prompt = no
[dn]
CN = TypeLess Dev
[codesign_ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "== Zertifikat erzeugen (10 Jahre gültig) =="
"$OSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" 2>/dev/null

"$OSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout "pass:$PW" -name "$NAME" 2>/dev/null

KEYCHAIN=$(security default-keychain | sed -e 's/^ *"//' -e 's/"$//')
echo "== in Schlüsselbund importieren: $KEYCHAIN =="
# -A: alle Programme dürfen den Schlüssel nutzen -> `codesign` signiert ohne Passwort-Dialog.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PW" -T /usr/bin/codesign -A

echo "== Ergebnis =="
security find-identity -p codesigning | grep "$NAME"
echo
echo "Fertig. Ab jetzt signiert scripts/build-app.sh automatisch mit '$NAME'."
