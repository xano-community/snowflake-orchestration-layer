// GET /metrics/revenue-summary — monthly revenue from Snowflake, with a 15-minute read-through cache.
// This is the ONLY cached endpoint: a cache_key is derived from the validated dates, an unexpired
// cached_query_results row is returned as cache_status:"hit" WITHOUT calling Snowflake; otherwise
// Snowflake is queried, the result is cached, and cache_status is "miss".
query "metrics/revenue-summary" verb=GET {
  api_group = "SnowflakeOrchestration"
  description = "Return revenue summarized by month from Snowflake between start_date and end_date. Requires the shared API secret. Validates both dates (YYYY-MM-DD, end >= start). Served from a 15-minute cache when warm (cache_status:hit), otherwise queried live and cached (cache_status:miss)."

  input {
    text start_date? { description = "Inclusive window start, YYYY-MM-DD (required)" }
    text end_date? { description = "Inclusive window end, YYYY-MM-DD (required)" }
    text api_secret? { description = "Shared secret; must equal $env.API_AUTH_SECRET when that env var is set" }
    text requester_id? { description = "Optional caller identifier recorded in audit logs" }
  }

  stack {
    security.create_uuid as $request_id

    var $params_snapshot { value = {start_date: $input.start_date, end_date: $input.end_date} }

    function.run "snowflake_orchestration_check_auth" {
      input = {provided_secret: $input.api_secret}
    } as $auth_check

    conditional {
      if ($auth_check.valid == false) {
        function.run "snowflake_orchestration_log_request" {
          input = {target: "request", request_id: $request_id, endpoint: "metrics/revenue-summary", requester_id: $input.requester_id, request_params: $params_snapshot, status: "auth_error", error_message: $auth_check.error}
        } as $log_auth
      }
    }

    function.run "snowflake_orchestration_validate_revenue_summary" {
      input = {start_date: $input.start_date, end_date: $input.end_date}
    } as $validation

    conditional {
      if (($auth_check.valid == true) && ($validation.valid == false)) {
        function.run "snowflake_orchestration_log_request" {
          input = {target: "request", request_id: $request_id, endpoint: "metrics/revenue-summary", requester_id: $input.requester_id, request_params: $params_snapshot, status: "validation_error", error_message: $validation.error}
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
        var $cache_key { value = "revenue_summary:" ~ $input.start_date ~ ":" ~ $input.end_date }

        // Cache lookup (revenue-summary only).
        function.run "snowflake_orchestration_cache_get" {
          input = {cache_key: $cache_key}
        } as $cache

        conditional {
          if ($cache.hit == true) {
            // Cache HIT — return without touching Snowflake. No query audit log (no query ran).
            function.run "snowflake_orchestration_envelope" {
              input = {success: true, data: $cache.data, request_id: $request_id, cache_status: "hit", errors: []}
            } as $env_hit
            var.update $response_body { value = $env_hit }
          }
          else {
            // Cache MISS — query Snowflake.
            function.run "snowflake_orchestration_query_revenue_summary" {
              input = {start_date: $input.start_date, end_date: $input.end_date}
            } as $query

            conditional {
              if ($query.ok == true) {
                var $payload { value = {by_month: $query.rows, row_count: $query.row_count, start_date: $input.start_date, end_date: $input.end_date} }
                function.run "snowflake_orchestration_log_request" {
                  input = {target: "query", request_id: $request_id, query_name: "revenue_summary", snowflake_object: $query.snowflake_object, filters: $params_snapshot, row_count: $query.row_count, execution_status: "success"}
                } as $log_query
                function.run "snowflake_orchestration_cache_put" {
                  input = {cache_key: $cache_key, query_name: "revenue_summary", data: $payload}
                } as $cache_write
                function.run "snowflake_orchestration_envelope" {
                  input = {success: true, data: $payload, request_id: $request_id, cache_status: "miss", errors: []}
                } as $env_ok
                var.update $response_body { value = $env_ok }
              }
              else {
                function.run "snowflake_orchestration_log_request" {
                  input = {target: "request", request_id: $request_id, endpoint: "metrics/revenue-summary", requester_id: $input.requester_id, request_params: $params_snapshot, status: "snowflake_error", error_message: $query.error}
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
    }
  }

  response = $response_body
  guid = "5ad264O1Eg0NAIMg8dyDuERqSWQ"
}
