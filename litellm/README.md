# LiteLLM Proxy — Home Lab Deployment

A self-hosted [LiteLLM](https://github.com/BerriAI/litellm) proxy with management UI, PostgreSQL backend, and nginx reverse proxy with TLS. Manage all your LLM provider keys and models from a single UI instead of editing config files.

---

## What's Included

| File | Purpose |
|---|---|
| `docker-compose.yml` | LiteLLM, PostgreSQL, and nginx services |
| `nginx.conf` | Reverse proxy config with TLS, streaming, and IP blocking |
| `.env.example` | Template for all required secrets |
| `generate-ssl.sh` | Generates a wildcard self-signed TLS certificate |
| `setup.sh` | One-time setup script — run this first |

---

## Architecture

```
LAN
 │
 ▼
┌─────────────────────┐
│        nginx        │  :80 / :443   (container: litellm-gateway)
│  litellm.home.lan │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│       LiteLLM       │  :4000
│   Proxy + UI        │──────────────────────────────────────┐
└─────────────────────┘                                      │
           │                                          backend_net
           │ backend_net                             (internal)
           ▼                                                  │
┌─────────────────────┐                                      │
│     PostgreSQL      │◄─────────────────────────────────────┘
│  models, keys,      │
│  spend logs, teams  │
└─────────────────────┘
```

**Two isolated Docker networks:**

- `frontend_net` — nginx talks to LiteLLM only
- `backend_net` — marked `internal: true`, no outbound internet access. LiteLLM talks to PostgreSQL. nginx cannot reach PostgreSQL directly.

---

## Prerequisites

- Ubuntu 22.04+ (or any Linux with Docker)
- Docker Engine 24+
- Docker Compose v2 (`docker compose version`)
- `openssl` (`apt install openssl`)

---

## Directory Structure

After setup, the host filesystem will look like this:

```
/home/litellm/
└── nginx/
    ├── nginx.conf          # copied here by setup.sh
    └── ssl/
        ├── wildcard.crt    # TLS certificate (nginx ssl_certificate)
        ├── wildcard.key    # TLS private key  (nginx ssl_certificate_key)
        ├── ca.crt          # Import this into your browser/OS to trust the cert
        └── ca.key          # CA private key — keep safe, not used by nginx
```

Docker named volumes (managed by Docker):
```
postgres_data    # PostgreSQL data — models, keys, spend logs
```

---

## Quick Start

### 1. Place all files in a directory on the VM

```
setup.sh
generate-ssl.sh
docker-compose.yml
nginx.conf
.env.example
```

### 2. Make scripts executable

```bash
chmod +x setup.sh generate-ssl.sh
```

### 3. Create and fill in your `.env`

```bash
cp .env.example .env
nano .env
```

See [Environment Variables](#environment-variables) for details on each value.

### 4. Run setup

```bash
sudo ./setup.sh
```

`setup.sh` will:
- Check all dependencies are installed
- Create `/home/litellm/nginx/` and `/home/litellm/nginx/ssl/`
- Copy `nginx.conf` into place
- Generate the wildcard TLS certificate
- Validate your `.env` (fails fast if any value is missing or still a placeholder)
- Pull Docker images and start the stack
- Wait for LiteLLM to become healthy

### 5. Add DNS record

Add an A record in your local DNS (Pi-hole, router, etc.):

```
litellm.home.lan  →  <VM IP address>
```

Or add it to your hosts file on each client:
```
# /etc/hosts (Linux/Mac) or C:\Windows\System32\drivers\etc\hosts (Windows)
<VM IP>  litellm.home.lan
```

### 6. Trust the CA certificate

Import `ca.crt` from `/home/litellm/nginx/ssl/ca.crt` into your browser or OS once. Without this, browsers will show a security warning (the proxy still works, you just have to click through it).

See [Trusting the CA Certificate](#trusting-the-ca-certificate) for per-OS instructions.

### 7. Open the UI

```
https://litellm.home.lan/ui
```

Log in with `UI_USERNAME` and `UI_PASSWORD` from your `.env`.

---

## Environment Variables

Copy `.env.example` to `.env` and fill in all values. Generate secrets with:

```bash
openssl rand -hex 32
```

| Variable | Required | Notes |
|---|---|---|
| `LITELLM_MASTER_KEY` | ✅ | Must start with `sk-`. This is the API key clients use to authenticate against the proxy. |
| `LITELLM_SALT_KEY` | ✅ | Encrypts provider API keys stored in PostgreSQL. **Never change after first run** — all stored keys become unreadable. |
| `POSTGRES_PASSWORD` | ✅ | Password for the internal PostgreSQL database. |
| `UI_USERNAME` | ✅ | Username for the LiteLLM management UI. |
| `UI_PASSWORD` | ✅ | Password for the LiteLLM management UI. |

> **Warning:** `LITELLM_SALT_KEY` is equivalent to n8n's encryption key. Back it up somewhere safe alongside your `.env` file. If it is lost or changed, every provider API key stored in the UI must be re-entered.

---

## Managing Models via the UI

Because `STORE_MODEL_IN_DB=True` is set, all model configuration is stored in PostgreSQL and managed through the UI — no `config.yaml` file is needed.

### Adding a model

1. Go to `https://litellm.home.lan/ui`
2. Navigate to **Models** → **Add Model**
3. Select your provider (OpenAI, Anthropic, Ollama, etc.)
4. Enter the model name and your provider API key
5. Save — the model is immediately available via the proxy API

### Connecting OpenWebUI to LiteLLM

In OpenWebUI, go to **Settings → Connections** and add an OpenAI-compatible connection:

```
URL:     https://litellm.home.lan
API Key: <your LITELLM_MASTER_KEY from .env>
```

All models you have configured in LiteLLM will appear in OpenWebUI automatically.

### Virtual API Keys

LiteLLM supports issuing separate virtual keys (under **API Keys** in the UI) with per-model access, rate limits, and spend budgets. Useful for giving different services or users their own keys without exposing your master key or provider keys.

---

## SSL Certificates

Certificates are generated by `generate-ssl.sh` and stored in `/home/litellm/nginx/ssl/`.

The script creates a two-layer trust chain:
1. A local **Certificate Authority** (`ca.crt` / `ca.key`)
2. A **wildcard certificate** for `*.home.lan` signed by that CA

This approach means you only need to import `ca.crt` **once** per device. Any future certificates signed by the same CA (other VMs, services) will be trusted automatically.

### Regenerating certificates

```bash
# Delete the existing certs first, then re-run setup
sudo rm /home/litellm/nginx/ssl/wildcard.crt \
        /home/litellm/nginx/ssl/wildcard.key
sudo ./generate-ssl.sh --dir /home/litellm/nginx/ssl
docker exec litellm-gateway nginx -s reload
```

### Trusting the CA Certificate

Copy `/home/litellm/nginx/ssl/ca.crt` to each device, then:

**macOS**
```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ca.crt
```

**Windows**

Double-click `ca.crt` → Install Certificate → Local Machine → Place in: **Trusted Root Certification Authorities**

**Linux**
```bash
sudo cp ca.crt /usr/local/share/ca-certificates/homelab-ca.crt
sudo update-ca-certificates
```

**iOS (iPhone / iPad)**
1. AirDrop or email `ca.crt` to the device
2. Settings → General → VPN & Device Management → Install Profile
3. Settings → General → About → Certificate Trust Settings → enable full trust for **HomeLab Root CA**

**Android**
1. Copy `ca.crt` to the device
2. Settings → Security → Encryption & Credentials → Install a certificate → CA certificate

> **Note for macOS + iCloud Private Relay:** Private Relay routes DNS through Apple's servers which cannot resolve `.home.lan` domains. Disable it per network:
> System Settings → Wi-Fi → your network → Details → uncheck **Limit IP Address Tracking**

---

## Nginx Configuration Notes

### IP blocking

The `default_server` catch-all block silently drops all connections that don't match `litellm.home.lan`:

```nginx
server {
    listen 80 default_server;
    listen 443 default_server ssl;
    server_name _;
    return 444;  # close connection, send no response
}
```

This block **must be declared first** in `nginx.conf`. nginx selects the default server in declaration order — if it isn't first, the first real service block becomes the fallback and is accessible via raw IP.

### Streaming responses

The LiteLLM proxy location uses `proxy_buffering off` and `proxy_cache off`. Without these, nginx buffers the entire LLM response before sending it to the client, which breaks streaming completely.

### Timeouts

`proxy_read_timeout` is set to `600s` for the API endpoint. Large model responses or slow providers can take a long time — the default nginx timeout of 60s will kill the connection mid-response.

---

## Applying Changes

### nginx config changes

```bash
# Always validate before applying
docker exec litellm-gateway nginx -t

# Graceful reload — zero downtime
docker exec litellm-gateway nginx -s reload
```

### docker-compose.yml changes

```bash
docker compose up -d
```

### .env changes

Environment variables are only read at container creation. A full restart is required:

```bash
docker compose down && docker compose up -d
```

---

## Useful Commands

```bash
# Check all container statuses and health
docker compose ps

# Follow all logs
docker compose logs -f

# Follow a specific service
docker compose logs -f litellm
docker compose logs -f nginx
docker compose logs -f postgres

# Restart a single service
docker compose restart litellm

# Stop the stack (preserves volumes)
docker compose down

# Stop and delete all data (destructive)
docker compose down -v
```

---

## Troubleshooting

### UI is not accessible

```bash
# Check LiteLLM is healthy
docker compose ps

# Check LiteLLM logs for startup errors
docker compose logs litellm

# Test the API directly from inside the network
docker exec litellm-gateway curl -s http://litellm:4000/health/liveliness
```

### PostgreSQL connection error

```bash
docker compose logs postgres
```

Most common cause: `.env` was changed after first start. Run:
```bash
docker compose down && docker compose up -d
```

### nginx fails to start

```bash
docker compose logs nginx
docker exec litellm-gateway nginx -t
```

Most common causes:
- SSL cert files missing from `/home/litellm/nginx/ssl/` → re-run `generate-ssl.sh`
- nginx.conf missing from `/home/litellm/nginx/` → re-run `setup.sh`
- Syntax error in `nginx.conf` — the `-t` output will show the exact line

### Browser shows security warning

The CA certificate hasn't been imported yet. See [Trusting the CA Certificate](#trusting-the-ca-certificate).

### Raw IP still shows the UI

The `default_server` block may not be first in `nginx.conf`. Check declaration order and reload:
```bash
docker exec litellm-gateway nginx -t && docker exec litellm-gateway nginx -s reload
```

Verify blocking is working:
```bash
# Should return nothing
curl -vk https://<VM IP>

# Should work
curl -vk https://litellm.home.lan/health/liveliness
```
