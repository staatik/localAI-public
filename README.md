# AI Stack Deployment Documentation

Home lab AI stack running OpenWebUI, n8n, SearXNG, Qdrant, Redis, and nginx on a single server.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Directory Structure](#directory-structure)
4. [Environment Variables](#environment-variables)
5. [Services](#services)
6. [Nginx Configuration](#nginx-configuration)
7. [SearXNG Configuration](#searxng-configuration)
8. [Deployment](#deployment)
9. [Applying Config Changes](#applying-config-changes)
10. [DNS Setup](#dns-setup)
11. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
Internet / LAN
      │
      ▼
┌─────────────┐
│    nginx    │  :80 / :443   (container: gateway)
│   gateway   │
└──────┬──────┘
       │  Routes by domain (server_name)
       ├── chat.home.lan    → openwebui:8080
       ├── n8n.home.lan     → n8n:5678
       └── search.home.lan  → searxng:8080

frontend_net (bridge)
       ├── nginx
       ├── openwebui
       ├── n8n
       └── searxng

backend_net (bridge, internal - no internet access)
       ├── openwebui   → qdrant:6333  (vector DB)
       ├── openwebui   → redis:6379   (session state)
       ├── searxng     → redis:6379   (rate limiting / valkey)
       ├── qdrant
       └── redis
```

Two isolated networks are used. `frontend_net` connects nginx to the app services. `backend_net` is marked `internal: true` — containers on it have no outbound internet access and nginx cannot reach qdrant or redis directly. OpenWebUI and SearXNG sit on both networks as they need to serve traffic AND reach backend services.

---

## Prerequisites

- Docker Engine 24+
- Docker Compose v2
- A wildcard TLS certificate for `*.home.lan` placed at:
  - `/home/openwebui/nginx/ssl/wildcard.crt`
  - `/home/openwebui/nginx/ssl/wildcard.key`
- Local DNS resolving `*.home.lan` to the server IP (`<SERVER_IP>`)

---

## Directory Structure

```
/home/openwebui/
├── nginx/
│   ├── nginx.conf          # Nginx reverse proxy config
│   └── ssl/
│       ├── wildcard.crt    # TLS certificate
│       └── wildcard.key    # TLS private key
├── searxng/
│   └── settings.yml        # SearXNG engine and server config
└── .env                    # Secret environment variables (never commit)
```

Docker named volumes (managed by Docker):
```
openwebui_data    # OpenWebUI database and uploads
n8n_data          # n8n workflows and credentials
qdrant_data       # Qdrant vector database storage
redis_data        # Redis persistence
```

---

## Environment Variables

Copy `.env.example` to `.env` and fill in values before first run.

```bash
cp .env.example .env
```

Generate each secret with:

```bash
openssl rand -hex 32
```

| Variable | Used By | Purpose |
|---|---|---|
| `WEBUI_SECRET_KEY` | OpenWebUI | Session signing key |
| `QDRANT_API_KEY` | OpenWebUI, Qdrant | Qdrant authentication |
| `SEARXNG_SECRET` | SearXNG | SearXNG session signing key |
| `N8N_ENCRYPTION_KEY` | n8n | Encrypts all saved credentials |

> **Note:** Redis has no password — it is on `backend_net` only with no published ports, so authentication adds no security value.

> **Warning:** Never change `N8N_ENCRYPTION_KEY` after n8n has saved credentials. If the key changes, all stored credentials (API keys, passwords, tokens) become permanently unreadable and must be re-entered.

---

## Services

### nginx (gateway)

Reverse proxy handling all inbound traffic. Enforces HTTPS, routes by domain, and drops requests to raw IPs.

- Image: `nginx:1.27-alpine`
- Published ports: `80`, `443`
- Config: `/home/openwebui/nginx/nginx.conf` (bind-mounted read-only)
- SSL: `/home/openwebui/nginx/ssl/` (bind-mounted read-only)

### OpenWebUI

The main chat UI. Connects to Qdrant for RAG vector search and SearXNG for live web search.

- Image: `ghcr.io/open-webui/open-webui:0.6.5`
- Internal port: `8080`
- Data volume: `openwebui_data:/app/backend/data`

### n8n

Workflow automation platform. Accessible at `n8n.home.lan`.

- Image: `n8nio/n8n:1.88.0`
- Internal port: `5678`
- Data volume: `n8n_data:/home/node/.n8n`

### Qdrant

Vector database used by OpenWebUI for RAG (Retrieval Augmented Generation).

- Image: `qdrant/qdrant:v1.13.0`
- Internal ports: `6333` (HTTP), `6334` (gRPC)
- Data volume: `qdrant_data:/qdrant/storage`
- Protected by `QDRANT_API_KEY`

### SearXNG

Privacy-respecting meta search engine. Used by OpenWebUI for web-augmented queries.

- Image: `searxng/searxng:2025.4.19-0`
- Internal port: `8080`
- Config: `/home/openwebui/searxng/settings.yml` (bind-mounted read-write)

### Redis

In-memory store used by OpenWebUI for session/websocket state and by SearXNG as a Valkey-compatible rate limiter.

- Image: `redis:7-alpine`
- Internal port: `6379`
- Data volume: `redis_data:/data`
- No authentication (internal network only)

---

## Nginx Configuration

Full config lives at `/home/openwebui/nginx/nginx.conf`.

### Key design decisions

**Default catch-all block (must be first)**

Drops all requests that don't match a known domain — this prevents accessing services via raw IP address. Uses nginx's special `444` status which closes the connection without sending any response.

```nginx
server {
    listen 80 default_server;
    listen 443 default_server ssl;
    ssl_certificate     /etc/nginx/ssl/wildcard.crt;
    ssl_certificate_key /etc/nginx/ssl/wildcard.key;
    server_name _;
    return 444;
}
```

> This block **must appear before all other server blocks**. Nginx selects the default server in declaration order.

**HTTP → HTTPS redirect**

All HTTP traffic for known domains is permanently redirected to HTTPS.

```nginx
server {
    listen 80;
    server_name *.home.lan home.lan;
    return 301 https://$host$request_uri;
}
```

**Proxy headers**

Every upstream proxy block passes these four headers. They are required for:
- OpenWebUI's security/CORS checks (`X-Forwarded-Proto`)
- SearXNG's bot detection (`X-Real-IP`, `X-Forwarded-For`)
- Correct host routing (`Host`)

```nginx
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```

**WebSocket support**

Required for OpenWebUI (streaming chat) and n8n (live workflow execution).

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade    $http_upgrade;
proxy_set_header Connection "upgrade";
```

**Extended timeout for OpenWebUI**

AI responses can take a long time. Without this, nginx cuts the connection after 60 seconds.

```nginx
proxy_read_timeout 300;
```

### Full nginx.conf

```nginx
events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    client_max_body_size 100M;

    ssl_protocols TLSv1.2 TLSv1.3;

    # --- Default: drop requests to raw IP or unknown domains ---
    server {
        listen 80 default_server;
        listen 443 default_server ssl;
        ssl_certificate     /etc/nginx/ssl/wildcard.crt;
        ssl_certificate_key /etc/nginx/ssl/wildcard.key;
        server_name _;
        return 444;
    }

    # --- Redirect HTTP → HTTPS for known domains ---
    server {
        listen 80;
        server_name *.home.lan home.lan;
        return 301 https://$host$request_uri;
    }

    # --- OpenWebUI (chat.home.lan) ---
    server {
        listen 443 ssl;
        server_name chat.home.lan;
        ssl_certificate     /etc/nginx/ssl/wildcard.crt;
        ssl_certificate_key /etc/nginx/ssl/wildcard.key;

        location / {
            proxy_pass http://openwebui:8080;
            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade    $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_read_timeout 300;
        }
    }

    # --- n8n (n8n.home.lan) ---
    server {
        listen 443 ssl;
        server_name n8n.home.lan;
        ssl_certificate     /etc/nginx/ssl/wildcard.crt;
        ssl_certificate_key /etc/nginx/ssl/wildcard.key;

        location / {
            proxy_pass http://n8n:5678;
            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade    $http_upgrade;
            proxy_set_header Connection "upgrade";
        }
    }

    # --- SearXNG (search.home.lan) ---
    server {
        listen 443 ssl;
        server_name search.home.lan;
        ssl_certificate     /etc/nginx/ssl/wildcard.crt;
        ssl_certificate_key /etc/nginx/ssl/wildcard.key;

        location / {
            proxy_pass http://searxng:8080;
            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
}
```

---

## SearXNG Configuration

Config lives at `/home/openwebui/searxng/settings.yml`.

### Key settings for OpenWebUI integration

SearXNG must serve JSON responses or OpenWebUI cannot parse its results:

```yaml
search:
  formats:
    - html
    - json   # required for OpenWebUI
```

The secret key and Valkey (Redis) URL are injected at runtime via environment variables set in `docker-compose.yml` — do not hardcode them in `settings.yml`:

```yaml
server:
  secret_key: ""   # overridden by SEARXNG_SECRET env var

valkey:
  url: false       # overridden by SEARXNG_VALKEY_URL env var
```

### Known broken engines (removed)

These engine modules no longer exist in the current SearXNG release and must be absent from `settings.yml` or the container will fail to start:

| Engine | Reason |
|---|---|
| `livespace` | `livespace.py` removed upstream |
| `seekr` / `seekr news` / `seekr images` / `seekr videos` | `seekr.py` removed upstream |
| `stract` | `stract.py` removed upstream |
| `wikidata` | Upstream bug — `KeyError: 'name'` on init — set `inactive: true` |

---

## Security Hardening

Every container has the following hardening applied:

### `security_opt: no-new-privileges:true`

Prevents any process inside the container from gaining additional Linux privileges via setuid/setgid binaries, even if such a binary exists in the image.

### `cap_drop: [ALL]`

Containers start with a default set of Linux capabilities (signal handling, raw sockets, etc). All are dropped. The only exception is nginx, which needs `NET_BIND_SERVICE` added back to bind ports 80 and 443.

### `pids_limit`

Caps the number of processes a container can spawn. Prevents runaway processes and fork-bomb style attacks from consuming host resources.

| Service | PID limit |
|---|---|
| nginx | 100 |
| openwebui | 200 |
| n8n | 200 |
| qdrant | 200 |
| searxng | 100 |
| redis | 100 |

### Resource limits

Every container has CPU and memory caps to prevent any single service from starving the host.

| Service | Memory | CPU |
|---|---|---|
| nginx | 128 MB | 0.5 |
| openwebui | 1 GB | 2.0 |
| n8n | 512 MB | 1.0 |
| qdrant | 1 GB | 2.0 |
| searxng | 512 MB | 1.0 |
| redis | 256 MB | 0.5 |

Adjust the `mem_limit` and `cpus` values in `hardened-docker-compose.yml` based on your server's available RAM and CPU.

### Log rotation

All containers use the `json-file` logging driver with a 10 MB per-file cap and a maximum of 3 rotated files (30 MB total per service). Without this, container logs grow unbounded and can fill the disk.

### Network segmentation

`backend_net` is declared `internal: true` — Docker blocks all outbound traffic from it. Qdrant and Redis can only be reached by OpenWebUI and SearXNG, not by nginx or anything outside the stack.

---

---

## Deployment

### First-time setup

```bash
# 1. Clone or place your files
cd /home/openwebui

# 2. Create your .env from the example
cp .env.example .env
# Edit .env and fill in all four secrets

# 3. Place your TLS certificate
# wildcard.crt and wildcard.key → /home/openwebui/nginx/ssl/

# 4. Place your SearXNG config
# settings.yml → /home/openwebui/searxng/

# 5. Start the stack
docker compose up -d

# 6. Check all containers are healthy
docker compose ps
```

All containers should show `healthy` or `running` within about 60 seconds. Qdrant takes the longest — up to 40 seconds before its healthcheck passes.

### Verify the stack

```bash
# Check container status
docker compose ps

# Follow all logs
docker compose logs -f

# Follow a specific service
docker compose logs -f openwebui
docker compose logs -f searxng
docker compose logs -f nginx
```

---

## Applying Config Changes

### nginx config changes

Always validate before applying — an invalid config will crash nginx on reload.

```bash
# Step 1: validate
docker exec gateway nginx -t

# Step 2: graceful reload (zero downtime, no dropped connections)
docker exec gateway nginx -s reload

# Only use restart if nginx is in a broken state
docker restart gateway
```

### docker-compose.yml changes

```bash
# Pull new images and recreate changed containers only
docker compose up -d

# Force recreate everything
docker compose up -d --force-recreate
```

### .env changes

Environment variables are only read at container creation time, not on restart. A full down/up is required:

```bash
docker compose down && docker compose up -d
```

### SearXNG settings.yml changes

SearXNG reads `settings.yml` at startup. Restart the container to apply:

```bash
docker compose restart searxng
```

---

## DNS Setup

All three domains must resolve to the server IP (`<SERVER_IP>`). Add A records in your local DNS (Pi-hole, router, etc.):

| Hostname | Type | Value |
|---|---|---|
| `chat.home.lan` | A | `<SERVER_IP>` |
| `n8n.home.lan` | A | `<SERVER_IP>` |
| `search.home.lan` | A | `<SERVER_IP>` |

### iCloud Private Relay

iCloud Private Relay routes DNS through Apple's servers, which cannot resolve local domains. Disable it per network on your Apple devices:

- **iPhone/iPad:** Settings → [Name] → iCloud → Private Relay → tap your Wi-Fi network → disable "Limit IP Address Tracking"
- **Mac:** System Settings → Wi-Fi → your network → Details → uncheck "Limit IP Address Tracking"

### Hosts file (no local DNS server)

If you don't have a local DNS server, add entries to the hosts file on each client:

```
# Windows: C:\Windows\System32\drivers\etc\hosts
# macOS / Linux: /etc/hosts

<SERVER_IP>  chat.home.lan
<SERVER_IP>  n8n.home.lan
<SERVER_IP>  search.home.lan
```

---

## Troubleshooting

### Test IP blocking

After applying the nginx catch-all, raw IP requests should return nothing:

```bash
# Should get no response
curl -vk https://<SERVER_IP>

# Should work normally
curl -vk https://chat.home.lan
```

### Container won't start / keeps restarting

```bash
docker compose logs <service-name>
```

Common causes:
- `.env` variables missing or empty → `docker compose config | grep -i secret` to verify substitution
- Qdrant healthcheck failing → check `start_period` is long enough; `docker compose logs qdrant`
- Port conflict → `ss -tlnp | grep -E '80|443'`

### SearXNG returns no results in OpenWebUI

1. Confirm `json` is in `formats` in `settings.yml`
2. Check `SEARXNG_QUERY_URL` in docker-compose matches `http://searxng:8080/search?q=<query>`
3. Test directly: `docker exec openwebui curl "http://searxng:8080/search?q=test&format=json"`

### Redis connection errors

Both OpenWebUI and SearXNG connect to Redis without authentication (by design). If you see auth errors, the most common cause is stale containers with old environment variables — do a full restart:

```bash
docker compose down && docker compose up -d
```

### Nginx config test fails

```bash
docker exec gateway nginx -t
```

Read the error line carefully — it will tell you the exact file and line number. Common issues: missing semicolons, unclosed braces, wrong file paths for SSL certs.

### Check which server block nginx matched

```bash
# Watch nginx access log while making a request
docker logs -f gateway
```

A request to the raw IP hitting return 444 will appear as a `-` status or not appear at all (connection dropped). A successful domain request will show `200` or `301`.
