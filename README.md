# Enterprise Data Enrichment and Approval Queue

Import records from an external Postgres database, enrich each one through a REST enrichment provider, score and classify the result automatically, and route only the low-confidence records to a human approval queue — with Slack alerts, retry limits, and a full audit trail.

Xano owns the pipeline and the judgment: what a record scores, whether it clears automatically or needs a human, who approved it, and when. Push it and the whole import → enrich → score → queue → resolve loop runs, with the external Postgres / enrichment / Slack calls doc-mocked so it works before you wire in credentials.

## Why this exists

Enrichment is easy to start and hard to trust. A script calls a provider, writes whatever comes back, and nobody notices when the provider returns half-empty rows or a low-confidence guess — until that bad data is three systems deep. The missing piece is judgment with a paper trail: score each result, auto-accept the clean ones, auto-reject the clearly bad ones, and put a human in the loop only for the uncertain middle.

This template is that pipeline. Records are imported from Postgres, enriched through a REST provider, and scored 0–100 by a deterministic rule set; the score maps to `approved_auto`, `needs_review`, or `rejected_auto`. Only `needs_review` items land in the approval queue and fire a Slack alert, so humans see the few records that actually need them. Every attempt is tracked (with a 3-try retry cap), every decision writes an event, and every API call is logged — so the enrichment your systems trust has a reconstructable history.

## How it works

1. **Import** — `POST /records/import` pulls a row from Postgres into `source_records` and opens a `pending` `enrichment_jobs` row.
2. **Enrich** — `POST /records/{record_id}/enrich` calls the provider, then **scores** (`deaq_score`) and **classifies** (`deaq_classify`):
   - **Score 0–100** starts at 100 and deducts for missing `company_name` / `domain` / `industry` / `employee_count` and for provider `confidence` below 0.75 (clamped ≥ 0).
   - **Classification** — score ≥ 85 → `approved_auto`, 50–84 → `needs_review`, < 50 → `rejected_auto`.
   - `approved_auto` / `rejected_auto` store the result in `enriched_records` with no human action. `needs_review` opens an `approval_queue` row, writes a `created` event, and sends a **Slack alert** (only for `needs_review`).
   - Every attempt updates `enrichment_jobs`; a failed provider call increments `attempt_count`, and after **3** attempts the record can't be retried.
3. **Review** — `GET /approvals/pending` lists open items.
4. **Resolve** — `approve` / `reject` flips `approval_status` and appends an event; rejection requires a non-empty `review_note`.

The scoring and classification are pure XanoScript functions (unit-tested at every boundary), so the rules are visible and adjustable in one place.

## Quick start

1. **Push the backend** to a Xano workspace (the CLI/agent flow below does this).
2. **Run the loop** — `POST /records/import` → `POST /records/{record_id}/enrich` → `GET /approvals/pending` → `approve` / `reject`.
3. **It runs before you wire credentials.** The Postgres fetch, enrichment call, and Slack alert are doc-mocked so the full flow exercises end-to-end; with `API_AUTH_SECRET` unset the auth check is a no-op. Set the [environment variables](#environment-variables) to connect your real Postgres, enrichment provider, and Slack workspace.

## API surface

All endpoints live in the `DataEnrichment` API group (canonical `deaq-data-enrichment`), take an `api_secret` field (matched against `API_AUTH_SECRET`), and write an `api_request_logs` row **before** auth is evaluated — so even a rejected request is audited (the shared `deaq_authorize_and_log` gate runs first).

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/records/import` | Fetch a row from Postgres → `source_records`; open a `pending` `enrichment_jobs` row. |
| `POST` | `/records/{record_id}/enrich` | Enrich, score, and classify; on `needs_review` queue it and Slack-alert. |
| `GET` | `/approvals/pending` | List `approval_queue` rows with `approval_status = pending`. |
| `POST` | `/approvals/{approval_id}/approve` | Set `approved`, write an `approved` event. |
| `POST` | `/approvals/{approval_id}/reject` | Set `rejected` (requires a note), write a `rejected` event. |

## Database Tables

- **source_records** — rows imported from Postgres, keyed by `external_record_id`.
- **enriched_records** — the stored enrichment result for auto-accepted/rejected records.
- **enrichment_jobs** — one job per record: status, score, classification, and `attempt_count` (3-try cap).
- **approval_queue** — the human review queue; one row per `needs_review` record (`approval_status`).
- **approval_events** — append-only audit trail of `created` / `approved` / `rejected` decisions.
- **api_request_logs** — one row per API call, written before auth so every request (even rejected) is audited.

## Testing

Run from a deployed workspace:
- **Unit tests** (`xano unit_test run_all`) — the scoring (`deaq_score`) and classification (`deaq_classify`) rules, with a case for every deduction, the `confidence == 0.75` and score boundary (49/50/84/85) edges, and the min-0 clamp.
- **Workflow test** (`xano workflow_test run_all`) — `deaq_enrichment_to_approval_flow`: import → enrich → a `needs_review` record lands in the queue → approve, asserting the statuses and event trail, against doc-mocked Postgres/enrichment/Slack.

## Environment variables

Set these to connect the real external systems. The flow runs without them (externals doc-mocked, auth no-op).

- `POSTGRES_CONNECTION_STRING` — connection string for the external Postgres the `import` step reads from.
- `ENRICHMENT_API_BASE_URL` — base URL of your REST enrichment provider.
- `ENRICHMENT_API_KEY` — API key for the enrichment provider.
- `SLACK_WEBHOOK_URL` — incoming-webhook URL alerts are posted to for `needs_review` records.
- `API_AUTH_SECRET` — shared secret every endpoint checks (via the `api_secret` field). When unset the check is a no-op so it runs out of the box; set it in production.

**Postgres source schema.** `POST /records/import` runs `SELECT * FROM records WHERE external_record_id = ?`, so the external Postgres must expose a `records` table with a unique `external_record_id` key — the rest of the row is stored in `source_records.source_payload` and forwarded to the enrichment provider. Minimal DDL to provision it:

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
