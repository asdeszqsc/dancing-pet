#!/bin/bash
# 고정된 자체 서명 코드사인 인증서를 만든다(1회).
# 이 인증서로 서명하면 재빌드해도 접근성 권한이 유지됨.
set -e
cd "$(dirname "$0")"

IDENTITY="DancingPet Self-Signed"
KCPASS="dancingpet"
KEYCHAIN="$HOME/Library/Keychains/dancingpet-signing.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✅ 이미 있음: $IDENTITY"
    exit 0
fi

TMP=$(mktemp -d)
cat > "$TMP/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $IDENTITY
[ ext ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

echo "▶︎ 자체 서명 인증서 생성..."
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf"

echo "▶︎ 전용 키체인 생성/임포트..."
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # 자동 잠금 없음
security unlock-keychain -p "$KCPASS" "$KEYCHAIN"
# 검색 목록에 추가(기존 유지)
EXISTING=$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')
security list-keychains -d user -s "$KEYCHAIN" $EXISTING
# PEM 키/인증서를 따로 임포트 (p12 MAC 문제 회피)
security import "$TMP/key.pem"  -k "$KEYCHAIN" -T /usr/bin/codesign
security import "$TMP/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KEYCHAIN" >/dev/null

rm -rf "$TMP"
echo "✅ 완료: '$IDENTITY' (키체인: $KEYCHAIN)"
security find-identity -v -p codesigning | grep "$IDENTITY" || true
