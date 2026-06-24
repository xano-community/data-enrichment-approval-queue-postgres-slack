table "source_records" {
  auth = false

  schema {
    int id
    text external_record_id { description = "The primary-key value used to look the record up in the external Postgres source" }
    json source_payload { description = "The raw row fetched from Postgres, stored verbatim" }
    enum import_status?="imported" {
      description = "Lifecycle of the import for this source record"
      values = ["imported", "enriched", "failed"]
    }
    timestamp created_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree|unique", field: [{name: "external_record_id"}]}
    {type: "btree", field: [{name: "import_status"}]}
  ]
  guid = "1FTWUs4S-qT3KwFom8ntDw8oaKw"
}
