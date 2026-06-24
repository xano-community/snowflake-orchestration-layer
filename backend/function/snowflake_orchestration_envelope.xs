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
