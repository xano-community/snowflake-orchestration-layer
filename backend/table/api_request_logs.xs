table "api_request_logs" {
  auth = false
  description = "Governance log of every API request handled by the orchestration layer. Failed requests (auth, validation, or Snowflake errors) are written here with the captured params and error message so operators have a full audit trail of rejected/failed traffic."

  schema {
    int id
    text request_id { description = "UUID generated per request and echoed in the response metadata" }
    text endpoint { description = "The logical endpoint that handled the request, e.g. customers/search" }
    text requester_id? { description = "Identifier of the caller when provided (header/param); null for anonymous" }
    json request_params? { description = "Sanitized snapshot of the request inputs (the API secret is never stored)" }
    text status { description = "Outcome of the request: auth_error | validation_error | snowflake_error" }
    text error_message? { description = "Human-readable reason the request failed" }
    timestamp created_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "request_id"}]}
    {type: "btree", field: [{name: "endpoint"}]}
    {type: "btree", field: [{name: "status"}]}
    {type: "btree", field: [{name: "created_at", op: "desc"}]}
  ]
  guid = "kYyT0DdfjtutAlHz28S3c30z7WA"
}
