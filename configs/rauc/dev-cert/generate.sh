#!/bin/bash
# generate.sh — Generate a self-signed CA certificate for RAUC bundle signing.
#
# Run once on the build host.  Keep ca.key.pem SECRET — never commit it.
# ca.cert.pem is public and IS committed to the repository.
#
# Usage:
#   cd configs/rauc/dev-cert
#   bash generate.sh
#
# Output:
#   ca.key.pem   — CA private key    (KEEP SECRET, see .gitignore)
#   ca.cert.pem  — CA certificate    (commit this to the repo)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v openssl >/dev/null || { echo "ERROR: openssl not found"; exit 1; }

echo "==> Generating RAUC dev CA keypair..."

openssl req -x509 -newkey rsa:4096 -sha256 \
    -days 3650 \
    -nodes \
    -keyout "${SCRIPT_DIR}/ca.key.pem" \
    -out    "${SCRIPT_DIR}/ca.cert.pem" \
    -subj   "/CN=CubieBoard4 RAUC Dev CA/O=CubieBoard4/C=XX"

chmod 600 "${SCRIPT_DIR}/ca.key.pem"
chmod 644 "${SCRIPT_DIR}/ca.cert.pem"

echo ""
echo "==> Done."
echo "    Certificate: ${SCRIPT_DIR}/ca.cert.pem  (commit this)"
echo "    Private key: ${SCRIPT_DIR}/ca.key.pem   (KEEP SECRET — do NOT commit)"
echo ""
echo "    ca.key.pem is listed in .gitignore."
echo "    Verify with: openssl x509 -in ca.cert.pem -text -noout"
