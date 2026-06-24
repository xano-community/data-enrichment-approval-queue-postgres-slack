query "records/{record_id}/enrich" verb=POST {
  api_group = "DataEnrichment"
  description = "Enrich an imported source record: call the enrichment provider, compute its score, classify it, and (when needs_review) create an approval_queue row and send a Slack alert. Failed provider calls increment the job's attempt_count, capped at 3. Requires API_AUTH_SECRET; writes an api_request_logs row on every call (before auth is checked, so rejected calls are still audited)."

  input {
    int record_id {
      table = "source_records"
      description = "id of the source_records row to enrich"
    }
    text api_secret? { description = "Shared secret, matched against $env.API_AUTH_SECRET" }
    text requester_id? { description = "Optional caller identifier, recorded in api_request_logs" }
  }

  stack {
    function.run "deaq_authorize_and_log" {
      input = { endpoint: "POST /records/{record_id}/enrich", api_secret: $input.api_secret, requester_id: $input.requester_id }
    } as $log

    function.run "deaq_enrich_record" {
      input = { source_record_id: $input.record_id }
    } as $enriched
  }

  response = {
    request_id: $log.request_id,
    enriched_record_id: $enriched.enriched_record_id,
    score: $enriched.score,
    classification: $enriched.classification,
    approval_queue_id: $enriched.approval_queue_id
  }
  guid = "ndSbeHZCZbmUeS3XClemcm7ANpY"
}
