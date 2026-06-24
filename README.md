# Snowflake API Orchestration Layer

A Xano module that puts a **logic-centralization and governance layer in front of Snowflake**. Snowflake stays the source of truth for your data; Xano owns the API contract — shared-secret access control, input validation, a read-through cache, audit logging, and a single normalized response envelope. Drop it into any Xano workspace, point it at your Snowflake account, and your apps call clean, governed REST endpoints instead of issuing raw SQL.

> **Honesty note — testing guarantee.** This module ships with unit tests whose Snowflake responses are **mocked from Snowflake's own SQL API v2 documentation** (the example response bodies on the docs pages, cited below), plus credential-free workflow (outcome) tests that exercise the cache-hit and validation-failure paths end-to-end against real seeded Xano tables. With no live Snowflake credentials in CI, the Snowflake-call success path is proven **"correct against the documented contract (mocked)"** — not against a live warehouse. Set the environment variables below to run it against your real Snowflake account.

## 1. What this template demonstrates

This module demonstrates **Xano as the orchestration / API layer on top of Snowflake**, so application logic lives in one governed place instead of being scattered across clients issuing ad-hoc SQL. It shows:

- **Reusable business logic** — one Snowflake query function and one validation function per endpoint, plus a single shared audit-logging function and a shared response-envelope builder. Logic is defined once and reused.
- **Access control** — every endpoint requires a shared secret (`API_AUTH_SECRET`) before it will touch Snowflake.
- **Input validation** — requests are validated (allowed status values, page-size bounds, date format and ordering) and rejected with a clear, typed error *before* a query is ever sent to Snowflake.
- **Transformation / normalization** — Snowflake's positional `rowType` + `data` result format is reshaped into clean, column-keyed row objects, and every endpoint returns the **same** response envelope.
- **Caching** — `GET /metrics/revenue-summary` is served through a 15-minute read-through cache, so repeated dashboard loads don't re-hit the warehouse.
- **Audit logging** — every failed request is written to `api_request_logs`; every successful Snowflake query is written to `query_audit_logs`. Data access is fully traceable.

Snowflake remains the system of record. Xano never replaces it — it governs access to it.

## 2. Required environment variables

Set all eight in your Xano workspace (Settings → Environment Variables). **Do not hardcode credentials.**

| Variable | Purpose |
| --- | --- |
| `SNOWFLAKE_ACCOUNT` | Your Snowflake account identifier (e.g. `myorg-myaccount`). Used to build the SQL API host `https://<account>.snowflakecomputing.com`. |
| `SNOWFLAKE_USERNAME` | The Snowflake user the token belongs to. Sent in the request `User-Agent` for traceability and documents which user the calls run as. |
| `SNOWFLAKE_PASSWORD` | The **bearer token** used to authenticate to the SQL API — a Snowflake **Programmatic Access Token (PAT)**. See the auth note below: this is sent as `Authorization: Bearer <token>`, *not* as a raw login password. |
| `SNOWFLAKE_DATABASE` | Database passed as the statement's session context. |
| `SNOWFLAKE_SCHEMA` | Schema passed as the statement's session context. |
| `SNOWFLAKE_WAREHOUSE` | Warehouse passed as the statement's session context. |
| `SNOWFLAKE_ROLE` | Role passed as the statement's session context. |
| `API_AUTH_SECRET` | Shared secret callers must present (as the `api_secret` request parameter) to use any endpoint. **Required in production** — when it is set, requests without the matching secret are rejected and logged. If it is left **unset**, the secret check is skipped (useful only for a throwaway/dev workspace). |

### How Snowflake authentication works here (important)

The Snowflake **SQL API v2** does **not** authenticate with a raw username/password. It authenticates with a bearer token plus a token-type header:

```
POST https://<SNOWFLAKE_ACCOUNT>.snowflakecomputing.com/api/v2/statements
Authorization: Bearer <SNOWFLAKE_PASSWORD>
X-Snowflake-Authorization-Token-Type: PROGRAMMATIC_ACCESS_TOKEN
Content-Type: application/json
```

So this module uses `SNOWFLAKE_PASSWORD` as the **Programmatic Access Token** value, `SNOWFLAKE_ACCOUNT` to build the host, and passes `SNOWFLAKE_DATABASE` / `SNOWFLAKE_SCHEMA` / `SNOWFLAKE_WAREHOUSE` / `SNOWFLAKE_ROLE` as the statement request's session context. `SNOWFLAKE_USERNAME` is sent in the `User-Agent` so each call is attributable to a user. To mint a PAT in Snowsight: `ALTER USER <user> ADD PROGRAMMATIC ACCESS TOKEN <name>` (PATs require a network policy on the user/account). You can substitute an OAuth or key-pair-JWT token by changing the token-type header in the query functions.

## 3. Required Snowflake tables/views

The shipped query functions read from two objects in your configured database/schema. Provide them as tables or views with at least these columns:

**CUSTOMERS** — used by `/customers/search` and `/customers/{customer_id}/profile`:

| Column | Type | Notes |
| --- | --- | --- |
| **CUSTOMER_ID** | text | Unique customer identifier |
| **NAME** | text | Customer name |
| **EMAIL** | text | Customer email |
| **STATUS** | text | One of ACTIVE, INACTIVE, PROSPECT (matched case-insensitively against the request) |
| **PHONE** | text | Phone (returned by the profile endpoint) |
| **CREATED_AT** | timestamp | Creation time |

**ORDERS** — used by `/metrics/revenue-summary`:

| Column | Type | Notes |
| --- | --- | --- |
| **ORDER_DATE** | date | Order date; revenue is grouped by month via `DATE_TRUNC('MONTH', ORDER_DATE)` |
| **AMOUNT** | number | Order amount; summed into the monthly TOTAL_REVENUE |

The SQL is parameterized with bind variables, so it adapts to your data without string interpolation. Adjust the column names in the three `snowflake_orchestration_query_*` functions if your schema differs.

## 4. Endpoint reference

All endpoints are `GET`, live under the `snowflake-orchestration` API group, require `api_secret` (when `API_AUTH_SECRET` is set), and return the [normalized envelope](#6-example-responses).

| Method | Path | Required params | Description |
| --- | --- | --- | --- |
| GET | `/customers/search` | `status`, `page`, `page_size` | Search customers by status with paging. `status` ∈ {`active`,`inactive`,`prospect`}; `page_size` 1–100. Always `cache_status: "miss"`. |
| GET | `/customers/{customer_id}/profile` | `customer_id` (path) | Return one canonical customer profile. `customer_id` must be non-empty. Always `cache_status: "miss"`. |
| GET | `/metrics/revenue-summary` | `start_date`, `end_date` | Revenue summarized by month. Both dates required, `YYYY-MM-DD`, `end_date` ≥ `start_date`. Served from a 15-minute cache (`cache_status: "hit"` when warm, else `"miss"`). |

Optional on every endpoint: `api_secret` (the shared secret) and `requester_id` (recorded in audit logs).

**Validation rules**

- `status` must be one of `active`, `inactive`, `prospect`.
- `page_size` must be an integer between 1 and 100; `page` must be ≥ 1.
- `customer_id` must be present and non-empty.
- `start_date` and `end_date` must both be present and formatted `YYYY-MM-DD`; `end_date` must not be earlier than `start_date`.

A request that fails auth or validation is rejected with an error envelope and recorded in `api_request_logs` — Snowflake is never queried.

## 5. Example requests

> Replace `<base>` with your API base URL, e.g. `https://your-instance.xano.io/api:snowflake-orchestration`.

```sh
# Customer search
curl "<base>/customers/search?status=active&page=1&page_size=25&api_secret=$API_AUTH_SECRET"

# Customer profile
curl "<base>/customers/C001/profile?api_secret=$API_AUTH_SECRET"

# Revenue summary (cached 15 min)
curl "<base>/metrics/revenue-summary?start_date=2024-01-01&end_date=2024-03-31&api_secret=$API_AUTH_SECRET"
```

## 6. Example responses

Every endpoint returns this exact envelope:

```json
{
  "success": true,
  "data": {},
  "metadata": {
    "request_id": "",
    "source": "snowflake",
    "cache_status": "hit_or_miss"
  },
  "errors": []
}
```

**Customer search (success):**

```json
{
  "success": true,
  "data": {
    "rows": [
      { "CUSTOMER_ID": "C001", "NAME": "Acme Corp", "EMAIL": "ops@acme.example", "STATUS": "ACTIVE", "CREATED_AT": "2024-01-15T10:00:00Z" },
      { "CUSTOMER_ID": "C002", "NAME": "Globex", "EMAIL": "hi@globex.example", "STATUS": "ACTIVE", "CREATED_AT": "2024-02-02T12:30:00Z" }
    ],
    "row_count": 2,
    "page": 1,
    "page_size": 25
  },
  "metadata": { "request_id": "f2b1…", "source": "snowflake", "cache_status": "miss" },
  "errors": []
}
```

**Revenue summary (served from cache):**

```json
{
  "success": true,
  "data": {
    "by_month": [
      { "MONTH": "2024-01", "ORDER_COUNT": "120", "TOTAL_REVENUE": "48250.00" },
      { "MONTH": "2024-02", "ORDER_COUNT": "98",  "TOTAL_REVENUE": "39110.50" },
      { "MONTH": "2024-03", "ORDER_COUNT": "143", "TOTAL_REVENUE": "60230.75" }
    ],
    "row_count": 3,
    "start_date": "2024-01-01",
    "end_date": "2024-03-31"
  },
  "metadata": { "request_id": "9c4a…", "source": "snowflake", "cache_status": "hit" },
  "errors": []
}
```

**Validation failure (no Snowflake call, logged to `api_request_logs`):**

```json
{
  "success": false,
  "data": {},
  "metadata": { "request_id": "11de…", "source": "snowflake", "cache_status": "miss" },
  "errors": ["end_date must not be earlier than start_date"]
}
```

## 7. How Xano centralizes logic without replacing Snowflake

Snowflake remains the **single source of truth** for the data. This module is deliberately a thin, governed layer *around* it, not a copy of it:

- **It does not store your business data.** The only Xano tables it owns are operational: `api_request_logs` (failed requests), `query_audit_logs` (successful queries), and `cached_query_results` (a short-lived cache). Customer and order data live in — and are read live from — Snowflake.
- **It centralizes the logic, not the data.** Validation rules, the SQL for each query, access control, and the response shape are defined **once** in reusable Xano functions. Every client gets the same governed behavior instead of re-implementing it (or issuing raw SQL) per app.
- **It governs and observes access.** The shared secret gates who can query; the audit tables record what was asked and what ran. You get an access trail Snowflake-side queries alone don't give you.
- **It protects the warehouse.** Inputs are validated before a query is sent, and the revenue endpoint's 15-minute cache absorbs repeated reads — fewer, cleaner queries hit Snowflake.

The result: a stable, documented API contract for your apps, with Snowflake doing what it does best (storing and computing over the data) and Xano doing what it does best (centralizing logic, access, and orchestration).

---

## Testing

Unit-test mocks are taken verbatim from Snowflake's SQL API v2 documentation:

- Request body / bindings — <https://docs.snowflake.com/en/developer-guide/sql-api/submitting-requests>
- Success response (`resultSetMetaData`, `rowType`, `data`, `partitionInfo`) — <https://docs.snowflake.com/en/developer-guide/sql-api/handling-responses> and <https://docs.snowflake.com/en/developer-guide/sql-api/reference>

## License

MIT — see [LICENSE](./LICENSE).
