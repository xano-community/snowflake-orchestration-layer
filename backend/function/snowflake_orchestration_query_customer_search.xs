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

    var $params {
      value = {
        statement: "SELECT CUSTOMER_ID, NAME, EMAIL, STATUS, CREATED_AT FROM CUSTOMERS WHERE STATUS = ? ORDER BY CREATED_AT DESC LIMIT ? OFFSET ?",
        timeout: 60,
        database: $env.SNOWFLAKE_DATABASE,
        schema: $env.SNOWFLAKE_SCHEMA,
        warehouse: $env.SNOWFLAKE_WAREHOUSE,
        role: $env.SNOWFLAKE_ROLE,
        bindings: {
          "1": {type: "TEXT", value: ($input.status|to_upper)},
          "2": {type: "FIXED", value: ($input.page_size|to_text)},
          "3": {type: "FIXED", value: ($offset|to_text)}
        },
        parameters: {CLIENT_SESSION_KEEP_ALIVE: "false"}
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
