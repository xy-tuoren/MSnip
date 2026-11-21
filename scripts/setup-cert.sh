#!/usr/bin/env bash
set -euo pipefail

CERT_NAME="MSnip Local Signer"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ 本机钥匙串已存在有效代码签名证书：$CERT_NAME"
    exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/openssl.cnf" << 'EOF'
[ req ]
distinguished_name = req_dn
x509_extensions = codesign_ext
prompt = no

[ req_dn ]
CN = MSnip Local Signer
O = MSnip Local Development

[ codesign_ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> 生成 10 年期本机固定代码签名证书 ($CERT_NAME)..."
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP_DIR/key.pem" \
    -out "$TMP_DIR/cert.pem" \
    -days 3650 \
    -config "$TMP_DIR/openssl.cnf" >/dev/null 2>&1

openssl pkcs12 -export -legacy \
    -inkey "$TMP_DIR/key.pem" \
    -in "$TMP_DIR/cert.pem" \
    -out "$TMP_DIR/cert.p12" \
    -passout pass:msnip >/dev/null 2>&1 || \
openssl pkcs12 -export \
    -inkey "$TMP_DIR/key.pem" \
    -in "$TMP_DIR/cert.pem" \
    -out "$TMP_DIR/cert.p12" \
    -passout pass:msnip >/dev/null 2>&1

echo "==> 导入登录钥匙串并设置代码签名信任（仅这一次会弹出系统密码/指纹确认框）..."
security import "$TMP_DIR/cert.p12" -k "$KEYCHAIN" -P msnip -T /usr/bin/codesign >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP_DIR/cert.pem"

echo "✅ 固定证书 [$CERT_NAME] 配置完成！今后执行 'bash scripts/install.sh --rebuild' 升级将永久保留屏幕录制与辅助功能权限。"
