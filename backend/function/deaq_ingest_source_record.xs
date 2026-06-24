function "deaq_ingest_source_record" {
  description = "Persist a fetched source row and open its enrichment job. Upserts source_records keyed on external_record_id (storing the raw payload, import_status 'imported'), then creates a pending enrichment_jobs row for it. This is the side of /records/import that is independent of the live Postgres fetch, so a workflow test can drive it directly with an injected source row. Returns the source_record id and the enrichment_job id."

  input {
    text external_record_id { description = "Primary-key value of the row in the external Postgres source" }
    json source_payload { description = "The raw row fetched from Postgres" }
  }

  stack {
    db.add_or_edit "source_records" {
      field_name = "external_record_id"
      field_value = $input.external_record_id
      data = {
        external_record_id: $input.external_record_id,
        source_payload: $input.source_payload,
        import_status: "imported"
      }
    } as $source

    db.add "enrichment_jobs" {
      data = {
        source_record_id: $source.id,
        job_status: "pending",
        attempt_count: 0,
        updated_at: now
      }
    } as $job
  }

  response = { source_record_id: $source.id, enrichment_job_id: $job.id, import_status: "imported" }

  test "ingest creates a source record and a pending job" {
    input = { external_record_id: "deaq-unit-ingest-1", source_payload: { name: "Acme", domain: "acme.com" } }
    expect.to_be_defined ($response.source_record_id)
    expect.to_be_defined ($response.enrichment_job_id)
    expect.to_equal ($response.import_status) { value = "imported" }
  }
  guid = "P2Szez2DblJsJN6DH_X1boNZbEk"
}
