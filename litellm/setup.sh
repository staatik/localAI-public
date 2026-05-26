#!/bin/bash
# =============================================================================
# setup.sh
# One-time setup script for the LiteLLM deployment.
# Run this before docker compose up.
#
# What it does:
#   1. Checks dependencies
#   2. Creates required host directory structure
#   3. Copies nginx.conf into place
#   4. Generates wildcard SSL certificate
#   5. Validates .env is populated
#   6. Starts the stack
#
# Usage:
#   chmod +x setup.sh
#   sudo ./setup.sh
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------
# Config — adjust if your paths differ
# --------------------------------------------------------------------------
NGINX_CONF_DIR="/home/litellm/nginx"
SSL_DIR="/home/litellm/nginx/ssl"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"
NGINX_CONF_SRC="${SCRIPT_DIR}/nginx.conf"
SSL_DOMAIN="home.lan"
SSL_DAYS=3650

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # no color

ok()   { echo -e "${GREEN}[OK]${NC}    $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
fail() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info() { echo -e "        $1"; }

echo ""
echo "============================================"
echo "   LiteLLM Stack — First-Time Setup"
echo "============================================"
echo ""

# --------------------------------------------------------------------------
# Step 1: Dependency checks
# --------------------------------------------------------------------------
echo "--- [1/6] Checking dependencies ---"

command -v docker   &>/dev/null || fail "docker is not installed."
command -v openssl  &>/dev/null || fail "openssl is not installed. Run: apt install openssl"

# Verify docker compose v2
if ! docker compose version &>/dev/null; then
  fail "Docker Compose v2 is not available. Run: apt install docker-compose-plugin"
fi

ok "docker $(docker --version | awk '{print $3}' | tr -d ',')"
ok "docker compose $(docker compose version --short)"
ok "openssl $(openssl version | awk '{print $2}')"
echo ""

# --------------------------------------------------------------------------
# Step 2: Create host directory structure
# --------------------------------------------------------------------------
echo "--- [2/6] Creating directory structure ---"

mkdir -p "${NGINX_CONF_DIR}"
mkdir -p "${SSL_DIR}"
chmod 700 "${SSL_DIR}"

ok "Created ${NGINX_CONF_DIR}"
ok "Created ${SSL_DIR}"
echo ""

# --------------------------------------------------------------------------
# Step 3: Copy nginx.conf into place
# --------------------------------------------------------------------------
echo "--- [3/6] Installing nginx config ---"

if [[ ! -f "${NGINX_CONF_SRC}" ]]; then
  fail "nginx.conf not found at ${NGINX_CONF_SRC}. Make sure it is in the same directory as this script."
fi

cp "${NGINX_CONF_SRC}" "${NGINX_CONF_DIR}/nginx.conf"
ok "Copied nginx.conf → ${NGINX_CONF_DIR}/nginx.conf"
echo ""

# --------------------------------------------------------------------------
# Step 4: Generate SSL certificates
# --------------------------------------------------------------------------
echo "--- [4/6] Generating SSL certificates ---"

if [[ -f "${SSL_DIR}/wildcard.crt" && -f "${SSL_DIR}/wildcard.key" ]]; then
  warn "SSL certificates already exist at ${SSL_DIR} — skipping generation."
  info "Delete them and re-run this script to regenerate."
else
  "${SCRIPT_DIR}/generate-ssl.sh" \
    --dir "${SSL_DIR}" \
    --domain "${SSL_DOMAIN}" \
    --days "${SSL_DAYS}"
  ok "SSL certificate generated."
fi
echo ""

# --------------------------------------------------------------------------
# Step 5: Validate .env
# --------------------------------------------------------------------------
echo "--- [5/6] Validating environment file ---"

if [[ ! -f "${ENV_FILE}" ]]; then
  if [[ -f "${ENV_EXAMPLE}" ]]; then
    cp "${ENV_EXAMPLE}" "${ENV_FILE}"
    warn ".env not found — copied from .env.example."
    info "You MUST edit ${ENV_FILE} and fill in all secrets before continuing."
    echo ""
    fail "Aborting. Fill in .env and re-run this script."
  else
    fail ".env file not found at ${ENV_FILE}. Create it before running this script."
  fi
fi

# Check that none of the required vars are still at their placeholder value
REQUIRED_VARS=(
  "LITELLM_MASTER_KEY"
  "LITELLM_SALT_KEY"
  "POSTGRES_PASSWORD"
  "UI_USERNAME"
  "UI_PASSWORD"
)

MISSING=0
for var in "${REQUIRED_VARS[@]}"; do
  value=$(grep "^${var}=" "${ENV_FILE}" | cut -d '=' -f2- | tr -d '"' | tr -d "'")
  if [[ -z "${value}" || "${value}" == *"replace-with"* ]]; then
    warn "${var} is not set or still has a placeholder value."
    MISSING=$((MISSING + 1))
  else
    ok "${var} is set."
  fi
done

# Check LITELLM_MASTER_KEY starts with sk-
MASTER_KEY=$(grep "^LITELLM_MASTER_KEY=" "${ENV_FILE}" | cut -d '=' -f2- | tr -d '"' | tr -d "'")
if [[ -n "${MASTER_KEY}" && "${MASTER_KEY}" != sk-* ]]; then
  warn "LITELLM_MASTER_KEY must start with 'sk-'. Current value does not."
  MISSING=$((MISSING + 1))
fi

if [[ "${MISSING}" -gt 0 ]]; then
  echo ""
  fail "${MISSING} variable(s) need to be set in ${ENV_FILE}. Fix them and re-run."
fi

echo ""

# --------------------------------------------------------------------------
# Step 6: Start the stack
# --------------------------------------------------------------------------
echo "--- [6/6] Starting the stack ---"

cd "${SCRIPT_DIR}"
docker compose pull
docker compose up -d

echo ""
echo "============================================"
echo "   Waiting for services to be healthy..."
echo "============================================"

# Wait up to 90 seconds for LiteLLM to become healthy
TIMEOUT=90
ELAPSED=0
until docker inspect --format='{{.State.Health.Status}}' litellm 2>/dev/null | grep -q "healthy"; do
  if [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; then
    warn "LiteLLM did not become healthy within ${TIMEOUT}s."
    info "Check logs with: docker compose logs litellm"
    break
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  echo -n "."
done
echo ""

echo ""
echo "============================================"
echo "   Setup Complete"
echo "============================================"
echo ""
docker compose ps
echo ""
echo "  UI      : https://litellm.${SSL_DOMAIN}/ui"
echo "  API     : https://litellm.${SSL_DOMAIN}"
echo "  CA cert : ${SSL_DIR}/ca.crt  (import into browser/OS to trust SSL)"
echo ""
echo "  Logs    : docker compose logs -f"
echo "  Stop    : docker compose down"
echo ""
echo "  Remember to:"
echo "  1. Add litellm.${SSL_DOMAIN} → $(hostname -I | awk '{print $1}') to your DNS"
echo "  2. Import ${SSL_DIR}/ca.crt into your browser or OS"
echo ""
