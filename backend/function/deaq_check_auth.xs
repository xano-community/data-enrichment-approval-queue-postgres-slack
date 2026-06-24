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
