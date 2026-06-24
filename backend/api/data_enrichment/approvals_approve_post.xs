query "approvals/{approval_id}/approve" verb=POST {
  api_group = "DataEnrichment"
  description = "Approve a pending approval_queue item. Sets approval_status to 'approved' and writes an 'approved' approval_events row carrying the reviewer note. reviewer_id and review_note are required. Requires API_AUTH_SECRET; writes an api_request_logs row on every call (before auth is checked, so rejected calls are still audited)."

  input {
    int approval_id {
      table = "approval_queue"
      description = "approval_queue row id to approve"
    }
    text api_secret? { description = "Shared secret, matched against $env.API_AUTH_SECRET" }
    text reviewer_id? { description = "Identifier of the reviewer approving the item (required)" }
    text review_note? { description = "Reviewer note recorded on the approval event (required)" }
  }

  stack {
    function.run "deaq_authorize_and_log" {
      input = { endpoint: "POST /approvals/{approval_id}/approve", api_secret: $input.api_secret, requester_id: $input.reviewer_id }
    } as $log

    precondition ($input.reviewer_id != null && $input.reviewer_id != "") {
      error_type = "inputerror"
      error = "reviewer_id is required"
    }
    precondition ($input.review_note != null && $input.review_note != "") {
      error_type = "inputerror"
      error = "review_note is required"
    }

    function.run "deaq_resolve_approval" {
      input = { approval_id: $input.approval_id, decision: "approved", reviewer_id: $input.reviewer_id, review_note: $input.review_note }
    } as $resolved
  }

  response = {
    request_id: $log.request_id,
    approval_id: $resolved.approval.id,
    approval_status: $resolved.approval.approval_status,
    approval_event_id: $resolved.approval_event_id
  }
  guid = "9bq3WkGaHeYhcRIOXUaqNAGt5SU"
}
