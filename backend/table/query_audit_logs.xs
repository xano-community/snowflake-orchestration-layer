table "query_audit_logs" {
  auth = false
  description = "Audit record of every SUCCESSFUL Snowflake query the orchestration layer runs. Captures the named query, the Snowflake object/view it targeted, the applied filters, the row count, and the execution status so data access is fully traceable."

  schema {
    int id
    text request_id { description = "UUID of the originating API request" }
    text query_name { description = "Logical query that ran, e.g. customers_search, customer_profile, revenue_summary" }
    text snowflake_object? { description = "The Snowflake table/view the query read from" }
    json filters? { description = "The validated filters/parameters applied to the query" }
    int row_count?=0 { description = "Number of rows returned by Snowflake" }
    text execution_status { description = "Snowflake execution outcome, e.g. success" }
    timestamp created_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "request_id"}]}
    {type: "btree", field: [{name: "query_name"}]}
    {type: "btree", field: [{name: "created_at", op: "desc"}]}
  ]
  guid = "WYPYAyhS39JeABdpzCLPkQXsB8Y"
}
