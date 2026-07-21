# Snowflake API Orchestration Layer

Put a governed API contract in front of Snowflake. Apps call clean REST endpoints instead of raw SQL — with shared-secret access control, input validation, a 15-minute read-through cache, audit logging, and one normalized response envelope across every query.

Snowflake stays the source of truth for the data; Xano owns the API contract, the access control, and the caching. Push it and three governed endpoints sit in front of your warehouse — the validation, caching, auth, and envelope logic run immediately; wiring your Snowflake account turns on the live queries.

## Why this exists

The moment more than one app needs warehouse data, "just give it a Snowflake connection" stops being safe. Every client re-implements the same query, there's no shared access control, no caching (so the warehouse — and the bill — takes every read), and each app shapes the response differently. The logic and the governance end up smeared across clients instead of living in one place.

This template is that one place. Three read endpoints wrap parameterized Snowflake queries behind a single API group: a shared secret gates access, inputs are validated before a query runs, results are cached read-through for 15 minutes (so repeat reads never touch Snowflake), every call is audited, and every response comes back in one normalized envelope. Change a query or a rule once and every consumer gets the same governed answer — and Snowflake sees far fewer queries.

## How it works

- **Auth to Snowflake** — the endpoints call Snowflake's **SQL API v2** with a **Programmatic Access Token** (the `SNOWFLAKE_PASSWORD` value) plus the PROGRAMMATIC_ACCESS_TOKEN token-type header; `SNOWFLAKE_ACCOUNT` builds the host and `DATABASE`/`SCHEMA`/`WAREHOUSE`/`ROLE` set the session context. Queries are parameterized with bind variables (no string interpolation).
- **Governance per request** — every endpoint runs a shared gate: validate the input, check the API secret, serve from the read-through cache if a fresh result exists (else query Snowflake and cache it for 15 minutes), and wrap the result in the normalized envelope. Every call writes an `api_request_logs` row and a `query_audit_logs` row.
- **Three endpoints** — customer search, a single customer profile, and a monthly revenue summary (grouped by `DATE_TRUNC('MONTH', ORDER_DATE)`), each backed by a pure validation function and a query function you can point at your own columns.

## Quick start

1. **Push the backend** to a Xano workspace (the CLI/agent flow below does this).
2. **Call the endpoints** — `GET /customers/search`, `GET /customers/{customer_id}/profile`, `GET /metrics/revenue-summary`.
3. **What runs without Snowflake.** Input validation, the shared-secret auth (a no-op when `API_AUTH_SECRET` is unset), the read-through cache on a hit, and the response envelope all run out of the box; the **live queries need your Snowflake account + PAT** and the `CUSTOMERS` / `ORDERS` objects below. Set the [environment variables](#environment-variables) to connect.

## API surface

All endpoints live in the `SnowflakeOrchestration` API group (canonical `snowflake-orchestration`), require the `api_secret` field when `API_AUTH_SECRET` is set, and return one normalized envelope. Every call is audited.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/customers/search` | Search `CUSTOMERS` (by name/email/status), validated + cached. |
| `GET` | `/customers/{customer_id}/profile` | A single customer's profile from `CUSTOMERS`. |
| `GET` | `/metrics/revenue-summary` | Monthly revenue from `ORDERS`, grouped by month (cached 15 min). |

## Database Tables

- **cached_query_results** — the read-through cache: one row per query key with the stored result and its 15-minute expiry.
- **query_audit_logs** — one row per Snowflake query issued (which query, params, timing).
- **api_request_logs** — one row per API call (endpoint, requester, status), for access auditing.

## Testing

Run from a deployed workspace with `xano workflow_test run_all` / `xano unit_test run_all`:
- **`snowflake_orchestration_cache_hit`** — a repeated query serves from `cached_query_results` without touching Snowflake.
- **`snowflake_orchestration_validation_failure`** — an invalid request is rejected by the validation gate before any query runs.
- **Unit tests** on the pure validation functions (`snowflake_orchestration_validate_*`).

These exercise the validation, cache, and envelope logic without a Snowflake account; the live query path requires your credentials.

## Environment variables

Set these to connect your Snowflake account. The validation/cache/auth/envelope logic runs without them.

- `SNOWFLAKE_ACCOUNT` — your account identifier; builds the `https://<account>.snowflakecomputing.com` host.
- `SNOWFLAKE_PASSWORD` — the **Programmatic Access Token** value, sent as the Bearer token (mint via `ALTER USER <user> ADD PROGRAMMATIC ACCESS TOKEN <name>`; PATs require a network policy on the user/account).
- `SNOWFLAKE_USERNAME` — the user the token belongs to; sent in the `User-Agent` so calls are attributable.
- `SNOWFLAKE_DATABASE`, `SNOWFLAKE_SCHEMA`, `SNOWFLAKE_WAREHOUSE`, `SNOWFLAKE_ROLE` — the statement session context.
- `API_AUTH_SECRET` — shared secret every endpoint checks (`api_secret` field). When unset the check is a no-op so it runs out of the box; set it in production.

**Required Snowflake objects.** The query functions read two objects in your configured database/schema — provide them as tables or views:
- **`CUSTOMERS`** (`/customers/search`, `/customers/{id}/profile`): CUSTOMER_ID, `NAME`, `EMAIL`, `STATUS` (ACTIVE/INACTIVE/PROSPECT), `PHONE`, CREATED_AT.
- **`ORDERS`** (`/metrics/revenue-summary`): ORDER_DATE (grouped by month), `AMOUNT` (summed).

Adjust the column names in the three `snowflake_orchestration_query_*` functions if your schema differs.
