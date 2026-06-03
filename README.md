# immich-edge

A self-hostable edge cache for [Immich](https://immich.app/). Runs on a VPS and caches thumbnails, previews, and encoded videos — so external users get fast access without your home server's upload speed being a bottleneck.

Your photos stay at home. The VPS only caches frequently-accessed files.

## Architecture

```
External user
      ↓
VPS (immich-edge)
├── Reverse proxy  — SSL termination + security headers (bring your own: Caddy, nginx, etc.)
├── Nginx          — authentication gate + cache/static file server (OpenResty)
├── Auth           — Go service: validates sessions, API keys, and shared links
└── Sync           — rclone daemon syncing thumbs/videos from home server (static mode only)
      ↓  (Tailscale / WireGuard tunnel)
Home server
└── Immich  — all your data stays here
```

Nginx listens on `127.0.0.1:8081`. Point your reverse proxy of choice at that address.

### Request flow

Every asset request (thumbnail or video) goes through the same auth gate regardless of how the user is authenticated:

```
Request → Reverse proxy → Nginx
                            ├── /_validate (internal auth_request to Auth service)
                            │     ├── Session cookie / API key   → GET /api/users/me
                            │     └── Shared link ?key=          → GET /api/shared-links/me
                            │           (cookies forwarded — covers password-protected links)
                            │           then: verify UUID is in the shared album
                            │
                            ├── Auth OK → serve from cache/static files
                            └── Auth fail → 401 (no asset served)
```

### Cache modes

#### proxy (default)

Nginx `proxy_cache` caches responses from Immich. Cache fills naturally as users browse. Cache keys are scoped per asset owner (`$user_id:$uri`) to prevent cross-user cache leakage.

```
Auth OK → proxy_cache HIT? → serve cached response
                    ↓ MISS
              proxy_pass to Immich → cache response → serve
```

#### static

rclone syncs Immich's `thumbs/` and `encoded-video/` directories to the VPS on a configurable interval. Nginx serves them as static files — zero proxy overhead on cache hits.

The auth service resolves the actual file path:
1. Authenticate request → get `userId`
2. Check `{CACHE_DIR}/thumbs/{userId}/{aa}/{bb}/{uuid}-thumbnail.webp` (and preview/video variants)
3. If not found under the requester's userId, look up the asset's `ownerId` (handles shared albums where owner ≠ viewer)
4. Return the resolved `userId` in `X-User-Id` header for Nginx to build the file path

```
Auth OK → Nginx content_by_lua reads file from disk → serve (cache=STATIC)
                    ↓ file not found
              proxy_pass to Immich → serve (cache=UPSTREAM)
```

**Sync behaviour with `CACHE_MAX_SIZE`:**

Each sync run:
1. Pre-evict oldest files to make room for new ones
2. Incremental sync (`rclone sync --max-age Xs`) — downloads only files added to Immich since the last run; handles remote deletions; old evicted files (mtime before last sync) are not re-downloaded
3. Post-evict if new files pushed over limit
4. Backfill — if headroom remains, fill it with the newest missing files (`rclone copy --order-by modtime,descending --max-transfer {available}`)

Once per `FULL_SYNC_INTERVAL` (default 24h) a full sync runs instead of incremental, which cleans up deletions of old files that the `--max-age` window would otherwise skip.

### Auth service detail

The auth service (`auth/`) is a small Go HTTP server with two endpoints:

- `GET /validate` — called by Nginx `auth_request`. Reads `X-Original-URI`, extracts `?key=` for shared links or forwards session headers for normal auth. Returns `X-User-Id` header on success or 401.
- `GET /health` — used by Docker healthcheck.

Authentication paths:

| Request type | Credentials | Immich API called |
|---|---|---|
| Logged-in session | `immich_access_token` cookie | `GET /api/users/me` |
| API key | `x-api-key` header | `GET /api/users/me` |
| Shared link | `?key=` query param | `GET /api/shared-links/me?key=` |
| Password-protected shared link | `?key=` + browser session cookie (set after `POST /api/shared-links/login`) | `GET /api/shared-links/me?key=` with cookie forwarded |

**Auth result cache** — results are cached in-process for `AUTH_CACHE_TTL` (default `10s`) keyed by a SHA-256 hash of the credential. This eliminates a ~150–250ms Tailscale round-trip on warm sessions. Two caches run independently:

- **Credential cache** — maps session token / API key / shared-link key → `userId`. Shared-link results also include the forwarded session cookie in the cache key so a new login invalidates the entry.
- **Membership cache** — maps `(uuid, sharedKey)` → `ownerId`. For every shared-link asset request, the auth service verifies the UUID belongs to the shared album by calling `GET /api/assets/{uuid}?key=`. Successful results are cached for `AUTH_CACHE_TTL`; failures (403, network errors) are never cached so newly added photos are immediately accessible.

Set `AUTH_CACHE_TTL=0` to disable all caching (immediate token revocation at the cost of a round-trip on every request).

### What gets cached

| Endpoint | proxy mode | static mode |
|---|---|---|
| `/api/assets/*/thumbnail` | nginx proxy_cache, key = `$user_id:$uri?$size` | static file from disk |
| `/api/assets/*/video/playback` | nginx proxy_cache, key = `$user_id:$uri` | static file from disk |
| `/api/server/version` | not cached (triggers meta cache eviction on version change) | same |
| `/api/server/{features,config,about,media-types}` | nginx proxy_cache 5m | same |
| `manifest.json`, `custom.css`, `service-worker.js`, favicons | nginx proxy_cache 24h | same |
| Everything else | proxied to Immich, no cache | same |

When the Immich server version changes, the meta cache (`nginx_meta`) is automatically evicted via a Lua `body_filter` on `/api/server/version` responses.

## Prerequisites

1. A VPS with ports 80 and 443 open
2. DNS: your domain's A record pointing to the VPS IP
3. A VPN tunnel (Tailscale or WireGuard) between VPS and home server
4. Docker and Docker Compose installed on the VPS
5. A reverse proxy on the VPS for TLS termination (Caddy, nginx, Traefik, etc.)
6. `IMMICH_INTERNAL_URL` reachable from the VPS:
   ```sh
   curl http://<tailscale-ip>:2283/api/server/ping
   ```

## Quick start

```sh
git clone https://github.com/youruser/immich-edge
cd immich-edge
cp .env.example .env
nano .env   # fill in required values
docker compose up -d
```

Then configure your reverse proxy to forward traffic to `127.0.0.1:8081`.

Check logs:

```sh
docker compose logs -f
```

## Configuration

| Variable | Required | Default | Description |
|---|---|---|---|
| `IMMICH_INTERNAL_URL` | Yes | — | Immich URL reachable from VPS (e.g. `http://100.x.x.x:2283`) |
| `CACHE_MODE` | No | `proxy` | `proxy` or `static` |
| `CACHE_MAX_SIZE` | No | `50g` | Max disk for nginx proxy cache |
| `CACHE_TTL` | No | `365d` | TTL for cached thumbnails/videos |
| `CACHE_TTL_404` | No | `1m` | TTL for 404 responses |
| `RATE_LIMIT` | No | `20` | Requests/sec per IP for general endpoints |
| `AUTH_PORT` | No | `8088` | Internal port for auth service |
| `AUTH_TIMEOUT` | No | `5` | Auth service HTTP timeout in seconds |
| `AUTH_CACHE_TTL` | No | `10s` | How long to cache auth results per credential (Go duration, e.g. `30s`, `5m`). Set to `0` to disable. |
| `NGINX_WORKERS` | No | `auto` | Nginx worker processes |
| `IMMICH_THUMBS_PATH` | No | `thumbs` | Relative path to Immich thumbs inside Immich data dir |
| `IMMICH_ENCODED_PATH` | No | `encoded-video` | Relative path to encoded videos |
| `IMMICH_PROFILE_PATH` | No | `profile` | Relative path to profile images |
| `CACHE_PATTERN_THUMBS` | No | `^/api/assets/([a-f0-9]{8}-…{12})/thumbnail` | Nginx regex for thumbnail URLs |
| `CACHE_PATTERN_VIDEOS` | No | `^/api/assets/([a-f0-9]{8}-…{12})/video/playback` | Nginx regex for video URLs |
| `RCLONE_REMOTE` | static only | — | rclone remote name |
| `RCLONE_IMMICH_PATH` | static only | — | Path to Immich data dir on remote |
| `RCLONE_SYNC_INTERVAL` | static only | `60` | Sync interval in seconds (`0` = one-time seed) |
| `RCLONE_TRANSFERS` | static only | `8` | Parallel rclone transfers |
| `FULL_SYNC_INTERVAL` | static only | `86400` | How often (seconds) to run a full sync; catches deletions of old files that the incremental window misses |

## Reverse proxy

immich-edge does not manage TLS — Nginx binds only on `127.0.0.1:8081`. Any reverse proxy that can terminate TLS and forward HTTP/1.1 to `localhost:8081` will work (Caddy, nginx, Traefik, HAProxy, etc.).

Recommended headers to set in your reverse proxy:

```
Strict-Transport-Security: max-age=31536000; includeSubDomains
X-Frame-Options: SAMEORIGIN
X-Content-Type-Options: nosniff
Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; font-src 'self' data:; connect-src 'self' wss:; worker-src 'self' blob:
```

## Static mode setup

```sh
# 1. Configure rclone (SSH/SFTP or any rclone-supported remote)
rclone config  # create remote pointing to your home server

# 2. Test access
rclone ls homeserver:/mnt/data/immich/thumbs | head

# 3. Add to .env
CACHE_MODE=static
RCLONE_REMOTE=homeserver
RCLONE_IMMICH_PATH=/mnt/data/immich

# 4. Start with the sync service enabled
COMPOSE_PROFILES=static docker compose up -d
```

The `sync` container runs rclone on startup (seed) and then periodically thereafter. Files are placed in the Docker volume at `CACHE_DIR` (`/var/cache/immich-edge` inside containers).

## Verifying the cache

```sh
# Thumbnails — expect cache=STATIC (static mode) or cache=HIT (proxy mode after first request)
docker compose logs nginx | grep thumbnail | grep -v 401

# Watch live
docker compose logs -f nginx
```

The access log format is:
```
$remote_addr - [$time_local] "$request_method $uri $server_protocol" $status $body_bytes_sent cache=$cache_status
```

Query strings (including shared link `?key=` params) are not logged.

## Security

**Authentication on every asset request** — every thumbnail and video request goes through `auth_request` to the auth service before any content is served. Results are cached in-process for `AUTH_CACHE_TTL` (default `10s`).

**Strict UUID validation** — the nginx location patterns only match well-formed UUIDs (`[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}`). Requests with malformed IDs fall through to `location /` and are proxied to Immich, which handles its own auth.

**Shared link membership verification** — for every shared-link asset request, the auth service calls `GET /api/assets/{uuid}?key=` to confirm the specific UUID is in the shared album. This prevents a valid key from being used to access assets outside its album. A 403 from Immich is never cached, so newly added photos are immediately accessible.

**Per-user cache keys (proxy mode)** — thumbnail cache keys include the asset's `ownerId` (`$user_id:$uri`). This prevents one user's cached response from being served to another user.

**Brute-force protection on login** — `POST /api/auth/login` and `POST /api/shared-links/login` share a dedicated rate-limit zone: 10 requests/minute per IP, burst 5. Thumbnail and video requests are not subject to this limit.

**HSTS + CSP** — apply security headers (`Strict-Transport-Security`, `X-Frame-Options`, `X-Content-Type-Options`, `Content-Security-Policy`) in your reverse proxy. See the [Reverse proxy](#reverse-proxy) section for the recommended values.

**Minimal privilege** — Nginx runs as `nobody`; auth service runs as `appuser` (uid 1001); all containers have `no-new-privileges: true`.

**Shared link keys not logged** — nginx logs use `$uri` (not `$request`), so `?key=` query params are excluded from access logs.

**Logs** — nginx access and error logs written to `/var/log/immich-edge/nginx/` on the host, rotated daily via logrotate with `copytruncate`.

## Tailscale / WireGuard note

If your home server is only reachable via Tailscale or WireGuard, the VPS must be on the same network. If the VPN interface is on the host (not inside a container), add `network_mode: host` to the `nginx` and `auth` services in `docker-compose.yml`.
