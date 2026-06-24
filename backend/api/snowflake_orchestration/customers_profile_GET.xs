// GET /customers/{customer_id}/profile — one canonical customer profile from Snowflake.
// cache_status is always "miss" (caching is revenue-summary only).
query "customers/{customer_id}/profile" verb=GET {
  api_group = "SnowflakeOrchestration"
  description = "Fetch a single canonical customer profile from Snowflake by customer_id. Requires the shared API secret. Validates that customer_id is non-empty, queries Snowflake, logs the access, and returns the normalized envelope (404-style error envelope when the customer does not exist)."

  input {
    text customer_id { description = "The customer identifier (path param)" }
    text api_secret? { description = "Shared secret; must equal $env.API_AUTH_SECRET when that env var is set" }
    text requester_id? { description = "Optional caller identifier recorded in audit logs" }
  }

  stack {
    security.create_uuid as $request_id

    var $params_snapshot { value = {customer_id: $input.customer_id} }

    function.run "snowflake_orchestration_check_auth" {
      input = {provided_secret: $input.api_secret}
    } as $auth_check

    conditional {
      if ($auth_check.valid == false) {
        function.run "snowflake_orchestration_log_request" {
          input = {target: "request", request_id: $request_id, endpoint: "customers/{customer_id}/profile", requester_id: $input.requester_id, request_params: $params_snapshot, status: "auth_error", error_message: $auth_check.error}
        } as $log_auth
      }
    }

    function.run "snowflake_orchestration_validate_customer_profile" {
      input = {customer_id: $input.customer_id}
    } as $validation

    conditional {
      if (($auth_check.valid == true) && ($validation.valid == false)) {
        function.run "snowflake_orchestration_log_request" {
          input = {target: "request", request_id: $request_id, endpoint: "customers/{customer_id}/profile", requester_id: $input.requester_id, request_params: $params_snapshot, status: "validation_error", error_message: $validation.error}
        } as $log_validation
      }
    }

    var $response_body { value = null }

    conditional {
      if ($auth_check.valid == false) {
        function.run "snowflake_orchestration_envelope" {
          input = {success: false, request_id: $request_id, cache_status: "miss", errors: [$auth_check.error]}
        } as $env_auth
        var.update $response_body { value = $env_auth }
      }
      elseif ($validation.valid == false) {
        function.run "snowflake_orchestration_envelope" {
          input = {success: false, request_id: $request_id, cache_status: "miss", errors: [$validation.error]}
        } as $env_val
        var.update $response_body { value = $env_val }
      }
      else {
        function.run "snowflake_orchestration_query_customer_profile" {
          input = {customer_id: $input.customer_id}
        } as $query

        conditional {
          if (($query.ok == true) && ($query.row_count > 0)) {
            function.run "snowflake_orchestration_log_request" {
              input = {target: "query", request_id: $request_id, query_name: "customer_profile", snowflake_object: $query.snowflake_object, filters: $params_snapshot, row_count: $query.row_count, execution_status: "success"}
            } as $log_query
            function.run "snowflake_orchestration_envelope" {
              input = {success: true, data: {profile: $query.profile}, request_id: $request_id, cache_status: "miss", errors: []}
            } as $env_ok
            var.update $response_body { value = $env_ok }
          }
          elseif (($query.ok == true) && ($query.row_count == 0)) {
            // Reached Snowflake successfully but no such customer -> failed request (not found).
            function.run "snowflake_orchestration_log_request" {
              input = {target: "request", request_id: $request_id, endpoint: "customers/{customer_id}/profile", requester_id: $input.requester_id, request_params: $params_snapshot, status: "snowflake_error", error_message: "Customer not found"}
            } as $log_nf
            function.run "snowflake_orchestration_envelope" {
              input = {success: false, request_id: $request_id, cache_status: "miss", errors: ["Customer not found"]}
            } as $env_nf
            var.update $response_body { value = $env_nf }
          }
          else {
            function.run "snowflake_orchestration_log_request" {
              input = {target: "request", request_id: $request_id, endpoint: "customers/{customer_id}/profile", requester_id: $input.requester_id, request_params: $params_snapshot, status: "snowflake_error", error_message: $query.error}
            } as $log_sf
            function.run "snowflake_orchestration_envelope" {
              input = {success: false, request_id: $request_id, cache_status: "miss", errors: [$query.error]}
            } as $env_sf
            var.update $response_body { value = $env_sf }
          }
        }
      }
    }
  }

  response = $response_body
  guid = "k8rO-QOkatKe9Ds8CKPNQUbFkuA"
}
