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
