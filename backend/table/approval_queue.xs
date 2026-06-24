table "approval_queue" {
  auth = false

  schema {
    int id
    int source_record_id {
      table = "source_records"
      description = "The source record under review"
    }
    int enriched_record_id {
      table = "enriched_records"
      description = "The enriched record that scored into needs_review"
    }
    enum approval_status?="pending" {
      description = "Human review decision"
      values = ["pending", "approved", "rejected"]
    }
    text assigned_to? { description = "Reviewer identifier the item is assigned to (optional)" }
    text review_reason? { description = "Why this record was routed to manual review" }
    timestamp created_at?=now
    timestamp updated_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "source_record_id"}]}
    {type: "btree", field: [{name: "approval_status"}]}
  ]
  guid = "VNdhhAkWZje0tkfJ-vYn7oUc4QA"
}
