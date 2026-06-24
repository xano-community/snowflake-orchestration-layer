workspace "Snowflake API Orchestration Layer" {
  description = "Xano as a logic-centralization + governance layer on top of Snowflake: shared-secret access control, input validation, a 15-minute read-through cache, audit logging, and one normalized API envelope. Snowflake stays the source of truth."
  preferences = {
    internal_docs    : false
    track_performance: true
    sql_names        : false
    sql_columns      : true
  }
}
