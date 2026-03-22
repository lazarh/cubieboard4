#!/bin/bash
# gen-rauc-cert.sh — Generate a self-signed dev CA certificate for RAUC bundle signing.
#
# Run once on the build host.  The private key is gitignored — keep it safe.
# The public certificate is committed to the repository and deployed to the board.
#
# Usage:
#   scripts/gen-rauc-cert.sh
#
# Output:
#   configs/rauc/dev-cert/ca.key.pem   — CA private key    (KEEP SECRET, gitignored)
#   configs/rauc/dev-cert/ca.cert.pem  — CA certificate    (commit to repo, deployed to board)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CERT_DIR="${REPO_ROOT}/configs/rauc/dev-cert"

command -v openssl >/dev/null || { echo "ERROR: openssl not found"; exit 1; }

KEY_FILE="${CERT_DIR}/ca.key.pem"
CERT_FILE="${CERT_DIR}/ca.cert.pem"

if [[ -f "${KEY_FILE}" ]]; then
    echo "==> ${KEY_FILE} already exists."
    read -rp "    Overwrite? [y/N] " ans
    [[ "${ans,,}" == "y" ]] || { echo "Aborted."; exit 0; }
fi

mkdir -p "${CERT_DIR}"

echo "==> Generating RAUC dev CA keypair (RSA-4096, 10 years)..."
openssl req -x509 -newkey rsa:4096 -sha256 \
    -days 3650 \
    -nodes \
    -keyout "${KEY_FILE}" \
    -out    "${CERT_FILE}" \
    -subj   "/CN=CubieBoard4 RAUC Dev CA/O=CubieBoard4/C=XX"

chmod 600 "${KEY_FILE}"
chmod 644 "${CERT_FILE}"

echo ""
echo "==> Done."
echo "    Certificate: ${CERT_FILE}"
echo "    Private key: ${KEY_FILE}"
echo ""
echo "    NEXT STEPS:"
echo "    1. Commit the certificate:  git add configs/rauc/dev-cert/ca.cert.pem"
echo "    2. Keep the private key secret — it is gitignored."
echo "    3. Rebuild the rootfs to deploy the cert to the image:"
echo "         sudo scripts/build-rootfs.sh"
echo ""
echo "    Verify certificate: openssl x509 -in ${CERT_FILE} -text -noout"
