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

| Subdomain                   | App                      |
| --------------------------- | ------------------------ |
| quangntran.com              | Portfolio landing page   |
| auth.quangntran.com         | Keycloak SSO             |
| app.quangntran.com          | Splitpush                |
| travel.quangntran.com       | TravelBin frontend       |
| api.quangntran.com          | TravelBin API            |
| agent.quangntran.com        | Itinerary-Agent frontend |
| intonational.quangntran.com | intonational aggregator  |

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

---

## Making Code Changes

### Workflow

```
edit locally → git push → SSH into server → git pull → rebuild container
```

### Rebuild a specific service

```bash
cd travel-platform
git pull
docker compose build --no-cache <service-name>
docker compose up -d <service-name>
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

- [ ] OCI instance provisioned (A1.Flex — script running)
- [ ] SSH access confirmed
- [ ] Docker installed on server
- [ ] Repo cloned on server
- [ ] All `.env` files filled with production values
- [ ] Keycloak admin password changed from default
- [ ] PostgreSQL credentials changed from defaults in `init.sql`
- [ ] Django `SECRET_KEY` set to a strong random value
- [ ] `DEBUG=False` in TravelBin Django settings
- [ ] OpenAI API key set for Itinerary-Agent

### DNS + TLS

- [ ] OCI public IP obtained
- [ ] Namecheap A records updated
- [ ] DNS propagated (verify with `nslookup quangntran.com`)
- [ ] nginx installed and configured
- [ ] Certbot SSL certs issued for all subdomains

### Keycloak production config

- [ ] `KC_HOSTNAME` set to `auth.quangntran.com`
- [ ] Client redirect URIs updated to production URLs
- [ ] `KeycloakClientConfig.java` removed from Splitpush (use standard issuer-uri)
- [ ] `KEYCLOAK_JWKS_URL` removed from TravelBin (not needed when issuer is public)
- [ ] Google OAuth credentials updated with production redirect URI

### Post-launch

- [ ] All apps reachable via HTTPS
- [ ] SSO login works across all apps
- [ ] TravelBin → Itinerary-Agent export works
- [ ] Certbot auto-renewal confirmed (`sudo certbot renew --dry-run`)
- [ ] Portfolio landing page hosted at quangntran.com
