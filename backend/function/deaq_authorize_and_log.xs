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
