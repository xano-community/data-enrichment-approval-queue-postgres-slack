query "approvals/{approval_id}/reject" verb=POST {
  api_group = "DataEnrichment"
  description = "Reject a pending approval_queue item. reviewer_id and review_note are required and review_note must not be empty. Sets approval_status to 'rejected' and writes a 'rejected' approval_events row carrying the reviewer note. Requires API_AUTH_SECRET; writes an api_request_logs row on every call (before auth is checked, so rejected calls — including those with an empty note — are still audited)."

  input {
    int approval_id {
      table = "approval_queue"
      description = "approval_queue row id to reject"
    }
    text api_secret? { description = "Shared secret, matched against $env.API_AUTH_SECRET" }
    text reviewer_id? { description = "Identifier of the reviewer rejecting the item (required)" }
    text review_note? { description = "Mandatory, non-empty reason for the rejection (recorded on the event)" }
  }

  stack {
    function.run "deaq_authorize_and_log" {
      input = { endpoint: "POST /approvals/{approval_id}/reject", api_secret: $input.api_secret, requester_id: $input.reviewer_id }
    } as $log

    precondition ($input.reviewer_id != null && $input.reviewer_id != "") {
      error_type = "inputerror"
      error = "reviewer_id is required"
    }

    // deaq_reject_approval enforces the non-empty review_note rule and throws inputerror on a blank note.
    function.run "deaq_reject_approval" {
      input = { approval_id: $input.approval_id, reviewer_id: $input.reviewer_id, review_note: $input.review_note }
    } as $resolved
  }

  response = {
    request_id: $log.request_id,
    approval_id: $resolved.approval.id,
    approval_status: $resolved.approval.approval_status,
    approval_event_id: $resolved.approval_event_id
  }
  guid = "ovFlKexI_W1xa8z_nBWYvXyFm9w"
}
