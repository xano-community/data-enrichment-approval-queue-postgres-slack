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
