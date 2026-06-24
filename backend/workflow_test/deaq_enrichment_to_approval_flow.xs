workflow_test "deaq_enrichment_to_approval_flow" {
  description = "End-to-end outcome test against real workspace tables. Imports a source row (injected, standing in for the credential-gated Postgres fetch), enriches it with an injected mid-confidence provider payload that scores into needs_review, and asserts: score 50, classification needs_review, an approval_queue row created (pending), a 'created' approval_events row, the enrichment job marked succeeded, and that the needs_review branch invoked Slack (slack_notified true; Slack runs in dry_run under the test seam so the wiring is provable without live webhook credentials — the real POST mechanics are covered by deaq_send_slack's own unit test). Then approves the first item via deaq_resolve_approval (approved + 'approved' event), and rejects a second needs_review item with a note (rejected + 'rejected' event). The reject-with-EMPTY-note refusal is proven by deaq_reject_approval's own unit tests."

  stack {
    // 1. Import: drive the ingest side directly with an injected source row (the live Postgres
    //    fetch can't be mocked, so the workflow exercises the persistence path that /records/import
    //    runs after the fetch).
    function.call "deaq_ingest_source_record" {
      input = {
        external_record_id: "deaq-wf-record-1",
        source_payload: { name: "Beta LLC", domain: "beta.io" }
      }
    } as $ingested

    expect.to_be_defined ($ingested.source_record_id)
    expect.to_be_defined ($ingested.enrichment_job_id)
    expect.to_equal ($ingested.import_status) { value = "imported" }

    // 2. Enrich with an injected mid-confidence payload (company_name + domain present; industry and
    //    employee_count missing; confidence 0.6) -> score 50 -> needs_review.
    function.call "deaq_enrich_record" {
      input = {
        source_record_id: $ingested.source_record_id,
        enrichment_override: { company_name: "Beta LLC", domain: "beta.io", industry: "", employee_count: 0, confidence: 0.6 }
      }
    } as $enriched

    expect.to_equal ($enriched.score) { value = 50 }
    expect.to_equal ($enriched.classification) { value = "needs_review" }
    expect.to_not_be_null ($enriched.approval_queue_id)
    expect.to_be_true ($enriched.slack_notified)

    // The enriched record was persisted with the needs_review classification.
    db.get "enriched_records" {
      field_name = "id"
      field_value = $enriched.enriched_record_id
    } as $er
    expect.to_equal ($er.classification) { value = "needs_review" }

    // The approval_queue row exists and is pending.
    db.get "approval_queue" {
      field_name = "id"
      field_value = $enriched.approval_queue_id
    } as $aq
    expect.to_equal ($aq.approval_status) { value = "pending" }

    // A 'created' approval event was written when the item entered the queue.
    db.query "approval_events" {
      where = $db.approval_events.approval_queue_id == $enriched.approval_queue_id && $db.approval_events.event_type == "created"
      return = { type: "single" }
    } as $created_event
    expect.to_not_be_null ($created_event)

    // The enrichment job is now succeeded.
    db.get "enrichment_jobs" {
      field_name = "id"
      field_value = $ingested.enrichment_job_id
    } as $job
    expect.to_equal ($job.job_status) { value = "succeeded" }

    // 3. Approve via the resolve function (what POST /approvals/{id}/approve calls).
    function.call "deaq_resolve_approval" {
      input = { approval_id: $enriched.approval_queue_id, decision: "approved", reviewer_id: "wf-reviewer", review_note: "Verified manually" }
    } as $approved

    expect.to_equal ($approved.approval.approval_status) { value = "approved" }
    expect.to_be_defined ($approved.approval_event_id)

    // An 'approved' approval event was written.
    db.query "approval_events" {
      where = $db.approval_events.approval_queue_id == $enriched.approval_queue_id && $db.approval_events.event_type == "approved"
      return = { type: "single" }
    } as $approved_event
    expect.to_not_be_null ($approved_event)

    // 4. Reject path end-to-end: set up a second needs_review item and reject it WITH a note (what
    //    POST /approvals/{id}/reject calls). Assert it flips to rejected and writes a 'rejected'
    //    event. (The reject-with-EMPTY-note refusal is proven deterministically by deaq_reject_approval's
    //    own unit tests, which assert the empty/null note throws.)
    function.call "deaq_ingest_source_record" {
      input = {
        external_record_id: "deaq-wf-record-2",
        source_payload: { name: "Gamma Inc" }
      }
    } as $ingested2

    function.call "deaq_enrich_record" {
      input = {
        source_record_id: $ingested2.source_record_id,
        enrichment_override: { company_name: "Gamma Inc", domain: "gamma.io", industry: "", employee_count: 0, confidence: 0.6 }
      }
    } as $enriched2
    expect.to_equal ($enriched2.classification) { value = "needs_review" }

    function.call "deaq_reject_approval" {
      input = { approval_id: $enriched2.approval_queue_id, reviewer_id: "wf-reviewer", review_note: "Domain does not resolve" }
    } as $rejected

    expect.to_equal ($rejected.approval.approval_status) { value = "rejected" }

    db.query "approval_events" {
      where = $db.approval_events.approval_queue_id == $enriched2.approval_queue_id && $db.approval_events.event_type == "rejected"
      return = { type: "single" }
    } as $rejected_event
    expect.to_not_be_null ($rejected_event)

    // 5. Auth / governance path: every endpoint runs deaq_authorize_and_log FIRST, so a rejected
    //    request still leaves an api_request_logs row. Present a non-matching secret -> the gate
    //    throws accessdenied, and the log row it wrote beforehand is flipped to status 'error'.
    expect.to_throw {
      stack {
        function.run "deaq_authorize_and_log" {
          input = { endpoint: "POST /records/import", api_secret: "wrong-secret-value", requester_id: "intruder" }
        } as $denied
      }
      exception = "Invalid API auth secret"
    }

    // The denied request was still audited: an 'error' log row exists for that endpoint + requester.
    db.query "api_request_logs" {
      where = $db.api_request_logs.endpoint == "POST /records/import" && $db.api_request_logs.requester_id == "intruder" && $db.api_request_logs.status == "error"
      return = { type: "single" }
    } as $denied_log
    expect.to_not_be_null ($denied_log)
    expect.to_equal ($denied_log.error_message) { value = "Invalid API auth secret" }

    // And the allowed path (no secret presented, none configured in the test workspace) writes an
    // 'ok' log row and returns a request_id.
    function.call "deaq_authorize_and_log" {
      input = { endpoint: "GET /approvals/pending", requester_id: "wf-allowed" }
    } as $allowed
    expect.to_be_defined ($allowed.request_id)
    db.query "api_request_logs" {
      where = $db.api_request_logs.requester_id == "wf-allowed" && $db.api_request_logs.status == "ok"
      return = { type: "single" }
    } as $allowed_log
    expect.to_not_be_null ($allowed_log)
  }

  tags = ["deaq", "e2e", "outcome"]
  guid = "AKLJoMmfktFka3sO8aKHhfiZV7w"
}
