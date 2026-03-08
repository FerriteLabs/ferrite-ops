#!/usr/bin/env sh
# Generate self-signed TLS certificates for Ferrite development/testing.
#
# Usage:
#   ./docker/generate-certs.sh              # Generate in docker/certs/
#   ./docker/generate-certs.sh /my/path     # Generate in custom directory
#
# Creates:
#   ca.key / ca.crt          - Certificate Authority
#   server.key / server.crt  - Server certificate (for Ferrite)
#   client.key / client.crt  - Client certificate (for mTLS testing)

set -euo pipefail

CERT_DIR="${1:-$(dirname "$0")/certs}"
DAYS=365
CA_SUBJECT="/CN=Ferrite Development CA"
SERVER_SUBJECT="/CN=localhost"
CLIENT_SUBJECT="/CN=ferrite-client"

mkdir -p "$CERT_DIR"

echo "==> Generating CA key and certificate..."
openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null
openssl req -new -x509 -days "$DAYS" -key "$CERT_DIR/ca.key" \
  -out "$CERT_DIR/ca.crt" -subj "$CA_SUBJECT" 2>/dev/null

echo "==> Generating server key and certificate..."
openssl genrsa -out "$CERT_DIR/server.key" 2048 2>/dev/null
openssl req -new -key "$CERT_DIR/server.key" \
  -out "$CERT_DIR/server.csr" -subj "$SERVER_SUBJECT" 2>/dev/null

# Create SAN extension for localhost and common Docker hostnames
cat > "$CERT_DIR/server-ext.cnf" <<EOF
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
DNS.2 = ferrite
DNS.3 = *.ferrite
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

openssl x509 -req -days "$DAYS" -in "$CERT_DIR/server.csr" \
  -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
  -out "$CERT_DIR/server.crt" \
  -extfile "$CERT_DIR/server-ext.cnf" -extensions v3_req 2>/dev/null

echo "==> Generating client key and certificate (for mTLS)..."
openssl genrsa -out "$CERT_DIR/client.key" 2048 2>/dev/null
openssl req -new -key "$CERT_DIR/client.key" \
  -out "$CERT_DIR/client.csr" -subj "$CLIENT_SUBJECT" 2>/dev/null
openssl x509 -req -days "$DAYS" -in "$CERT_DIR/client.csr" \
  -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
  -out "$CERT_DIR/client.crt" 2>/dev/null

# Clean up CSR and temporary files
rm -f "$CERT_DIR"/*.csr "$CERT_DIR"/*.cnf "$CERT_DIR"/*.srl

# Restrict key permissions
chmod 600 "$CERT_DIR"/*.key
chmod 644 "$CERT_DIR"/*.crt

echo ""
echo "Certificates generated in: $CERT_DIR"
echo "  CA:     $CERT_DIR/ca.crt"
echo "  Server: $CERT_DIR/server.crt / $CERT_DIR/server.key"
echo "  Client: $CERT_DIR/client.crt / $CERT_DIR/client.key"
echo ""
echo "Test with:"
echo "  redis-cli --tls --cacert $CERT_DIR/ca.crt -h 127.0.0.1 -p 6380 PING"
