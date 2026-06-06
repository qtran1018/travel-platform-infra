# Travel Platform — Production Deployment Guide

## Infrastructure

| Resource | Details                                                 |
| -------- | ------------------------------------------------------- |
| Provider | Oracle Cloud Infrastructure (OCI)                       |
| Instance | VM.Standard.A1.Flex — 4 OCPUs, 24 GB RAM (Always Free) |
| OS       | Ubuntu 24.04 aarch64                                    |
| Region   | us-ashburn-1                                            |
| Domain   | quangntran.com (Namecheap)                              |
| DNS      | A record @ + wildcard * → OCI public IP                |

---

## Subdomain Plan

| Subdomain                       | App                              |
| ------------------------------- | -------------------------------- |
| quangntran.com                  | Portfolio landing page           |
| auth.quangntran.com             | Keycloak SSO                     |
| app.quangntran.com              | Splitpush                        |
| travelbin.quangntran.com        | TravelBin frontend               |
| travelbin-api.quangntran.com    | TravelBin API                    |
| agent.quangntran.com            | Itinerary-Agent frontend         |
| intonational.quangntran.com     | intonational frontend (future)   |
| intonational-api.quangntran.com | intonational aggregator API      |

---

## Tech Stack

| Layer               | Technology                      |
| ------------------- | ------------------------------- |
| Reverse proxy + TLS | nginx + Certbot (Let's Encrypt) |
| Containerization    | Docker + Docker Compose         |
| SSO                 | Keycloak 26.0                   |
| Database            | PostgreSQL 16 (shared)          |
| Cache               | Redis                           |
| Document store      | MongoDB                         |

---

## One-Time Server Setup

### 1. SSH into instance

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@<OCI-PUBLIC-IP>
```

### 2. Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker ubuntu
newgrp docker
sudo apt install docker-compose-plugin -y
```

### 3. Install nginx + Certbot

```bash
sudo apt install nginx certbot python3-certbot-nginx -y
```

### 4. Clone repo

```bash
git clone https://github.com/<your-repo>/travel-platform.git
cd travel-platform
```

### 5. Create Docker network

```bash
docker network create travelplatform-network
```

---

## Cloudflare Setup (DDoS Protection + CDN)

Route DNS through Cloudflare instead of pointing Namecheap directly at OCI. This hides the real OCI IP, absorbs DDoS traffic before it reaches the server, and gives free CDN + SSL.

1. Create a free Cloudflare account
2. Add `quangntran.com` to Cloudflare
3. Cloudflare provides two nameservers — set these in Namecheap:
   - Namecheap → Domain List → quangntran.com → Nameservers → **Custom DNS** → enter Cloudflare's two nameservers
4. Add DNS records in Cloudflare (not Namecheap) — see DNS section below
5. Set SSL/TLS mode to **Full** in Cloudflare → SSL/TLS settings

**Important:** Keep the OCI IP out of Namecheap entirely — all DNS lives in Cloudflare once this is set up.

---

## DNS Setup (Cloudflare)

Add these records in **Cloudflare DNS** (not Namecheap — Namecheap only holds the nameserver pointers):

| Type  | Host | Value               |
| ----- | ---- | ------------------- |
| A     | @    | `<OCI-PUBLIC-IP>` |
| A     | *    | `<OCI-PUBLIC-IP>` |
| CNAME | www  | quangntran.com      |

DNS propagation takes up to 24 hours (usually under 30 minutes).

---

## OCI Security List — Open Ports

In OCI Console → Networking → VCN → travel-platform-vcn → Security Lists → add Ingress Rules:

| Port | Protocol | Purpose                          |
| ---- | -------- | -------------------------------- |
| 22   | TCP      | SSH                              |
| 80   | TCP      | HTTP (nginx, redirects to HTTPS) |
| 443  | TCP      | HTTPS (nginx)                    |

All app ports (8080, 8000, 3001, etc.) stay internal — nginx proxies them.

---

## Environment Variables to Set

### keycloak-service

```env
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=<strong-password>
KC_HOSTNAME=auth.quangntran.com
KC_HOSTNAME_STRICT=true
KC_PROXY=edge
```

### postgres-service

- Credentials defined in `init.sql` — change defaults before first run

### Splitpush

```env
POSTGRES_HOST=platform-postgres
SPRING_PROFILES_ACTIVE=docker
JAVA_TOOL_OPTIONS=-Xms128m -Xmx256m
KEYCLOAK_CLIENT_SECRET=<from-keycloak-admin>
```

- In production, delete `KeycloakClientConfig.java` and restore standard `issuer-uri` autodiscovery in `application.properties`

### TravelBin backend

```env
SECRET_KEY=<strong-django-secret>
DB_HOST=platform-postgres
KEYCLOAK_ISSUER=https://auth.quangntran.com/realms/travel-platform
# KEYCLOAK_JWKS_URL not needed in production — issuer URL is publicly reachable
```

### TravelBin frontend

```env
VITE_API_URL=https://api.quangntran.com
```

### Itinerary-Agent backend

```env
OPENAI_API_KEY=<your-key>
DATABASE_URL=postgresql://itinerary_user:<pass>@platform-postgres:5432/itinerary_agent
KEYCLOAK_ISSUER=https://auth.quangntran.com/realms/travel-platform
KEYCLOAK_JWKS_URL=https://auth.quangntran.com/realms/travel-platform/protocol/openid-connect/certs
TRAVELBIN_API_URL=https://api.quangntran.com
```

### Keycloak client redirect URIs to update

After going live, update in Keycloak Admin → travel-platform realm → Clients:

| Client             | Redirect URIs                       |
| ------------------ | ----------------------------------- |
| splitpush          | `https://app.quangntran.com/*`    |
| travelbin-frontend | `https://travel.quangntran.com/*` |
| itinerary-agent    | `https://agent.quangntran.com/*`  |

---

## Start Services (Combined Mode)

```bash
# Infrastructure
docker compose up -d                                    # keycloak-service/
docker compose up -d                                    # postgres-service/
docker compose up -d                                    # intonational/

# Apps
POSTGRES_HOST=platform-postgres docker compose up -d   # Splitpush/
POSTGRES_HOST=platform-postgres docker compose up -d   # TravelBin/
POSTGRES_HOST=platform-postgres docker compose up -d   # Itinerary-Agent/
```

## First-Time DB Migrations

```bash
docker exec travelbin-backend python manage.py migrate
docker exec itinerary-agent-backend npx prisma migrate deploy
docker exec platform-postgres psql -U splitpush_user -d splitpush -c "ALTER TABLE users ALTER COLUMN password DROP NOT NULL;"
```

---

## nginx Config

Create `/etc/nginx/sites-available/travel-platform`:

```nginx
server {
    server_name auth.quangntran.com;
    location / { proxy_pass http://localhost:8180; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
}
server {
    server_name app.quangntran.com;
    location / { proxy_pass http://localhost:8080; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
}
server {
    server_name api.quangntran.com;
    location / { proxy_pass http://localhost:8000; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
}
server {
    server_name travel.quangntran.com;
    location / { proxy_pass http://localhost:3001; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
}
server {
    server_name agent.quangntran.com;
    location / { proxy_pass http://localhost:3010; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
}
```

Enable and get SSL:

```bash
sudo ln -s /etc/nginx/sites-available/travel-platform /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d auth.quangntran.com -d app.quangntran.com -d api.quangntran.com -d travel.quangntran.com -d agent.quangntran.com -d quangntran.com -d www.quangntran.com
```

---

## Security Hardening

### nginx rate limiting
Add to the top of `/etc/nginx/nginx.conf` inside the `http {}` block:
```nginx
limit_req_zone $binary_remote_addr zone=general:10m rate=30r/m;
limit_req_zone $binary_remote_addr zone=auth:10m rate=10r/m;
```

Add inside each `server {}` block in `sites-available/travel-platform`:
```nginx
limit_req zone=general burst=10 nodelay;
```

Use `zone=auth` for the Keycloak server block — stricter limit on login endpoints.

### fail2ban (SSH + nginx brute force protection)
```bash
sudo apt install fail2ban -y
sudo systemctl enable fail2ban
sudo systemctl start fail2ban
```

Default config bans IPs after 5 failed SSH attempts. No further config needed for basic protection.

### OCI Security List reminder
Only ports 22, 80, 443 should be open. All app ports (8080, 8000, 3001, etc.) are internal only — nginx proxies them and they are never exposed directly.

### Shared Postgres — remove host exposure + rotate credentials (Phase 0, do first)

The shared `platform-postgres` (holding **all three** app databases) currently publishes `5432:5432` to the host and ships with default/dictionary credentials at every level (`postgres/postgres`, `travelbin/travelbin`, `splitpush_user/splitpush_pass`, `itinerary_user/itinerary_pass`). The published port means the OCI Security List is the *only* layer between the internet and the database — no defense-in-depth. Two independently-shippable parts:

**0a. Remove host port exposure — near-zero risk.**
- `postgres-service/docker-compose.yml`: delete the `ports: - "5432:5432"` block. Apps reach the DB via `platform-postgres:5432` on `travelplatform-network` — unaffected.
- `postgres-service/docker-compose.override.yml` (new): re-add `ports: - "127.0.0.1:5432:5432"` for local dev tools, bound to localhost only.
- Verify: `docker compose -f docker-compose.yml config` shows no published port; local `docker compose config` shows `127.0.0.1:5432`.
- ⚠️ Removing a port mapping forces a container **recreate** → brief DB blip while apps reconnect. Do it in a low-traffic window; apps auto-reconnect via `restart: unless-stopped`.

**0b. Rotate credentials — data-sensitive, separate step.**
- ⚠️ **Landmine:** `POSTGRES_PASSWORD` and init scripts only apply on **first init of an empty volume**. The live DB already has data, so editing compose/init changes nothing on the running DB. Rotation must be done with SQL against the live DB, coordinated with updating each app's env.
- Credentials are now env-driven in all compose files (`${VAR:-devdefault}`). Production must set strong values in `postgres-service/.env.secrets` (not committed — see `.env.example`). Generate passwords with `openssl rand -base64 32`.
- **Rotation procedure (run once on the prod server):**

```bash
# 1. Rotate each role in the running DB
docker exec platform-postgres psql -U postgres -c "ALTER ROLE postgres WITH PASSWORD 'NEW_SUPERUSER_PASS';"
docker exec platform-postgres psql -U postgres -c "ALTER ROLE travelbin WITH PASSWORD 'NEW_TRAVELBIN_PASS';"
docker exec platform-postgres psql -U postgres -c "ALTER ROLE splitpush_user WITH PASSWORD 'NEW_SPLITPUSH_PASS';"
docker exec platform-postgres psql -U postgres -c "ALTER ROLE itinerary_user WITH PASSWORD 'NEW_ITINERARY_PASS';"

# 2. Create postgres-service/.env.secrets with the same values
# (this file is gitignored — never commit it)

# 3. Restart services one at a time, verifying each reconnects before the next
docker compose -f docker-compose.yml up -d  # postgres-service — picks up new superuser pw
# Then from each app directory:
docker compose -f docker-compose.yml up -d travelbin-backend
docker compose -f docker-compose.yml up -d splitpush-app
docker compose -f docker-compose.yml up -d itinerary-agent-backend
```

- `init.sql` has been replaced by `init.sh` which reads the same env vars — fresh installs automatically use strong credentials if the secrets file is present.

---

## Making Code Changes

### Workflow

```
edit locally → git push → SSH into server → git pull → rebuild container
```

### Rebuild a specific service

> **⚠️ Deploy discipline:** override files (`docker-compose.override.yml`) now exist for `postgres-service`, `keycloak-service`, `TravelBin`, and `Itinerary-Agent`, holding **local-dev** values (localhost URLs, exposed DB port, Keycloak `start-dev`). `docker compose` auto-merges them. **Production must always pin `-f docker-compose.yml`** to exclude them — a bare `docker compose up` on the server would silently flip every service to localhost and break prod.

```bash
cd travel-platform
git pull
docker compose -f docker-compose.yml build --no-cache <service-name>
docker compose -f docker-compose.yml up -d <service-name>
```

### Service names

| App                      | Service name                |
| ------------------------ | --------------------------- |
| TravelBin backend        | `travelbin-backend`       |
| TravelBin frontend       | `travelbin-frontend`      |
| Splitpush                | `splitpush`               |
| Itinerary-Agent backend  | `itinerary-agent-backend` |
| Itinerary-Agent frontend | `itinerary-agent`         |

---

## TODO Checklist

### Before going live

- [x] OCI instance provisioned (A1.Flex)
- [x] SSH access confirmed (required IPv6 + internet gateway — see log below)
- [x] Docker installed on server
- [x] Repos cloned on server (one repo per app + `travel-platform-infra`)
- [x] All `.env` files filled with production values
- [x] Keycloak admin password changed from default (production no longer uses `admin`/`admin`; CLAUDE.md still documents the dev default)
- [ ] PostgreSQL credentials changed from defaults in `init.sql` (still default in prod — DO THIS)
- [x] Django `SECRET_KEY` env-based (override `DJANGO_SECRET_KEY` for a strong value)
- [x] `DEBUG=False` in TravelBin Django settings
- [x] OpenAI API key set for Itinerary-Agent

### DNS + TLS

- [x] OCI public IP obtained (`158.101.110.211`)
- [x] DNS via Cloudflare (nameservers set in Namecheap)
- [x] DNS propagated
- [x] nginx installed and configured (version-controlled — see log)
- [x] Certbot SSL certs issued for all subdomains

### Keycloak production config

- [x] `KC_HOSTNAME` set (full URL `https://auth.quangntran.com`, `KC_PROXY_HEADERS=xforwarded`)
- [x] Client redirect URIs set to production URLs (via `setup-realm.sh`)
- [ ] `KeycloakClientConfig.java` — **kept** in Splitpush (not removed; works via env-configurable URIs)
- [x] `KEYCLOAK_JWKS_URL` — **kept** in TravelBin (Cloudflare blocks server→public JWKS fetch; uses internal Docker URL)
- [ ] Google OAuth credentials updated with production redirect URI

### Post-launch

- [x] All apps reachable via HTTPS
- [x] SSO login works across all apps (register + login tested)
- [ ] TravelBin → Itinerary-Agent export works (untested end to end)
- [x] Certbot auto-renewal confirmed (`sudo certbot renew --dry-run`)
- [x] Portfolio landing page live at quangntran.com (GitHub Pages, not OCI — see log)

### Still outstanding (post-launch hardening)

- [x] Change Keycloak admin password from `admin`/`admin` (done — production admin is no longer the default)
- [ ] Change Postgres credentials in `init.sql` (still default in production — outstanding)
- [ ] Switch both Vite frontends + the Itinerary-Agent backend from dev servers to production builds — see **[Production Hardening — Path to "Real" Production](#production-hardening--path-to-real-production)** for the full per-app plan, rationale, and landmines
- [ ] Migrate Keycloak `start-dev` → production `start` (separate higher-risk pass — see same section)
- [ ] intonational Python services still have empty placeholder Dockerfiles — only Mongo + Redis run
- [ ] Migrate intonational MongoDB → shared Postgres (drop a container)
- [ ] nginx rate limiting + apply security hardening section
- [ ] Decommission Splitpush on Render once OCI is trusted

---

## Production Hardening — Path to "Real" Production (planned, not yet done)

The platform is **live and functional**, but three services still run **development servers** behind nginx rather than production builds. This section documents the current state, why moving to production builds matters, and the exact per-app migration — so it can be executed later as a deliberate pass.

### Current runtime state (June 2026)

| Service | Runs as | Production-correct? |
|---|---|---|
| TravelBin backend | `gunicorn` (2 workers) | ✅ Yes |
| Splitpush | multi-stage built JAR (`java -jar`) | ✅ Yes |
| Keycloak | `start-dev` + `KC_HOSTNAME` hacks | ⚠️ Works, but dev mode (see below) |
| **TravelBin frontend** | **Vite dev server** (`npm run dev`) | ❌ No |
| **Itinerary-Agent frontend** | **Vite dev server** (`npm run dev --host`) | ❌ No |
| **Itinerary-Agent backend** | `node dist/server.js` (built JS) | ✅ Yes — migrated June 2026 |
| intonational | empty Dockerfiles — only Mongo + Redis run | ⏸️ Not deployed (out of scope) |

The visible symptom of the dev frontends: a console error `Firefox can't establish a connection to wss://travelbin.quangntran.com/?token=…` — Vite's HMR websocket trying (and failing) to reach a hot-reload endpoint that nginx/Cloudflare don't proxy. Harmless functionally, but a tell that dev servers are public-facing.

### Why move to production builds (rationale)

This is a **public-facing portfolio**, which is exactly where it matters — other engineers may inspect the network tab and console.

- **Security (primary):** Vite's dev server ships unminified source + source maps + the full module graph publicly; it is explicitly *not* hardened for internet exposure (HMR websocket, `/@fs/` filesystem endpoint have had CVEs). Both configs set `allowedHosts: true`, which disables the host-header check. `ts-node` keeps the TS compiler + dev tooling in the running container. Production = nginx serving static minified bundles + `node dist/server.js`, far smaller attack surface.
- **Resource use:** Always-Free OCI has finite RAM. Dev servers hold the module graph in memory and recompile on the fly; nginx serving `dist/` uses a fraction of the RAM/CPU and serves pre-minified, pre-gzipped assets (faster page loads).
- **Stability:** built artifacts are fixed and tested ("what you build is what runs"); dev servers can leak memory over long uptimes and assume a developer is watching.
- **Correctness:** `vite build` / `tsc` run the full type-check + bundler, surfacing errors the lenient dev path tolerates.

**Counterpoint (why it's not urgent):** functionally identical to a casual visitor; no new features; carries migration risk. If this were a 3-user internal tool, leaving it would be defensible.

**Decision:** do it later, **incrementally, lowest-risk first** (backend → TravelBin frontend → Itinerary frontend). All changes are reversible (revert Dockerfile, rebuild → dev image returns).

### Per-app migration plan + landmines

**1. Itinerary-Agent backend (`ts-node` → built JS)** — ✅ Done June 2026
- `RUN npm run build` at build time; `CMD ["node", "dist/server.js"]`. `tsc` was clean — no type errors surfaced.
- ⚠️ **Session note:** after any auth-config change (e.g. switching Keycloak URL), browsers holding a stale token will get a 400. Users must log out and back in to get a fresh token. Expected — not a bug.

**2. TravelBin frontend (Vite dev → static nginx)** — ✅ Done June 2026
- Multi-stage Dockerfile: `node:20-alpine` runs `npm ci && npm run build` → `dist/`; `nginx:alpine` serves `dist/` on port 3001.
- `VITE_API_URL` and `VITE_KEYCLOAK_URL` are baked as Docker `ARG`s at build time. Prod values in `docker-compose.yml` `build.args`; localhost defaults in `docker-compose.override.yml` (auto-applied by plain `docker compose`).
- Uses `HashRouter` — `try_files` SPA fallback added to nginx config (harmless, not strictly needed).
- API calls go to `travelbin-api.quangntran.com` (separate subdomain, proxied to `:8000`), so the frontend nginx needs **no** `/api` proxy.

**3. Itinerary-Agent frontend (Vite dev → static nginx)** — ✅ Done June 2026
- Multi-stage Dockerfile: `node:20-alpine` build → `nginx:alpine` serves `dist/` on port 3000.
- **The `/api` proxy landmine resolved:** `Quiz.vue` and `Profile.vue` use `import.meta.env.VITE_API_URL ?? ''`. Setting `VITE_API_URL=https://agent-api.quangntran.com` at build time makes all fetch calls absolute — no nginx `/api` proxy needed in the static build. The nginx inside the container still has `location /api/ { proxy_pass http://itinerary-agent-backend:5000; }` as a fallback (unused in prod since calls are absolute).
- `VITE_KEYCLOAK_URL` is also a build `ARG` (reads `import.meta.env.VITE_KEYCLOAK_URL` in `keycloak.ts`).
- Uses hash routing — no SPA `try_files` needed.

### Keycloak: dev mode → production `start` (separate, higher-risk follow-up)

Keycloak still runs `start-dev` with `KC_HOSTNAME=https://auth.quangntran.com` + `KC_PROXY_HEADERS=xforwarded`. True production is `start` with `KC_HOSTNAME_STRICT=true`. Auth is the backbone of every app, so this is its **own deliberate migration**, not part of the frontend pass. Note: per the original plan, going to a single public issuer would let you delete the Splitpush `KeycloakClientConfig.java` workaround and TravelBin's `KEYCLOAK_JWKS_URL` split — **but** the deployment log shows both were intentionally *kept* because Cloudflare 403s the server→public JWKS fetch. Re-validate that constraint before removing either.

### Middle-ground (if not doing the full migration)

To silence just the HMR websocket console error without a build migration: set `hmr: false` in each `vite.config` `server` block and rebuild the frontend images. Removes the visible error but keeps all the source-exposure / resource downsides above.

---

## Deployment Log — What Actually Happened (June 2026)

The clean instructions above are the *destination*. This is the *route* — every wall we hit and how we got past it, so it never costs a day again.

### 1. Could not SSH into the instance (the big one)

Symptom: `ssh ubuntu@158.101.110.211` timed out. Spent hours here.

**Things tried that did NOT fix it:**
- Adding ports 22/80/443 to the OCI Security List ingress — necessary but not sufficient.
- Fixing iptables inside the instance — couldn't get in to do it; tried serial console (login needs a password Ubuntu cloud images don't set) and UEFI boot editing (GRUB timeout is 0, can't interrupt it). All dead ends.
- OCI **serial console** / instance console connection — useful for looking, useless for logging in (no password).
- `instance-agent command create` via Cloud Shell — ran successfully but SSH still timed out, because the real problem was upstream of the OS.

**What actually fixed it — THE ROOT CAUSE:** the VCN had **no internet gateway / route**. Fix: Instance page → **Networking tab → Quick Actions → "Connect public subnet to internet."** This created the internet gateway, route table rule (`0.0.0.0/0 → IGW`), and an NSG. SSH worked immediately after. **Do this first on any new OCI instance.**

**Key facts learned along the way:**
- The SSH key the instance was actually provisioned with is visible via Cloud Shell: `oci compute instance list --compartment-id <tenancy-ocid>` → look at `metadata.ssh_authorized_keys`. Ours matched the local `~/.ssh/id_ed25519` — the key was never the problem.
- OCI Cloud Shell is FIPS mode: `ssh-keygen -t ed25519` is blocked, use `-t rsa -b 4096`.

### 2. IPv6 — required because Cloudflare prefers it

Symptom: after SSH worked and apps were up, browsers got "Server Not Found" / `DNS_PROBE_FINISHED_NXDOMAIN` even though `nslookup` resolved. Cause: Cloudflare returns AAAA (IPv6) records to clients and tries IPv6 to the origin, but the OCI instance had no IPv6.

**Enabling IPv6 on OCI (free tier supports it):**
1. VCN → enable IPv6 → assign Oracle-allocated `/56` GUA prefix.
2. Subnet → add IPv6 prefix (a `/64` from the `/56`).
3. Instance VNIC → assign an IPv6 address (OCI gave a `/80`, e.g. `2603:c020:4020:8000:2c7f::/80`).
4. Security List → add **ingress** rules `::/0` TCP 22/80/443.
5. Security List → add **egress** rule `::/0` all protocols.
6. Route table → add **`::/0` → internet gateway** (easy to forget; without it IPv6 is one-way).

**OS side (Ubuntu 24.04, netplan):** the address did NOT auto-configure via SLAAC/DHCPv6. Had to assign it manually and persist it in `/etc/netplan/50-cloud-init.yaml`:
```yaml
network:
  version: 2
  ethernets:
    enp0s6:
      match: { macaddress: "02:00:17:3f:a9:f5" }
      dhcp4: true
      dhcp6: true
      accept-ra: true
      addresses:
        - 2603:c020:4020:8000:2c7f::1/64
      set-name: "enp0s6"
      mtu: 9000
```
`sudo netplan apply`, then `ip addr show enp0s6` shows the address (survives reboot).

**Outcome / caveat:** Outbound IPv6 works (`ping6` to Cloudflare succeeds). **Inbound IPv6 never fully worked** — external `Test-NetConnection` to the v6 address still fails; OCI's fabric wasn't accepting inbound on the `/80`. So we did NOT rely on origin IPv6. **The actual resolution: keep Cloudflare records proxied with only A (IPv4) records, and DELETE any AAAA records.** Proxied + IPv4-only means clients reach Cloudflare (which has its own IPv6), and Cloudflare reaches the origin over IPv4, which is rock-solid. A leftover **wildcard AAAA** `*.quangntran.com` was the thing silently breaking every subdomain at random — deleting it stabilized everything.

### 3. Cloudflare gotchas

- **SSL/TLS mode:** use **Full** (not Full Strict, not Flexible). Flexible causes redirect loops; Full Strict was finicky during setup.
- **Proxied (orange cloud)** for all app subdomains and apex → keeps the OCI IP hidden + DDoS protection.
- **Per-subdomain explicit A records** were added (`auth`, `splitpush`, `travelbin`, `travelbin-api`, `agent`, `intonational-api`) but the **wildcard `*` A record alone is sufficient** — the wildcard covers them.
- **Negative DNS cache is brutal:** after all the record churn, a local machine cached `NXDOMAIN` for `agent.quangntran.com` specifically. `nslookup` worked (queries the resolver directly) but the browser/curl didn't (use the OS cache). Fix: `ipconfig /flushdns` + `Restart-Service Dnscache -Force`, or reboot. Confirm with a different network (phone on mobile data) before assuming the server is broken.
- Purge cache (Caching → Purge Everything) after DNS/origin changes to clear stale failures.

### 4. nginx

- Certbot generated the SSL config but the per-app `server` blocks needed cleanup. nginx config is now **version-controlled** at `nginx/travel-platform.conf` in `travel-platform-infra` and symlinked:
  ```bash
  sudo rm /etc/nginx/sites-available/travel-platform
  sudo ln -s ~/apps/travel-platform-infra/nginx/travel-platform.conf /etc/nginx/sites-available/travel-platform
  sudo nginx -t && sudo systemctl reload nginx
  ```
  Update flow is now `git pull` + `sudo systemctl reload nginx` — no pasting giant configs into the terminal.
- Every `server` block needs **both** `listen 443 ssl;` **and** `listen [::]:443 ssl;` (and the same for 80). Missing the `[::]` line breaks IPv6 inbound from Cloudflare.
- `X-Forwarded-Proto $scheme` must be set on every proxy block so backends know they're behind HTTPS.
- Default nginx site (`/etc/nginx/sites-enabled/default`) was removed so it stops shadowing our config.

### 5. Per-app production fixes

- **Splitpush (Spring Boot):**
  - `eclipse-temurin:17-jre-alpine` has **no ARM64 build** → switched runtime image to `eclipse-temurin:17-jre-jammy` (server is aarch64).
  - Behind nginx, Spring generated `redirect_uri=localhost:8080` → added `server.forward-headers-strategy=framework` + nginx `X-Forwarded-Proto`/`X-Forwarded-Host`.
  - Hardcoded `localhost:8180` register/login URLs → made env-configurable (`keycloak.*-uri`, `app.base-url`) in `application-docker.properties` + `ViewController`.
  - `KeycloakClientConfig.java` was **kept** (the env-driven URIs handle prod fine).
- **TravelBin (Django + React):**
  - Dev server (`manage.py runserver`) **crashed on CORS OPTIONS** preflight (connection reset). Fix: switched to **gunicorn** (`gunicorn Teyvat.wsgi:application --bind 0.0.0.0:8000 --workers 2`). gunicorn handles OPTIONS correctly; CORS is handled by Django's `corsheaders`.
  - Briefly tried CORS at the nginx layer — caused **duplicate `Access-Control-Allow-Origin`** (nginx + Django both adding it). Reverted nginx to plain proxy, let Django own CORS.
  - `SECRET_KEY`, `DEBUG`, `ALLOWED_HOSTS`, `CORS_ALLOWED_ORIGINS` all made env-based; set in docker-compose. `travelbin-api.quangntran.com` must be in `ALLOWED_HOSTS`.
  - **`KEYCLOAK_JWKS_URL` kept** pointing at the internal Docker URL (`http://keycloak:8080/...`): Cloudflare returns **403** when the backend tries to fetch JWKS from the public `auth.quangntran.com`. Internal fetch + public `KEYCLOAK_ISSUER` (for `iss` validation) is the working combo.
  - **`VITE_API_URL` wasn't reaching the browser** — Vite reads it from a `.env` *file*, not the container env. The POST was silently going to the frontend origin (404, 5-byte Vite response). Fix: Dockerfile CMD writes it at startup — `sh -c 'echo "VITE_API_URL=$VITE_API_URL" > .env && npm run dev -- --host --port 3001'`.
  - Dockerfile `EXPOSE`/port mismatch (5173 vs 3001) fixed.
  - Frontend crashed white (`data.filter is not a function`) when the user had no destinations yet (API returned an object, not an array) → guarded with `Array.isArray(...)`.
- **Itinerary-Agent (Vue + Express):**
  - Vite blocked the host (`"agent.quangntran.com" is not allowed`) → `allowedHosts: true` in `vite.config.ts` **and** Dockerfile CMD needs `--host`.
  - Hardcoded `localhost:8180` in `keycloak.ts` → `https://auth.quangntran.com`.
- **All apps:** `POSTGRES_HOST` now **defaults to `platform-postgres`** in each docker-compose, so a bare `docker compose up -d` (e.g. when restarting just the frontend) no longer reconnects the backend to the dead standalone DB. Several 502s traced back to this.
- **Keycloak realm was lost** during container recreation; rebuilt it idempotently via `keycloak-service/setup-realm.sh` (realm, 3 clients, test user, login theme). The admin user `admin` was accidentally deleted — recovered by inserting the admin role mapping directly in the Keycloak Postgres DB. First-time registration also silently failed until `firstName`/`lastName` were made non-required in the realm's user-profile config (see the keycloak-service notes in CLAUDE.md).

### 6. Portfolio at the apex (GitHub Pages, not OCI)

`quangntran.com` and `www` hit a **redirect loop**: nginx/Cloudflare redirected apex→www, and GitHub Pages (custom domain = apex) redirected www→apex. Resolution: serve the portfolio straight from GitHub Pages at the apex, bypassing OCI for just the apex:
- Deleted the apex `A → 158.101.110.211` and the Cloudflare apex→www redirect rule.
- Added the four GitHub Pages A records on the apex, **DNS only** (grey cloud): `185.199.108.153`, `.109.153`, `.110.153`, `.111.153`.
- GitHub repo `qtran1018.github.io` → Pages → custom domain `quangntran.com`, Enforce HTTPS.
- App subdomains are unaffected (still wildcard → OCI, proxied).

### 7. Repo layout decisions

- One GitHub repo per app (portfolio visibility) + a separate `travel-platform-infra` repo for shared infra (keycloak-service, postgres-service, nginx config, docs, scripts). The app folders are gitignored inside the infra repo so they aren't accidentally re-added as submodules.
- TravelBin frontend + backend consolidated into a single `travelbin` repo (old `Celestia`/`Celestia-React` archived).
- Repo names lowercased on GitHub; local remotes updated with `git remote set-url`.
- Splitpush: Render autodeploy turned **off** so pushing the new (Keycloak/OCI) version doesn't break the still-live Render deployment. Force-pushed over the old README/Actions commits.
