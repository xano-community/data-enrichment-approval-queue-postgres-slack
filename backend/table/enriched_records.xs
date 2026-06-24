table "enriched_records" {
  auth = false

  schema {
    int id
    int source_record_id {
      table = "source_records"
      description = "The source_records row this enrichment belongs to"
    }
    json enrichment_payload { description = "The normalized response returned by the enrichment provider" }
    int enrichment_score { description = "Computed data-quality score, 0..100 (see scoring rules)" }
    enum classification {
      description = "Routing decision derived from the score"
      values = ["approved_auto", "needs_review", "rejected_auto"]
    }
    timestamp created_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "source_record_id"}]}
    {type: "btree", field: [{name: "classification"}]}
  ]
  guid = "Gerayfq-ZB_XzjCgfCTcODWFjVk"
}
