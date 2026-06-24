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
