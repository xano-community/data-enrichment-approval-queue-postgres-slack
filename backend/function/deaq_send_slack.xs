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
