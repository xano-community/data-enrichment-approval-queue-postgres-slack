table "enrichment_jobs" {
  auth = false

  schema {
    int id
    int source_record_id {
      table = "source_records"
      description = "The source_records row this enrichment job tracks"
    }
    enum job_status?="pending" {
      description = "State of the enrichment job"
      values = ["pending", "succeeded", "failed"]
    }
    int attempt_count?=0 { description = "Number of enrichment attempts made; failed calls increment this, capped at 3" }
    text error_message? { description = "Message from the most recent failed attempt, if any" }
    timestamp created_at?=now
    timestamp updated_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "source_record_id"}]}
    {type: "btree", field: [{name: "job_status"}]}
  ]
  guid = "AlgCkcDmKAAqd9XosVGb30VAPrk"
}
