function "snowflake_orchestration_cache_put" {
  description = "Write a fresh revenue-summary result into cached_query_results with a 15-minute TTL. expires_at is stored as epoch milliseconds (now + 900000). Pure Xano-native (no Snowflake call). Returns the created cache row."

  input {
    text cache_key { description = "Deterministic cache key to store under" }
    text query_name { description = "Logical query name, e.g. revenue_summary" }
    json data { description = "The normalized `data` payload to cache" }
  }

  stack {
    var $expires_at { value = (("now"|to_ms) + 900000) }

    db.add "cached_query_results" {
      data = {
        cache_key: $input.cache_key,
        query_name: $input.query_name,
        response_json: $input.data,
        expires_at: $expires_at
      }
    } as $row

    var $result { value = $row }
  }

  response = $result
  guid = "1QNM67-UmG7TPIEQcMo4soVk1Do"
}
