# ADR 0003: Semantics of POST /api/templates/pdf

- Status: accepted
- Date: 2026-10-20

## Context

The endpoint should be a drop-in for DocuSeal Pro's `POST /api/templates/pdf` (request and
response shape), but the Pro behaviour is only partly documented and some of it does not fit a
contract-signing use case. Facts from DocuSeal 3.3.3:

- Submissions copy the template's fields and schema lazily: only when the first signer saves
  values (or values/variables are prefilled at creation). Until then a pending submission
  renders the template's *current* documents.
- `POST /api/submissions` matches roles case-insensitively and falls back to the position of a
  submitter when the role is unknown.
- Field areas are stored relative to the rendered page (0..1, origin top-left); the API shows
  pages 0-based.

## Decisions

1. **`external_id` never updates an existing template.** Pro documents "Existing template with
   specified `external_id` will be updated with a new PDF". Doing that here would silently swap
   the document of pending submissions that nobody has started yet – for signed contracts a
   wrong document is worse than a duplicate. Every call creates a new template; clients can
   list versions with `GET /api/templates?external_id=…` and archive old ones with
   `DELETE /api/templates/:id`.
2. **Coordinates are relative (0..1) and validated.** Values outside 0..1, zero-sized areas and
   areas leaving the page are rejected with 422 instead of being clamped, so a client sending
   PDF points or pixels notices immediately. `page` is 1-based in requests.
3. **`file` must be base64.** Pro also accepts a URL that the server downloads; skipping that
   removes an SSRF surface and the dependency on outbound network access.
4. **No text tags.** `{{Field;role=…}}` tags are not parsed; at least one explicit field is
   required. `flatten` and `remove_tags` are accepted (must be booleans) and have no effect.
5. **Strict but complete validation.** Required: template name, document name, field name,
   type and role (Pro has defaults for some). All problems are reported in one 422 response
   (`error` = first message for compatibility, `errors` = all). Roles that differ only in case
   are rejected because submissions could not tell them apart.
6. **Same creation path as the UI.** Upstream's `Templates::CreateAttachments` stores the PDF
   (unchanged bytes, decrypted if it only had an owner password), extracts link annotations and
   renders previews; field defaults follow the upstream template builder. The response uses
   `Templates::SerializeForApi`, so it equals `GET /api/templates/:id`.
7. **Limits** (protect the single web process): 20 MB per decoded PDF (`PDF_API_MAX_FILE_MB`),
   request body 64 MB (`PDF_API_MAX_REQUEST_MB`, 413), 10 documents, 500 fields, 100 areas per
   field, 100 options per field.

## Consequences

- Clients written for Pro work if they send base64 files, relative coordinates and explicit
  fields; code relying on in-place updates via `external_id` must handle new template ids.
- Old templates accumulate unless the client archives them.
- Changing any of these decisions is a breaking API change and needs a new ADR.
