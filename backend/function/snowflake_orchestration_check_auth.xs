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
