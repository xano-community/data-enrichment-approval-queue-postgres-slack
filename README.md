# Enterprise Data Enrichment and Approval Queue

A Xano module that turns your backend into the **centralized workflow layer** for enriching enterprise records and routing low-confidence records to human review. It imports records from an external **Postgres** database, enriches each one through a **generic REST enrichment provider**, scores and classifies the result with deterministic rules, and pushes records that land in the "needs review" band into a human **approval queue** with a **Slack** alert.

> **Honesty note — what is proven, and how.** The pure workflow logic (scoring, classification, the enrichment-job retry state machine, the approval state machine, the auth gate) is fully unit-tested in a throwaway Xano workspace (29 unit assertions) and the human-review outcome is proven end-to-end by a workflow test. No live credentials are used in CI, so the guarantee for the two outbound integration points is *"correct against the documented contract"* defined below — not a live-traffic guarantee. Specifically: the **Slack** webhook call carries a doc-derived `mock` (HTTP 200, body `ok`) and is unit-tested directly. The **enrichment provider** call is proven two ways — the `api.request` carries the same doc-derived `mock` for direct unit runs, and because that mock cannot fire when the call is reached through `function.run` inside the workflow test, the workflow proves the score → classify → queue → Slack chain with an **injected representative payload** matching the documented response contract (the live provider HTTP call is credential-gated, exactly like Postgres). The **Postgres** import uses Xano's native external-Postgres query (`db.external.postgres.direct_query`), which makes a real database connection and so cannot be mocked the way an HTTP call can — it is **credential-gated** and runs only when `POSTGRES_CONNECTION_STRING` is configured; the persistence half of the import (writing `source_records` + opening the enrichment job) is exercised end-to-end by the workflow test with an injected source row.

## 1. What this template demonstrates

- **Xano as the orchestration layer.** A single Xano workspace owns the whole pipeline: pull from Postgres → enrich over REST → score → classify → queue for review → record the human decision. No external workflow engine, no glue code in another runtime.
- **Deterministic, testable business logic.** Scoring, classification, the enrichment retry cap, and the approval state machine are pure Xano functions with exhaustive unit tests — they behave identically regardless of which provider or database is wired in.
- **Human-in-the-loop review.** Records the provider can't confidently enrich are routed to an `approval_queue`, surfaced through `GET /approvals/pending`, and resolved via approve/reject endpoints that write an immutable `approval_events` audit trail.
- **Operational hygiene.** Every endpoint is gated by a shared secret and writes an `api_request_logs` row; every enrichment attempt updates an `enrichment_jobs` row, and failed provider calls increment a capped attempt counter.

This is a **module**: a cohesive set of tables, functions, and five REST endpoints you drop into a Xano workspace. It is not a frontend app.

## 2. Required environment variables

Set these in your Xano workspace (Settings → Environment Variables). The code reads exactly these five names — no more, no fewer:

| Variable | Used by | Purpose |
| --- | --- | --- |
| `POSTGRES_CONNECTION_STRING` | `deaq_fetch_source_record` | Connection string for the external Postgres source database. |
| `ENRICHMENT_API_KEY` | `deaq_enrich_record` | Bearer token sent to the enrichment provider. |
| `ENRICHMENT_API_BASE_URL` | `deaq_enrich_record` | Base URL of the enrichment provider; the module calls `POST {ENRICHMENT_API_BASE_URL}/enrich`. |
| `SLACK_WEBHOOK_URL` | `deaq_send_slack` | Slack Incoming Webhook URL that needs-review alerts are POSTed to. |
| `API_AUTH_SECRET` | `deaq_authorize_and_log` → `deaq_check_auth` (every endpoint) | Shared secret required on every request via the `api_secret` field. |

Without `POSTGRES_CONNECTION_STRING`, `POST /records/import` cannot fetch source rows. Without `ENRICHMENT_API_KEY` / `ENRICHMENT_API_BASE_URL`, `POST /records/{record_id}/enrich` cannot call the provider. Without `SLACK_WEBHOOK_URL`, needs-review alerts cannot be delivered.

**Auth behavior.** When `API_AUTH_SECRET` is set (which you must do in production), every request's `api_secret` must match it exactly or the endpoint returns `403`. As a convenience for an unprovisioned workspace, when `API_AUTH_SECRET` is **not** set the gate is open only for requests that send **no** `api_secret`; a request that sends a non-matching secret is still rejected with `403`. Always set `API_AUTH_SECRET` so the gate is closed by default. Either way, the request is written to `api_request_logs` **before** auth is checked, so even a rejected request leaves an audit row (status `error`).

## 3. Required Postgres schema

`POST /records/import` looks the record up with:

```sql
SELECT * FROM records WHERE external_record_id = ? LIMIT 1
```

So the external Postgres database must expose a table named **`records`** with at least:

| Column | Type | Notes |
| --- | --- | --- |
| `external_record_id` | text / varchar | The primary lookup key passed to `POST /records/import`. Should be unique. |
| *(any other columns)* | any | The entire row is stored verbatim in `source_records.source_payload` and forwarded to the enrichment provider as `source`. |

A representative seed row for the demo:

```sql
CREATE TABLE records (
  external_record_id text PRIMARY KEY,
  company_name       text,
  domain             text,
  raw                jsonb
);

INSERT INTO records (external_record_id, company_name, domain)
VALUES ('acct-1001', 'Beta LLC', 'beta.io');
```

## 4. Required enrichment API contract

The enrichment provider is intentionally **generic**. To keep the integration honest and mockable, this module pins the exact request/response contract it expects. Any provider (or a thin adapter in front of one) that implements this contract will work.

**Request** — the module sends:

```
POST {ENRICHMENT_API_BASE_URL}/enrich
Authorization: Bearer {ENRICHMENT_API_KEY}
Content-Type: application/json

{
  "external_record_id": "acct-1001",
  "source": { ...the raw Postgres row... }
}
```

**Response** — the provider must return HTTP `200` with a JSON body shaped like:

```json
{
  "company_name": "Beta LLC",
  "domain": "beta.io",
  "industry": "Software",
  "employee_count": 250,
  "confidence": 0.92
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `company_name` | string \| null | Enriched company name. Treated as missing when null or `""`. |
| `domain` | string \| null | Enriched company domain. Treated as missing when null or `""`. |
| `industry` | string \| null | Enriched industry. Treated as missing when null or `""`. |
| `employee_count` | integer \| null | Enriched headcount. Treated as missing when null or `0`. |
| `confidence` | number (0..1) | Provider's confidence in the match. |

Any non-`200` response is treated as a failed attempt: it increments the job's `attempt_count` (capped at 3) and the call returns an error.

This is the contract the unit tests and the workflow test mock against. The representative success body above is the mock used for the "needs review" path (with `industry` and `employee_count` omitted to push the score into the 50–84 band).

## 5. Scoring rules

After a successful enrichment call, the response is scored **0..100**:

- Start at **100**.
- **−25** if `company_name` is missing (null or empty).
- **−25** if `domain` is missing.
- **−20** if `industry` is missing.
- **−15** if `employee_count` is missing (null or `0`).
- **−15** if the provider `confidence` is **below 0.75**.
- The final score is clamped to a **minimum of 0**.

Implemented in `deaq_score`, with a unit test for every individual deduction, the `confidence == 0.75` boundary, a combined mid-band case, and the min-0 clamp.

## 6. Classification rules

The score maps to exactly one classification (`deaq_classify`):

| Score | Classification |
| --- | --- |
| **≥ 85** | `approved_auto` |
| **50 – 84** | `needs_review` |
| **< 50** | `rejected_auto` |

Boundaries are unit-tested: 49 → `rejected_auto`, 50 → `needs_review`, 84 → `needs_review`, 85 → `approved_auto`.

## 7. Approval workflow

1. **Import** — `POST /records/import` pulls a row from Postgres into `source_records` and opens a `pending` row in `enrichment_jobs`.
2. **Enrich** — `POST /records/{record_id}/enrich` calls the provider, scores, and classifies:
   - `approved_auto` / `rejected_auto` → the result is stored in `enriched_records`; no human action.
   - `needs_review` → an `approval_queue` row is created (`approval_status = pending`), a `created` event is written to `approval_events`, and a **Slack alert** is sent to `SLACK_WEBHOOK_URL`. Slack is notified **only** for `needs_review`.
   - Every attempt updates the `enrichment_jobs` row. A failed provider call increments `attempt_count`; after **3** attempts the record cannot be retried.
3. **Review** — `GET /approvals/pending` lists open items.
4. **Resolve** — `POST /approvals/{approval_id}/approve` or `.../reject` flips `approval_status` and appends an `approved` / `rejected` row to `approval_events`. Rejection requires a non-empty `review_note`.

The six tables: `source_records`, `enriched_records`, `enrichment_jobs`, `approval_queue`, `approval_events`, `api_request_logs`.

## 8. Endpoint reference

All five endpoints belong to the `DataEnrichment` API group (canonical `deaq-data-enrichment`), require the `api_secret` field (matched against `API_AUTH_SECRET`), and write an `api_request_logs` row **before** auth is evaluated (so even a rejected request is audited). Each endpoint runs the shared `deaq_authorize_and_log` gate first.

| Method | Path | Body / query fields | Does |
| --- | --- | --- | --- |
| `POST` | `/records/import` | `api_secret`, `external_record_id`, `requester_id?` | Fetch the row from Postgres → `source_records`; open a `pending` `enrichment_jobs` row. |
| `POST` | `/records/{record_id}/enrich` | `api_secret`, `requester_id?` | Enrich, score, classify; on `needs_review` queue it + Slack-alert. |
| `GET` | `/approvals/pending` | `api_secret`, `requester_id?` | List all `approval_queue` rows with `approval_status = pending`. |
| `POST` | `/approvals/{approval_id}/approve` | `api_secret`, `reviewer_id`, `review_note` | Set `approval_status = approved`; write an `approved` event. |
| `POST` | `/approvals/{approval_id}/reject` | `api_secret`, `reviewer_id`, `review_note` (non-empty) | Set `approval_status = rejected`; write a `rejected` event. |

There are exactly these five endpoints — no batch enrichment, no AI, and no optional source systems.

## 9. Example requests

Replace `<base>` with your instance URL and `api:deaq-data-enrichment` with your group's canonical.

```sh
# 1. Import a record from Postgres
curl -X POST "<base>/api:deaq-data-enrichment/records/import" \
  -H "Content-Type: application/json" \
  -d '{"api_secret":"<API_AUTH_SECRET>","external_record_id":"acct-1001","requester_id":"importer-bot"}'

# 2. Enrich the imported record (use the source_record_id returned above)
curl -X POST "<base>/api:deaq-data-enrichment/records/12/enrich" \
  -H "Content-Type: application/json" \
  -d '{"api_secret":"<API_AUTH_SECRET>","requester_id":"enricher-bot"}'

# 3. List pending approvals
curl "<base>/api:deaq-data-enrichment/approvals/pending?api_secret=<API_AUTH_SECRET>"

# 4. Approve an item
curl -X POST "<base>/api:deaq-data-enrichment/approvals/5/approve" \
  -H "Content-Type: application/json" \
  -d '{"api_secret":"<API_AUTH_SECRET>","reviewer_id":"alice","review_note":"Verified against CRM"}'

# 5. Reject an item (review_note must not be empty)
curl -X POST "<base>/api:deaq-data-enrichment/approvals/5/reject" \
  -H "Content-Type: application/json" \
  -d '{"api_secret":"<API_AUTH_SECRET>","reviewer_id":"alice","review_note":"Domain does not resolve"}'
```

## 10. Example responses

```jsonc
// POST /records/import
{
  "request_id": "8f1c…",
  "source_record_id": 12,
  "enrichment_job_id": 12,
  "import_status": "imported"
}

// POST /records/{record_id}/enrich  — a needs_review outcome
{
  "request_id": "a90e…",
  "enriched_record_id": 34,
  "score": 50,
  "classification": "needs_review",
  "approval_queue_id": 7
}

// GET /approvals/pending
{
  "request_id": "c4d2…",
  "count": 1,
  "items": [
    {
      "id": 7,
      "source_record_id": 12,
      "enriched_record_id": 34,
      "approval_status": "pending",
      "review_reason": "Enrichment score 50 in manual-review band (50-84)",
      "assigned_to": null,
      "created_at": 1730000000000,
      "updated_at": 1730000000000
    }
  ]
}

// POST /approvals/{approval_id}/approve
{
  "request_id": "e771…",
  "approval_id": 7,
  "approval_status": "approved",
  "approval_event_id": 18
}

// POST /approvals/{approval_id}/reject  (empty review_note)
{
  "code": "ERROR_CODE_INPUT_ERROR",
  "message": "review_note is required and must not be empty when rejecting"
}
```

## 11. How Xano centralizes enrichment and review logic

Everything in this pipeline lives in one Xano workspace, and that is the point:

- **One source of truth for state.** `source_records`, `enrichment_jobs`, `enriched_records`, `approval_queue`, and `approval_events` are Xano tables. The status of any record — imported, enriched, queued, approved, rejected, how many enrichment attempts it has had — is queryable in one place, not spread across a database, a job runner, and a ticketing tool.
- **The integrations are thin and swappable.** Postgres is reached through Xano's native external-database query; the enrichment provider and Slack are plain `api.request` calls behind a pinned contract. The deterministic logic (`deaq_score`, `deaq_classify`, `deaq_next_job_state`, `deaq_resolve_approval`) never changes when you swap the provider or the database.
- **The human-in-the-loop is first-class.** Routing to review, the Slack alert, the pending list, and the approve/reject decisions with their audit trail are all endpoints and tables in the same workspace — so the "low-confidence record needs a human" path is modeled explicitly instead of bolted on.
- **Governance is built in.** A shared-secret gate on every endpoint, an `api_request_logs` row per request, a capped retry counter per job, and an append-only `approval_events` log give you traceability without extra infrastructure.

The result is a backend that imports, enriches, scores, routes, and records human decisions as one coherent workflow — which is exactly what Xano is for.

## License

MIT — see [LICENSE](./LICENSE).
