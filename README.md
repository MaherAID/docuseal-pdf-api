# docuseal-pdf-api

[DocuSeal](https://github.com/docusealco/docuseal) is an open source document signing
platform. Its free edition can send existing templates through the API, but it cannot create
a template from your own PDF with field positions – that endpoint (`POST /api/templates/pdf`)
is part of DocuSeal Pro.

**docuseal-pdf-api** is the official DocuSeal Docker image plus a small overlay that adds this
one endpoint. Everything else – signing UI, submissions API, webhooks, audit trail, PDF
signatures – is unmodified DocuSeal.

> **This is a modified version of DocuSeal.** DocuSeal is © 2023-2026 DocuSeal LLC and licensed under the
> GNU Affero General Public License v3.0 with an additional term under section 7(b) that
> requires keeping the original DocuSeal attribution in interactive user interfaces
> ([LICENSE](LICENSE), [LICENSE_ADDITIONAL_TERMS](LICENSE_ADDITIONAL_TERMS)). This project is
> distributed under the same terms. See [License and attribution](#license-and-attribution).

- Upstream: `docuseal/docuseal:3.3.3`
  (`sha256:28d0ca583860e2c73e5b068756023a93a325799a22da1f788355d566865dd051`,
  source tag [3.3.3](https://github.com/docusealco/docuseal/tree/3.3.3), commit `8f8f69f0bc6a`)
- Image: `ghcr.io/maheraid/docuseal-pdf-api:<upstream-version>` and `:<short-sha>`
- Source of this modified version: <https://github.com/MaherAID/docuseal-pdf-api>

## Contents

- [What the overlay changes](#what-the-overlay-changes)
- [License and attribution](#license-and-attribution)
- [Quickstart with Docker](#quickstart-with-docker)
- [Configuration](#configuration) and [running on Cloud Run](#running-on-google-cloud-run)
- [API reference: POST /api/templates/pdf](#api-reference-post-apitemplatespdf)
- [Webhooks](#webhooks) and [verifying signatures](#verifying-webhook-signatures)
- [Development workflow](#development-workflow)

## What the overlay changes

The image is `FROM docuseal/docuseal:<tag>@<digest>` plus files that are **added** to `/app`;
no upstream file is edited or replaced (the Dockerfile fails the build if one would be).

| Added file | Purpose |
|---|---|
| `app/controllers/api/templates_pdf_controller.rb` | `POST /api/templates/pdf` |
| `lib/docuseal_pdf_api.rb`, `lib/docuseal_pdf_api/*.rb` | request validation and template creation |
| `config/initializers/docuseal_pdf_api.rb` | routes (via the `:routes` load hook of `config/routes.rb`) and a prepended view path |
| `vendor/docuseal_pdf_api/views/shared/_attribution.html.erb` | renders the unchanged DocuSeal attribution and adds a "Source code (AGPL-3.0)" link below it |
| `app/controllers/docuseal_pdf_api/source_controller.rb` | `GET /source` redirects to the source of the running version |
| `config/locales/docuseal_pdf_api.yml` | label of the source link (14 languages) |

USER, ENTRYPOINT and CMD are inherited from upstream; the image only adds a `HEALTHCHECK` on
`/up`. Details and alternatives: [ADR 0001](docs/adr/0001-overlay-on-upstream-image.md).

## License and attribution

- License: GNU AGPL v3.0 ([LICENSE](LICENSE)) with DocuSeal's additional term under section
  7(b) ([LICENSE_ADDITIONAL_TERMS](LICENSE_ADDITIONAL_TERMS)). Both files are the unmodified
  upstream files.
- Modification notice: [NOTICE](NOTICE) lists what was changed and when.
- Attribution: the "Powered by DocuSeal – open source documents software" line and all other
  DocuSeal branding stay exactly as upstream renders them. The overlay only adds a link below
  it.
- Corresponding source (AGPL section 13): every page that shows the DocuSeal attribution (the
  signing form and its completed/declined/expired pages, start forms, submission previews)
  shows a "Source code (AGPL-3.0)" link; `GET /source` redirects to the same place for API
  clients. The link points to the exact commit the image was built from (OCI label
  `org.opencontainers.image.revision`); `SOURCE_CODE_URL` overrides it, e.g. for a fork.
  Reasoning: [ADR 0002](docs/adr/0002-agpl-source-offer.md).
- The corresponding source of the unmodified part is DocuSeal at tag `3.3.3`; the image also
  contains the Ruby source of both parts under `/app`.

If you run a further modified version, publish your source and point `SOURCE_CODE_URL` to it.

## Quickstart with Docker

Requirements: Docker with Compose v2.

```bash
cp .env.example .env
# fill in POSTGRES_PASSWORD and SECRET_KEY_BASE, e.g. with `openssl rand -hex 32` / `openssl rand -hex 64`
docker compose up -d --build
```

Open <http://localhost:3080>, complete the DocuSeal setup wizard (first account and admin
user) and create an API token under *Settings → API*. The database runs in the `db` service
(PostgreSQL 16, volume `pgdata`), uploaded files and the embedded Redis live in the
`docuseal-data` volume. The database port is not published.

```bash
docker compose ps        # app becomes "healthy" after migrations (first start ~30 s)
docker compose logs -f app
docker compose down      # add -v to delete all data
```

## Configuration

All configuration is done through environment variables of the upstream image (12-factor);
the overlay adds three optional ones.

| Variable | Required | Purpose |
|---|---|---|
| `DATABASE_URL` | yes (prod) | `postgresql://user:pass@host:5432/db`. Without it DocuSeal falls back to SQLite in `/data/docuseal`. |
| `SECRET_KEY_BASE` | yes | Rails secret **and** key material for encrypted columns (API tokens, webhook secrets, e-signature certificates). Must stay stable; if missing, upstream writes a random one to `/data/docuseal/docuseal.env`. |
| `ENCRYPTION_SECRET` | no | Separate key for encrypted columns instead of deriving it from `SECRET_KEY_BASE`. |
| `APP_URL` | yes | Public base URL, e.g. `https://sign.example.com`. Used for `embed_src`, file URLs, webhook payloads and emails. Without it the URL entered in the setup wizard is used. |
| `HOST` | no | Only used in DocuSeal's multitenant mode (and by upstream's Caddy example); single-tenant instances use `APP_URL`. |
| `FORCE_SSL` | behind TLS | Any non-empty value except `false` enables `assume_ssl` + `force_ssl` (HSTS, secure cookies). |
| `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_DOMAIN`, `SMTP_FROM`, `SMTP_AUTHENTICATION`, `SMTP_ENABLE_STARTTLS`, `SMTP_ENABLE_SSL`, `SMTP_ENABLE_TLS`, `SMTP_SSL_VERIFY` | no | Outgoing email. Setting `SMTP_ADDRESS` (even empty) switches to SMTP. Alternatively configure email in the UI (*Settings → Email*). |
| `GCS_BUCKET`, `GCS_PROJECT`, `GCS_CREDENTIALS` | no | Google Cloud Storage for documents (`GCS_CREDENTIALS` = service account JSON). |
| `S3_ATTACHMENTS_BUCKET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `S3_ENDPOINT` | no | S3 (or compatible) storage. Without GCS/S3/Azure, files go to `/data/docuseal/attachments`. |
| `REDIS_URL` | no | External Redis for Sidekiq. Unset: the image starts `redis-server` on 127.0.0.1:16379 and runs Sidekiq inside the Puma process. |
| `FILE_URLS_EXPIRE_MINUTES` | no | Lifetime of signed file URLs in API responses and webhooks (default 40). |
| `PORT` | no | Listen port (default 3000). |
| `PDF_API_MAX_FILE_MB` | no | Overlay: maximum decoded PDF size per document (default 20). |
| `PDF_API_MAX_REQUEST_MB` | no | Overlay: maximum request body of `POST /api/templates/pdf` (default 64, larger → 413). |
| `SOURCE_CODE_URL` | no | Overlay: target of the AGPL source link and `GET /source`. Default: the repository at the image's revision. |

Background jobs (webhooks, signed PDF generation, emails, expiry) run in Sidekiq inside the
Puma process. Without `REDIS_URL` the image starts its own `redis-server` (127.0.0.1:16379,
password derived from `SECRET_KEY_BASE`); Redis' default snapshots go to
`/data/docuseal/dump.rdb`, so queued jobs and scheduled retries survive restarts only if
`/data/docuseal` is persistent.

### Running on Google Cloud Run

Not yet validated in this project (see [backlog](docs/BACKLOG.md)); what the image needs:

- **Database:** Cloud SQL for PostgreSQL or Supabase via `DATABASE_URL` (Secret Manager).
  Note: if the host name contains `_`, upstream splits the URL into `DATABASE_HOST` etc.
- **Secrets:** `SECRET_KEY_BASE` (and optionally `ENCRYPTION_SECRET`) from Secret Manager;
  never let Cloud Run instances generate their own.
- **URL/TLS:** `APP_URL=https://<domain>`, `FORCE_SSL=true`.
- **Storage:** the container filesystem is ephemeral – configure `GCS_BUCKET`/`GCS_PROJECT`/
  `GCS_CREDENTIALS` (or S3).
- **Background jobs:** Sidekiq runs inside the web process. With the embedded Redis set
  `--no-cpu-throttling` (CPU always allocated), `--min-instances=1` and `--max-instances=1`;
  queued and scheduled jobs are lost on instance replacement. For more instances or durable
  retries use Memorystore (`REDIS_URL`, VPC connector).
- **Probes:** Cloud Run ignores the Docker `HEALTHCHECK`; configure an HTTP startup probe on
  `/up` with enough time for migrations on first start (they run automatically unless
  `RUN_MIGRATIONS=false`). Cloud Run sets `PORT=8080`, which the image honours.
- **Limits:** Cloud Run accepts at most 32 MiB per HTTP/1 request, i.e. PDFs up to roughly
  23 MB after base64 encoding. Give the service at least 1–2 GiB memory (PDF rendering).
- **Email:** `SMTP_*` variables (password from Secret Manager).

## API reference: POST /api/templates/pdf

Creates a template from a PDF and field areas, the same way the web upload does (same storage,
page previews and metadata), so it can be sent with the standard `POST /api/submissions`.

### Authentication

Header `X-Auth-Token: <API token>` (*Settings → API*), exactly like every other DocuSeal API
endpoint. Missing or unknown token → `401 {"error":"Not authenticated"}`. The user needs the
`create` permission on templates (every user of the account in the free edition).

### Request body

```jsonc
{
  "name": "Vertrag 4711",            // required, template name (max 255)
  "external_id": "contract-4711",   // optional, your id (string or integer, max 255)
  "folder_name": "AutoContract",    // optional, created if missing; "Parent / Child" for a subfolder
  "shared_link": false,             // optional, default false
  "flatten": false,                 // optional, accepted for Pro compatibility, no effect
  "remove_tags": true,              // optional, accepted for Pro compatibility, no effect
  "documents": [                    // required, 1..10 documents, in this order
    {
      "name": "Vertrag 4711",       // required, document name (".pdf" is appended for the file name)
      "file": "<base64 PDF>",       // required, base64 (a data:...;base64, prefix and line breaks are fine)
      "fields": [                   // optional per document, but at least one field in total
        {
          "name": "Unterschrift Kunde",   // required
          "type": "signature",            // required, see field types below
          "role": "Kunde",                // required, signer role
          "required": true,               // optional, default true (false for checkbox)
          "title": "Ihre Unterschrift",   // optional, shown instead of the name (Markdown)
          "description": "…",             // optional (Markdown)
          "options": ["A", "B"],          // select/radio/multiple only
          "preferences": { "font_size": 12, "align": "center", "format": "DD.MM.YYYY" },
          "validation": { "pattern": "[A-Z]{2}[0-9]+", "message": "…" },
          "areas": [                      // required, 1..100
            { "x": 0.10, "y": 0.75, "w": 0.35, "h": 0.08, "page": 2 }
          ]
        }
      ]
    }
  ]
}
```

**Coordinates.** `x`, `y`, `w`, `h` are fractions of the page as it is displayed (after
`/Rotate`), origin at the **top-left** corner, `x`/`w` relative to the page width and `y`/`h`
relative to the page height – the representation DocuSeal stores internally. The area must lie
on the page (`x + w ≤ 1`, `y + h ≤ 1`, `w`, `h` > 0). `page` is **1-based**; responses show
DocuSeal's internal 0-based index (`page: 2` in the request → `"page": 1` in the response).

Converting from PDF points (origin bottom-left) for a page of `W × H` points and a box whose
lower-left corner is `(left, bottom)` with size `width × height`:

```
x = left / W          y = (H - bottom - height) / H
w = width / W         h = height / H
```

Example A4 (595.28 × 841.89 pt), box 200 × 40 pt, 50 pt from the left and 100 pt from the top:
`x = 0.0840, y = 0.1188, w = 0.3360, h = 0.0475`.

**Roles.** Every distinct `role` becomes one template submitter (`{name, uuid}`) in order of
first appearance. Roles must not differ only in case (DocuSeal matches roles
case-insensitively). The signing order is decided later by `POST /api/submissions`
(`order: "preserved"` follows the order of the `submitters` array there).

**Field types** (DocuSeal's own list): `heading`, `text`, `signature`, `initials`, `date`,
`datenow`, `number`, `image`, `checkbox`, `multiple`, `file`, `radio`, `select`, `cells`,
`stamp`, `payment`, `phone`, `verification`, `kba`, `strikethrough`. Defaults match DocuSeal's
template builder: `stamp` and `strikethrough` are read-only, `datenow` is stored as a read-only
`date` filled with the signing date. `payment`, `phone` (SMS), `verification` and `kba` depend
on integrations that the free edition does not provide.

**Options.** `select` needs `options`. For `radio`/`multiple` every area shows one option:
give each area an `option` value, or pass exactly one entry in `options` per area. Values are
stored as DocuSeal options (`{value, uuid}`) and areas reference them via `option_uuid`.
`cells` areas accept `cell_w` (default as in the builder).

**Preferences/validation.** Only the keys documented for DocuSeal Pro are kept
(`font_size font_type font color background align valign format price currency mask reasons`
and `pattern message min max step`); others are ignored. Use `"format": "DD.MM.YYYY"` for Swiss
dates – the default follows the account locale.

### Response

`200` with the template, serialized exactly like `GET /api/templates/:id` (same serializer):

```json
{
  "id": 1, "slug": "GPHreVQS892Gjr", "name": "Vertrag 4711", "source": "api",
  "external_id": "contract-4711", "folder_id": 2, "folder_name": "AutoContract",
  "submitters": [ { "name": "Kunde", "uuid": "5bcb4cf0-…" }, { "name": "Auto-i-DAT", "uuid": "194961b7-…" } ],
  "schema": [ { "attachment_uuid": "0b573d1c-…", "name": "Vertrag 4711" } ],
  "fields": [
    { "uuid": "126ec117-…", "submitter_uuid": "5bcb4cf0-…", "name": "Unterschrift Kunde", "type": "signature",
      "required": true, "preferences": {},
      "areas": [ { "x": 0.1, "y": 0.75, "w": 0.35, "h": 0.08, "attachment_uuid": "0b573d1c-…", "page": 1 } ] }
  ],
  "documents": [ { "id": 1, "uuid": "0b573d1c-…", "url": "https://…/file/…/Vertrag%204711.pdf",
                   "preview_image_url": "https://…/file/…/0.png", "filename": "Vertrag 4711.pdf" } ],
  "preferences": {}, "variables_schema": {}, "shared_link": false, "archived_at": null,
  "author_id": 1, "author": { "id": 1, "email": "…", "first_name": "…", "last_name": "…" },
  "application_key": "contract-4711", "created_at": "…", "updated_at": "…"
}
```

A `template.created` webhook is sent as for uploads in the UI.

### Errors

| Status | When | Body |
|---|---|---|
| 401 | missing/unknown `X-Auth-Token` | `{"error":"Not authenticated"}` |
| 403 | no permission | `{"error":"Not authorized"}` |
| 413 | body larger than `PDF_API_MAX_REQUEST_MB` | `{"error":"Request body is too large"}` |
| 422 | invalid payload | `{"error":"<first problem>","errors":["<all problems>"]}` |

Validation covers: base64 decoding, `%PDF-` header, size limit (20 MB per file), readable and
not password-protected PDF, field type, non-empty name/role, areas inside the page, page within
the document's page count, option rules, limits (10 documents, 500 fields, 100 areas per field,
100 options). Nothing is stored when validation fails. Example:

```json
{
  "error": "documents[0].fields[1].areas[0].page must be an integer between 1 and 2 (pages of the document)",
  "errors": [
    "documents[0].fields[1].areas[0].page must be an integer between 1 and 2 (pages of the document)",
    "documents[0].fields[2].role is required and must be a non-empty string"
  ]
}
```

### Example

```bash
PDF_B64="$(base64 -w0 vertrag.pdf)"   # macOS: base64 -i vertrag.pdf
curl -sS -X POST "https://sign.example.com/api/templates/pdf" \
  -H "X-Auth-Token: $DOCUSEAL_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @- <<EOF
{
  "name": "Vertrag 4711",
  "external_id": "contract-4711",
  "folder_name": "AutoContract",
  "documents": [{
    "name": "Vertrag 4711",
    "file": "$PDF_B64",
    "fields": [
      {"name": "Datum Kunde", "type": "date", "role": "Kunde", "preferences": {"format": "DD.MM.YYYY"},
       "areas": [{"x": 0.10, "y": 0.20, "w": 0.30, "h": 0.04, "page": 1}]},
      {"name": "Unterschrift Kunde", "type": "signature", "role": "Kunde",
       "areas": [{"x": 0.10, "y": 0.75, "w": 0.35, "h": 0.08, "page": 2}]},
      {"name": "Unterschrift Auto-i-DAT", "type": "signature", "role": "Auto-i-DAT",
       "areas": [{"x": 0.55, "y": 0.75, "w": 0.35, "h": 0.08, "page": 2}]}
    ]
  }]
}
EOF
```

Then send it with the standard API:

```bash
curl -sS -X POST "https://sign.example.com/api/submissions" \
  -H "X-Auth-Token: $DOCUSEAL_API_TOKEN" -H "Content-Type: application/json" \
  -d '{"template_id": 1, "send_email": false, "order": "preserved",
       "submitters": [{"role": "Kunde", "email": "kunde@example.com"},
                      {"role": "Auto-i-DAT", "email": "vertrag@example.com"}]}'
```

Each returned submitter has a `slug` and an `embed_src` (`<APP_URL>/s/<slug>`) – the signing
link.

### Differences from the DocuSeal Pro endpoint

| Topic | DocuSeal Pro | docuseal-pdf-api |
|---|---|---|
| `documents[].file` | base64 or a downloadable URL | base64 only (no server-side downloads, no SSRF surface) |
| Coordinates | documented as "coordinates"/"pixel coordinates" | relative 0..1 (DocuSeal's internal format); values > 1 are rejected |
| `external_id` of an existing template | that template is updated with the new PDF | always creates a new template (updating in place would change pending submissions, [ADR 0003](docs/adr/0003-api-semantics.md)); find versions with `GET /api/templates?external_id=…` |
| Text tags `{{…}}`, `flatten`, `remove_tags` | supported | tags are not parsed (fields are required), both flags accepted without effect |
| `shared_link` default | `true` | `false` |
| Optional in Pro, required here | template `name`, document `name`, field `name`, `type`, `role` | – |
| Extras | – | type `datenow`, area `cell_w`, `errors` array in 422 responses, 413 for oversized bodies |

## Webhooks

Webhooks are unchanged DocuSeal 3.3.3 features. Summary (full reference with captured payloads
of every event: [docs/webhooks.md](docs/webhooks.md)):

- `POST` with `Content-Type: application/json`, `User-Agent: DocuSeal.com Webhook`, body
  `{"event_type", "timestamp", "data"}`; `form.*` events carry the submitter, `submission.*`
  events the submission as in `GET /api/submissions/:id`.
- Every request is signed: `X-Docuseal-Signature: <unix-ts>.<hex HMAC-SHA256>`; the per-endpoint
  secret (`whsec_…`) is shown in *Settings → Webhooks → Security → HMAC*. An optional static
  header (*Security → Secret*) can be added as well.
- Failed deliveries (network error, timeout 8 s connect / 15 s read, status ≥ 400) are retried
  after 1, 2, 4, 8 … minutes – 14 attempts for `form.completed`, 12 for the others.
- No ordering guarantee; de-duplicate on `(event_type, data.id, timestamp)`.

### Verifying webhook signatures

Compute `HMAC-SHA256(key = whole secret string incl. "whsec_", message = "<ts>.<raw body>")`,
compare in constant time with the hex part of the header and reject timestamps older than
5 minutes. Always use the raw body bytes, not re-serialized JSON.

TypeScript (Node):

```ts
import { createHmac, timingSafeEqual } from "node:crypto";

export function verifyDocusealSignature(
  secret: string, rawBody: Buffer, header: string | undefined, toleranceSeconds = 300,
): boolean {
  const match = /^(\d+)\.([0-9a-f]{64})$/.exec(header ?? "");
  if (!match) return false;
  const timestamp = Number(match[1]);
  if (Math.abs(Date.now() / 1000 - timestamp) > toleranceSeconds) return false;
  const expected = createHmac("sha256", secret).update(`${match[1]}.`).update(rawBody).digest();
  return timingSafeEqual(expected, Buffer.from(match[2], "hex"));
}
```

Python:

```python
import hashlib, hmac, time

def verify_docuseal_signature(secret: str, raw_body: bytes, header: str, tolerance: int = 300) -> bool:
    timestamp, _, signature = header.partition(".")
    if not timestamp.isdigit() or abs(time.time() - int(timestamp)) > tolerance:
        return False
    expected = hmac.new(secret.encode(), timestamp.encode() + b"." + raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)
```

Shell (debugging):

```bash
printf '%s.%s' "$TS" "$RAW_BODY" | openssl dgst -sha256 -hmac "$WHSEC" -hex
```

## Development workflow

```
overlay/                 files added to /app in the image (the actual modification)
Dockerfile               FROM docuseal/docuseal:<tag>@<digest> + guards + COPY overlay
docker-compose.yml       local stack (app + postgres:16-alpine); profile "test" for the e2e test
tests/e2e/               end-to-end test: run.sh, bootstrap.rb (rails runner), test_e2e.py, receiver.py
scripts/lint.sh          all lint/scan steps of CI in pinned containers
docs/                    architecture, ADRs, webhook reference, backlog
```

```bash
scripts/lint.sh            # hadolint, shellcheck, actionlint, ruff, rubocop, trivy fs
scripts/lint.sh --image    # + trivy scan of docuseal-pdf-api:local
tests/e2e/run.sh           # build + full end-to-end test (needs only Docker and bash)
E2E_KEEP=1 tests/e2e/run.sh   # keep the stack afterwards (app on 127.0.0.1:3090)
pre-commit install         # run the lint hooks on every commit
```

The end-to-end test creates an account, admin user (random password, never printed), API
token and webhook endpoint through `rails runner`, then checks authentication and validation
errors, template creation (fields, areas, page conversion, stored PDF, previews),
`GET /api/templates/:id`, submissions with two signers, the signing page (including the
attribution and source link), completion through `PUT /api/submitters/:id`, HMAC-signed
`form.viewed`, `form.completed`, `form.declined`, `submission.completed` and
`submission.expired` deliveries, the signed and digitally signed PDFs, and all option field
types.

CI (`.github/workflows/ci.yml`) runs lint → Trivy filesystem scan → image build → end-to-end
test → Trivy image scan, and pushes `ghcr.io/maheraid/docuseal-pdf-api:<short-sha>` and
`:<upstream-version>` on `main`.

### Updating DocuSeal

Dependabot proposes new `docuseal/docuseal` tags with their digest. CI then verifies that the
overlay still only adds files, that `config/routes.rb` still runs the `:routes` load hook and
that the wrapped attribution partial is unchanged (sha256 in the Dockerfile), and runs the
end-to-end test. If the partial changed upstream, review the change, adapt
`vendor/docuseal_pdf_api/views/shared/_attribution.html.erb` and update the checksum. Also
update the version in this README, `NOTICE` and the `CHANGELOG`.

More for contributors and coding agents: [AGENTS.md](AGENTS.md),
[architecture](docs/architecture.md), [ADRs](docs/adr), [backlog](docs/BACKLOG.md).
