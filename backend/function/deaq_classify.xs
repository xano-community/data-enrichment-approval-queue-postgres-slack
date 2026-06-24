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
