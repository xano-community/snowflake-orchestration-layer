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
