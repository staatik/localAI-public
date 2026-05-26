#!/bin/bash
# =============================================================================
# generate-ssl.sh
# Generates a wildcard self-signed certificate for *.home.lan
#
# Run this script on EACH VM that needs SSL (AI stack, LiteLLM, etc.)
# The generated cert covers all *.home.lan subdomains.
#
# Usage:
#   chmod +x generate-ssl.sh
#   sudo ./generate-ssl.sh [--dir /path/to/ssl] [--days 3650] [--domain home.lan]
#
# Defaults:
#   --dir    /home/openwebui/nginx/ssl    (change per VM as needed)
#   --days   3650                         (10 years)
#   --domain home.lan
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------
# Defaults (override with flags)
# --------------------------------------------------------------------------
SSL_DIR="/home/openwebui/nginx/ssl"
DAYS=3650
DOMAIN="home.lan"

# --------------------------------------------------------------------------
# Parse arguments
# --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)    SSL_DIR="$2";  shift 2 ;;
    --days)   DAYS="$2";     shift 2 ;;
    --domain) DOMAIN="$2";   shift 2 ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--dir /path] [--days N] [--domain domain.tld]"
      exit 1
      ;;
  esac
done

WILDCARD="*.${DOMAIN}"
CERT="${SSL_DIR}/wildcard.crt"
KEY="${SSL_DIR}/wildcard.key"
CA_CERT="${SSL_DIR}/ca.crt"
CA_KEY="${SSL_DIR}/ca.key"
CSR="${SSL_DIR}/wildcard.csr"
EXT="${SSL_DIR}/wildcard.ext"

# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------
if ! command -v openssl &>/dev/null; then
  echo "[ERROR] openssl is not installed. Install it with:"
  echo "        apt install openssl   # Debian/Ubuntu"
  echo "        yum install openssl   # RHEL/CentOS"
  exit 1
fi

echo "=========================================="
echo "  Wildcard SSL Certificate Generator"
echo "=========================================="
echo "  Domain  : ${WILDCARD}"
echo "  Output  : ${SSL_DIR}"
echo "  Valid   : ${DAYS} days"
echo "=========================================="
echo ""

# --------------------------------------------------------------------------
# Create output directory
# --------------------------------------------------------------------------
mkdir -p "${SSL_DIR}"
chmod 700 "${SSL_DIR}"

# --------------------------------------------------------------------------
# Step 1: Generate a local Certificate Authority (CA)
# --------------------------------------------------------------------------
echo "[1/4] Generating local Certificate Authority (CA)..."

openssl genrsa -out "${CA_KEY}" 4096 2>/dev/null

openssl req -new -x509 \
  -key "${CA_KEY}" \
  -out "${CA_CERT}" \
  -days "${DAYS}" \
  -subj "/C=US/ST=Local/L=Local/O=HomeLab CA/OU=HomeLab/CN=HomeLab Root CA" \
  2>/dev/null

echo "    CA certificate : ${CA_CERT}"
echo "    CA key         : ${CA_KEY}"

# --------------------------------------------------------------------------
# Step 2: Generate wildcard private key + CSR
# --------------------------------------------------------------------------
echo "[2/4] Generating wildcard private key and CSR..."

openssl genrsa -out "${KEY}" 4096 2>/dev/null

openssl req -new \
  -key "${KEY}" \
  -out "${CSR}" \
  -subj "/C=US/ST=Local/L=Local/O=HomeLab/OU=HomeLab/CN=${WILDCARD}" \
  2>/dev/null

echo "    Private key : ${KEY}"
echo "    CSR         : ${CSR}"

# --------------------------------------------------------------------------
# Step 3: Create the SAN (Subject Alternative Name) extension file
# --------------------------------------------------------------------------
echo "[3/4] Writing SAN extension config..."

cat > "${EXT}" << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${WILDCARD}
DNS.2 = ${DOMAIN}
DNS.3 = localhost
EOF

echo "    SAN config  : ${EXT}"

# --------------------------------------------------------------------------
# Step 4: Sign the wildcard cert with the local CA
# --------------------------------------------------------------------------
echo "[4/4] Signing wildcard certificate with local CA..."

openssl x509 -req \
  -in "${CSR}" \
  -CA "${CA_CERT}" \
  -CAkey "${CA_KEY}" \
  -CAcreateserial \
  -out "${CERT}" \
  -days "${DAYS}" \
  -sha256 \
  -extfile "${EXT}" \
  2>/dev/null

# --------------------------------------------------------------------------
# Cleanup temp files
# --------------------------------------------------------------------------
rm -f "${CSR}" "${EXT}" "${SSL_DIR}/wildcard.srl"

# --------------------------------------------------------------------------
# Lock down permissions
# --------------------------------------------------------------------------
chmod 644 "${CERT}" "${CA_CERT}"
chmod 600 "${KEY}" "${CA_KEY}"

# --------------------------------------------------------------------------
# Verify
# --------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "  Certificate Details"
echo "=========================================="
openssl x509 -in "${CERT}" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null
echo "=========================================="
echo ""
echo "[OK] Files generated:"
echo "     ${CERT}      <- use in nginx ssl_certificate"
echo "     ${KEY}       <- use in nginx ssl_certificate_key"
echo "     ${CA_CERT}   <- import into your browser/OS to trust the cert"
echo ""

# --------------------------------------------------------------------------
# Per-OS trust instructions
# --------------------------------------------------------------------------
echo "=========================================="
echo "  Next Step: Trust the CA on your devices"
echo "=========================================="
echo ""
echo "  Without importing ca.crt, browsers will show a security warning."
echo "  The proxy will still WORK, but you must click through the warning."
echo ""
echo "  --- macOS ---"
echo "  Copy ${CA_CERT} to your Mac, then:"
echo "  $ sudo security add-trusted-cert -d -r trustRoot \\"
echo "      -k /Library/Keychains/System.keychain ca.crt"
echo ""
echo "  --- Windows ---"
echo "  Copy ca.crt to your Windows machine, then:"
echo "  Double-click ca.crt -> Install Certificate -> Local Machine"
echo "  -> Place in: Trusted Root Certification Authorities"
echo ""
echo "  --- Linux ---"
echo "  $ sudo cp ca.crt /usr/local/share/ca-certificates/homelab-ca.crt"
echo "  $ sudo update-ca-certificates"
echo ""
echo "  --- iOS (iPhone/iPad) ---"
echo "  1. AirDrop or email ca.crt to your device"
echo "  2. Settings -> General -> VPN & Device Management -> Install Profile"
echo "  3. Settings -> General -> About -> Certificate Trust Settings"
echo "     -> Enable full trust for HomeLab Root CA"
echo ""
echo "  --- Android ---"
echo "  1. Copy ca.crt to your device"
echo "  2. Settings -> Security -> Encryption & Credentials"
echo "     -> Install a certificate -> CA certificate"
echo ""
echo "=========================================="
echo "  For the LiteLLM VM, run with --dir:"
echo "  sudo ./generate-ssl.sh --dir /home/litellm/nginx/ssl"
echo "=========================================="
