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
