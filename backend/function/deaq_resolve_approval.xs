function "deaq_resolve_approval" {
  description = "Apply a human review decision to an approval_queue row. Loads the row (must exist and still be pending), sets approval_status to the decision ('approved' or 'rejected'), stamps assigned_to with the reviewer, and writes a matching approval_events row carrying the reviewer note. Returns the updated approval row and the event id."

  input {
    int approval_id { description = "approval_queue row id" }
    text decision { description = "'approved' or 'rejected'" }
    text reviewer_id { description = "Identifier of the reviewer making the decision" }
    text review_note? { description = "Reviewer's note, stored on the approval event" }
  }

  stack {
    precondition ($input.decision == "approved" || $input.decision == "rejected") {
      error_type = "inputerror"
      error = "decision must be 'approved' or 'rejected'"
    }

    db.get "approval_queue" {
      field_name = "id"
      field_value = $input.approval_id
    } as $approval

    precondition ($approval != null) {
      error_type = "notfound"
      error = "Approval item not found: " ~ ($input.approval_id|to_text)
    }

    precondition ($approval.approval_status == "pending") {
      error_type = "inputerror"
      error = "Approval item " ~ ($input.approval_id|to_text) ~ " is already " ~ $approval.approval_status
    }

    db.edit "approval_queue" {
      field_name = "id"
      field_value = $input.approval_id
      data = {
        approval_status: $input.decision,
        assigned_to: $input.reviewer_id,
        updated_at: now
      }
    } as $updated

    db.add "approval_events" {
      data = {
        approval_queue_id: $input.approval_id,
        event_type: $input.decision,
        event_payload: { note: $input.review_note },
        created_by: $input.reviewer_id
      }
    } as $event
  }

  response = { approval: $updated, approval_event_id: $event.id }

  // The happy approve/reject paths touch real approval_queue rows, so they are proven end-to-end by
  // the deaq_enrichment_to_approval_flow workflow test (which creates a real queue row first). The
  // decision guard below throws before any DB access, so it is unit-testable here.
  test "invalid decision is rejected" {
    input = { approval_id: 1, decision: "maybe", reviewer_id: "reviewer-7" }
    expect.to_throw
  }
  guid = "Yw-_RgrRHmiPtU0OBiKDrlXQ1UI"
}
