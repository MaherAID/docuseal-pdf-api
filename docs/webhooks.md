# Webhooks of DocuSeal 3.3.3

Everything below is the unmodified behaviour of DocuSeal 3.3.3 (this project does not change
webhooks). It was read from the upstream source at tag `3.3.3` and confirmed by the
end-to-end test, which receives real deliveries and verifies every signature
(`tests/e2e/test_e2e.py`).

Source references (upstream repository, tag 3.3.3): `lib/send_webhook_request.rb`,
`lib/webhook_urls.rb`, `lib/webhook_urls/signatures.rb`, `app/models/webhook_url.rb`,
`app/jobs/send_*_webhook_request_job.rb`, `lib/submitters/serialize_for_webhook.rb`,
`lib/submissions/serialize_for_api.rb`.

## Configuration

A webhook endpoint is a `WebhookUrl` of an account (UI: *Settings → Webhooks*). It has

- `url` – any http(s) URL; self-hosted (non-multitenant) instances may also call private hosts;
- `events` – a subset of `form.viewed`, `form.started`, `form.completed`, `form.declined`,
  `submission.created`, `submission.completed`, `submission.expired`, `submission.archived`,
  `template.created`, `template.updated`, `template.archived`
  (new endpoints default to the four `form.*` events);
- `hmac_secret` – generated on creation: `whsec_` + Base64 of 24 random bytes. Shown in the UI
  under *Settings → Webhooks → (endpoint) → Security → HMAC*. There is no rotation in the UI;
  create a new endpoint to change it;
- `secret` – optional static header (name/value) under *Security → Secret*, sent verbatim with
  every request.

## Request

```
POST <url>
Content-Type: application/json
User-Agent: DocuSeal.com Webhook
X-Docuseal-Signature: <unix-timestamp>.<hex hmac-sha256>
<optional static secret header>
```

Body (always these three keys):

```json
{ "event_type": "form.completed", "timestamp": "2026-10-20T10:14:18.023Z", "data": { } }
```

- `timestamp` is the creation time of the event (ISO 8601, UTC). It stays the same for all
  retries of that event.
- `data` depends on the event (see [Payloads](#payloads)). There is no event id in the body.

Timeouts: 8 s to connect, 15 s to read the response. Any status below 400 counts as success
(redirects are not followed). Deliveries are not ordered: every event is its own background job.

## Signature (HMAC)

```
X-Docuseal-Signature: 1792498458.6f1c...e9a0
                      └─ timestamp ┘ └ hex(HMAC-SHA256(key = hmac_secret, message = "<timestamp>.<raw body>"))
```

- Algorithm: HMAC-SHA256, lowercase hex digest (64 characters).
- Key: the complete secret string including the `whsec_` prefix, as UTF-8 bytes (the Base64
  part is **not** decoded).
- Message: the decimal timestamp, a dot, then the raw request body exactly as received.
- The header timestamp is the time of *this* send attempt (it changes on retries); the body
  `timestamp` is the event time.
- DocuSeal's own verifier (`WebhookUrls::Signatures.verify`) accepts timestamps within ±300 s.
- Edge case: if the static secret header is named `X-Docuseal-Signature`, it replaces the HMAC
  header.

Verification recipes are in the [README](../README.md#verifying-webhook-signatures).

## Retries

On a network error, timeout or HTTP status >= 400 the job schedules the next attempt
`2^attempt` minutes later (attempt starts at 0): 1, 2, 4, 8, ... minutes.

| Event | Attempts in total | Last retry after |
|---|---|---|
| `form.completed` | 14 (initial + 13 retries) | about 5.7 days |
| every other event | 12 (initial + 11 retries) | about 34 hours |

Retries are skipped once the event was delivered successfully (state kept per endpoint and
event in `webhook_events` / `webhook_attempts`, visible under *Settings → Webhooks → (endpoint)*,
where single events can also be re-sent manually). Scheduled retries live in Redis; with the
embedded Redis of the image they are lost when the container is replaced.

Recommended receiver behaviour: verify the signature, answer `2xx` quickly, process
asynchronously, and de-duplicate on `(event_type, data.id, timestamp)`.

## Payloads

### `form.viewed`, `form.started`, `form.completed`, `form.declined`

`data` is a submitter (`Submitters::SerializeForWebhook`). Captured `form.completed` of the
first signer (URLs shortened):

```json
{
  "event_type": "form.completed",
  "timestamp": "2026-10-20T10:14:18.023Z",
  "data": {
    "id": 1,
    "submission_id": 1,
    "email": "kunde@example.com",
    "phone": null,
    "name": "Max Muster",
    "ua": null,
    "ip": null,
    "sent_at": null,
    "opened_at": "2026-10-20T10:14:15.295Z",
    "completed_at": "2026-10-20T10:14:16.637Z",
    "declined_at": null,
    "created_at": "2026-10-20T10:14:14.452Z",
    "updated_at": "2026-10-20T10:14:16.663Z",
    "external_id": null,
    "metadata": {},
    "status": "completed",
    "application_key": null,
    "decline_reason": null,
    "role": "Kunde",
    "preferences": { "send_email": false, "send_sms": false },
    "values": [
      { "field": "Datum Kunde", "value": "2026-10-20" },
      { "field": "Unterschrift Kunde", "value": "https://sign.example.com/file/<signed-id>/signature.png" }
    ],
    "documents": [
      { "name": "Vertrag 4711", "url": "https://sign.example.com/file/<signed-id>/Vertrag%204711.pdf" },
      { "name": "AGB", "url": "https://sign.example.com/file/<signed-id>/AGB.pdf" }
    ],
    "audit_log_url": null,
    "submission_url": "https://sign.example.com/e/<submission-slug>",
    "template": {
      "id": 1, "name": "E2E Vertrag 4711", "external_id": "contract-4711",
      "created_at": "2026-10-20T10:14:12.133Z", "updated_at": "2026-10-20T10:14:12.778Z",
      "folder_name": "E2E"
    },
    "submission": {
      "id": 1,
      "audit_log_url": null,
      "combined_document_url": null,
      "status": "completed",
      "url": "https://sign.example.com/e/<submission-slug>",
      "variables": {},
      "created_at": "2026-10-20T10:14:14.435Z"
    }
  }
}
```

Differences between the four events (same keys every time):

| Event | Trigger | Typical values |
|---|---|---|
| `form.viewed` | signing page reports a view (`POST /s/:slug/view`, or `POST /api/submitter_form_views` from the embedded form) | `status: "opened"`, `opened_at` set, `values: []`, `documents: []` |
| `form.started` | signer saves the first step in the form (not sent for API completion) | `status: "opened"`, partial `values` |
| `form.completed` | signer finished (form or `PUT /api/submitters/:id` with `completed: true`) | `status: "completed"`, all `values`, signed `documents`; `audit_log_url` only for the last signer |
| `form.declined` | signer declined (`POST /s/:slug/decline`) | `status: "declined"`, `declined_at` and `decline_reason` set, `submission.status: "declined"` |

Notes:

- Signature, initials, image, stamp, payment and kba values are URLs to the stored image,
  file fields an array of URLs; other values are plain JSON values.
- `ua`/`ip` stay `null` when the signer was completed through the API.
- `submission.status` reflects the state when the job runs, not when the event happened (the
  captured `form.completed` of the first signer already says `completed` because the second
  signer finished before the delivery).
- File URLs use `APP_URL` as host and are signed with an expiry of 40 minutes
  (`FILE_URLS_EXPIRE_MINUTES`; the account setting for download link expiry can switch it off).
  Download the documents when the webhook arrives, or request fresh URLs later with
  `GET /api/submissions/:id/documents`.

### `submission.created`, `submission.completed`, `submission.expired`

`data` is a submission (`Submissions::SerializeForApi`, the same shape as
`GET /api/submissions/:id`). Captured `submission.completed` (submitters shortened):

```json
{
  "event_type": "submission.completed",
  "timestamp": "2026-10-20T10:14:19.915Z",
  "data": {
    "id": 1,
    "name": null,
    "slug": "<submission-slug>",
    "source": "api",
    "submitters_order": "preserved",
    "expire_at": null,
    "created_at": "2026-10-20T10:14:14.435Z",
    "updated_at": "2026-10-20T10:14:19.791Z",
    "archived_at": null,
    "submitters": [
      {
        "id": 1, "slug": "<submitter-slug>", "uuid": "<role-uuid>", "name": "Max Muster",
        "email": "kunde@example.com", "phone": null,
        "completed_at": "2026-10-20T10:14:16.637Z", "declined_at": null, "external_id": null,
        "submission_id": 1, "metadata": {}, "opened_at": "2026-10-20T10:14:15.295Z", "sent_at": null,
        "created_at": "2026-10-20T10:14:14.452Z", "updated_at": "2026-10-20T10:14:16.663Z",
        "status": "completed", "application_key": null,
        "values": [ { "field": "Datum Kunde", "value": "2026-10-20" } ],
        "documents": [ { "name": "Vertrag 4711", "url": "https://sign.example.com/file/<signed-id>/Vertrag%204711.pdf" } ],
        "preferences": { "send_email": false, "send_sms": false },
        "role": "Kunde"
      }
    ],
    "template": {
      "id": 1, "name": "E2E Vertrag 4711", "external_id": "contract-4711",
      "created_at": "2026-10-20T10:14:12.133Z", "updated_at": "2026-10-20T10:14:12.778Z",
      "folder_name": "E2E"
    },
    "created_by_user": { "id": 1, "email": "admin@example.com", "first_name": "E2E", "last_name": "Admin" },
    "variables": {},
    "submission_events": [
      { "id": 1, "submitter_id": 1, "event_type": "view_form", "event_timestamp": "2026-10-20T10:14:15.351Z", "data": {} },
      { "id": 2, "submitter_id": 1, "event_type": "api_complete_form", "event_timestamp": "2026-10-20T10:14:16.725Z", "data": {} }
    ],
    "documents": [
      { "name": "Vertrag 4711", "url": "https://sign.example.com/file/<signed-id>/Vertrag%204711.pdf" },
      { "name": "AGB", "url": "https://sign.example.com/file/<signed-id>/AGB.pdf" }
    ],
    "audit_log_url": "https://sign.example.com/file/<signed-id>/Audit%20Log%20-%20E2E%20Vertrag%204711.pdf",
    "combined_document_url": null,
    "status": "completed",
    "completed_at": "2026-10-20T10:14:17.218Z"
  }
}
```

| Event | Trigger | Typical values |
|---|---|---|
| `submission.created` | submission created (API, UI, shared link) | `status: "pending"`, `documents: []`, `audit_log_url: null` |
| `submission.completed` | last signer completed | `status: "completed"`, `completed_at`, signed `documents` (of the last signer, i.e. with all signatures), `audit_log_url` |
| `submission.expired` | `expire_at` passed (scheduled job; skipped if completed, declined or archived) | `status: "expired"`, `completed_at: null`, `documents: []` |

`combined_document_url` is only filled when the account setting "combine PDF result" is on.

### `template.created`, `template.updated`, `submission.archived`, `template.archived`

`template.created`/`template.updated` send the template as returned by
`GET /api/templates/:id` (`POST /api/templates/pdf` triggers `template.created`). The two
`*.archived` events send only `{ "id": ..., "archived_at": ... }`.
