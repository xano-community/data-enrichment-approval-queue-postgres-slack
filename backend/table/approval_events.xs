table "approval_events" {
  auth = false

  schema {
    int id
    int approval_queue_id {
      table = "approval_queue"
      description = "The approval_queue row this event belongs to"
    }
    enum event_type {
      description = "What happened on the approval item"
      values = ["created", "approved", "rejected"]
    }
    json event_payload? { description = "Structured detail for the event (e.g. reviewer note)" }
    text created_by? { description = "Identifier of the actor who triggered the event" }
    timestamp created_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "approval_queue_id"}]}
    {type: "btree", field: [{name: "event_type"}]}
  ]
  guid = "X0MHMeNxm2UfLJhQd7IqKngZkLY"
}
