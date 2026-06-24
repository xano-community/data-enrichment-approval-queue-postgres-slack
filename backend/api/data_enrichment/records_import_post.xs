query "records/import" verb=POST {
  api_group = "DataEnrichment"
  description = "Import one record from the external Postgres source into source_records and open a pending enrichment job. Looks the row up by external_record_id in Postgres, stores its payload, and creates an enrichment_jobs row with status 'pending'. Requires API_AUTH_SECRET; writes an api_request_logs row on every call (before auth is checked, so rejected calls are still audited)."

  // api_secret and external_record_id are declared optional at the platform layer so blank/invalid
  // values reach the stack — the request is logged first, then the auth gate (deaq_authorize_and_log)
  // and the required-field guard produce a governed 403/400 instead of a generic platform rejection.
  input {
    text api_secret? { description = "Shared secret, matched against $env.API_AUTH_SECRET" }
    text external_record_id? { description = "Primary-key value of the row to import from Postgres (required)" }
    text requester_id? { description = "Optional caller identifier, recorded in api_request_logs" }
  }

  stack {
    function.run "deaq_authorize_and_log" {
      input = { endpoint: "POST /records/import", api_secret: $input.api_secret, requester_id: $input.requester_id }
    } as $log

    precondition ($input.external_record_id != null && $input.external_record_id != "") {
      error_type = "inputerror"
      error = "external_record_id is required"
    }

    function.run "deaq_fetch_source_record" {
      input = { external_record_id: $input.external_record_id }
    } as $row

    function.run "deaq_ingest_source_record" {
      input = { external_record_id: $input.external_record_id, source_payload: $row }
    } as $ingested
  }

  response = {
    request_id: $log.request_id,
    source_record_id: $ingested.source_record_id,
    enrichment_job_id: $ingested.enrichment_job_id,
    import_status: $ingested.import_status
  }
  guid = "9Mq_XRiggWoOakOnT1WwH3Ltkac"
}
