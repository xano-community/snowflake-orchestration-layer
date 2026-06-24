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
