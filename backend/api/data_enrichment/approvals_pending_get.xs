query "approvals/pending" verb=GET {
  api_group = "DataEnrichment"
  description = "List every approval_queue row whose approval_status is 'pending'. Requires API_AUTH_SECRET; writes an api_request_logs row on every call (before auth is checked, so rejected calls are still audited)."

  input {
    text api_secret? { description = "Shared secret, matched against $env.API_AUTH_SECRET" }
    text requester_id? { description = "Optional caller identifier, recorded in api_request_logs" }
  }

  stack {
    function.run "deaq_authorize_and_log" {
      input = { endpoint: "GET /approvals/pending", api_secret: $input.api_secret, requester_id: $input.requester_id }
    } as $log

    db.query "approval_queue" {
      where = $db.approval_queue.approval_status == "pending"
      sort = { created_at: "asc" }
      return = { type: "list" }
    } as $pending
  }

  response = { request_id: $log.request_id, count: ($pending|count), items: $pending }
  guid = "N8XehnSJKRlhN7Zaxf8LA_rFSZU"
}
