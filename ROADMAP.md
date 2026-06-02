# Travel Platform — Future Roadmap

Ideas for expanding the ecosystem with new standalone apps and a unified dashboard portal. All apps share Keycloak SSO, so any logged-in user gets a consistent identity across the whole platform.

---

## GitHub & Hosting Plan

### Repository strategy

Each app stays in its own GitHub repo — **no monorepo**. Reasons:
- Individual commit histories are visible to employers/recruiters
- Apps don't share source code, only infrastructure
- Splitpush is already deployed on Render via its own repo — no disruption needed

A separate **`travel-platform-infra`** repo will hold shared infrastructure only:
- `docker-compose.yml` (orchestrates all apps on the server)
- `nginx/` config
- `postgres-service/`
- `keycloak-service/`
- `DEPLOYMENT.md`
- `ROADMAP.md`

App repos remain independent. The infra repo is what gets cloned on the OCI server.

### Current repo status

| Repo | Status | Notes |
|---|---|---|
| `splitpush` | Active — keep | Render deploys from this repo, do not archive |
| `travelbin` | Keep as-is | Will archive after OCI deployment confirmed |
| `itinerary-agent` | Keep as-is | Will archive after OCI deployment confirmed |
| `intonational` | Keep as-is | Will archive after OCI deployment confirmed |
| `travel-platform-infra` | To create | New repo for shared infrastructure |

### Hosting plan

| Stage | Status |
|---|---|
| OCI A1.Flex instance (4 OCPUs / 24 GB, Ashburn) | Provisioning — retry script running |
| Domain: quangntran.com (Namecheap) | Ready — currently pointing to GitHub Pages |
| DNS via Cloudflare (DDoS protection + CDN) | To configure after instance is live |
| Splitpush on Render | Live — stays until OCI deployment confirmed |

### Migration order (once OCI instance is live)

1. Set up server (Docker, nginx, Cloudflare)
2. Deploy full travel-platform on OCI
3. Test all apps + SSO integration
4. Point quangntran.com to OCI via Cloudflare
5. Confirm everything works end-to-end
6. Decommission Render (Splitpush moves to OCI)
7. Archive old individual repos (except splitpush until Render is fully decommissioned)

---

---

## The Big Idea: TravelHub Portal

Before new standalone apps, the highest-leverage addition is a **central portal** that makes the existing four apps feel like one cohesive product. Right now each app lives in isolation — a user has to open four browser tabs to see their itineraries, destinations, expenses, and weather. TravelHub collapses that into a single authenticated dashboard.

Each existing app (and future ones) exposes a lightweight `/widget/summary` endpoint. TravelHub calls all of them with the user's Keycloak Bearer token and renders the results as draggable widget cards. Clicking a widget deep-links into the originating app.

### Widget endpoint pattern

Each app adds one endpoint:

```
GET /api/widget/summary
Authorization: Bearer <token>

→ Returns a compact JSON payload (< 2KB) designed for card display
```

#### Existing app widget endpoints to add

| App                       | Endpoint                                       | Returns                                                 |
| ------------------------- | ---------------------------------------------- | ------------------------------------------------------- |
| **TravelBin**       | `GET /travel/widget/summary/`                | Destination count, last 3 destinations with entry count |
| **Itinerary-Agent** | `GET /api/widget/summary`                    | Trip count, last 2 trips with destination + entry count |
| **Splitpush**       | `GET /api/widget/summary`                    | Net balance across all groups, count of unsettled debts |
| **intonational**    | `GET /api/v1/widget/conditions?locations=[]` | Weather + FX snapshot for a list of lat/lon pairs       |

### TravelHub tech suggestion

**Next.js** (React, SSR) — a deliberate contrast to the Vite SPAs already in the portfolio. SSR means widget data can be fetched server-side so the page arrives pre-rendered, not blank while API calls complete. Keycloak auth via `next-auth` with the Keycloak provider.

Port: **4000**

---

## New Standalone Apps

Each app below is designed to work independently (no other app required) but gains extra value when integrated with TravelBin, intonational, or Splitpush.

---

### 1. TravelMap

**Purpose:** Visual interactive map of all your TravelBin destinations and their individual entries. Plan where you've been and where you're going.

**How it works:**

- Calls TravelBin's destination + entry APIs to get location strings
- Passes those strings to intonational's `GET /api/v1/geocode` to resolve coordinates
- Renders pins on a map using **Leaflet.js + OpenStreetMap** (no API key required)
- Clicking a pin shows the destination name, entry count, and a link to TravelBin

**Standalone use:** Yes — any user can paste a place name and see it on the map, even without a TravelBin account.

**Widget:** A mini read-only map showing the user's last 5 destinations as pins.

**Tech:** React + Leaflet — no new backend needed. Pure frontend that calls existing APIs.

**Port:** 4001

**Integration points:**

- TravelBin `GET /travel/u/<username>/` → destination list
- TravelBin `GET /travel/d/<id>/` → entry locations
- intonational `GET /api/v1/geocode?search_term=` → lat/lon for each location

---

### 2. PackList

**Purpose:** AI-assisted packing list generator. Enter a destination and travel dates → get a smart packing list tailored to the forecasted weather, trip type (beach, city, hiking), and duration.

**How it works:**

- User enters destination + dates (or links a TravelBin destination)
- PackList calls intonational for the weather forecast for those dates
- Sends destination + weather summary + trip type to an AI (Claude or OpenAI) to generate a categorised packing list
- User can check items off, add customs, and save the list
- Lists are stored per-trip and persist between sessions

**Standalone use:** Yes — works without TravelBin. User just types a destination manually.

**Widget:** Shows completion percentage for an active packing list ("Paris trip — 14/32 items packed").

**Tech:** Vue 3 + Vite (frontend), FastAPI (backend, fits intonational's stack) + PostgreSQL for saved lists.

**Port:** 5001 (backend), 4002 (frontend)

**Integration points:**

- intonational `GET /api/v1/weather-forecast` → temperature + precipitation for packing decisions
- intonational `GET /api/v1/geocode` → resolve destination name to coordinates
- TravelBin destination list → auto-populate destination field for saved destinations
- Keycloak JWT → save lists per user

---

### 3. TravelBudget

**Purpose:** Pre-trip budget planner. Set spending targets by category (accommodation, food, transport, activities, shopping) before a trip. When you return, compare your planned budget against actual Splitpush expenses.

**How it works:**

- Create a budget linked to a trip name and destination
- Assign amounts per category in your home currency
- intonational provides live FX rates so you can budget in local currency too
- After the trip, pull Splitpush expense data and overlay it against the budget to show over/under per category

**Standalone use:** Yes — the budget planner works without Splitpush. The comparison feature requires it.

**Widget:** Shows a compact bar chart of budget vs. actual for the most recent trip.

**Tech:** Svelte + SvelteKit (frontend — a different framework for portfolio variety), Express + Prisma + PostgreSQL (backend).

**Port:** 5002 (backend), 4003 (frontend)

**Integration points:**

- intonational `GET /api/v1/fxrates` → live currency conversion
- Splitpush `GET /api/expenses/group/{groupId}` → actual expenses for comparison
- Splitpush `GET /api/dashboard/balances` → net balance context
- Keycloak JWT → associate budgets with users

---

### 4. TravelJournal

**Purpose:** A private trip diary. Write retrospective journal entries per day, attach photos, and link them to TravelBin destinations and entries. Different from TravelBin (which is a planner) — Journal is for reflection and memory.

**How it works:**

- Select a TravelBin destination as the context
- Write dated diary entries (rich text — Markdown or Tiptap editor)
- Attach photos (stored as files, served from the backend)
- Each journal entry can tag specific TravelBin entries it relates to ("today we went to Senso-ji — entry #42")
- Private by default; can be shared with specific users (same permission model as TravelBin)

**Standalone use:** Yes — works without TravelBin. The destination linkage is optional.

**Widget:** Shows the most recent journal entry's first sentence and the destination it belongs to.

**Tech:** Django 5 + DRF (backend, consistent with TravelBin) + React (frontend). Photo storage via local filesystem in dev, S3-compatible (Backblaze B2 or Cloudflare R2) in production.

**Port:** 9000 (backend), 4004 (frontend)

**Integration points:**

- TravelBin `GET /travel/u/<username>/` → destination list for linking
- TravelBin `GET /travel/d/<id>/` → individual entries for tagging
- Keycloak JWT → private per-user journals

---

### 5. VisaCheck

**Purpose:** Quickly check visa requirements, entry rules, vaccination recommendations, and travel advisories for any destination — based on your passport nationality.

**How it works:**

- User sets their passport country once in their profile
- Enter a destination → see: visa required (yes/no/on arrival), typical validity, vaccination recommendations, current travel advisory level, currency restrictions
- Data sourced from intonational's static-data-service (the travel advisory scraper, currently WIP)
- Results displayed clearly with colour-coded advisory levels (green/yellow/orange/red)

**Standalone use:** Yes — fully self-contained. Doesn't need other apps.

**Widget:** For each TravelBin destination, show a coloured advisory dot and "Visa: Not required / Required / On arrival."

**Tech:** Extend intonational's `static-data-service` to complete the advisory scraping (currently stubbed). Frontend: Vue 3 (fits alongside Itinerary-Agent). No separate backend — purely a UI over intonational's API.

**Port:** 4005

**Integration points:**

- intonational `GET /api/v1/advisories` → advisory level + entry requirements (needs completing)
- intonational `GET /api/v1/geocode` → resolve destination to country code
- TravelBin destination list → auto-check advisories for saved destinations

---

### 6. WeatherDash

**Purpose:** Compare weather across multiple destinations side by side for trip planning. "Should we go to Bali in June or September?" answers itself with a visual climate comparison.

**How it works:**

- Add up to 4 destinations to compare
- Pick a month
- See side-by-side cards showing: average high/low, rainfall, humidity, typical conditions — all from intonational's historical weather data
- Toggle to "Forecast" view for the next 16 days (intonational forecast endpoint)
- Destinations can be pulled from TravelBin's saved list or typed manually

**Standalone use:** Yes — fully self-contained.

**Widget:** Shows weather snapshot (high/low + condition icon) for the user's next upcoming TravelBin destination.

**Tech:** React + Vite (frontend only — calls intonational directly, no new backend needed). Recharts or Chart.js for the comparison visuals.

**Port:** 4006

**Integration points:**

- intonational `GET /api/v1/historical-weather` → climate normals per month
- intonational `GET /api/v1/weather-forecast` → 16-day forecast
- intonational `GET /api/v1/geocode` → destination → coordinates
- intonational `GET /api/v1/aggregator` → combined data in one call
- TravelBin `GET /travel/u/<username>/` → pre-fill destinations from saved list

---

## Architecture Notes

### Shared widget contract

Every widget endpoint should follow this envelope so TravelHub can handle them uniformly:

```json
{
  "app": "travelbin",
  "displayName": "TravelBin",
  "ok": true,
  "data": { ... },
  "deepLink": "http://localhost:3001/#/u/testuser"
}
```

If an app is down or the user has no data, `ok: false` with an `error` string — TravelHub shows a graceful "unavailable" card rather than crashing.

### Keycloak client IDs to add

Each new app that has a frontend needs a public (PKCE) client in the `travel-platform` Keycloak realm:

| App                    | Client ID         | Redirect URI                |
| ---------------------- | ----------------- | --------------------------- |
| TravelHub              | `travelhub`     | `http://localhost:4000/*` |
| TravelMap              | `travelmap`     | `http://localhost:4001/*` |
| PackList frontend      | `packlist`      | `http://localhost:4002/*` |
| TravelBudget frontend  | `travelbudget`  | `http://localhost:4003/*` |
| TravelJournal frontend | `traveljournal` | `http://localhost:4004/*` |
| WeatherDash            | `weatherdash`   | `http://localhost:4006/*` |

### Docker network

All new services join `travelplatform-network` (already exists). Each gets a `docker-compose.yml` that follows the same `external: true` pattern as the existing apps.

### Port allocation

| Port           | App                      |
| -------------- | ------------------------ |
| 8180           | Keycloak                 |
| 8080           | Splitpush                |
| 8000           | TravelBin backend        |
| 3001           | TravelBin frontend       |
| 5000           | Itinerary-Agent backend  |
| 3000           | Itinerary-Agent frontend |
| 8001–8003     | intonational services    |
| **4000** | TravelHub                |
| **4001** | TravelMap                |
| **4002** | PackList frontend        |
| **4003** | TravelBudget frontend    |
| **4004** | TravelJournal frontend   |
| **4005** | VisaCheck                |
| **4006** | WeatherDash              |
| **5001** | PackList backend         |
| **5002** | TravelBudget backend     |
| **9000** | TravelJournal backend    |

---

## Suggested Build Order

### Phase 1 — High value, low effort (frontend-heavy, no new backends)

1. **Widget endpoints** on existing apps — small backend additions, big payoff
2. **TravelMap** — pure frontend, uses existing APIs, visually impressive
3. **WeatherDash** — pure frontend, showcases intonational

### Phase 2 — New standalone apps (new backends required)

4. **TravelHub** — brings everything together; most impactful for the portfolio
5. **PackList** — useful, showcases AI + weather integration
6. **VisaCheck** — complete intonational's advisory scraping first

### Phase 3 — Deeper integrations

7. **TravelBudget** — Splitpush + intonational FX integration, new framework (SvelteKit)
8. **TravelJournal** — photo storage, rich text editing, most complex frontend

---

## Framework Diversity Summary

| App             | Frontend          | Backend            | Why                          |
| --------------- | ----------------- | ------------------ | ---------------------------- |
| TravelBin       | React 19          | Django 5           | Existing                     |
| Itinerary-Agent | Vue 3             | Express/TypeScript | Existing                     |
| Splitpush       | Thymeleaf         | Spring Boot        | Existing                     |
| intonational    | —                | FastAPI            | Existing                     |
| TravelHub       | **Next.js** | —                 | SSR, differs from Vite SPAs  |
| TravelMap       | React             | —                 | Frontend only                |
| PackList        | Vue 3             | **FastAPI**  | Consistent with intonational |
| TravelBudget    | **Svelte**  | Express/Prisma     | New framework for portfolio  |
| TravelJournal   | React             | Django 5           | Consistent with TravelBin    |
| WeatherDash     | React             | —                 | Frontend only                |
| VisaCheck       | Vue 3             | —                 | Extends intonational         |
