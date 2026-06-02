# Analytics Plan — Travel Platform

A non-invasive, cookie-free analytics strategy for tracking usage across the Travel Platform portfolio apps.

---

## Guiding Principles

- **No PII.** No usernames, emails, or user IDs are stored in analytics.
- **No cookies.** The chosen tool is cookie-free — no consent banner needed.
- **No cross-site identity linking.** Each app is tracked independently.
- **No session replay or keystroke capture.** Aggregate counts only.
- **"How many times was X done" — not "who did X."**

---

## Recommended Tool: Umami (self-hosted)

[Umami](https://umami.is) is an open-source, privacy-first analytics platform.

| Property | Detail |
|---|---|
| Cookie-free | Yes — GDPR compliant by design |
| Script size | ~2KB |
| Custom events | Built-in `umami.track()` API |
| Self-hosted | Docker container — fits existing `travelplatform-network` |
| Multi-site | One instance tracks all 3 apps from a single dashboard |
| Database | PostgreSQL |

---

## Infrastructure Setup

### Docker service (add to a new `docker-compose.yml` in `analytics/` or the root)

```yaml
services:
  umami:
    image: ghcr.io/umami-software/umami:postgresql-latest
    ports:
      - "3002:3000"
    environment:
      DATABASE_URL: postgresql://umami:umami@umami-db:5432/umami
      DATABASE_TYPE: postgresql
      APP_SECRET: replace-with-a-long-random-string
    depends_on:
      - umami-db
    networks:
      - travelplatform-network

  umami-db:
    image: postgres:16
    environment:
      POSTGRES_DB: umami
      POSTGRES_USER: umami
      POSTGRES_PASSWORD: umami
    volumes:
      - umami-db-data:/var/lib/postgresql/data
    networks:
      - travelplatform-network

volumes:
  umami-db-data:

networks:
  travelplatform-network:
    external: true
```

- Dashboard available at `http://localhost:3002`
- Register each app as a separate **Website** in the Umami UI — each gets its own `data-website-id`

---

## Per-App Integration

### Itinerary-Agent (Vue 3 / Vite — port 3000)

**Script tag** — add to `Itinerary-Agent/itinerary-agent/index.html`:
```html
<script
  defer
  src="http://localhost:3002/script.js"
  data-website-id="ITINERARY-AGENT-WEBSITE-ID"
></script>
```

Page views are auto-tracked on Vue Router navigation.

**Custom events** — fire `umami.track(eventName, payload?)` in the frontend after a successful API response:

| Where | Event name | Payload |
|---|---|---|
| After `POST /api/chat` resolves | `itinerary_generated` | `{ destination }` — extracted from quiz answers |
| After `POST /api/trips` resolves | `trip_saved` | — |
| After `POST /api/trips/:id/export` resolves | `trip_exported` | — |
| After `DELETE /api/trips/:id` resolves | `trip_deleted` | — |

The `destination` value for `itinerary_generated` comes from the quiz answer for the destination question, which is already part of the `message` string sent to `/api/chat`. Parse it client-side (e.g. `Quiz.vue` knows the selected country/city) and pass it through to the event after the response resolves.

---

### TravelBin (React / Vite — port 3001)

**Script tag** — add to `TravelBin/travelbin-frontend/index.html`:
```html
<script
  defer
  src="http://localhost:3002/script.js"
  data-website-id="TRAVELBIN-WEBSITE-ID"
></script>
```

**Custom events** — add `umami.track(eventName, payload?)` calls in the relevant components:

| File | Location | Event name | Payload |
|---|---|---|---|
| `DestinationShow.jsx` | `destination-link` onClick (before navigating) | `destination_opened` | `{ name: item.name }` |
| `DestinationShow.jsx` | After `handleCreate` succeeds | `destination_created` | `{ name: newName }` |
| `DestinationShow.jsx` | After `handleConfirmDelete` succeeds | `destination_deleted` | — |
| `EntryShow.jsx` | After inline entry create succeeds | `entry_created` | `{ type: newEntry.type }` |
| `EntryShow.jsx` | After `handleConfirmDelete` succeeds | `entry_deleted` | — |
| `InviteJoin.jsx` | After join API call succeeds | `invite_joined` | — |
| `Entry.jsx` | After `handleCopyInviteLink` runs | `invite_link_copied` | — |
| `DestinationShow.jsx` (import flow) | After export from Itinerary-Agent succeeds | `import_from_itinerary_agent` | — |

`destination_opened` with `{ name }` is the key event for **"most popular destinations"** — it fires each time any user navigates into a destination, giving you an aggregate count per destination name with no user identity attached.

`entry_created` with `{ type }` gives aggregate counts of activity types (Sightseeing, Food & Drink, Shopping, etc.) across all users.

---

### Splitpush (Spring Boot / Thymeleaf — port 8080)

**Script tag** — add to each of the 8 Thymeleaf templates before `</head>` (same pattern used for the favicon):
```html
<script
  defer
  src="http://localhost:3002/script.js"
  data-website-id="SPLITPUSH-WEBSITE-ID"
></script>
```

Page views are auto-tracked on each server-rendered page load.

**Custom events** — add inline `<script>` blocks that call `umami.track()` on user actions:

| Template | Trigger | Event name |
|---|---|---|
| `groups.html` | Group creation form submit | `group_created` |
| `expenses.html` | Expense form submit | `expense_added` |
| `settlements.html` | Settlement form submit | `settlement_recorded` |
| `groups.html` | Copy invite link button click | `invite_link_copied` |
| `invite.html` | Join group button click | `invite_joined` |

---

### intonational (FastAPI microservices — ports 8001–8003)

No browser — Umami doesn't apply. Use a **FastAPI middleware** for structured request logging instead.

Add to each service's `main.py`:

```python
import time, json, logging
from starlette.middleware.base import BaseHTTPMiddleware

logger = logging.getLogger("analytics")

class AnalyticsMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        start = time.monotonic()
        response = await call_next(request)
        duration_ms = round((time.monotonic() - start) * 1000)
        # Log only non-sensitive fields — no IP, no auth tokens, no query values
        logger.info(json.dumps({
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "method": request.method,
            "path": request.url.path,
            "status": response.status_code,
            "ms": duration_ms,
        }))
        return response
```

**What is explicitly excluded:** IP addresses, Authorization headers, query parameter values, request/response bodies.

**Optional stretch goal:** expose a `GET /metrics` endpoint on the aggregator service that returns per-endpoint call counts and average response times from the in-memory log, usable as a lightweight health/usage dashboard.

Log rotation: configure logrotate (or Docker log driver) to rotate after 30 days.

---

## What NOT to Track

- Keycloak `sub` / any user identifier
- Trip, group, or expense names (too personally identifiable)
- Search queries typed into filter inputs
- IP addresses — in the Umami settings UI, enable **"Remove IP address from data"**
- Failed login or auth error events (security-sensitive)

### Content names: the line

**Destination names (e.g. "Tokyo") → OK to track.** These are place names, not personal data. Stored as aggregate counts with no user linkage — equivalent to a search engine tracking popular query terms.

**Activity types (e.g. "Sightseeing") → OK to track.** Categorical, not personal.

**Specific activity names (e.g. "Grandma's secret restaurant") → Do not track.** These are user-authored strings that could be personal or sensitive.

**Expense descriptions / amounts → Do not track.** Financial data is always sensitive.

The rule of thumb: if the value could appear in a travel guidebook, it's safe. If the user typed it themselves and it's unique to them, skip it.

---

## Production Deployment

When deploying the apps publicly:

1. **Host Umami** on Railway, Render, Fly.io, or a VPS (Docker-compatible).
2. **Managed DB** — use a managed PostgreSQL instance (Railway, Supabase, or Neon) for Umami's database in prod.
3. **Reverse proxy** Umami behind a custom subdomain (e.g. `analytics.yourdomain.com`) — this prevents ad-blockers from blocking requests to `umami.is`.
4. **Environment variables** — use `VITE_UMAMI_SCRIPT_URL` and `VITE_UMAMI_WEBSITE_ID` in each Vite app so dev and prod point at different Umami instances with different site IDs.
5. **Splitpush** — inject the Umami URL via a Thymeleaf variable or Spring Boot environment property instead of hardcoding `localhost`.

---

## Data Retention

| Data | Retention |
|---|---|
| Umami page views & events | 90 days raw (configure auto-purge in Umami settings in prod) |
| intonational JSON logs | 30 days (logrotate) |
| Umami aggregated stats | Indefinite — aggregates are not PII |

---

## Privacy Notice

Add a one-line note to the footer of each app:

> *Anonymous usage data is collected to improve this app. No personal information is stored.*

No cookie consent banner is required — Umami stores no cookies.
