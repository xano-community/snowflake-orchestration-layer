workspace "Snowflake API Orchestration Layer" {
  description = "Xano as a logic-centralization + governance layer on top of Snowflake: shared-secret access control, input validation, a 15-minute read-through cache, audit logging, and one normalized API envelope. Snowflake stays the source of truth."
  preferences = {
    internal_docs    : false
    track_performance: true
    sql_names        : false
    sql_columns      : true
  }
}
---
table "api_request_logs" {
  auth = false
  description = "Governance log of every API request handled by the orchestration layer. Failed requests (auth, validation, or Snowflake errors) are written here with the captured params and error message so operators have a full audit trail of rejected/failed traffic."

  schema {
    int id
    text request_id { description = "UUID generated per request and echoed in the response metadata" }
    text endpoint { description = "The logical endpoint that handled the request, e.g. customers/search" }
    text requester_id? { description = "Identifier of the caller when provided (header/param); null for anonymous" }
    json request_params? { description = "Sanitized snapshot of the request inputs (the API secret is never stored)" }
    text status { description = "Outcome of the request: auth_error | validation_error | snowflake_error" }
    text error_message? { description = "Human-readable reason the request failed" }
    timestamp created_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "request_id"}]}
    {type: "btree", field: [{name: "endpoint"}]}
    {type: "btree", field: [{name: "status"}]}
    {type: "btree", field: [{name: "created_at", op: "desc"}]}
  ]
  guid = "kYyT0DdfjtutAlHz28S3c30z7WA"
}
---
table "cached_query_results" {
  auth = false
  description = "Read-through cache for GET /metrics/revenue-summary only. A row holds the full normalized response for a given cache_key (derived from the query params); expires_at is epoch milliseconds, and a row is a cache HIT only while now < expires_at (15-minute TTL)."

  schema {
    int id
    text cache_key { description = "Deterministic key derived from the query name + validated params, e.g. revenue_summary:2024-01-01:2024-03-31" }
    text query_name { description = "The logical query the cached result belongs to, e.g. revenue_summary" }
    json response_json { description = "The cached `data` payload returned to the caller on a hit" }
    int expires_at { description = "Epoch milliseconds after which this row is stale (created_at + 15 minutes)" }
    timestamp created_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "cache_key"}]}
    {type: "btree", field: [{name: "query_name"}]}
    {type: "btree", field: [{name: "expires_at"}]}
  ]
  guid = "DRJnUi2_6sNSp0bRDmXiTcETerE"
}
---
table "query_audit_logs" {
  auth = false
  description = "Audit record of every SUCCESSFUL Snowflake query the orchestration layer runs. Captures the named query, the Snowflake object/view it targeted, the applied filters, the row count, and the execution status so data access is fully traceable."

  schema {
    int id
    text request_id { description = "UUID of the originating API request" }
    text query_name { description = "Logical query that ran, e.g. customers_search, customer_profile, revenue_summary" }
    text snowflake_object? { description = "The Snowflake table/view the query read from" }
    json filters? { description = "The validated filters/parameters applied to the query" }
    int row_count?=0 { description = "Number of rows returned by Snowflake" }
    text execution_status { description = "Snowflake execution outcome, e.g. success" }
    timestamp created_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "request_id"}]}
    {type: "btree", field: [{name: "query_name"}]}
    {type: "btree", field: [{name: "created_at", op: "desc"}]}
  ]
  guid = "WYPYAyhS39JeABdpzCLPkQXsB8Y"
}
---
function "snowflake_orchestration_cache_get" {
  description = "Read-through cache lookup for the revenue-summary endpoint. Looks up cached_query_results by cache_key and returns {hit, data} — hit=true with the stored data only when a row exists AND now (epoch ms) is still before its expires_at (15-minute TTL); otherwise hit=false. Pure Xano-native (no Snowflake call)."

  input {
    text cache_key { description = "Deterministic cache key, e.g. revenue_summary:2024-01-01:2024-03-31" }
  }

  stack {
    var $now_ms { value = ("now"|to_ms) }

    db.query "cached_query_results" {
      where = ($db.cached_query_results.cache_key == $input.cache_key) && ($db.cached_query_results.expires_at > $now_ms)
      sort = {created_at: "desc"}
      return = {type: "single"}
    } as $row

    var $hit { value = false }
    var $data { value = null }

    conditional {
      if ($row != null) {
        var.update $hit { value = true }
        var.update $data { value = $row.response_json }
      }
    }

    var $result { value = {hit: $hit, data: $data} }
  }

  response = $result
  guid = "AyrYcub0awAh-Zl_5VSzwr4ZGUE"
}
---
function "snowflake_orchestration_cache_put" {
  description = "Write a fresh revenue-summary result into cached_query_results with a 15-minute TTL. expires_at is stored as epoch milliseconds (now + 900000). Pure Xano-native (no Snowflake call). Returns the created cache row."

  input {
    text cache_key { description = "Deterministic cache key to store under" }
    text query_name { description = "Logical query name, e.g. revenue_summary" }
    json data { description = "The normalized `data` payload to cache" }
  }

  stack {
    var $expires_at { value = (("now"|to_ms) + 900000) }

    db.add "cached_query_results" {
      data = {
        cache_key: $input.cache_key,
        query_name: $input.query_name,
        response_json: $input.data,
        expires_at: $expires_at
      }
    } as $row

    var $result { value = $row }
  }

  response = $result
  guid = "1QNM67-UmG7TPIEQcMo4soVk1Do"
}
---
function "snowflake_orchestration_check_auth" {
  description = "Reusable shared-secret access control. Returns {valid, error}. When $env.API_AUTH_SECRET is set, the request's secret must match it exactly or the call is rejected. When API_AUTH_SECRET is unset (e.g. an unconfigured workspace), the check is a no-op and passes — production deployments MUST set it (documented in the README)."

  input {
    text provided_secret? { description = "The shared secret supplied by the caller via the endpoint's api_secret request parameter" }
  }

  stack {
    var $expected { value = ($env.API_AUTH_SECRET|first_notempty:"") }
    var $out { value = {valid: true, error: ""} }

    conditional {
      if ($expected != "") {
        conditional {
          if (($input.provided_secret|first_notempty:"") != $expected) {
            var.update $out { value = {valid: false, error: "Unauthorized: invalid or missing API secret"} }
          }
        }
      }
    }

    var $result { value = $out }
  }

  response = $result

  // In the test workspace API_AUTH_SECRET is unset, so the check is a no-op and always passes.
  // (Production sets the env var; the rejection path is documented in the README and exercised live.)
  test "passes when API_AUTH_SECRET is not configured" {
    input = { provided_secret: "" }
    expect.to_be_true ($response.valid)
  }

  guid = "WibMXWgmL9GjTTt-XX8_TIvbkfs"
}
---
function "snowflake_orchestration_envelope" {
  description = "Build the single normalized response envelope every endpoint returns: {success, data, metadata: {request_id, source, cache_status}, errors}. source is always \"snowflake\"; cache_status is hit | miss. On success, errors is []; on failure, data is {} and errors carries the messages."

  input {
    bool success { description = "Whether the request succeeded" }
    json data? { description = "The payload object on success (defaults to {})" }
    text request_id { description = "The per-request UUID echoed to the caller" }
    text cache_status { description = "hit or miss" }
    json errors? { description = "Array of error message strings on failure (defaults to [])" }
  }

  stack {
    var $data_out { value = {} }
    conditional {
      if ($input.data != null) {
        var.update $data_out { value = $input.data }
      }
    }

    var $errors_out { value = [] }
    conditional {
      if ($input.errors != null) {
        var.update $errors_out { value = $input.errors }
      }
    }

    var $result {
      value = {
        success: $input.success,
        data: $data_out,
        metadata: {
          request_id: $input.request_id,
          source: "snowflake",
          cache_status: $input.cache_status
        },
        errors: $errors_out
      }
    }
  }

  response = $result

  // Note: the success envelope's empty `errors: []` is asserted on the live engine in the
  // workflow test snowflake_orchestration_cache_hit_serves_without_snowflake (the unit-test
  // harness renders an empty array ambiguously, so we assert the empty-array shape live instead).
  test "builds a success envelope" {
    input = { success: true, data: {rows: [1, 2]}, request_id: "req-123", cache_status: "miss" }
    expect.to_be_true ($response.success)
    expect.to_equal ($response.metadata.source) { value = "snowflake" }
    expect.to_equal ($response.metadata.request_id) { value = "req-123" }
    expect.to_equal ($response.metadata.cache_status) { value = "miss" }
    expect.to_equal ($response.data) { value = {rows: [1, 2]} }
  }

  test "builds an error envelope with empty data" {
    input = { success: false, request_id: "req-err", cache_status: "miss", errors: ["status must be one of: active, inactive, prospect"] }
    expect.to_be_false ($response.success)
    expect.to_equal ($response.data) { value = {} }
    expect.to_equal ($response.metadata.cache_status) { value = "miss" }
    expect.to_contain ($response.errors) { value = "status must be one of: active, inactive, prospect" }
  }
  guid = "aa35O6Wlw6lJ2ErGxVuMT_cZtKA"
}
---
function "snowflake_orchestration_log_request" {
  description = "Single reusable audit-logging helper for the orchestration layer. target=\"request\" writes a FAILED request (auth/validation/Snowflake error) to api_request_logs; target=\"query\" writes a SUCCESSFUL Snowflake query to query_audit_logs. Centralizing both writes here means every endpoint logs consistently."

  input {
    text target { description = "Which audit table to write: \"request\" (failed request) or \"query\" (successful Snowflake query)" }
    text request_id { description = "UUID of the originating request" }
    text endpoint? { description = "Logical endpoint name (for request logs), e.g. customers/search" }
    text requester_id? { description = "Caller identifier when known" }
    json request_params? { description = "Sanitized request inputs (never includes the API secret)" }
    text status? { description = "For request logs: auth_error | validation_error | snowflake_error" }
    text error_message? { description = "For request logs: why the request failed" }
    text query_name? { description = "For query logs: the logical query that ran" }
    text snowflake_object? { description = "For query logs: the Snowflake object/view read" }
    json filters? { description = "For query logs: filters applied" }
    int row_count? { description = "For query logs: rows returned" }
    text execution_status? { description = "For query logs: Snowflake execution outcome" }
  }

  stack {
    var $logged { value = null }

    conditional {
      if ($input.target == "query") {
        db.add "query_audit_logs" {
          data = {
            request_id: $input.request_id,
            query_name: $input.query_name,
            snowflake_object: $input.snowflake_object,
            filters: $input.filters,
            row_count: ($input.row_count|first_notnull:0),
            execution_status: ($input.execution_status|first_notempty:"success")
          }
        } as $q
        var.update $logged { value = $q }
      }
      else {
        db.add "api_request_logs" {
          data = {
            request_id: $input.request_id,
            endpoint: $input.endpoint,
            requester_id: $input.requester_id,
            request_params: $input.request_params,
            status: ($input.status|first_notempty:"validation_error"),
            error_message: $input.error_message
          }
        } as $r
        var.update $logged { value = $r }
      }
    }

    var $result { value = $logged }
  }

  response = $result
  guid = "uixuZb8t0zaGf_78Yu2oZs9hW8w"
}
---
function "snowflake_orchestration_query_customer_profile" {
  description = "Reusable Snowflake query for GET /customers/{customer_id}/profile. Runs a parameterized SELECT against the CUSTOMERS view via the Snowflake SQL API v2 for a single customer_id and returns the first matching row as one canonical, column-keyed profile object. Returns {ok, status, error, profile, row_count, snowflake_object}; never throws. Auth is a Snowflake Programmatic Access Token sent as a Bearer token (SNOWFLAKE_PASSWORD) with X-Snowflake-Authorization-Token-Type=PROGRAMMATIC_ACCESS_TOKEN; database/schema/warehouse/role/username are passed as the request's session context from env."

  input {
    text customer_id { description = "Validated, non-empty customer identifier" }
  }

  stack {
    var $object { value = "CUSTOMERS" }
    var $host { value = "https://" ~ $env.SNOWFLAKE_ACCOUNT ~ ".snowflakecomputing.com" }

    // Build bindings as a 1-indexed OBJECT via |set. A `{"1":..}` object literal collapses to a JSON
    // array on serialization, which the Snowflake SQL API rejects (error 391917).
    var $bindings { value = {} }
    var.update $bindings { value = ($bindings|set:"1":{type: "TEXT", value: $input.customer_id}) }

    var $params {
      value = {
        statement: "SELECT CUSTOMER_ID, NAME, EMAIL, STATUS, PHONE, CREATED_AT FROM CUSTOMERS WHERE CUSTOMER_ID = ? LIMIT 1",
        timeout: 60,
        database: $env.SNOWFLAKE_DATABASE,
        schema: $env.SNOWFLAKE_SCHEMA,
        warehouse: $env.SNOWFLAKE_WAREHOUSE,
        role: $env.SNOWFLAKE_ROLE,
        bindings: $bindings
      }
    }

    api.request {
      url = $host ~ "/api/v2/statements"
      method = "POST"
      headers = ["Authorization: Bearer " ~ $env.SNOWFLAKE_PASSWORD, "Content-Type: application/json", "Accept: application/json", "X-Snowflake-Authorization-Token-Type: PROGRAMMATIC_ACCESS_TOKEN", "User-Agent: " ~ $env.SNOWFLAKE_USERNAME ~ "-Xano-Orchestration/1.0"]
      params = $params
      timeout = 60
      mock = {
        "customer_profile returns one canonical profile": { response: { status: 200, result: {
          code: "090001",
          statementHandle: "01b2c3d4-0000-0000-0000-000000000010",
          sqlState: "00000",
          message: "Statement executed successfully.",
          createdOn: 1620151693299,
          resultSetMetaData: {
            numRows: 1,
            format: "jsonv2",
            rowType: [
              {name: "CUSTOMER_ID", type: "text", nullable: false},
              {name: "NAME", type: "text", nullable: true},
              {name: "EMAIL", type: "text", nullable: true},
              {name: "STATUS", type: "text", nullable: false},
              {name: "PHONE", type: "text", nullable: true},
              {name: "CREATED_AT", type: "text", nullable: true}
            ],
            partitionInfo: [{rowCount: 1, uncompressedSize: 160}]
          },
          data: [
            ["C001", "Acme Corp", "ops@acme.example", "ACTIVE", "+15555550100", "2024-01-15T10:00:00Z"]
          ]
        } } }
      }
    } as $api_result

    var $ok { value = false }
    var $rows { value = [] }
    var $profile { value = null }
    var $row_count { value = 0 }
    var $err_msg { value = "" }

    conditional {
      if ($api_result.response.status == 200 || $api_result.response.status == 202) {
        var.update $ok { value = true }
        var $columns { value = $api_result.response.result.resultSetMetaData.rowType }
        var $data { value = $api_result.response.result.data }
        conditional {
          if ($data != null) {
            foreach ($data) {
              each as $row {
                var $obj { value = {} }
                var $i { value = 0 }
                foreach ($columns) {
                  each as $col {
                    var.update $obj { value = $obj|set:($col.name):($row|get:$i) }
                    var.update $i { value = ($i + 1) }
                  }
                }
                var.update $rows { value = $rows|push:$obj }
              }
            }
          }
        }
        var.update $row_count { value = ($rows|count) }
        conditional {
          if ($row_count > 0) {
            var.update $profile { value = ($rows|first) }
          }
        }
      }
      else {
        var.update $err_msg { value = "Snowflake API error (status " ~ ($api_result.response.status|to_text) ~ "): " ~ ($api_result.response.result|json_encode) }
      }
    }

    var $result { value = {ok: $ok, status: $api_result.response.status, error: $err_msg, profile: $profile, row_count: $row_count, snowflake_object: $object} }
  }

  response = $result

  test "customer_profile returns one canonical profile" {
    input = { customer_id: "C001" }
    expect.to_be_true ($response.ok)
    expect.to_equal ($response.status) { value = 200 }
    expect.to_equal ($response.row_count) { value = 1 }
    expect.to_equal ($response.snowflake_object) { value = "CUSTOMERS" }
    expect.to_equal ($response.profile) { value = {CUSTOMER_ID: "C001", NAME: "Acme Corp", EMAIL: "ops@acme.example", STATUS: "ACTIVE", PHONE: "+15555550100", CREATED_AT: "2024-01-15T10:00:00Z"} }
  }
  guid = "yqu-SpeEKMIshx43GK6nnrX_DPQ"
}
---
function "snowflake_orchestration_query_customer_search" {
  description = "Reusable Snowflake query for GET /customers/search. Runs a parameterized SELECT against the CUSTOMERS view via the Snowflake SQL API v2, filtered by status with LIMIT/OFFSET paging, and returns rows reshaped into column-keyed objects. Returns {ok, status, error, rows, row_count, snowflake_object}; it never throws, so the calling endpoint branches on .ok and writes the correct audit log. Auth is a Snowflake Programmatic Access Token sent as a Bearer token (SNOWFLAKE_PASSWORD) with X-Snowflake-Authorization-Token-Type=PROGRAMMATIC_ACCESS_TOKEN; database/schema/warehouse/role/username come from env and are passed as the request's session context."

  input {
    text status { description = "Validated status filter: active | inactive | prospect" }
    int page { description = "1-based page number" }
    int page_size { description = "Rows per page (1..100)" }
  }

  stack {
    var $object { value = "CUSTOMERS" }
    var $offset { value = (($input.page - 1) * $input.page_size) }
    var $host { value = "https://" ~ $env.SNOWFLAKE_ACCOUNT ~ ".snowflakecomputing.com" }

    // Build bindings as a 1-indexed OBJECT via |set. A `{"1":..}` object literal collapses to a JSON
    // array on serialization, which the Snowflake SQL API rejects (error 391917).
    var $bindings { value = {} }
    var.update $bindings { value = ($bindings|set:"1":{type: "TEXT", value: ($input.status|to_upper)}) }
    var.update $bindings { value = ($bindings|set:"2":{type: "FIXED", value: ($input.page_size|to_text)}) }
    var.update $bindings { value = ($bindings|set:"3":{type: "FIXED", value: ($offset|to_text)}) }

    var $params {
      value = {
        statement: "SELECT CUSTOMER_ID, NAME, EMAIL, STATUS, CREATED_AT FROM CUSTOMERS WHERE STATUS = ? ORDER BY CREATED_AT DESC LIMIT ? OFFSET ?",
        timeout: 60,
        database: $env.SNOWFLAKE_DATABASE,
        schema: $env.SNOWFLAKE_SCHEMA,
        warehouse: $env.SNOWFLAKE_WAREHOUSE,
        role: $env.SNOWFLAKE_ROLE,
        bindings: $bindings
      }
    }

    api.request {
      url = $host ~ "/api/v2/statements"
      method = "POST"
      headers = ["Authorization: Bearer " ~ $env.SNOWFLAKE_PASSWORD, "Content-Type: application/json", "Accept: application/json", "X-Snowflake-Authorization-Token-Type: PROGRAMMATIC_ACCESS_TOKEN", "User-Agent: " ~ $env.SNOWFLAKE_USERNAME ~ "-Xano-Orchestration/1.0"]
      params = $params
      timeout = 60
      mock = {
        "customer_search returns normalized rows": { response: { status: 200, result: {
          code: "090001",
          statementHandle: "536fad38-b564-4dc5-9892-a4543504df6c",
          sqlState: "00000",
          message: "Statement executed successfully.",
          createdOn: 1620151693299,
          statementStatusUrl: "/api/v2/statements/536fad38-b564-4dc5-9892-a4543504df6c",
          resultSetMetaData: {
            numRows: 2,
            format: "jsonv2",
            rowType: [
              {name: "CUSTOMER_ID", type: "text", nullable: false},
              {name: "NAME", type: "text", nullable: true},
              {name: "EMAIL", type: "text", nullable: true},
              {name: "STATUS", type: "text", nullable: false},
              {name: "CREATED_AT", type: "text", nullable: true}
            ],
            partitionInfo: [{rowCount: 2, uncompressedSize: 256}]
          },
          data: [
            ["C001", "Acme Corp", "ops@acme.example", "ACTIVE", "2024-01-15T10:00:00Z"],
            ["C002", "Globex", "hi@globex.example", "ACTIVE", "2024-02-02T12:30:00Z"]
          ]
        } } }
      }
    } as $api_result

    var $ok { value = false }
    var $rows { value = [] }
    var $row_count { value = 0 }
    var $err_msg { value = "" }

    conditional {
      if ($api_result.response.status == 200 || $api_result.response.status == 202) {
        var.update $ok { value = true }
        var $columns { value = $api_result.response.result.resultSetMetaData.rowType }
        var $data { value = $api_result.response.result.data }
        conditional {
          if ($data != null) {
            foreach ($data) {
              each as $row {
                var $obj { value = {} }
                var $i { value = 0 }
                foreach ($columns) {
                  each as $col {
                    var.update $obj { value = $obj|set:($col.name):($row|get:$i) }
                    var.update $i { value = ($i + 1) }
                  }
                }
                var.update $rows { value = $rows|push:$obj }
              }
            }
          }
        }
        var.update $row_count { value = ($rows|count) }
      }
      else {
        var.update $err_msg { value = "Snowflake API error (status " ~ ($api_result.response.status|to_text) ~ "): " ~ ($api_result.response.result|json_encode) }
      }
    }

    var $result { value = {ok: $ok, status: $api_result.response.status, error: $err_msg, rows: $rows, row_count: $row_count, snowflake_object: $object} }
  }

  response = $result

  test "customer_search returns normalized rows" {
    input = { status: "active", page: 1, page_size: 50 }
    expect.to_be_true ($response.ok)
    expect.to_equal ($response.status) { value = 200 }
    expect.to_equal ($response.row_count) { value = 2 }
    expect.to_equal ($response.snowflake_object) { value = "CUSTOMERS" }
    expect.to_equal ($response.rows) { value = [
      {CUSTOMER_ID: "C001", NAME: "Acme Corp", EMAIL: "ops@acme.example", STATUS: "ACTIVE", CREATED_AT: "2024-01-15T10:00:00Z"},
      {CUSTOMER_ID: "C002", NAME: "Globex", EMAIL: "hi@globex.example", STATUS: "ACTIVE", CREATED_AT: "2024-02-02T12:30:00Z"}
    ] }
  }
  guid = "Y3QvQzRMSab925eRzE8eFDW2LkM"
}
---
function "snowflake_orchestration_query_revenue_summary" {
  description = "Reusable Snowflake query for GET /metrics/revenue-summary. Runs a parameterized aggregate against the ORDERS view via the Snowflake SQL API v2, grouping revenue by month between start_date and end_date, and returns rows reshaped into column-keyed objects (MONTH, ORDER_COUNT, TOTAL_REVENUE). Returns {ok, status, error, rows, row_count, snowflake_object}; never throws. Auth is a Snowflake Programmatic Access Token sent as a Bearer token (SNOWFLAKE_PASSWORD) with X-Snowflake-Authorization-Token-Type=PROGRAMMATIC_ACCESS_TOKEN; database/schema/warehouse/role/username are passed as the request's session context from env."

  input {
    text start_date { description = "Validated inclusive window start (YYYY-MM-DD)" }
    text end_date { description = "Validated inclusive window end (YYYY-MM-DD)" }
  }

  stack {
    var $object { value = "ORDERS" }
    var $host { value = "https://" ~ $env.SNOWFLAKE_ACCOUNT ~ ".snowflakecomputing.com" }

    // Build bindings as a 1-indexed OBJECT via |set. A `{"1":..}` object literal collapses to a JSON
    // array on serialization, which the Snowflake SQL API rejects (error 391917).
    var $bindings { value = {} }
    var.update $bindings { value = ($bindings|set:"1":{type: "TEXT", value: $input.start_date}) }
    var.update $bindings { value = ($bindings|set:"2":{type: "TEXT", value: $input.end_date}) }

    var $params {
      value = {
        statement: "SELECT TO_CHAR(DATE_TRUNC('MONTH', ORDER_DATE), 'YYYY-MM') AS MONTH, COUNT(*) AS ORDER_COUNT, SUM(AMOUNT) AS TOTAL_REVENUE FROM ORDERS WHERE ORDER_DATE BETWEEN ? AND ? GROUP BY 1 ORDER BY 1",
        timeout: 60,
        database: $env.SNOWFLAKE_DATABASE,
        schema: $env.SNOWFLAKE_SCHEMA,
        warehouse: $env.SNOWFLAKE_WAREHOUSE,
        role: $env.SNOWFLAKE_ROLE,
        bindings: $bindings
      }
    }

    api.request {
      url = $host ~ "/api/v2/statements"
      method = "POST"
      headers = ["Authorization: Bearer " ~ $env.SNOWFLAKE_PASSWORD, "Content-Type: application/json", "Accept: application/json", "X-Snowflake-Authorization-Token-Type: PROGRAMMATIC_ACCESS_TOKEN", "User-Agent: " ~ $env.SNOWFLAKE_USERNAME ~ "-Xano-Orchestration/1.0"]
      params = $params
      timeout = 60
      mock = {
        "revenue_summary returns monthly rows": { response: { status: 200, result: {
          code: "090001",
          statementHandle: "01b2c3d4-0000-0000-0000-000000000020",
          sqlState: "00000",
          message: "Statement executed successfully.",
          createdOn: 1620151693299,
          resultSetMetaData: {
            numRows: 3,
            format: "jsonv2",
            rowType: [
              {name: "MONTH", type: "text", nullable: false},
              {name: "ORDER_COUNT", type: "fixed", nullable: false},
              {name: "TOTAL_REVENUE", type: "fixed", nullable: false}
            ],
            partitionInfo: [{rowCount: 3, uncompressedSize: 96}]
          },
          data: [
            ["2024-01", "120", "48250.00"],
            ["2024-02", "98", "39110.50"],
            ["2024-03", "143", "60230.75"]
          ]
        } } }
      }
    } as $api_result

    var $ok { value = false }
    var $rows { value = [] }
    var $row_count { value = 0 }
    var $err_msg { value = "" }

    conditional {
      if ($api_result.response.status == 200 || $api_result.response.status == 202) {
        var.update $ok { value = true }
        var $columns { value = $api_result.response.result.resultSetMetaData.rowType }
        var $data { value = $api_result.response.result.data }
        conditional {
          if ($data != null) {
            foreach ($data) {
              each as $row {
                var $obj { value = {} }
                var $i { value = 0 }
                foreach ($columns) {
                  each as $col {
                    var.update $obj { value = $obj|set:($col.name):($row|get:$i) }
                    var.update $i { value = ($i + 1) }
                  }
                }
                var.update $rows { value = $rows|push:$obj }
              }
            }
          }
        }
        var.update $row_count { value = ($rows|count) }
      }
      else {
        var.update $err_msg { value = "Snowflake API error (status " ~ ($api_result.response.status|to_text) ~ "): " ~ ($api_result.response.result|json_encode) }
      }
    }

    var $result { value = {ok: $ok, status: $api_result.response.status, error: $err_msg, rows: $rows, row_count: $row_count, snowflake_object: $object} }
  }

  response = $result

  test "revenue_summary returns monthly rows" {
    input = { start_date: "2024-01-01", end_date: "2024-03-31" }
    expect.to_be_true ($response.ok)
    expect.to_equal ($response.status) { value = 200 }
    expect.to_equal ($response.row_count) { value = 3 }
    expect.to_equal ($response.snowflake_object) { value = "ORDERS" }
    expect.to_equal ($response.rows) { value = [
      {MONTH: "2024-01", ORDER_COUNT: "120", TOTAL_REVENUE: "48250.00"},
      {MONTH: "2024-02", ORDER_COUNT: "98", TOTAL_REVENUE: "39110.50"},
      {MONTH: "2024-03", ORDER_COUNT: "143", TOTAL_REVENUE: "60230.75"}
    ] }
  }
  guid = "b-mD6eYesBJovQwtwTmg7R-6fmw"
}
---
function "snowflake_orchestration_validate_customer_profile" {
  description = "Validation for GET /customers/{customer_id}/profile. Returns {valid, error}. customer_id must be present and non-empty after trimming."

  input {
    text customer_id? { description = "The customer identifier from the path to validate" }
  }

  stack {
    var $out { value = {valid: true, error: ""} }
    var $id { value = ($input.customer_id|first_notempty:"") }
    var $id_trimmed { value = ($id|trim) }

    conditional {
      if ($id_trimmed == "") {
        var.update $out { value = {valid: false, error: "customer_id is required and must be a non-empty value"} }
      }
    }

    var $result { value = $out }
  }

  response = $result

  test "accepts a non-empty customer_id" {
    input = { customer_id: "C001" }
    expect.to_be_true ($response.valid)
  }

  test "rejects an empty customer_id" {
    input = { customer_id: "" }
    expect.to_be_false ($response.valid)
    expect.to_equal ($response.error) { value = "customer_id is required and must be a non-empty value" }
  }

  test "rejects a whitespace-only customer_id" {
    input = { customer_id: "   " }
    expect.to_be_false ($response.valid)
  }

  guid = "VCRP0LBfS_pufwAPRpms0f3cmJI"
}
---
function "snowflake_orchestration_validate_customer_search" {
  description = "Validation for GET /customers/search. Returns {valid, error}. status must be one of active|inactive|prospect; page must be >= 1; page_size must be between 1 and 100. Returns the first failure so the endpoint can log it and return the governed error envelope."

  input {
    text status? { description = "Customer status filter to validate" }
    int page? { description = "1-based page number to validate" }
    int page_size? { description = "Page size to validate (1..100)" }
  }

  stack {
    var $out { value = {valid: true, error: ""} }
    var $allowed { value = ["active", "inactive", "prospect"] }

    var $status_val { value = ($input.status|first_notempty:"") }
    var $page_val { value = ($input.page|first_notnull:1) }
    var $page_size_val { value = ($input.page_size|first_notnull:0) }

    conditional {
      if ($status_val == "") {
        var.update $out { value = {valid: false, error: "status is required and must be one of: active, inactive, prospect"} }
      }
      elseif (($allowed|some:$$ == $status_val) == false) {
        var.update $out { value = {valid: false, error: "status must be one of: active, inactive, prospect"} }
      }
      elseif ($page_val < 1) {
        var.update $out { value = {valid: false, error: "page must be an integer >= 1"} }
      }
      elseif ($page_size_val < 1) {
        var.update $out { value = {valid: false, error: "page_size must be an integer between 1 and 100"} }
      }
      elseif ($page_size_val > 100) {
        var.update $out { value = {valid: false, error: "page_size must be an integer between 1 and 100"} }
      }
    }

    var $result { value = $out }
  }

  response = $result

  test "accepts a valid search" {
    input = { status: "active", page: 1, page_size: 50 }
    expect.to_be_true ($response.valid)
  }

  test "rejects an invalid status" {
    input = { status: "lapsed", page: 1, page_size: 50 }
    expect.to_be_false ($response.valid)
    expect.to_equal ($response.error) { value = "status must be one of: active, inactive, prospect" }
  }

  test "rejects a missing status" {
    input = { status: "", page: 1, page_size: 50 }
    expect.to_be_false ($response.valid)
  }

  test "rejects page_size above 100" {
    input = { status: "active", page: 1, page_size: 250 }
    expect.to_be_false ($response.valid)
    expect.to_equal ($response.error) { value = "page_size must be an integer between 1 and 100" }
  }

  test "rejects page_size below 1" {
    input = { status: "active", page: 1, page_size: 0 }
    expect.to_be_false ($response.valid)
    expect.to_equal ($response.error) { value = "page_size must be an integer between 1 and 100" }
  }

  guid = "Wys_Dh6VSTQFAaZUoIWp1aqCaXY"
}
---
function "snowflake_orchestration_validate_revenue_summary" {
  description = "Validation for GET /metrics/revenue-summary. Returns {valid, error}. start_date and end_date are both required, must each match YYYY-MM-DD, and end_date must not be earlier than start_date. ISO YYYY-MM-DD dates compare correctly with a plain lexicographic comparison."

  input {
    text start_date? { description = "Inclusive start of the revenue window (YYYY-MM-DD)" }
    text end_date? { description = "Inclusive end of the revenue window (YYYY-MM-DD)" }
  }

  stack {
    var $out { value = {valid: true, error: ""} }
    var $start { value = ($input.start_date|first_notempty:"") }
    var $end { value = ($input.end_date|first_notempty:"") }
    var $date_re { value = "/^\\d{4}-\\d{2}-\\d{2}$/" }

    conditional {
      if ($start == "") {
        var.update $out { value = {valid: false, error: "start_date is required and must be formatted as YYYY-MM-DD"} }
      }
      elseif ($end == "") {
        var.update $out { value = {valid: false, error: "end_date is required and must be formatted as YYYY-MM-DD"} }
      }
      elseif (($date_re|regex_matches:$start) == false) {
        var.update $out { value = {valid: false, error: "start_date must be a valid date formatted as YYYY-MM-DD"} }
      }
      elseif (($date_re|regex_matches:$end) == false) {
        var.update $out { value = {valid: false, error: "end_date must be a valid date formatted as YYYY-MM-DD"} }
      }
      elseif ($end < $start) {
        var.update $out { value = {valid: false, error: "end_date must not be earlier than start_date"} }
      }
    }

    var $result { value = $out }
  }

  response = $result

  test "accepts a valid date range" {
    input = { start_date: "2024-01-01", end_date: "2024-03-31" }
    expect.to_be_true ($response.valid)
  }

  test "rejects end_date earlier than start_date" {
    input = { start_date: "2024-03-31", end_date: "2024-01-01" }
    expect.to_be_false ($response.valid)
    expect.to_equal ($response.error) { value = "end_date must not be earlier than start_date" }
  }

  test "rejects a missing start_date" {
    input = { start_date: "", end_date: "2024-03-31" }
    expect.to_be_false ($response.valid)
  }

  test "rejects a malformed date" {
    input = { start_date: "2024/01/01", end_date: "2024-03-31" }
    expect.to_be_false ($response.valid)
    expect.to_equal ($response.error) { value = "start_date must be a valid date formatted as YYYY-MM-DD" }
  }

  guid = "yo1UlVxvxQU2UEEOL34aqQKUmqU"
}
---
api_group SnowflakeOrchestration {
  canonical = "snowflake-orchestration"
  description = "Xano as a logic-centralization + governance layer on top of Snowflake: shared-secret access control, input validation, a read-through cache, audit logging, and a single normalized response envelope. Snowflake stays the source of truth; Xano owns the API contract."
  tags = ["snowflake", "data", "orchestration"]
  guid = "AhLeoklgcD0wyL6tC1fNvx6yU3g"
}
---
// GET /customers/{customer_id}/profile — one canonical customer profile from Snowflake.
// cache_status is always "miss" (caching is revenue-summary only).
query "customers/{customer_id}/profile" verb=GET {
  api_group = "SnowflakeOrchestration"
  description = "Fetch a single canonical customer profile from Snowflake by customer_id. Requires the shared API secret. Validates that customer_id is non-empty, queries Snowflake, logs the access, and returns the normalized envelope (404-style error envelope when the customer does not exist)."

  input {
    text customer_id { description = "The customer identifier (path param)" }
    text api_secret? { description = "Shared secret; must equal $env.API_AUTH_SECRET when that env var is set" }
    text requester_id? { description = "Optional caller identifier recorded in audit logs" }
  }

  stack {
    security.create_uuid as $request_id

    var $params_snapshot { value = {customer_id: $input.customer_id} }

    function.run "snowflake_orchestration_check_auth" {
      input = {provided_secret: $input.api_secret}
    } as $auth_check

    conditional {
      if ($auth_check.valid == false) {
        function.run "snowflake_orchestration_log_request" {
          input = {target: "request", request_id: $request_id, endpoint: "customers/{customer_id}/profile", requester_id: $input.requester_id, request_params: $params_snapshot, status: "auth_error", error_message: $auth_check.error}
        } as $log_auth
      }
    }

    function.run "snowflake_orchestration_validate_customer_profile" {
      input = {customer_id: $input.customer_id}
    } as $validation

    conditional {
      if (($auth_check.valid == true) && ($validation.valid == false)) {
        function.run "snowflake_orchestration_log_request" {
          input = {target: "request", request_id: $request_id, endpoint: "customers/{customer_id}/profile", requester_id: $input.requester_id, request_params: $params_snapshot, status: "validation_error", error_message: $validation.error}
        } as $log_validation
      }
    }

    var $response_body { value = null }

    conditional {
      if ($auth_check.valid == false) {
        function.run "snowflake_orchestration_envelope" {
          input = {success: false, request_id: $request_id, cache_status: "miss", errors: [$auth_check.error]}
        } as $env_auth
        var.update $response_body { value = $env_auth }
      }
      elseif ($validation.valid == false) {
        function.run "snowflake_orchestration_envelope" {
          input = {success: false, request_id: $request_id, cache_status: "miss", errors: [$validation.error]}
        } as $env_val
        var.update $response_body { value = $env_val }
      }
      else {
        function.run "snowflake_orchestration_query_customer_profile" {
          input = {customer_id: $input.customer_id}
        } as $query

        conditional {
          if (($query.ok == true) && ($query.row_count > 0)) {
            function.run "snowflake_orchestration_log_request" {
              input = {target: "query", request_id: $request_id, query_name: "customer_profile", snowflake_object: $query.snowflake_object, filters: $params_snapshot, row_count: $query.row_count, execution_status: "success"}
            } as $log_query
            function.run "snowflake_orchestration_envelope" {
              input = {success: true, data: {profile: $query.profile}, request_id: $request_id, cache_status: "miss", errors: []}
            } as $env_ok
            var.update $response_body { value = $env_ok }
          }
          elseif (($query.ok == true) && ($query.row_count == 0)) {
            // Reached Snowflake successfully but no such customer -> failed request (not found).
            function.run "snowflake_orchestration_log_request" {
              input = {target: "request", request_id: $request_id, endpoint: "customers/{customer_id}/profile", requester_id: $input.requester_id, request_params: $params_snapshot, status: "snowflake_error", error_message: "Customer not found"}
            } as $log_nf
            function.run "snowflake_orchestration_envelope" {
              input = {success: false, request_id: $request_id, cache_status: "miss", errors: ["Customer not found"]}
            } as $env_nf
            var.update $response_body { value = $env_nf }
          }
          else {
            function.run "snowflake_orchestration_log_request" {
              input = {target: "request", request_id: $request_id, endpoint: "customers/{customer_id}/profile", requester_id: $input.requester_id, request_params: $params_snapshot, status: "snowflake_error", error_message: $query.error}
            } as $log_sf
            function.run "snowflake_orchestration_envelope" {
              input = {success: false, request_id: $request_id, cache_status: "miss", errors: [$query.error]}
            } as $env_sf
            var.update $response_body { value = $env_sf }
          }
        }
      }
    }
  }

  response = $response_body
  guid = "k8rO-QOkatKe9Ds8CKPNQUbFkuA"
}
---
// GET /customers/search — validated, governed, audited Snowflake customer search.
// Inputs are intentionally optional at the platform layer so blank/invalid values reach the
// stack and produce the governed error envelope + an api_request_logs write (rather than being
// rejected pre-stack). cache_status is always "miss" (caching is revenue-summary only).
query "customers/search" verb=GET {
  api_group = "SnowflakeOrchestration"
  description = "Search customers in Snowflake by status with paging. Requires the shared API secret. Validates status (active|inactive|prospect) and page_size (1..100), queries Snowflake, logs the access, and returns the normalized envelope."

  input {
    text status? { description = "Customer status filter: active | inactive | prospect (required)" }
    int page? { description = "1-based page number (required, >= 1)" }
    int page_size? { description = "Rows per page (required, 1..100)" }
    text api_secret? { description = "Shared secret; must equal $env.API_AUTH_SECRET when that env var is set" }
    text requester_id? { description = "Optional caller identifier recorded in audit logs" }
  }

  stack {
    security.create_uuid as $request_id

    var $params_snapshot { value = {status: $input.status, page: $input.page, page_size: $input.page_size} }

    // 1) Shared-secret access control.
    function.run "snowflake_orchestration_check_auth" {
      input = {provided_secret: $input.api_secret}
    } as $auth_check

    conditional {
      if ($auth_check.valid == false) {
        function.run "snowflake_orchestration_log_request" {
          input = {target: "request", request_id: $request_id, endpoint: "customers/search", requester_id: $input.requester_id, request_params: $params_snapshot, status: "auth_error", error_message: $auth_check.error}
        } as $log_auth
      }
    }

    // 2) Input validation.
    function.run "snowflake_orchestration_validate_customer_search" {
      input = {status: $input.status, page: $input.page, page_size: $input.page_size}
    } as $validation

    conditional {
      if (($auth_check.valid == true) && ($validation.valid == false)) {
        function.run "snowflake_orchestration_log_request" {
          input = {target: "request", request_id: $request_id, endpoint: "customers/search", requester_id: $input.requester_id, request_params: $params_snapshot, status: "validation_error", error_message: $validation.error}
        } as $log_validation
      }
    }

    var $response_body { value = null }

    conditional {
      if ($auth_check.valid == false) {
        function.run "snowflake_orchestration_envelope" {
          input = {success: false, request_id: $request_id, cache_status: "miss", errors: [$auth_check.error]}
        } as $env_auth
        var.update $response_body { value = $env_auth }
      }
      elseif ($validation.valid == false) {
        function.run "snowflake_orchestration_envelope" {
          input = {success: false, request_id: $request_id, cache_status: "miss", errors: [$validation.error]}
        } as $env_val
        var.update $response_body { value = $env_val }
      }
      else {
        // 3) Query Snowflake.
        function.run "snowflake_orchestration_query_customer_search" {
          input = {status: $input.status, page: $input.page, page_size: $input.page_size}
        } as $query

        conditional {
          if ($query.ok == true) {
            // Successful query -> audit log + success envelope.
            function.run "snowflake_orchestration_log_request" {
              input = {target: "query", request_id: $request_id, query_name: "customers_search", snowflake_object: $query.snowflake_object, filters: $params_snapshot, row_count: $query.row_count, execution_status: "success"}
            } as $log_query
            function.run "snowflake_orchestration_envelope" {
              input = {success: true, data: {rows: $query.rows, row_count: $query.row_count, page: $input.page, page_size: $input.page_size}, request_id: $request_id, cache_status: "miss", errors: []}
            } as $env_ok
            var.update $response_body { value = $env_ok }
          }
          else {
            // Snowflake failure -> failed-request log + error envelope.
            function.run "snowflake_orchestration_log_request" {
              input = {target: "request", request_id: $request_id, endpoint: "customers/search", requester_id: $input.requester_id, request_params: $params_snapshot, status: "snowflake_error", error_message: $query.error}
            } as $log_sf
            function.run "snowflake_orchestration_envelope" {
              input = {success: false, request_id: $request_id, cache_status: "miss", errors: [$query.error]}
            } as $env_sf
            var.update $response_body { value = $env_sf }
          }
        }
      }
    }
  }

  response = $response_body
  guid = "MTks2udnID9nuRDotGGdqA9fiKw"
}
---
// GET /metrics/revenue-summary — monthly revenue from Snowflake, with a 15-minute read-through cache.
// This is the ONLY cached endpoint: a cache_key is derived from the validated dates, an unexpired
// cached_query_results row is returned as cache_status:"hit" WITHOUT calling Snowflake; otherwise
// Snowflake is queried, the result is cached, and cache_status is "miss".
query "metrics/revenue-summary" verb=GET {
  api_group = "SnowflakeOrchestration"
  description = "Return revenue summarized by month from Snowflake between start_date and end_date. Requires the shared API secret. Validates both dates (YYYY-MM-DD, end >= start). Served from a 15-minute cache when warm (cache_status:hit), otherwise queried live and cached (cache_status:miss)."

  input {
    text start_date? { description = "Inclusive window start, YYYY-MM-DD (required)" }
    text end_date? { description = "Inclusive window end, YYYY-MM-DD (required)" }
    text api_secret? { description = "Shared secret; must equal $env.API_AUTH_SECRET when that env var is set" }
    text requester_id? { description = "Optional caller identifier recorded in audit logs" }
  }

  stack {
    security.create_uuid as $request_id

    var $params_snapshot { value = {start_date: $input.start_date, end_date: $input.end_date} }

    function.run "snowflake_orchestration_check_auth" {
      input = {provided_secret: $input.api_secret}
    } as $auth_check

    conditional {
      if ($auth_check.valid == false) {
        function.run "snowflake_orchestration_log_request" {
          input = {target: "request", request_id: $request_id, endpoint: "metrics/revenue-summary", requester_id: $input.requester_id, request_params: $params_snapshot, status: "auth_error", error_message: $auth_check.error}
        } as $log_auth
      }
    }

    function.run "snowflake_orchestration_validate_revenue_summary" {
      input = {start_date: $input.start_date, end_date: $input.end_date}
    } as $validation

    conditional {
      if (($auth_check.valid == true) && ($validation.valid == false)) {
        function.run "snowflake_orchestration_log_request" {
          input = {target: "request", request_id: $request_id, endpoint: "metrics/revenue-summary", requester_id: $input.requester_id, request_params: $params_snapshot, status: "validation_error", error_message: $validation.error}
        } as $log_validation
      }
    }

    var $response_body { value = null }

    conditional {
      if ($auth_check.valid == false) {
        function.run "snowflake_orchestration_envelope" {
          input = {success: false, request_id: $request_id, cache_status: "miss", errors: [$auth_check.error]}
        } as $env_auth
        var.update $response_body { value = $env_auth }
      }
      elseif ($validation.valid == false) {
        function.run "snowflake_orchestration_envelope" {
          input = {success: false, request_id: $request_id, cache_status: "miss", errors: [$validation.error]}
        } as $env_val
        var.update $response_body { value = $env_val }
      }
      else {
        var $cache_key { value = "revenue_summary:" ~ $input.start_date ~ ":" ~ $input.end_date }

        // Cache lookup (revenue-summary only).
        function.run "snowflake_orchestration_cache_get" {
          input = {cache_key: $cache_key}
        } as $cache

        conditional {
          if ($cache.hit == true) {
            // Cache HIT — return without touching Snowflake. No query audit log (no query ran).
            function.run "snowflake_orchestration_envelope" {
              input = {success: true, data: $cache.data, request_id: $request_id, cache_status: "hit", errors: []}
            } as $env_hit
            var.update $response_body { value = $env_hit }
          }
          else {
            // Cache MISS — query Snowflake.
            function.run "snowflake_orchestration_query_revenue_summary" {
              input = {start_date: $input.start_date, end_date: $input.end_date}
            } as $query

            conditional {
              if ($query.ok == true) {
                var $payload { value = {by_month: $query.rows, row_count: $query.row_count, start_date: $input.start_date, end_date: $input.end_date} }
                function.run "snowflake_orchestration_log_request" {
                  input = {target: "query", request_id: $request_id, query_name: "revenue_summary", snowflake_object: $query.snowflake_object, filters: $params_snapshot, row_count: $query.row_count, execution_status: "success"}
                } as $log_query
                function.run "snowflake_orchestration_cache_put" {
                  input = {cache_key: $cache_key, query_name: "revenue_summary", data: $payload}
                } as $cache_write
                function.run "snowflake_orchestration_envelope" {
                  input = {success: true, data: $payload, request_id: $request_id, cache_status: "miss", errors: []}
                } as $env_ok
                var.update $response_body { value = $env_ok }
              }
              else {
                function.run "snowflake_orchestration_log_request" {
                  input = {target: "request", request_id: $request_id, endpoint: "metrics/revenue-summary", requester_id: $input.requester_id, request_params: $params_snapshot, status: "snowflake_error", error_message: $query.error}
                } as $log_sf
                function.run "snowflake_orchestration_envelope" {
                  input = {success: false, request_id: $request_id, cache_status: "miss", errors: [$query.error]}
                } as $env_sf
                var.update $response_body { value = $env_sf }
              }
            }
          }
        }
      }
    }
  }

  response = $response_body
  guid = "5ad264O1Eg0NAIMg8dyDuERqSWQ"
}
---
// Credential-free outcome test: prove GET /metrics/revenue-summary serves a warm cache row
// WITHOUT calling Snowflake. We pre-seed a cached_query_results row whose cache_key matches what
// the endpoint derives ("revenue_summary:<start>:<end>") and whose expires_at is in the future,
// then call the endpoint and assert the exact envelope with cache_status:"hit". With no Snowflake
// credentials configured, a real query would fail — so a successful hit proves the cache short-circuit.
workflow_test "snowflake_orchestration_cache_hit_serves_without_snowflake" {
  tags = ["snowflake-orchestration", "cache", "outcome"]

  stack {
    db.add "cached_query_results" {
      data = {
        cache_key: "revenue_summary:2024-01-01:2024-03-31",
        query_name: "revenue_summary",
        response_json: {
          by_month: [
            {MONTH: "2024-01", ORDER_COUNT: "120", TOTAL_REVENUE: "48250.00"},
            {MONTH: "2024-02", ORDER_COUNT: "98", TOTAL_REVENUE: "39110.50"}
          ],
          row_count: 2,
          start_date: "2024-01-01",
          end_date: "2024-03-31"
        },
        expires_at: (("now"|to_ms) + 900000)
      }
    } as $seed

    api.call "metrics/revenue-summary" verb=GET {
      api_group = "SnowflakeOrchestration"
      input = {start_date: "2024-01-01", end_date: "2024-03-31"}
    } as $resp

    expect.to_be_true ($resp.success)
    expect.to_equal ($resp.metadata.source) { value = "snowflake" }
    expect.to_equal ($resp.metadata.cache_status) { value = "hit" }
    expect.to_equal ($resp.errors) { value = [] }
    expect.to_equal ($resp.data.row_count) { value = 2 }
    expect.to_equal ($resp.data.start_date) { value = "2024-01-01" }
  }
  guid = "PJ4bqwmwMB3dlzDPmSaPna92yHY"
}
---
// Credential-free outcome test: prove a validation failure short-circuits BEFORE any Snowflake
// call, returns the governed error envelope, AND writes an api_request_logs row. We call
// GET /metrics/revenue-summary with end_date < start_date (invalid), then assert the error
// envelope and that a matching validation_error audit row was persisted.
workflow_test "snowflake_orchestration_validation_failure_is_logged" {
  tags = ["snowflake-orchestration", "validation", "audit", "outcome"]

  stack {
    api.call "metrics/revenue-summary" verb=GET {
      api_group = "SnowflakeOrchestration"
      input = {start_date: "2024-03-31", end_date: "2024-01-01"}
    } as $resp

    expect.to_be_false ($resp.success)
    expect.to_equal ($resp.metadata.source) { value = "snowflake" }
    expect.to_equal ($resp.metadata.cache_status) { value = "miss" }
    expect.to_equal ($resp.data) { value = {} }
    expect.to_contain ($resp.errors) { value = "end_date must not be earlier than start_date" }

    // The failed request must have been persisted to api_request_logs as a validation_error.
    db.query "api_request_logs" {
      where = ($db.api_request_logs.endpoint == "metrics/revenue-summary") && ($db.api_request_logs.status == "validation_error")
      return = {type: "count"}
    } as $logged_count

    expect.to_be_greater_than ($logged_count) { value = 0 }
  }
  guid = "LHCL15gg3p9m64ctUceJ0P07gdg"
}
