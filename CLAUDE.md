# Travel Platform — CLAUDE.md

A portfolio of five independent travel apps plus shared infrastructure (Keycloak SSO + shared PostgreSQL). Each app is standalone-capable but designed to integrate when run together. All services join the `travelplatform-network` Docker network.

**Repository strategy:** Each app has its own GitHub repo. Shared infrastructure lives in a separate `travel-platform-infra` repo. No monorepo — individual repos preserve commit history for portfolio visibility.

**Production hosting:** OCI VM.Standard.A1.Flex (4 OCPUs / 24 GB RAM, Always Free) in us-ashburn-1. Domain: `quangntran.com` via Cloudflare (DNS + DDoS protection) → nginx reverse proxy → Docker Compose. See `DEPLOYMENT.md` for full setup. See `ROADMAP.md` for migration plan from current Render (Splitpush) to OCI.

---

## Apps at a Glance

| App | Stack | Auth | Port (Docker) |
|---|---|---|---|
| [postgres-service](#postgres-service) | PostgreSQL 16-alpine | — | 5432 |
| [keycloak-service](#keycloak-service) | Keycloak 26.0 + Postgres | Auth server | **8180** |
| [intonational](#intonational) | FastAPI + Python | Keycloak JWT (Bearer) | 8001–8003 |
| [Itinerary-Agent](#itinerary-agent) | Vue 3 + Express + TS | Keycloak optional login | 3010 / 5000 |
| [Splitpush](#splitpush) | Spring Boot 3.2 + Thymeleaf | Keycloak OAuth2 login | 8080 |
| [TravelBin](#travelbin) | Django 5.1 + React 19 | Keycloak JWT + keycloak-js | 8000 / 3001 |

---

## postgres-service

**Path:** `postgres-service/`
**Purpose:** Shared PostgreSQL 16 instance hosting all three app databases (splitpush, travelbin, itinerary_agent). Replaces the per-app PG containers when running in "combined" mode — saves ~300MB RAM and simplifies backups.

- `docker-compose.yml` — single PG container, container name `platform-postgres`. Port 5432 is **not published in prod**; the local-dev override binds `127.0.0.1:5432:5432` for DB tools. Per-app DB passwords come from env vars (`SPLITPUSH_DB_PASSWORD`, `TRAVELBIN_DB_PASSWORD`, `ITINERARY_DB_PASSWORD`, `POSTGRES_SUPERUSER_PASSWORD`).
- `init.sh` — creates one DB + user per app, reading the password env vars (replaces the old static `init.sql`). Each app only sees its own DB. Runs only on first init of an empty volume.

Each app's docker-compose still has its own PG service marked `profiles: ["standalone"]`, so the original isolated mode is preserved. See [Running Locally](#running-locally-dev-setup) for the two modes.

---

## keycloak-service

**Path:** `keycloak-service/`
**Purpose:** Centralized SSO server. Docker Compose only — no app code.
**Stack:** Keycloak 26.0 + PostgreSQL 16
**Admin:** `http://localhost:8180` — dev credentials `admin` / `admin`
**Port:** 8180 (host) → 8080 (container). In the base (prod) compose the host side is bound to `127.0.0.1:8180:8080` — admin console reachable only via the nginx reverse proxy, never the public internet.
**JVM heap cap:** `JAVA_OPTS_APPEND=-Xms128m -Xmx384m` (saves ~300MB vs default)

**Credentials are env-driven** (no longer hardcoded in compose): `KEYCLOAK_DB_PASSWORD` (required, `:?`), `KEYCLOAK_ADMIN` (default `admin`), `KEYCLOAK_ADMIN_PASSWORD` (required, `:?`). Local dev supplies them via gitignored `keycloak-service/.env` (auto-loaded). ⚠️ On an existing deployment, `KEYCLOAK_DB_PASSWORD` must match the password already in the `keycloak_pgdata` volume (a mismatch takes down all SSO), and `KEYCLOAK_ADMIN_PASSWORD` only seeds the admin on first boot. See `DEPLOYMENT.md` for the rotation procedure.

**Realm:** `travel-platform`

**Clients:**

| Client ID | Type | Redirect URIs | Used By |
|---|---|---|---|
| `splitpush` | Confidential | `http://localhost:8080/*` | Splitpush Spring Boot |
| `travelbin-frontend` | Public (PKCE) | `http://localhost:3000/*`, `http://localhost:3001/*`, `http://localhost:5173/*` | TravelBin React frontend |
| `itinerary-agent` | Public (PKCE) | `http://localhost:3000/*`, `http://localhost:3010/*` | Itinerary-Agent Vue frontend |

**Test user:** `test@example.com` / `password123` (username: `testuser`)

> **Why we don't set `KC_HOSTNAME`:** Keycloak in dev mode dynamically uses the request URL as the issuer. Setting `KC_HOSTNAME=localhost` causes UserInfo/JWKS endpoints to expect a single issuer regardless of which URL hit them, breaking the localhost/keycloak split required by Docker. The split-brain is handled per-app instead (see Splitpush + TravelBin notes).

### Custom Login Theme

**Path:** `keycloak-service/themes/travel-platform/login/`
**Active:** Set in Keycloak Admin → `travel-platform` realm → Realm Settings → Themes → Login Theme → `travel-platform`. Mounted into the container via `volumes: ./themes:/opt/keycloak/themes` in `docker-compose.yml`.

**Design:** Two-panel split layout. Left: dark navy hero with dot-grid, brand, tagline, feature list, and abstract SVG flight-path decoration. Right: clean form panel (white / dark-navy in dark mode). Fixed sun/moon toggle in top-right persists preference in `localStorage` under `tp-theme`. On mobile (≤780 px) the hero hides and a compact sticky brand bar replaces it.

**Theme files:**

| File | Purpose |
|---|---|
| `theme.properties` | `parent=keycloak.v2` — inherits all PatternFly v5 styles and JS |
| `template.ftl` | Full layout override: two-panel HTML shell, anti-FOUC inline script, theme toggle button, mobile brand bar, conditional social-providers divider. Replaces `favicon.ico` reference with `favicon.svg` + correct MIME type. |
| `social-providers.ftl` | Removes the "Or sign in with" band; renders OAuth buttons directly. |
| `user-profile-commons.ftl` | Skips `firstName` and `lastName` fields via `<#continue>` — they are never rendered on the register form. |
| `resources/css/login.css` | Full custom stylesheet: `tp-` prefixed layout classes, PatternFly form-element overrides, dark mode via `html.pf-v5-theme-dark`, mobile breakpoints. Injected as an extra `<link>` in `template.ftl` so parent styles are untouched. |
| `resources/img/favicon.svg` | SVG airplane favicon (blue rounded tile). |

**firstName / lastName removal — two layers:**
- Template: `user-profile-commons.ftl` skips them with `<#continue>`
- Keycloak User Profile config (persisted in DB via admin API): `required: {}` and `permissions.edit: ['admin']` — not required, not user-editable. Only admins can set them. Re-apply if the realm is reset:
```bash
TOKEN=$(curl -s -X POST "http://localhost:8180/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli&username=admin&password=admin&grant_type=password" \
  | python -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
PROFILE=$(curl -s -H "Authorization: Bearer $TOKEN" "http://localhost:8180/admin/realms/travel-platform/users/profile")
UPDATED=$(echo "$PROFILE" | python -c "
import sys, json
p = json.load(sys.stdin)
for a in p.get('attributes', []):
    if a['name'] in ('firstName', 'lastName'):
        a['required'] = {}
        a['permissions'] = {'edit': ['admin'], 'view': a.get('permissions', {}).get('view', ['admin', 'user'])}
print(json.dumps(p))
")
curl -s -o /dev/null -w "%{http_code}" -X PUT "http://localhost:8180/admin/realms/travel-platform/users/profile" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$UPDATED"
```

**Register field order** (email, username, password, confirm password) is controlled by attribute order in the Keycloak User Profile config (persisted in DB). Password fields are injected by `register.ftl` after the `username` attribute via `afterField` callback. Re-apply if realm is reset:
```bash
# Same TOKEN as above, then:
UPDATED=$(echo "$PROFILE" | python -c "
import sys, json
p = json.load(sys.stdin)
by_name = {a['name']: a for a in p.get('attributes', [])}
order = ['email', 'username', 'firstName', 'lastName']
p['attributes'] = [by_name[n] for n in order if n in by_name]
print(json.dumps(p))
")
curl -s -o /dev/null -w "%{http_code}" -X PUT "http://localhost:8180/admin/realms/travel-platform/users/profile" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$UPDATED"
```

**Theme CSS pitfalls:**
- Do NOT use `styles=css/login.css` in `theme.properties` — it replaces the parent's `css/styles.css`, breaking the entire layout (PatternFly styles gone). Instead, inject the extra CSS as a bare `<link>` tag in `template.ftl`.
- Do NOT set `KC_SPI_THEME_DEFAULT` in `docker-compose.yml` — it applies to all theme types (welcome, account, etc.) and breaks pages that have no `travel-platform` version. Set the theme per-realm in the admin console instead.
- Keycloak dev mode (`start-dev`) serves theme files live from the mounted volume — no container restart needed after editing `.ftl` or `.css` files, just hard-refresh (`Ctrl+Shift+R`).
- `meta.ftl` is NOT called by `keycloak.v2`'s `template.ftl` — override `template.ftl` directly for head customisation.

---

## intonational

**Path:** `intonational/`
**Purpose:** Microservices backend aggregating static + dynamic travel data (weather, FX, geocoding, advisories).

**Services:** `aggregator-service` (8001), `dynamic-data-service` (8002, Redis-cached), `static-data-service` (8003, MongoDB + Playwright scraping).

**Key tech:** FastAPI 0.125, Pydantic, MongoDB, Redis, httpx, Playwright, PyJWT
**Auth:** Keycloak JWT validation via `app/shared/auth.py`. Routes require `Authorization: Bearer <token>`. JWKS at `http://localhost:8180/realms/travel-platform/protocol/openid-connect/certs`.

**Exception handling:** Each service registers global `@app.exception_handler`s for `httpx.HTTPStatusError`, `httpx.TimeoutException`, `ValueError`, and generic `Exception` — returns structured JSON instead of stack traces. Redis `redis_repository.py` swallows all Redis errors and degrades gracefully (cache miss > 500 error). MongoDB index creation in `static-data-service` wrapped in try/except so the service starts if Mongo is slow.

**Tests:** `tests/test_weather_service.py` (dynamic-data-service) and `tests/test_weather_historical_service.py` (static-data-service) cover Redis degradation, month validation, and upstream API failure modes via pytest-asyncio.

**Run:** Currently the service Dockerfiles are empty placeholders; services run locally via the venv (`intonational/venv/`). Mongo + Redis come up via `docker compose up -d` from `intonational/`.

---

## Itinerary-Agent

**Path:** `Itinerary-Agent/`
**Purpose:** Quiz-driven AI travel planner. Login is optional. Authenticated users save trips and export to TravelBin.

**Structure:**
- `itinerary-agent/` — Vue 3 frontend (Vite, TS) — port **3010** in Docker (mapped from container's 3000), **3000** local dev
- `itinerary-agent-backend/` — Express 5 backend (TS), port 5000 (internal only)

**Key tech:** Vue 3, TypeScript, Vite, Express 5, OpenAI SDK, Prisma 5, PostgreSQL, Marked, keycloak-js, jwks-rsa
**Env:** `itinerary-agent-backend/.env` needs `OPENAI_API_KEY`, `DATABASE_URL`. In docker-compose, `DATABASE_URL` is overridden to use the container hostname (`itinerary-db` standalone or `platform-postgres` combined).
**DB:** Prisma at `itinerary-agent-backend/prisma/schema.prisma` — models `Trip` and `TripEntry`. Postgres on 5434 in standalone mode, 5432 (shared) in combined mode.

**Auth:** Optional. Frontend Navbar has Register/Login buttons when logged out, username + Logout when logged in (`AuthButton.vue`). `keycloak.register()` redirects to Keycloak registration; `keycloak.login()` redirects to login. Both appear in the mobile hamburger menu too. Backend has `optionalAuth` middleware that validates token if present but never blocks unauthenticated requests; `requireAuth` blocks for trip CRUD routes.

**Structured output (`/api/chat`):** OpenAI returns `{ title, markdown, entries }` where `title` is a 3–7 word LLM-generated trip name (e.g. "Hidden Gems of Kansai Weekend"), `entries` are `{ name, type, location, notes }` and `type ∈ {Food & Drink | Shopping | Sightseeing | Activity | Other}`. The title is used as the trip name for Save and Export; falls back to the raw quiz destination answer if absent.

**Routes (backend):**
- `POST /api/chat` — OpenAI quiz → `{ title, reply, entries }`. Server-side max message length: 2000 chars.
- `GET /api/trips` — list saved trips (auth)
- `POST /api/trips` — save trip (auth)
- `DELETE /api/trips/:id` — delete (auth)
- `POST /api/trips/:id/export` — proxy to TravelBin's `/travel/destinations/import/` (auth, forwards Bearer token)

All Prisma routes wrapped in `try/catch` with `next(err)`; global 4-arg Express error middleware returns structured JSON.

**Quiz questions (`src/data/questions.ts` / `prompts.ts`):**
- Free-text questions (q3, q16) use `maxLength` field on the `Question` type; rendered as HTML `maxlength` attribute with a live char counter. q3 = 300 chars, q16 = 200 chars.
- `optional: true` on a question renders a Skip button (calls `handleAnswer('')`) in addition to Next.
- `mapAnswersToPrompts` guards function-type prompts with `answer.trim()` — prevents empty/whitespace strings from being included in the OpenAI prompt (previously, q3 with empty input generated `"Make an itinerary for . If that is not a real location..."` which was truthy and slipped through).
- Checkbox questions with no selection (`[]`) already produced no prompt contribution; this is now explicit via the same guard.
- q16 prompt function returns `""` for blank input; `filter(Boolean)` at the end of `mapAnswersToPrompts` drops it.
- `submitCheckbox` now calls `sendPrompt()` in its terminal branch (was missing — would have silently skipped the API call if the last question were ever a checkbox type).

**API URL abstraction:** `Quiz.vue` and `Profile.vue` use `const API_URL = import.meta.env.VITE_API_URL ?? ''`. An empty string produces relative `/api/...` paths proxied by Vite's dev server (`vite.config.ts` `server.proxy`). A non-empty `VITE_API_URL` (e.g. `https://agent-api.quangntran.com`) produces absolute URLs for production static builds. The proxy target is hardcoded to `'http://localhost:5000'` in `vite.config.ts` — `process.env` is unavailable in Vite configs without `@types/node`, and the proxy is dev-only anyway.

**Docker — static build + override file:**

`itinerary-agent/Dockerfile` is a multi-stage build: `node:20-alpine` compiles with `ARG VITE_API_URL` / `ARG VITE_KEYCLOAK_URL`; `nginx:alpine` serves `dist/` on port 3000. The nginx config includes an `/api/` proxy block (`proxy_pass http://itinerary-agent-backend:5000`) — critical because the backend has no public subdomain; the static build loses the Vite proxy and the nginx must replicate it.

- `docker-compose.yml` — **production**: backend `ports: "127.0.0.1:5000:5000"` (localhost-only, not publicly exposed); frontend build args `VITE_API_URL: https://agent-api.quangntran.com`, `VITE_KEYCLOAK_URL: https://auth.quangntran.com`.
- `docker-compose.override.yml` — **local dev**: backend `KEYCLOAK_ISSUER: http://localhost:8180/...`; frontend build args `VITE_API_URL: http://localhost:5000`, `VITE_KEYCLOAK_URL: http://localhost:8180`. Auto-applied by plain `docker compose` (no `-f`).

**Docker env vars required (backend, combined mode):**
```yaml
KEYCLOAK_ISSUER: http://localhost:8180/realms/travel-platform   # validates token iss
KEYCLOAK_JWKS_URL: http://keycloak:8080/realms/travel-platform/protocol/openid-connect/certs  # fetches keys via internal network
TRAVELBIN_API_URL: http://travelbin-backend:8000   # internal network hostname
```

**Frontend routing:** Vue Router 4 with hash history. `/` → Quiz (Planner), `/profile` → Profile (saved trips). On `check-sso` callback, App.vue cleans any leftover OAuth params from the URL so the Planner route renders correctly when not authenticated.

**Prisma + Docker quirk:** The backend Dockerfile must use `node:20-slim` (Debian), not `node:20-alpine`. Alpine 3.20 dropped OpenSSL 1.1 entirely; Prisma 5's default `linux-musl` engine binary still links against it. The Dockerfile installs `openssl` (gets v3) and `schema.prisma` declares `binaryTargets = ["native", "debian-openssl-3.0.x"]`. Run migrations: `docker exec itinerary-agent-backend npx prisma migrate deploy`.

---

## Splitpush

**Path:** `Splitpush/`
**Purpose:** Splitwise-style expense splitter. Users create groups, log expenses, settle balances.

**Stack:** Spring Boot 3.2.0 (Java 17), Spring Security, Spring Data JPA, Thymeleaf, Caffeine cache, PostgreSQL
**URL:** `http://localhost:8080` (base/prod compose binds the host side to `127.0.0.1:8080:8080` — reachable only via nginx)
**JVM heap cap:** `JAVA_TOOL_OPTIONS=-Xms128m -Xmx256m` (saves ~250MB)
**Production:** Render + Supabase — see `RENDER_DEPLOYMENT.md`

**`KEYCLOAK_CLIENT_SECRET` is required** — wired through `docker-compose.yml` as `${KEYCLOAK_CLIENT_SECRET:?}`; the confidential client no longer falls back to the committed `splitpush-secret`. Local dev supplies it via gitignored `Splitpush/.env` (auto-loaded); prod sets a strong value from Keycloak Admin → `splitpush` client → Credentials. `application-docker.properties` (the prod profile) logs Spring Security oauth2/web at **WARN**, not DEBUG.

### Auth — Keycloak OIDC

Splitpush is the trickiest auth case because Spring Boot's OAuth2 client wants a single issuer URL, but in Docker the browser must use `http://localhost:8180` while the app container can only reach Keycloak via `http://keycloak:8080`. These two URLs produce tokens with different `iss` claims, and Keycloak validates the issuer on every introspection-style call.

The solution (active when `SPRING_PROFILES_ACTIVE=docker`):

- **`KeycloakClientConfig.java`** — manually constructs a `ClientRegistration` bean, bypassing Spring Boot's `issuer-uri`-driven autodiscovery. This eliminates the startup OIDC discovery call AND skips the `iss` claim check in `OidcIdTokenValidator` (since no issuer is set on the registration). JWT signatures are still validated via `jwkSetUri`.
- **`application-docker.properties`** — provides four endpoint URIs read by `KeycloakClientConfig` via `@Value`:
  - `keycloak.auth-uri` = `http://localhost:8180/...` (browser-facing redirect)
  - `keycloak.token-uri` = `http://keycloak:8080/...` (server-to-server, no `iss` check on this request)
  - `keycloak.jwk-uri` = `http://keycloak:8080/...` (public keys, no validation)
  - `keycloak.end-session-uri` = `http://localhost:8180/...` (browser logout redirect)
- **No `userInfoUri` is configured** — `OidcUserService.shouldRetrieveUserInfo()` returns false, so all user claims come from the ID token (which has email, preferred_username, name when `profile email` scope is requested). This avoids the issuer mismatch that occurs when calling UserInfo from inside Docker against a Keycloak that thinks its issuer is whatever URL hit it.

**RP-Initiated Logout (global SSO logout):** `SecurityConfig.oidcLogoutSuccessHandler()` is a Spring `OidcClientInitiatedLogoutSuccessHandler` that reads `end_session_endpoint` from the `ClientRegistration`'s `providerConfigurationMetadata`. When the user hits `POST /api/auth/logout`, Spring ends the local session AND redirects the browser to Keycloak's logout endpoint, terminating the SSO session. Without this the local logout would only end Splitpush's cookie — Keycloak's session would remain, and the user would be silently re-authenticated on the next visit.

**Other auth behavior:**
- Any unauthenticated request redirects directly to Keycloak (no intermediate login page)
- `/login` and `/register` routes immediately redirect to Keycloak login / registration
- On first login, `KeycloakOidcUserService` auto-provisions a local `User` record from email + preferred_username
- `authentication.getName()` returns email — existing controllers work unchanged

**Critical DB fix (combined mode):** `User.password` is `nullable=true` in the model, but Hibernate's `ddl-auto=update` creates the column as NOT NULL in fresh databases. After the first startup, manually fix:
```sql
ALTER TABLE users ALTER COLUMN password DROP NOT NULL;
```

### Exception handling

`GlobalExceptionHandler` (`@RestControllerAdvice`) catches `EntityNotFoundException` (404), `AccessDeniedException` (403), `IllegalArgumentException` / `MethodArgumentNotValidException` (400), `RuntimeException` (400 with message), `NoResourceFoundException` (404, suppresses noisy favicon logs), and generic `Exception` (500). Tests in `src/test/java/com/splitpush/exception/GlobalExceptionHandlerTest.java`.

### Invite links

- `InviteToken` entity (UUID PK, FK to `TripGroup` and `User`, `createdAt`)
- `POST /api/invite` — creates token
- `GET /invite/{token}` — public Thymeleaf page with Login/Register buttons
- `GET /invite/{token}/join` — protected; Spring Security saves the request before Keycloak redirect, replays after login
- `SecurityConfig` uses `defaultSuccessUrl("/dashboard", false)` so saved-request redirect works

**DB schema:** `users`, `trip_groups`, `trip_group_members`, `expenses`, `expense_participants`, `settlements`, `invite_tokens`. Groups use ULID IDs. Caffeine wraps user/group/expense/balance lookups.

---

## TravelBin

**Path:** `TravelBin/`
**Purpose:** Collaborative travel planning. Users build and share trip itineraries.

**Structure:**
- `travelbin-backend/` — Django 5.1 REST API, port 8000 (base/prod compose binds host side to `127.0.0.1:8000:8000` — reachable only via nginx)
- `travelbin-frontend/` — React 19 SPA, port **3001** (mapped 3001:3001 in Docker — Vite config is `host: '0.0.0.0', port: 3001`; left on `0.0.0.0` for local LAN device testing)

**`DJANGO_SECRET_KEY` is required** — compose passes `SECRET_KEY: ${DJANGO_SECRET_KEY:?}`; the insecure `django-insecure-…` fallback was removed from compose. Local dev supplies it via gitignored `TravelBin/.env` (auto-loaded); prod sets a strong value. (`settings.py` still keeps its own `os.getenv('SECRET_KEY', 'django-insecure-…')` fallback, but the compose `:?` guarantees the var is always set in docker prod, so the fallback is never reached there.)

**Backend:** Django 5.1.7, DRF 3.15.2, PyJWT, psycopg v3, gunicorn
**Frontend:** React 19, Vite 6, React Router v7, TanStack Query v5, Axios, keycloak-js
**Frontend env:** `VITE_API_URL=http://localhost:8000` in `travelbin-frontend/.env`

### Auth — Keycloak JWT (backend) + keycloak-js (frontend)

*Backend:*
- `Traveler/auth.py` — `KeycloakJWTAuthentication` DRF class validates RS256 Bearer tokens via JWKS
- Auto-provisions local `User` on first authenticated request using `keycloak_sub` claim
- `GET /travel/me/` returns current user info
- `settings.py` reads `KEYCLOAK_ISSUER` (must match token `iss` — defaults to `http://localhost:8180/...`) and **`KEYCLOAK_JWKS_URL`** (separate var, optional, lets Docker fetch JWKS via `http://keycloak:8080/...` while still validating `iss` against the public URL). In `docker-compose.yml` both are set so backend can reach Keycloak even when the browser-facing issuer is different.

*Frontend:*
- `src/keycloak.js` — Keycloak client (`realm: travel-platform`, `clientId: travelbin-frontend`)
- `AuthContext.jsx` — `keycloak.init({ onLoad: 'check-sso' })`, exposes `user` and `authLoading`. Components wait on `authLoading` to prevent flash of unauthenticated UI
- `api.js` — Axios interceptor calls `keycloak.updateToken(30)` before each request
- Navbar "Log In" calls `keycloak.login()` directly; `/login` and `/register` routes redirect immediately to Keycloak
- `AuthContext.jsx` `logout()` uses `redirectUri: window.location.href` — user stays on the current page after logout (not redirected to home)
- `Home.jsx` guards on `authLoading` before rendering (`if (authLoading) return null`) — prevents the logged-out home flash during the Keycloak SSO check on login

### Exception handling

`Traveler/exceptions.py` — custom DRF exception handler logs unhandled errors and returns `{"error": "..."}`. Settings registers it via `REST_FRAMEWORK['EXCEPTION_HANDLER']`. Django `LOGGING` config in `settings.py` routes the `Traveler` logger to console (replaces `print()` calls in views). 15+ test cases in `Traveler/tests.py` cover auth, 404s, permission denials, import.

### Docker — static build + override file

`travelbin-frontend/Dockerfile` is a multi-stage build: `node:20-alpine` compiles the Vite app with `ARG VITE_API_URL` / `ARG VITE_KEYCLOAK_URL`; the resulting `dist/` is served by `nginx:alpine` on port 3001. The nginx config includes `try_files $uri $uri/ /index.html` (SPA fallback — harmless with HashRouter but present for robustness).

**Build arg discipline:** `VITE_API_URL` and `VITE_KEYCLOAK_URL` are baked at build time.
- `docker-compose.yml` — **production** values (`https://travelbin-api.quangntran.com`, `https://auth.quangntran.com`) under `build.args`. Ports `3001:3001`.
- `docker-compose.override.yml` — **local dev** values (`http://localhost:8000`, `http://localhost:8180`) + backend `KEYCLOAK_ISSUER` / `CORS_ALLOWED_ORIGINS` overrides. Auto-applied by plain `docker compose` (no `-f`).
- Running `docker compose -f docker-compose.yml up` explicitly skips the override (production build). Never use `-f` for local dev.

After changing `package.json`, rebuild: `docker compose build travelbin-frontend && docker compose up -d travelbin-frontend`.

### Invite links

- `POST /travel/invite/create/` (auth + permissions) generates token
- `GET /travel/invite/<token>/` — public, returns destination name + inviter
- `POST /travel/invite/<token>/join/` (auth) adds user to permissions
- `App.jsx`'s `PendingInviteAutoJoin` — on return from Keycloak with `pendingInviteToken` in sessionStorage, calls the join API and navigates to the destination directly
- `InviteJoin.jsx` handles already-authenticated visits

### Members management

- `MembersModal.jsx` — overlay from "Members" button on entry page (auth + perms required). Shows members (username + email) with trash button; email input to add by email
- `GET /travel/permissions/get_by_destination/<id>` returns enriched `[{permission_id, user_id, username, email}]`

### Import from Itinerary-Agent

- `POST /travel/destinations/import/` — creates destination + pre-populates `TravelEntry` from structured entries array

### Destination name editing and creation

- Destination `name` is a plain `CharField(max_length=100)` — no `unique` constraint, no FK references (all relationships use UUID `id`). Safe to rename without breaking anything.
- `DestinationShow.jsx`: ✏️ pencil button appears per row when `canCreate=true` (owner). Click → inline `<input>` pre-filled with current name, max 100 chars. Enter/✓ saves via `PATCH /travel/d/<id>/update/`; Escape/✕ cancels. All members see the updated name (one shared name per destination — per-user independent labels would require a new model field).
- New-destination input is an inline form in the header (`newName`/`setNewName` state, `onSubmit={handleCreate}`). No search popup — the input doubles as the create field. The `+ New` button is `type="submit"` so Enter also submits.

### Entry table — day groups, drag-and-drop, editable cells

Entries are grouped into per-day sections using a `groupByDate()` helper that returns `[[dateKey, items[]], ...]` sorted chronologically, with an "Unscheduled" group (null date) always last. Each group renders as a `<section class="day-group">` with a header showing the formatted date and entry count, then a table of entries.

**Drag-and-drop reordering** uses `@atlaskit/pragmatic-drag-and-drop` v1.5.2 (`draggable`, `dropTargetForElements`, `monitorForElements` from `element/adapter`). Each row has a drag handle column (hidden on mobile). Drop updates local state immediately (optimistic), then calls `POST /travel/d/<id>/reorder/` with the target group's new sort order.

**Cross-group drag:** dropping an entry onto a row in a different day group assigns that group's date to the entry (null for Unscheduled). The `monitorForElements` handler detects `sourceDateKey !== targetDateKey`, PATCHes the entry's date, and posts the target group's new sort order. `canDrop` only excludes self-drop (no same-group restriction).

**`sort_order`** (`IntegerField(default=0)`) persists the within-day order. Backend query orders by `sort_date` then `sort_order`. Batch reorder uses `bulk_update` in an atomic transaction.

- Name, Location, and Notes cells use `<textarea rows="1">` with JS auto-resize. Textareas grow to fit content; no fixed min-height.
- Type uses `<select>`, Date uses `<input type="date">` — unchanged.
- Auto-save fires 600 ms after the last keystroke (debounced). Saving/Saved/Error indicator shown per-row.
- New-entry row sits above all day groups in its own table (always Unscheduled until a date is entered).
- Entry page heading shows the actual destination name from `GET /travel/d/<pk>/detail/` (public, no auth).

### Backend endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/travel/` | — | List all destinations |
| POST | `/travel/d/add_travel/` | ✓ | Create destination |
| GET | `/travel/d/<pk>/detail/` | — | Get single destination by ID (name, id) |
| PATCH | `/travel/d/<pk>/update/` | ✓ perms | Update destination (name etc.) |
| DELETE | `/travel/d/<pk>/delete/` | ✓ perms | Delete destination |
| GET | `/travel/d/<destination_id>/` | — | List entries for a destination |
| POST | `/travel/d/<pk>/create_entry/` | ✓ | Add entry |
| POST | `/travel/d/<destination_id>/reorder/` | ✓ perms | Batch-reorder entries (DnD) |
| PATCH | `/travel/<pk>/update/` | ✓ | Update entry (auto-save, supports `date` + `sort_order`) |
| DELETE | `/travel/<pk>/delete/` | ✓ | Delete entry |
| GET | `/travel/me/` | ✓ | Current user info |
| POST | `/travel/destinations/import/` | ✓ | Import from Itinerary-Agent |
| POST | `/travel/invite/create/` | ✓ perms | Generate invite token |
| GET | `/travel/invite/<token>/` | — | Invite info (destination name + inviter) |
| POST | `/travel/invite/<token>/join/` | ✓ | Join via invite |
| GET | `/travel/permissions/get_by_destination/<id>` | ✓ | List members |
| POST | `/travel/permissions/add/` | ✓ | Add member by email |
| DELETE | `/travel/permissions/delete/<dest>/<email>/` | ✓ | Remove member |

### Docker env vars required (combined mode)

`ALLOWED_HOSTS` in `settings.py` reads from env var, defaults to `localhost,127.0.0.1,travelbin-backend,0.0.0.0`. The `travelbin-backend` hostname is needed so inter-container calls from itinerary-agent-backend (export) are accepted.

### UI notes

- Light mode uses cool blue-slate palette (`--bg-color: #f0f4fa`, `--secondary-color: #e8eef7`). Table headers flat (no gradient)
- Entry table Name/Location columns: `min-width: 180px` via `.col-name` / `.col-location`
- Members + Copy Invite Link buttons render in the same toolbar row as Reset Filters (via `extraControls` prop to `EntryShow`)

**Rate limiting:** 10 req/min (anon), 200 req/hr (auth)

---

## Running Locally (Dev Setup)

Two modes are supported. **Combined mode** is the default and what gets used on a VPS.

### 1. Network (one-time)

```bash
docker network create travelplatform-network
```

### 2. Start infrastructure

**Combined mode** (single shared Postgres, ~300MB lower RAM):
```bash
docker compose up -d   # from keycloak-service/   → Keycloak on :8180
docker compose up -d   # from postgres-service/   → Shared Postgres on :5432
docker compose up -d   # from intonational/       → MongoDB + Redis
```

**Standalone mode** (each app keeps its own Postgres — original setup):
```bash
docker compose up -d                                       # from keycloak-service/
docker compose --profile standalone up -d postgres         # from Splitpush/        → :5432
docker compose --profile standalone up -d travelbin-db     # from TravelBin/        → :5433
docker compose --profile standalone up -d itinerary-db     # from Itinerary-Agent/  → :5434
docker compose up -d                                       # from intonational/
```

### 3. Start apps (Docker)

Combined mode — pass `POSTGRES_HOST=platform-postgres`:

```bash
POSTGRES_HOST=platform-postgres docker compose up -d   # from Splitpush/
POSTGRES_HOST=platform-postgres docker compose up -d   # from TravelBin/
POSTGRES_HOST=platform-postgres docker compose up -d   # from Itinerary-Agent/
```

Standalone mode — no env var needed; each compose defaults to its own DB container.

### 4. Or start apps locally (no container)

```bash
cd Splitpush && mvn spring-boot:run
cd TravelBin/travelbin-backend && ../venv/Scripts/python.exe manage.py runserver 8000
cd TravelBin/travelbin-frontend && npm run dev          # port 3001
cd Itinerary-Agent/itinerary-agent-backend && npm run dev
cd Itinerary-Agent/itinerary-agent && npm run dev       # port 3000 locally
```

> TravelBin venv: `TravelBin/venv/`. Install psycopg if missing: `python -m pip install "psycopg[binary]"`.

### 5. First-time DB migrations

Combined mode requires running migrations after the first startup:

```bash
docker exec travelbin-backend python manage.py migrate
docker exec itinerary-agent-backend npx prisma migrate deploy
# Splitpush uses ddl-auto=update — auto-migrates on first run
# Then fix the Splitpush users.password NOT NULL constraint:
docker exec platform-postgres psql -U splitpush_user -d splitpush -c "ALTER TABLE users ALTER COLUMN password DROP NOT NULL;"
```

### 6. URLs

| App | URL |
|---|---|
| Keycloak admin | http://localhost:8180/admin |
| Splitpush | http://localhost:8080 |
| TravelBin frontend | http://localhost:3001 |
| TravelBin API | http://localhost:8000 |
| Itinerary-Agent frontend | http://localhost:3010 (Docker) or http://localhost:3000 (local) |
| intonational | http://localhost:8001 (aggregator) / 8002 (dynamic) / 8003 (static) |

**Test credentials:** `test@example.com` / `password123` (username: `testuser`)
**Register:** click "Register" on Keycloak login — account works across all apps (SSO).

---

## Keycloak SSO — Implementation Notes

### Token validation

All apps validate tokens the same way: **RS256 JWT signed by Keycloak**, verified against JWKS. No shared secret — the public key is fetched and cached.

### The localhost vs Docker-internal split

Keycloak in dev mode dynamically uses the request URL as the issuer claim. This is fundamentally at odds with Docker: the browser uses `http://localhost:8180` (hits Keycloak via the host port mapping), but app containers can only reach Keycloak via `http://keycloak:8080` on the internal network. Tokens minted via the browser flow carry `iss=http://localhost:8180/...`, but a request from inside a container to `http://keycloak:8080/userinfo` would be validated against `iss=http://keycloak:8080/...` — mismatch.

The pattern used by each app:
- **TravelBin** splits `KEYCLOAK_ISSUER` (`localhost:8180`, validated against token `iss`) from `KEYCLOAK_JWKS_URL` (`keycloak:8080`, used to fetch public keys — no issuer check on this request).
- **Splitpush** bypasses Spring Boot's `issuer-uri` autodiscovery entirely via a custom `ClientRegistrationRepository` bean (`KeycloakClientConfig`). It does NOT call `/userinfo` (claims read from ID token), only the public `/auth` (browser), `/token` (server), and `/certs` (server) endpoints. JWT signatures validated via `jwkSetUri`; `iss` validation skipped because no issuer is set on the registration.
- **Itinerary-Agent** uses `keycloak-js` (browser-only), so the issuer question doesn't arise on the frontend. The backend (`server.ts`) validates JWTs via `jwks-rsa` pointed at `KEYCLOAK_ISSUER`.
- **intonational** validates JWTs in `app/shared/auth.py` per-service via PyJWKClient. JWKS URL is constructed from `KEYCLOAK_ISSUER`.

### First-login user provisioning

- **TravelBin:** first authenticated API call → look up `keycloak_sub`, create `User` if missing
- **Splitpush:** during OIDC callback → `KeycloakOidcUserService` creates `User` if email not found

### Global logout (RP-Initiated Logout)

**Splitpush** logs out of both the local session and the Keycloak SSO session via `OidcClientInitiatedLogoutSuccessHandler`. Without this, clicking logout would only end the Splitpush cookie — the browser would silently re-authenticate via the still-live Keycloak session on the next visit. This is the OIDC-spec-compliant approach.

TravelBin and Itinerary-Agent use `keycloak-js`'s `keycloak.logout()` which performs RP-Initiated Logout natively.

### Google OAuth via Keycloak

Configured as a Keycloak Identity Provider (broker). All apps automatically get "Continue with Google" once credentials are added.

1. [Google Cloud Console](https://console.cloud.google.com/) → APIs & Services → Credentials → Create OAuth 2.0 Client ID (Web application)
2. Authorized redirect URI: `http://localhost:8180/realms/travel-platform/broker/google/endpoint`
3. Keycloak Admin → `travel-platform` realm → Identity Providers → Google → set Client ID + Secret

### Getting a token for API testing (password grant)

```bash
curl -s -X POST http://localhost:8180/realms/travel-platform/protocol/openid-connect/token \
  -d "client_id=travelbin-frontend&username=testuser&password=password123&grant_type=password&scope=openid" \
  | python -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
```

> Direct access grants enabled on `travelbin-frontend` for dev/testing only. Disable in production.

---

## Production Deployment Notes

The dev setup's complexity (localhost-vs-container split, custom Splitpush KeycloakClientConfig, KEYCLOAK_JWKS_URL split in TravelBin) exists only because dev runs Keycloak at two different URLs depending on who's asking. **In production this all collapses** — Keycloak gets a single public domain (`https://auth.yourdomain.com`) reachable by both browsers and backend containers, so the issuer is consistent everywhere.

When you have a domain:

| What | Dev | Production |
|---|---|---|
| Keycloak URL | `http://localhost:8180` / `http://keycloak:8080` (split) | `https://auth.yourdomain.com` (single) |
| TravelBin `KEYCLOAK_JWKS_URL` | Set to internal URL | **Delete it** — issuer URL is now publicly reachable |
| Splitpush `KeycloakClientConfig.java` | Required workaround | **Delete it** — restore standard `issuer-uri` autodiscovery in `application.properties` |
| Keycloak `start-dev` | Yes | `start` with `KC_HOSTNAME=auth.yourdomain.com`, `KC_HOSTNAME_STRICT=true`, `KC_PROXY=edge` |
| Keycloak client redirect URIs | `http://localhost:*` | `https://yourdomain.com/*` |
| `VITE_API_URL` (TravelBin) | `http://localhost:8000` | `https://api.yourdomain.com` |
| `TRAVELBIN_API_URL` (Itinerary-Agent) | `http://localhost:8000` | `https://api.yourdomain.com` |

Recommended VPS architecture: nginx (or Nginx Proxy Manager) terminates TLS, subdomains route to each app's port, all containers share `travelplatform-network`. ~4GB RAM is enough with the JVM heap caps and shared Postgres.

### Production build status (as of June 2026 — live on OCI)

The platform is deployed. Full state, rationale, and the per-app migration plan (with landmines) live in **`DEPLOYMENT.md` → "Production Hardening — Path to Real Production"**. Summary:

| Service | Runtime | Prod-correct? |
|---|---|---|
| TravelBin backend | gunicorn | ✅ |
| Splitpush | built JAR | ✅ |
| Itinerary-Agent backend | `node dist/server.js` | ✅ |
| TravelBin frontend | static nginx (`nginx:alpine`) | ✅ |
| Itinerary-Agent frontend | static nginx + `/api` proxy | ✅ |
| Keycloak | `start-dev` + `KC_HOSTNAME` | ⚠️ works, dev mode |
| intonational | empty Dockerfiles | ⏸️ not deployed |

Keycloak `start-dev`→`start` is a separate higher-risk pass and is the only remaining production hardening item.

---

## Docker Network

All services join `travelplatform-network`:

```bash
docker network create travelplatform-network
```

Each `docker-compose.yml` declares:
```yaml
networks:
  travelplatform-network:
    external: true
```

---

## Environment Variables (Summary)

**Required secrets fail loud.** Compose files use `${VAR:?}` for the secrets below — the container won't start if unset. Provide them in a **gitignored `.env` file in the same directory as the compose file** (auto-loaded by `docker compose`, even with `-f docker-compose.yml`). Each directory has a `.env.example`. **🔑 = required (`:?`).**

| App | Key Variables |
|---|---|
| postgres-service | 🔑 `POSTGRES_SUPERUSER_PASSWORD`, 🔑 `SPLITPUSH_DB_PASSWORD`, 🔑 `TRAVELBIN_DB_PASSWORD`, 🔑 `ITINERARY_DB_PASSWORD` (consumed by `init.sh`) |
| keycloak-service | 🔑 `KEYCLOAK_DB_PASSWORD`, 🔑 `KEYCLOAK_ADMIN_PASSWORD`, `KEYCLOAK_ADMIN` (default `admin`), `JAVA_OPTS_APPEND` |
| intonational | External API keys, Redis/Mongo URIs |
| Itinerary-Agent backend | `OPENAI_API_KEY`, `DATABASE_URL` (overridden in compose), `KEYCLOAK_ISSUER` |
| Splitpush | 🔑 `KEYCLOAK_CLIENT_SECRET`, `POSTGRES_HOST` (combined mode), `SPRING_PROFILES_ACTIVE=docker`, `JAVA_TOOL_OPTIONS` |
| TravelBin backend | 🔑 `DJANGO_SECRET_KEY` (→ `SECRET_KEY`), `DB_HOST` (from `POSTGRES_HOST`), `DB_PORT`, `KEYCLOAK_ISSUER`, `KEYCLOAK_JWKS_URL` |
| TravelBin frontend | `VITE_API_URL` |

> `init.sql` was replaced by `init.sh` (reads the per-app password env vars). On an *existing* DB volume, password env vars only apply via SQL rotation, not a recreate — see `DEPLOYMENT.md`.

---

## Rebuilding Docker Images

If you change source code, you must rebuild the affected image — `docker compose up` reuses cached images otherwise.

```bash
# Full rebuild (most common after source changes)
docker compose build --no-cache <service> && docker compose up -d <service>

# Frontends specifically: removing the volume mount means rebuild required for ANY source change
# Backends: usually only rebuild when changing requirements.txt / package.json / pom.xml
```

The intonational, postgres-service, and keycloak-service containers don't need rebuilds — they use pre-built images.
