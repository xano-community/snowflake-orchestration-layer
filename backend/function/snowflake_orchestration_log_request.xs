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
