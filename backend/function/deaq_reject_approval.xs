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
