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
