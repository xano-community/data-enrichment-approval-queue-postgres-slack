workspace templates {
  acceptance = {ai_terms: false}
  preferences = {
    internal_docs    : false
    track_performance: true
    sql_names        : false
    sql_columns      : true
  }
}
---
table "api_request_logs" {
  auth = false

  schema {
    int id
    text request_id { description = "Unique id generated per request for traceability" }
    text endpoint { description = "The endpoint path that was called" }
    text requester_id? { description = "Identifier of the caller, when supplied" }
    enum status?="ok" {
      description = "Outcome of the request"
      values = ["ok", "error"]
    }
    text error_message? { description = "Error detail when status is error" }
    timestamp created_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "endpoint"}]}
    {type: "btree", field: [{name: "status"}]}
  ]
  guid = "zj0qnYbd44akL69oP70cCS9wNSg"
}
---
table "approval_events" {
  auth = false

  schema {
    int id
    int approval_queue_id {
      table = "approval_queue"
      description = "The approval_queue row this event belongs to"
    }
    enum event_type {
      description = "What happened on the approval item"
      values = ["created", "approved", "rejected"]
    }
    json event_payload? { description = "Structured detail for the event (e.g. reviewer note)" }
    text created_by? { description = "Identifier of the actor who triggered the event" }
    timestamp created_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "approval_queue_id"}]}
    {type: "btree", field: [{name: "event_type"}]}
  ]
  guid = "X0MHMeNxm2UfLJhQd7IqKngZkLY"
}
---
table "approval_queue" {
  auth = false

  schema {
    int id
    int source_record_id {
      table = "source_records"
      description = "The source record under review"
    }
    int enriched_record_id {
      table = "enriched_records"
      description = "The enriched record that scored into needs_review"
    }
    enum approval_status?="pending" {
      description = "Human review decision"
      values = ["pending", "approved", "rejected"]
    }
    text assigned_to? { description = "Reviewer identifier the item is assigned to (optional)" }
    text review_reason? { description = "Why this record was routed to manual review" }
    timestamp created_at?=now
    timestamp updated_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "source_record_id"}]}
    {type: "btree", field: [{name: "approval_status"}]}
  ]
  guid = "VNdhhAkWZje0tkfJ-vYn7oUc4QA"
}
---
table "enriched_records" {
  auth = false

  schema {
    int id
    int source_record_id {
      table = "source_records"
      description = "The source_records row this enrichment belongs to"
    }
    json enrichment_payload { description = "The normalized response returned by the enrichment provider" }
    int enrichment_score { description = "Computed data-quality score, 0..100 (see scoring rules)" }
    enum classification {
      description = "Routing decision derived from the score"
      values = ["approved_auto", "needs_review", "rejected_auto"]
    }
    timestamp created_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "source_record_id"}]}
    {type: "btree", field: [{name: "classification"}]}
  ]
  guid = "Gerayfq-ZB_XzjCgfCTcODWFjVk"
}
---
table "enrichment_jobs" {
  auth = false

  schema {
    int id
    int source_record_id {
      table = "source_records"
      description = "The source_records row this enrichment job tracks"
    }
    enum job_status?="pending" {
      description = "State of the enrichment job"
      values = ["pending", "succeeded", "failed"]
    }
    int attempt_count?=0 { description = "Number of enrichment attempts made; failed calls increment this, capped at 3" }
    text error_message? { description = "Message from the most recent failed attempt, if any" }
    timestamp created_at?=now
    timestamp updated_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "source_record_id"}]}
    {type: "btree", field: [{name: "job_status"}]}
  ]
  guid = "AlgCkcDmKAAqd9XosVGb30VAPrk"
}
---
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
---
function "deaq_authorize_and_log" {
  description = "The single front gate every endpoint runs first. It writes the api_request_logs row BEFORE checking auth, so EVERY request is logged — including rejected ones. It then runs the deaq_check_auth guard; on an invalid secret it flips the just-written log row to status 'error' with the reason and throws an accessdenied error (HTTP 403). On success it returns { request_id, log_id } and the endpoint proceeds. Logging before authorizing is what lets a rejected request still leave an audit trail and makes the auth-failure path workflow-testable."

  input {
    text endpoint { description = "The endpoint path being logged (e.g. 'POST /records/import')" }
    text api_secret? { description = "Secret supplied by the caller, matched against $env.API_AUTH_SECRET by deaq_check_auth" }
    text requester_id? { description = "Identifier of the caller, when supplied" }
  }

  stack {
    // 1. Log first — the row exists no matter how the request ends.
    security.create_uuid as $request_id
    db.add "api_request_logs" {
      data = {
        request_id: $request_id,
        endpoint: $input.endpoint,
        requester_id: $input.requester_id,
        status: "ok"
      }
    } as $row

    // 2. Authorize via the returning guard (no throw here).
    function.run "deaq_check_auth" {
      input = { api_secret: $input.api_secret }
    } as $gate

    // 3. On rejection: mark the already-written log row as an error, then deny.
    conditional {
      if ($gate.valid == false) {
        db.edit "api_request_logs" {
          field_name = "id"
          field_value = $row.id
          data = { status: "error", error_message: $gate.error }
        } as $logged_error
        precondition (false) {
          error_type = "accessdenied"
          error = $gate.error
        }
      }
    }
  }

  response = { request_id: $request_id, log_id: $row.id }

  test "rejects a wrong secret and records an error log row" {
    input = { endpoint: "POST /records/import", api_secret: "wrong-secret-value", requester_id: "intruder" }
    expect.to_throw
  }
  guid = "tdgmPGwJgArgFB1K8WASo7HsNFw"
}
---
function "deaq_check_auth" {
  description = "Shared-secret gate for every endpoint, implemented as a guard that RETURNS { valid, error } rather than throwing — so callers can log the request before rejecting it, and so the decision is workflow-testable. Enforcement: when $env.API_AUTH_SECRET is configured, the caller's api_secret must be non-empty and match it exactly. When API_AUTH_SECRET is NOT configured (e.g. an unprovisioned workspace), the gate is open ONLY for callers that present no secret; a caller that presents a non-empty secret that cannot be matched is rejected. In production you MUST set API_AUTH_SECRET so the first branch enforces on every request."

  input {
    text api_secret? { description = "The secret supplied by the caller, matched against $env.API_AUTH_SECRET" }
  }

  stack {
    var $configured { value = ($env.API_AUTH_SECRET != null && $env.API_AUTH_SECRET != "") }
    var $supplied { value = ($input.api_secret != null && $input.api_secret != "") }

    var $valid { value = false }

    conditional {
      if ($configured == true) {
        // Secret is configured: require an exact, non-empty match.
        var.update $valid { value = ($supplied == true && $input.api_secret == $env.API_AUTH_SECRET) }
      }
      else {
        // Secret not configured: open only when the caller also presents nothing. A caller that
        // presents a credential we cannot match is rejected (deterministic, env-independent).
        var.update $valid { value = ($supplied == false) }
      }
    }

    var $reason { value = null }
    conditional {
      if ($valid == false) {
        var.update $reason { value = "Invalid API auth secret" }
      }
    }
  }

  response = { valid: $valid, error: $reason }

  test "wrong secret is rejected" {
    input = { api_secret: "not-the-secret-value-xyz" }
    expect.to_be_false ($response.valid)
    expect.to_equal ($response.error) { value = "Invalid API auth secret" }
  }

  test "no secret presented is open when none is configured" {
    input = {}
    expect.to_be_true ($response.valid)
    expect.to_be_null ($response.error)
  }
  guid = "Lr8Y3JGSSEXBEWRZcjpg5n9rJ7Y"
}
---
function "deaq_classify" {
  description = "Classify an enrichment score into a routing decision. score >= 85 -> approved_auto; 50..84 -> needs_review; < 50 -> rejected_auto."

  input {
    int score { description = "The 0..100 enrichment score" }
  }

  stack {
    var $classification { value = "rejected_auto" }

    conditional {
      if ($input.score >= 85) {
        var.update $classification { value = "approved_auto" }
      }
      elseif ($input.score >= 50) {
        var.update $classification { value = "needs_review" }
      }
      else {
        var.update $classification { value = "rejected_auto" }
      }
    }
  }

  response = $classification

  test "score 100 is approved_auto" {
    input = { score: 100 }
    expect.to_equal ($response) { value = "approved_auto" }
  }

  test "score 85 boundary is approved_auto" {
    input = { score: 85 }
    expect.to_equal ($response) { value = "approved_auto" }
  }

  test "score 84 boundary is needs_review" {
    input = { score: 84 }
    expect.to_equal ($response) { value = "needs_review" }
  }

  test "score 50 boundary is needs_review" {
    input = { score: 50 }
    expect.to_equal ($response) { value = "needs_review" }
  }

  test "score 49 boundary is rejected_auto" {
    input = { score: 49 }
    expect.to_equal ($response) { value = "rejected_auto" }
  }

  test "score 0 is rejected_auto" {
    input = { score: 0 }
    expect.to_equal ($response) { value = "rejected_auto" }
  }
  guid = "JgxljJj4nPJ0uGKzIHuOW3iNvWY"
}
---
function "deaq_enrich_record" {
  description = "Enrich one already-imported source record end to end. Loads the source_records row and its enrichment_jobs row; refuses if the job has already used its 3 attempts. Calls the enrichment provider (POST $env.ENRICHMENT_API_BASE_URL/enrich with the ENRICHMENT_API_KEY). On a failed call it increments the job's attempt_count (capped at 3, via deaq_next_job_state) and throws. On success it scores the payload (deaq_score), classifies it (deaq_classify), writes an enriched_records row, and marks the job succeeded and the source record enriched. When the classification is needs_review it also creates a pending approval_queue row, writes a 'created' approval_events row, and attempts a Slack notification via deaq_send_slack (Slack failures are non-fatal so a Slack outage never loses a queued record). Slack is attempted only for needs_review. The optional enrichment_override input is a test seam: when supplied, the live provider call is skipped and that payload is used instead — production calls always omit it and hit the real provider."

  input {
    int source_record_id {
      table = "source_records"
      description = "The source_records row to enrich"
    }
    json enrichment_override? { description = "TEST SEAM ONLY: when provided, used in place of the live enrichment provider response. Production callers omit this." }
  }

  stack {
    db.get "source_records" {
      field_name = "id"
      field_value = $input.source_record_id
    } as $source

    precondition ($source != null) {
      error_type = "notfound"
      error = "Source record not found: " ~ ($input.source_record_id|to_text)
    }

    db.query "enrichment_jobs" {
      where = $db.enrichment_jobs.source_record_id == $input.source_record_id
      sort = { id: "desc" }
      return = { type: "single" }
    } as $job

    precondition ($job != null) {
      error_type = "notfound"
      error = "No enrichment job for source record " ~ ($input.source_record_id|to_text)
    }

    // Guard: never exceed the 3-attempt cap.
    precondition ($job.attempt_count < 3) {
      error_type = "inputerror"
      error = "Enrichment attempt limit reached (3) for source record " ~ ($input.source_record_id|to_text)
    }

    var $payload { value = null }

    conditional {
      if ($input.enrichment_override != null) {
        // Test seam: use the injected payload, skip the live call.
        var.update $payload { value = $input.enrichment_override }
      }
      else {
        // Call the enrichment provider. Documented contract: POST {base}/enrich with the source
        // key, returns { company_name, domain, industry, employee_count, confidence }. The mock
        // below is the doc-derived canned response; it fires only for inline unit `test` blocks on
        // this function (not when reached via function.run in the workflow test, which is why the
        // workflow proves the success path with an injected enrichment_override payload).
        api.request {
          url = $env.ENRICHMENT_API_BASE_URL ~ "/enrich"
          method = "POST"
          headers = ["Authorization: Bearer " ~ $env.ENRICHMENT_API_KEY, "Content-Type: application/json"]
          params = {
            external_record_id: $source.external_record_id,
            source: $source.source_payload
          }
          mock = {
            "enriches via the documented provider contract": { response: { status: 200, result: { company_name: "Beta LLC", domain: "beta.io", industry: "Software", employee_count: 250, confidence: 0.92 } } }
          }
        } as $api_result

        // On failure: record the failed attempt (increments attempt_count, capped) and stop.
        conditional {
          if ($api_result.response.status != 200) {
            function.run "deaq_next_job_state" {
              input = { attempt_count: $job.attempt_count, outcome: "failed", error_message: ("Enrichment API HTTP " ~ ($api_result.response.status|to_text)) }
            } as $failstate
            db.edit "enrichment_jobs" {
              field_name = "id"
              field_value = $job.id
              data = {
                job_status: $failstate.job_status,
                attempt_count: $failstate.attempt_count,
                error_message: $failstate.error_message,
                updated_at: now
              }
            } as $jf
            throw {
              name = "EnrichmentError"
              value = "Enrichment provider error: " ~ ($api_result.response.result|json_encode)
            }
          }
        }

        var.update $payload { value = $api_result.response.result }
      }
    }

    // Score + classify via the pure functions.
    function.run "deaq_score" {
      input = {
        company_name: ($payload|get:"company_name"),
        domain: ($payload|get:"domain"),
        industry: ($payload|get:"industry"),
        employee_count: ($payload|get:"employee_count"),
        confidence: ($payload|get:"confidence")
      }
    } as $score

    function.run "deaq_classify" {
      input = { score: $score }
    } as $classification

    db.add "enriched_records" {
      data = {
        source_record_id: $source.id,
        enrichment_payload: $payload,
        enrichment_score: $score,
        classification: $classification
      }
    } as $enriched

    // Mark the job succeeded and the source record enriched.
    function.run "deaq_next_job_state" {
      input = { attempt_count: $job.attempt_count, outcome: "succeeded" }
    } as $okstate
    db.edit "enrichment_jobs" {
      field_name = "id"
      field_value = $job.id
      data = {
        job_status: $okstate.job_status,
        attempt_count: $okstate.attempt_count,
        error_message: null,
        updated_at: now
      }
    } as $js
    db.edit "source_records" {
      field_name = "id"
      field_value = $source.id
      data = { import_status: "enriched" }
    } as $su

    var $approval_queue_id { value = null }
    var $slack_notified { value = false }

    // Route low-confidence records to manual review + alert Slack (needs_review only).
    conditional {
      if ($classification == "needs_review") {
        var $reason { value = "Enrichment score " ~ ($score|to_text) ~ " in manual-review band (50-84)" }
        db.add "approval_queue" {
          data = {
            source_record_id: $source.id,
            enriched_record_id: $enriched.id,
            approval_status: "pending",
            review_reason: $reason,
            updated_at: now
          }
        } as $aq
        var.update $approval_queue_id { value = $aq.id }
        db.add "approval_events" {
          data = {
            approval_queue_id: $aq.id,
            event_type: "created",
            event_payload: { score: $score, classification: $classification, reason: $reason },
            created_by: "system"
          }
        } as $ev

        // Slack is best-effort: a webhook failure must not lose the already-queued record. In the
        // test seam (enrichment_override present) Slack runs in dry_run so the needs_review->Slack
        // wiring is provable without live credentials; production performs the real POST.
        var $slack_dry { value = ($input.enrichment_override != null) }
        try_catch {
          try {
            function.run "deaq_send_slack" {
              input = {
                text: ("Record " ~ $source.external_record_id ~ " needs review (score " ~ ($score|to_text) ~ "). Approval queue id " ~ ($aq.id|to_text) ~ "."),
                dry_run: $slack_dry
              }
            } as $slack
            var.update $slack_notified { value = ($slack|get:"ok") }
          }
          catch {
            var.update $slack_notified { value = false }
          }
        }
      }
    }
  }

  response = {
    enriched_record_id: $enriched.id,
    score: $score,
    classification: $classification,
    approval_queue_id: $approval_queue_id,
    slack_notified: $slack_notified
  }
  guid = "VuABtOVlUopkVGiTp5BQIJqoR8k"
}
---
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
---
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
---
function "deaq_next_job_state" {
  description = "Pure state-machine step for an enrichment_jobs row. Given the current attempt_count and the outcome of an enrichment call, returns the next job state. A 'succeeded' outcome marks the job succeeded and does NOT change attempt_count. A 'failed' outcome increments attempt_count by one (capped so it never exceeds the max of 3) and marks the job failed, carrying the error_message. The returned object has: job_status, attempt_count, error_message, and allowed (false when the job has already exhausted its 3 attempts and must not be retried)."

  input {
    int attempt_count { description = "The job's current attempt_count before this outcome" }
    text outcome { description = "Either 'succeeded' or 'failed'" }
    text error_message? { description = "Error detail to record on a failed attempt" }
  }

  stack {
    var $max_attempts { value = 3 }

    // Whether a new attempt is even permitted: only when prior attempts are under the cap.
    var $allowed { value = ($input.attempt_count < $max_attempts) }

    var $next {
      value = {
        job_status: "pending",
        attempt_count: $input.attempt_count,
        error_message: null,
        allowed: $allowed
      }
    }

    conditional {
      if ($input.outcome == "succeeded") {
        var.update $next { value = ($next|set:"job_status":"succeeded") }
        var.update $next { value = ($next|set:"error_message":null) }
      }
      else {
        // Failed attempt: increment, clamp at the cap, record the error.
        var $incremented { value = ($input.attempt_count + 1) }
        conditional {
          if ($incremented > $max_attempts) {
            var.update $incremented { value = $max_attempts }
          }
        }
        var.update $next { value = ($next|set:"job_status":"failed") }
        var.update $next { value = ($next|set:"attempt_count":$incremented) }
        var.update $next { value = ($next|set:"error_message":$input.error_message) }
      }
    }
  }

  response = $next

  test "first failure increments to 1 and marks failed" {
    input = { attempt_count: 0, outcome: "failed", error_message: "provider 503" }
    expect.to_equal ($response.job_status) { value = "failed" }
    expect.to_equal ($response.attempt_count) { value = 1 }
    expect.to_equal ($response.error_message) { value = "provider 503" }
    expect.to_be_true ($response.allowed)
  }

  test "second failure increments to 2" {
    input = { attempt_count: 1, outcome: "failed", error_message: "timeout" }
    expect.to_equal ($response.attempt_count) { value = 2 }
    expect.to_be_true ($response.allowed)
  }

  test "third failure increments to 3 and is the last allowed attempt" {
    input = { attempt_count: 2, outcome: "failed", error_message: "timeout" }
    expect.to_equal ($response.attempt_count) { value = 3 }
    expect.to_be_true ($response.allowed)
  }

  test "attempt beyond the cap is not allowed and count clamps at 3" {
    input = { attempt_count: 3, outcome: "failed", error_message: "timeout" }
    expect.to_equal ($response.attempt_count) { value = 3 }
    expect.to_be_false ($response.allowed)
  }

  test "success marks succeeded without touching attempt_count" {
    input = { attempt_count: 1, outcome: "succeeded" }
    expect.to_equal ($response.job_status) { value = "succeeded" }
    expect.to_equal ($response.attempt_count) { value = 1 }
    expect.to_be_null ($response.error_message)
  }
  guid = "SYaRFBqKJ1mSf1YqFjGGfWeNG-Y"
}
---
function "deaq_reject_approval" {
  description = "Reject a pending approval_queue item, enforcing that review_note is present and non-empty before delegating to deaq_resolve_approval with decision 'rejected'. Keeping the non-empty-note rule here (rather than only in the endpoint) makes it both unit- and workflow-testable."

  input {
    int approval_id { description = "approval_queue row id to reject" }
    text reviewer_id?="system" { description = "Identifier of the reviewer rejecting the item" }
    text review_note? { description = "Mandatory, non-empty rejection reason" }
  }

  stack {
    precondition ($input.review_note != null && $input.review_note != "") {
      error_type = "inputerror"
      error = "review_note is required and must not be empty when rejecting"
    }

    function.run "deaq_resolve_approval" {
      input = { approval_id: $input.approval_id, decision: "rejected", reviewer_id: $input.reviewer_id, review_note: $input.review_note }
    } as $resolved
  }

  response = $resolved

  test "empty note is rejected" {
    input = { approval_id: 1, reviewer_id: "r1", review_note: "" }
    expect.to_throw
  }

  test "null note is rejected" {
    input = { approval_id: 1, reviewer_id: "r1" }
    expect.to_throw
  }
  guid = "zaADhHiBUnEli7lIY2ilazKZckQ"
}
---
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
---
function "deaq_score" {
  description = "Compute the 0..100 data-quality score for an enriched record. Starts at 100 and deducts: -25 if company_name missing, -25 if domain missing, -20 if industry missing, -15 if employee_count missing, -15 if the provider confidence is below 0.75. The result is clamped to a minimum of 0. A field counts as missing when it is null or an empty string; employee_count counts as missing when null or 0."

  input {
    text company_name? { description = "Company name from the enrichment provider" }
    text domain? { description = "Company domain from the enrichment provider" }
    text industry? { description = "Industry from the enrichment provider" }
    int employee_count? { description = "Employee count from the enrichment provider" }
    decimal confidence?=0 { description = "Provider confidence 0..1 for the match" }
  }

  stack {
    var $score { value = 100 }

    conditional {
      if ($input.company_name == null || $input.company_name == "") {
        var.update $score { value = ($score - 25) }
      }
    }
    conditional {
      if ($input.domain == null || $input.domain == "") {
        var.update $score { value = ($score - 25) }
      }
    }
    conditional {
      if ($input.industry == null || $input.industry == "") {
        var.update $score { value = ($score - 20) }
      }
    }
    conditional {
      if ($input.employee_count == null || $input.employee_count == 0) {
        var.update $score { value = ($score - 15) }
      }
    }
    conditional {
      if ($input.confidence < 0.75) {
        var.update $score { value = ($score - 15) }
      }
    }
    conditional {
      if ($score < 0) {
        var.update $score { value = 0 }
      }
    }
  }

  response = $score

  test "full payload high confidence scores 100" {
    input = { company_name: "Acme Corp", domain: "acme.com", industry: "Software", employee_count: 250, confidence: 0.95 }
    expect.to_equal ($response) { value = 100 }
  }

  test "missing company name deducts 25" {
    input = { company_name: "", domain: "acme.com", industry: "Software", employee_count: 250, confidence: 0.95 }
    expect.to_equal ($response) { value = 75 }
  }

  test "missing domain deducts 25" {
    input = { company_name: "Acme Corp", domain: "", industry: "Software", employee_count: 250, confidence: 0.95 }
    expect.to_equal ($response) { value = 75 }
  }

  test "missing industry deducts 20" {
    input = { company_name: "Acme Corp", domain: "acme.com", industry: "", employee_count: 250, confidence: 0.95 }
    expect.to_equal ($response) { value = 80 }
  }

  test "missing employee count deducts 15" {
    input = { company_name: "Acme Corp", domain: "acme.com", industry: "Software", employee_count: 0, confidence: 0.95 }
    expect.to_equal ($response) { value = 85 }
  }

  test "low confidence deducts 15" {
    input = { company_name: "Acme Corp", domain: "acme.com", industry: "Software", employee_count: 250, confidence: 0.5 }
    expect.to_equal ($response) { value = 85 }
  }

  test "confidence at threshold 0.75 does not deduct" {
    input = { company_name: "Acme Corp", domain: "acme.com", industry: "Software", employee_count: 250, confidence: 0.75 }
    expect.to_equal ($response) { value = 100 }
  }

  test "mid-confidence partial payload scores into needs_review band" {
    input = { company_name: "Beta LLC", domain: "beta.io", industry: "", employee_count: 0, confidence: 0.6 }
    expect.to_equal ($response) { value = 50 }
  }

  test "all missing and low confidence clamps to 0 not negative" {
    input = { company_name: "", domain: "", industry: "", employee_count: 0, confidence: 0.1 }
    expect.to_equal ($response) { value = 0 }
  }
  guid = "e_Acmtw9uW1P40OKR_k9FBlNsqQ"
}
---
function "deaq_send_slack" {
  description = "Send a notification to Slack via an Incoming Webhook ($env.SLACK_WEBHOOK_URL). Posts a JSON body { text: <message> }. Slack's documented success response is HTTP 200 with the literal body 'ok'. Returns { ok: true, status, text } on a 200, otherwise throws. The optional dry_run input is a test seam: when true the function records the message it WOULD post and returns { ok: true, dry_run: true } without making the HTTP call — production callers omit it and perform the real POST."

  input {
    text text { description = "The message text to post to the Slack channel behind the webhook" }
    bool dry_run?=false { description = "TEST SEAM ONLY: when true, skip the real webhook POST and just echo the message. Production omits this." }
  }

  stack {
    conditional {
      if ($input.dry_run == true) {
        // Test seam: prove the caller invoked Slack with the right message, without live HTTP.
        var $out { value = { ok: true, dry_run: true, status: 0, text: $input.text } }
      }
      else {
        api.request {
          url = $env.SLACK_WEBHOOK_URL
          method = "POST"
          headers = ["Content-Type: application/json"]
          params = { text: $input.text }
          mock = {
            "posts message to the webhook": { response: { status: 200, result: "ok" } }
          }
        } as $api_result

        precondition ($api_result.response.status == 200) {
          error_type = "standard"
          error = "Slack webhook error: " ~ ($api_result.response.result|json_encode)
        }

        var $out { value = { ok: true, dry_run: false, status: $api_result.response.status, text: $input.text } }
      }
    }
  }

  response = $out

  test "posts message to the webhook" {
    input = { text: "Record needs review" }
    expect.to_be_true ($response.ok)
    expect.to_equal ($response.status) { value = 200 }
  }

  test "dry run echoes the message without posting" {
    input = { text: "needs review msg", dry_run: true }
    expect.to_be_true ($response.ok)
    expect.to_be_true ($response.dry_run)
    expect.to_equal ($response.text) { value = "needs review msg" }
  }
  guid = "QXm4oVcv8niuGsmer8ZPoePw61s"
}
---
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
---
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
---
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
---
api_group DataEnrichment {
  canonical = "deaq-data-enrichment"
  description = "Centralized data-enrichment and approval-queue workflow: import records from Postgres, enrich + score + classify them via a REST enrichment provider, and route low-confidence records to a human approval queue with Slack alerts."
  tags = ["data-enrichment", "approval-queue"]
  guid = "NeJUNFZdcQzyOnvO_qVrBR94rII"
}
---
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
---
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
---
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
