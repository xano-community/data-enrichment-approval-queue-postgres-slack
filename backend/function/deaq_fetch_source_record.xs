function "deaq_fetch_source_record" {
  description = "Fetch one row from the external Postgres source by its external_record_id, using Xano's native external-Postgres query (db.external.postgres.direct_query) against $env.POSTGRES_CONNECTION_STRING. This is a real database connection and cannot be mocked the way api.request can, so it is credential-gated: with POSTGRES_CONNECTION_STRING configured it returns the live row; the import side that persists the row (deaq_ingest_source_record) is what tests drive directly. Expects a 'records' table whose primary lookup column is external_record_id (see the README's Required Postgres schema)."

  input {
    text external_record_id { description = "Primary-key value to look up in the external Postgres 'records' table" }
  }

  stack {
    db.external.postgres.direct_query {
      connection_string = $env.POSTGRES_CONNECTION_STRING
      sql = "SELECT * FROM records WHERE external_record_id = ? LIMIT 1"
      arg = [$input.external_record_id]
      response_type = "single"
    } as $row

    precondition ($row != null) {
      error_type = "notfound"
      error = "No source record found in Postgres for external_record_id " ~ $input.external_record_id
    }
  }

  response = $row
  guid = "0U5tWHiGAScjlW0IQaevLnkycFY"
}
