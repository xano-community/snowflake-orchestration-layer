function "snowflake_orchestration_cache_get" {
  description = "Read-through cache lookup for the revenue-summary endpoint. Looks up cached_query_results by cache_key and returns {hit, data} — hit=true with the stored data only when a row exists AND now (epoch ms) is still before its expires_at (15-minute TTL); otherwise hit=false. Pure Xano-native (no Snowflake call)."

  input {
    text cache_key { description = "Deterministic cache key, e.g. revenue_summary:2024-01-01:2024-03-31" }
  }

  stack {
    var $now_ms { value = ("now"|to_ms) }

    db.query "cached_query_results" {
      where = ($db.cached_query_results.cache_key == $input.cache_key) && ($db.cached_query_results.expires_at > $now_ms)
      sort = {created_at: "desc"}
      return = {type: "single"}
    } as $row

    var $hit { value = false }
    var $data { value = null }

    conditional {
      if ($row != null) {
        var.update $hit { value = true }
        var.update $data { value = $row.response_json }
      }
    }

    var $result { value = {hit: $hit, data: $data} }
  }

  response = $result
  guid = "AyrYcub0awAh-Zl_5VSzwr4ZGUE"
}
