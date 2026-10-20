# Backlog

Status: `todo` / `doing` / `done` / `wontdo`. Each item lists measurable acceptance criteria.

## DPA-001 POST /api/templates/pdf on top of the official image — done

Goal: create a signable template from our own PDF with field coordinates in DocuSeal's free
edition, compatible with the DocuSeal Pro request/response.

- [x] Image `FROM docuseal/docuseal:3.3.3@sha256:28d0ca58…`, overlay adds files only, upstream
      ENTRYPOINT/CMD unchanged, HEALTHCHECK on `/up` (USER changed to 2000:2000 in DPA-007).
- [x] Authentication with `X-Auth-Token` via `Api::ApiBaseController`; `authorize!(:create, Template)`.
- [x] Body `{name, external_id?, folder_name?, shared_link?, documents[{name, file, fields[{name,
      type, role, required?, areas[{x,y,w,h,page}]}]}], flatten?, remove_tags?}`; pages 1-based in,
      0-based stored.
- [x] 422 for invalid base64, missing `%PDF-`, > 20 MB, unknown type, areas outside 0..1 or the
      page, page outside the document, empty role (all asserted by the e2e test).
- [x] Template created through `Templates::CreateAttachments` (previews exist), one submitter
      per role, fields with `submitter_uuid`, areas with `attachment_uuid`, schema entries.
- [x] Response equals `GET /api/templates/:id` (asserted field by field).
- [x] Routes registered via `ActiveSupport.on_load(:routes)`; build fails if the hook disappears.

## DPA-002 AGPL-3.0 compliance — done

- [x] Upstream `LICENSE` and `LICENSE_ADDITIONAL_TERMS` shipped unchanged (checksums equal the image).
- [x] README and `NOTICE` state the modification, date and source location.
- [x] DocuSeal attribution untouched; "Source code (AGPL-3.0)" link below it on signing pages
      and `GET /source` (asserted by the e2e test); decision in ADR 0002.

## DPA-003 Local stack and end-to-end test — done

- [x] `docker-compose.yml` with app + `postgres:16-alpine` + volumes, no port 5433, `.env.example`.
- [x] `tests/e2e/run.sh` builds, starts, bootstraps (rails runner, random password never
      printed), tests and tears down; passes locally (221 checks).
- [x] Webhooks of `form.viewed`, `form.completed`, `form.declined`, `submission.completed`,
      `submission.expired` received and HMAC-verified; signed documents are PDFs with a
      digital signature.
- [x] Runs with `/data/docuseal/attachments` on a separate mount owned by 2000:2000
      (`tests/e2e/compose.attachments-mount.yml`) and checks that documents are stored there.

## DPA-004 CI/CD — done (first GitHub run pending DPA-005)

- [x] `.github/workflows/ci.yml`: hadolint, ShellCheck, actionlint, ruff, RuboCop, Trivy fs
      (vuln/secret/misconfig), build, e2e, Trivy image, GHCR push on `main` with tags
      `<short-sha>` and `<upstream-version>`.
- [x] Actions pinned to commit SHAs, minimal permissions, concurrency with cancel-in-progress.
- [x] `.github/dependabot.yml` (docker, docker-compose, github-actions, bundler) and
      `.pre-commit-config.yaml` mirroring the lint job.
- [ ] Workflow green on GitHub (requires the repository, DPA-005).

## DPA-005 Publish the public repository — todo

- [ ] `gh repo create MaherAID/docuseal-pdf-api --public` with description and topics
      (docuseal, e-signature, agpl, docker), push `main`.
- [ ] CI green; image visible at `ghcr.io/maheraid/docuseal-pdf-api` (package set to public).
- [ ] Repository public before any instance is reachable by external signers (ADR 0002).

## DPA-006 Validate the Cloud Run deployment — todo

- [ ] Service (gen2 execution environment) with `APP_URL`, `FORCE_SSL=true`,
      `DATABASE_URL`/`SECRET_KEY_BASE` from Secret Manager and startup probe `/up`; image
      served from Artifact Registry.
- [ ] Storage: default disk storage with a Cloud Storage FUSE volume at
      `/data/docuseal/attachments` (mount options `uid=2000;gid=2000`), service account with
      `roles/storage.objectUser`, no `GCS_*` variables and no service account key (README recipe).
- [ ] Decision on background jobs: embedded Redis with CPU always allocated and exactly one
      instance, or Memorystore via `REDIS_URL`; documented in an ADR.
- [ ] e2e flow (template → submission → completion → webhook → documents) succeeds against the
      deployed service with a test account (no production data); uploaded and signed documents
      appear as objects in the bucket and survive a new revision.

## DPA-007 Run the container as non-root — done

Upstream starts as root and only switches the effective uid to 2000 (real and saved uid stay 0).
The owner's guideline asks for a non-root container.

- [x] Image runs with `USER 2000:2000`; `/data/docuseal` is owned by 2000:2000 (0750) at build
      time; ENTRYPOINT/CMD unchanged.
- [x] e2e passes and asserts that Puma (PID 1) and `redis-server` run with real, effective,
      saved and filesystem uid 2000.
- [x] Compatibility checked: volumes created by the upstream image work; `--user 0:0` restores
      upstream behaviour; an upstream-generated root-only `docuseal.env` needs
      `SECRET_KEY_BASE`/`DATABASE_URL` as environment variables or a one-time chown (README
      "Running as non-root", ADR 0001).
- [x] Trivy DS-0002 exception removed; misconfiguration scan has no findings.

## DPA-008 Keep the upstream corresponding source available — todo

- [ ] Mirror DocuSeal tag `3.3.3` (and every later base version) to an Auto-i-DAT controlled
      location linked from the README (AGPL section 6).

## DPA-009 Re-assess accepted Trivy findings — todo (due 2026-12-31)

- [ ] `.trivyignore.yaml` entries for CVE-2026-33210 and CVE-2026-42257 removed after an
      upstream image ships fixed Ruby default gems, or re-justified.
- [ ] HIGH CVE-2026-80212 (resolv 0.7.0, loaded by the app) fixed by an upstream bump.

## DPA-010 AutoContract integration — todo (in the AutoContract repository)

- [ ] AutoContract converts its field positions (PDF points) to relative coordinates and calls
      `POST /api/templates/pdf` + `POST /api/submissions`.
- [ ] Webhook endpoint verifies `X-Docuseal-Signature` on the raw body, de-duplicates and
      downloads signed documents within the 40-minute URL lifetime.

## DPA-011 linux/arm64 image — todo (optional)

- [ ] CI builds and pushes a multi-arch image (amd64 + arm64); e2e runs on amd64.

## DPA-012 In-place update via external_id (Pro semantics) — wontdo

Rejected in ADR 0003: replacing the PDF of an existing template would change pending
submissions. Re-open only with a design that protects pending submissions.
