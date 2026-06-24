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
