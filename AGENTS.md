# AGENTS.md — docuseal-pdf-api

Official DocuSeal Docker image (AGPL-3.0) plus an overlay that adds `POST /api/templates/pdf`
(create a signable template from a base64 PDF with field coordinates, DocuSeal Pro compatible).
Owner: Auto-i-DAT AG (GitHub MaherAID). Consumer: AutoContract (sibling repository).

## Architecture

| Part | Path | Notes |
|---|---|---|
| Base image | `Dockerfile` | `FROM docuseal/docuseal:<tag>@sha256:…`; guards (overlay adds only, routes hook present, attribution partial checksum), `COPY overlay/ /app/`, HEALTHCHECK `/up`. USER/ENTRYPOINT/CMD inherited. |
| Endpoint | `overlay/app/controllers/api/templates_pdf_controller.rb` | Inherits `Api::ApiBaseController` (X-Auth-Token, CanCanCan). |
| Validation | `overlay/lib/docuseal_pdf_api/{template_request,pdf_decoder,field_parser,area_parser,validation}.rb` | Collects all errors → `DocusealPdfApi::InvalidRequest` → 422 `{error, errors}`. |
| Creation | `overlay/lib/docuseal_pdf_api/template_builder.rb` | Upstream `Templates::CreateAttachments.handle_pdf_or_image`, builder defaults, page 1-based → 0-based. |
| Wiring | `overlay/config/initializers/docuseal_pdf_api.rb` | `ActiveSupport.on_load(:routes)` + prepended view path `vendor/docuseal_pdf_api/views`. |
| AGPL §13 | `overlay/vendor/docuseal_pdf_api/views/shared/_attribution.html.erb`, `overlay/app/controllers/docuseal_pdf_api/source_controller.rb`, `overlay/config/locales/docuseal_pdf_api.yml` | Upstream attribution unchanged + "Source code" link; `GET /source`. |
| Local stack | `docker-compose.yml` | `db` (postgres:16-alpine, no published port), `app` (127.0.0.1:${APP_PORT:-3080}); profile `test`: `webhook-receiver`, `e2e`. |
| E2E test | `tests/e2e/` | `run.sh` (orchestrator), `bootstrap.rb` (rails runner: account/admin/token/webhook), `test_e2e.py` + `testpdf.py` (stdlib only), `receiver.py`. |
| CI | `.github/workflows/ci.yml` | lint → trivy fs → build → e2e → trivy image → push GHCR on `main`. |

Upstream source for reading (not part of this repo): clone tag `3.3.3` into a temp dir, never
into OneDrive. Key upstream files: `config/routes.rb`, `app/controllers/api/api_base_controller.rb`,
`lib/templates/create_attachments.rb`, `lib/templates/process_document.rb`,
`lib/templates/serialize_for_api.rb`, `lib/send_webhook_request.rb`, `config/dotenv.rb`,
`config/puma.rb`, `lib/puma/plugin/*.rb`.

## Commands

```bash
tests/e2e/run.sh                 # build image + full e2e (Docker + bash only), ~3-5 min
E2E_KEEP=1 tests/e2e/run.sh      # keep stack (app on 127.0.0.1:3090), outputs in .e2e/out/
E2E_SKIP_APP_BUILD=1 IMAGE=… tests/e2e/run.sh   # test an existing image (CI)
scripts/lint.sh [--image]        # hadolint, shellcheck, actionlint, ruff, rubocop, trivy (pinned containers)
scripts/rubocop.sh [-a]          # rubocop only (local Ruby or container)
docker build -t docuseal-pdf-api:local .
docker compose up -d --build     # dev stack, needs .env (copy .env.example)
```

## Conventions

- Code, comments, docs, commits: English. Conventional Commits; every commit ends with the
  `Co-Authored-By` line requested by the owner.
- Overlay files only ADD to `/app`; never copy an upstream file into `overlay/` to edit it.
  Every overlay file carries the short AGPL/modified-version header.
- Ruby style = upstream RuboCop settings (`.rubocop.yml`, gems pinned to DocuSeal 3.3.3's
  versions in `Gemfile`). Python test code: ruff (`ruff.toml`), stdlib only.
- Pin everything: base images by digest, actions by commit SHA (`# vX.Y.Z`), pre-commit revs by SHA.
- Secrets only via environment; e2e secrets are generated per run into `.e2e/` (gitignored)
  and passed by environment. Never print tokens, passwords or webhook secrets.
- API changes need an update of README "API reference", `docs/adr/0003` (if semantics change)
  and the e2e test.

## Pitfalls

- Git Bash rewrites `/app/...` arguments to Windows paths → scripts set `MSYS_NO_PATHCONV=1`.
- Repo stores LF (`.gitattributes`); the global `core.autocrlf=true` would add CRLF elsewhere
  (an upstream clone made on Windows has CRLF – checksums then differ from the image).
- Upstream bump: if the Dockerfile guard reports a changed `_attribution.html.erb`, review the
  upstream diff, adapt the override, update the sha256. Upstream internals used by the overlay
  (`handle_pdf_or_image`, `SerializeForApi`, `Pdfium::Document.open_bytes`) can change.
- `python -I` hides sibling modules; the e2e runner uses `python -E -s` instead.
- The container starts as root by upstream design (Trivy DS-0002 accepted in `.trivyignore.yaml`).
- Trivy accepts two shadowed default-gem CVEs until 2026-12-31 (`.trivyignore.yaml`); re-check
  after every upstream bump.
- Signed file URLs expire after 40 min (`FILE_URLS_EXPIRE_MINUTES`); `APP_URL` decides their host.
- Embedded Redis/Sidekiq: jobs and webhook retries are lost when the container is replaced.
- `rails runner` inside the app container also runs pending migrations (upstream initializer).

## Backlog

`docs/BACKLOG.md` — status and acceptance criteria per item.
