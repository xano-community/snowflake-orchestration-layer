// Credential-free outcome test: prove GET /metrics/revenue-summary serves a warm cache row
// WITHOUT calling Snowflake. We pre-seed a cached_query_results row whose cache_key matches what
// the endpoint derives ("revenue_summary:<start>:<end>") and whose expires_at is in the future,
// then call the endpoint and assert the exact envelope with cache_status:"hit". With no Snowflake
// credentials configured, a real query would fail — so a successful hit proves the cache short-circuit.
workflow_test "snowflake_orchestration_cache_hit_serves_without_snowflake" {
  tags = ["snowflake-orchestration", "cache", "outcome"]

  stack {
    db.add "cached_query_results" {
      data = {
        cache_key: "revenue_summary:2024-01-01:2024-03-31",
        query_name: "revenue_summary",
        response_json: {
          by_month: [
            {MONTH: "2024-01", ORDER_COUNT: "120", TOTAL_REVENUE: "48250.00"},
            {MONTH: "2024-02", ORDER_COUNT: "98", TOTAL_REVENUE: "39110.50"}
          ],
          row_count: 2,
          start_date: "2024-01-01",
          end_date: "2024-03-31"
        },
        expires_at: (("now"|to_ms) + 900000)
      }
    } as $seed

    api.call "metrics/revenue-summary" verb=GET {
      api_group = "SnowflakeOrchestration"
      input = {start_date: "2024-01-01", end_date: "2024-03-31"}
    } as $resp

    expect.to_be_true ($resp.success)
    expect.to_equal ($resp.metadata.source) { value = "snowflake" }
    expect.to_equal ($resp.metadata.cache_status) { value = "hit" }
    expect.to_equal ($resp.errors) { value = [] }
    expect.to_equal ($resp.data.row_count) { value = 2 }
    expect.to_equal ($resp.data.start_date) { value = "2024-01-01" }
  }
  guid = "PJ4bqwmwMB3dlzDPmSaPna92yHY"
}
