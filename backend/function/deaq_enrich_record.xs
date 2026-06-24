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
