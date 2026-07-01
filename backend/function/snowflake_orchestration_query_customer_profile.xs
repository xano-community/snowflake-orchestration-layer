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
