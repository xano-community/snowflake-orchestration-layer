// GET /customers/search — validated, governed, audited Snowflake customer search.
// Inputs are intentionally optional at the platform layer so blank/invalid values reach the
// stack and produce the governed error envelope + an api_request_logs write (rather than being
// rejected pre-stack). cache_status is always "miss" (caching is revenue-summary only).
query "customers/search" verb=GET {
  api_group = "SnowflakeOrchestration"
  description = "Search customers in Snowflake by status with paging. Requires the shared API secret. Validates status (active|inactive|prospect) and page_size (1..100), queries Snowflake, logs the access, and returns the normalized envelope."

  input {
    text status? { description = "Customer status filter: active | inactive | prospect (required)" }
    int page? { description = "1-based page number (required, >= 1)" }
    int page_size? { description = "Rows per page (required, 1..100)" }
    text api_secret? { description = "Shared secret; must equal $env.API_AUTH_SECRET when that env var is set" }
    text requester_id? { description = "Optional caller identifier recorded in audit logs" }
  }

  stack {
    security.create_uuid as $request_id

    var $params_snapshot { value = {status: $input.status, page: $input.page, page_size: $input.page_size} }

    // 1) Shared-secret access control.
    function.run "snowflake_orchestration_check_auth" {
      input = {provided_secret: $input.api_secret}
    } as $auth_check

    conditional {
      if ($auth_check.valid == false) {
        function.run "snowflake_orchestration_log_request" {
          input = {target: "request", request_id: $request_id, endpoint: "customers/search", requester_id: $input.requester_id, request_params: $params_snapshot, status: "auth_error", error_message: $auth_check.error}
        } as $log_auth
      }
    }

    // 2) Input validation.
    function.run "snowflake_orchestration_validate_customer_search" {
      input = {status: $input.status, page: $input.page, page_size: $input.page_size}
    } as $validation

    conditional {
      if (($auth_check.valid == true) && ($validation.valid == false)) {
        function.run "snowflake_orchestration_log_request" {
          input = {target: "request", request_id: $request_id, endpoint: "customers/search", requester_id: $input.requester_id, request_params: $params_snapshot, status: "validation_error", error_message: $validation.error}
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
        // 3) Query Snowflake.
        function.run "snowflake_orchestration_query_customer_search" {
          input = {status: $input.status, page: $input.page, page_size: $input.page_size}
        } as $query

        conditional {
          if ($query.ok == true) {
            // Successful query -> audit log + success envelope.
            function.run "snowflake_orchestration_log_request" {
              input = {target: "query", request_id: $request_id, query_name: "customers_search", snowflake_object: $query.snowflake_object, filters: $params_snapshot, row_count: $query.row_count, execution_status: "success"}
            } as $log_query
            function.run "snowflake_orchestration_envelope" {
              input = {success: true, data: {rows: $query.rows, row_count: $query.row_count, page: $input.page, page_size: $input.page_size}, request_id: $request_id, cache_status: "miss", errors: []}
            } as $env_ok
            var.update $response_body { value = $env_ok }
          }
          else {
            // Snowflake failure -> failed-request log + error envelope.
            function.run "snowflake_orchestration_log_request" {
              input = {target: "request", request_id: $request_id, endpoint: "customers/search", requester_id: $input.requester_id, request_params: $params_snapshot, status: "snowflake_error", error_message: $query.error}
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
  guid = "MTks2udnID9nuRDotGGdqA9fiKw"
}
