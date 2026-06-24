table "cached_query_results" {
  auth = false
  description = "Read-through cache for GET /metrics/revenue-summary only. A row holds the full normalized response for a given cache_key (derived from the query params); expires_at is epoch milliseconds, and a row is a cache HIT only while now < expires_at (15-minute TTL)."

  schema {
    int id
    text cache_key { description = "Deterministic key derived from the query name + validated params, e.g. revenue_summary:2024-01-01:2024-03-31" }
    text query_name { description = "The logical query the cached result belongs to, e.g. revenue_summary" }
    json response_json { description = "The cached `data` payload returned to the caller on a hit" }
    int expires_at { description = "Epoch milliseconds after which this row is stale (created_at + 15 minutes)" }
    timestamp created_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "cache_key"}]}
    {type: "btree", field: [{name: "query_name"}]}
    {type: "btree", field: [{name: "expires_at"}]}
  ]
  guid = "DRJnUi2_6sNSp0bRDmXiTcETerE"
}
