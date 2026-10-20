# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/) for the overlay. Images are additionally tagged with
the upstream DocuSeal version they are based on.

## [0.1.0] - 2026-10-20

Based on DocuSeal 3.3.3 (`docuseal/docuseal:3.3.3@sha256:28d0ca58…`).

### Added

- `POST /api/templates/pdf`: creates a template from base64 PDFs with explicit field areas
  (relative coordinates, 1-based pages), one submitter per role, upstream upload pipeline
  (storage, previews), response identical to `GET /api/templates/:id`, `template.created`
  webhook. Full validation with 422 `{error, errors}` and 413 for oversized bodies.
- AGPL-3.0 compliance: unmodified upstream `LICENSE` and `LICENSE_ADDITIONAL_TERMS`, `NOTICE`,
  "Source code (AGPL-3.0)" link below the unchanged DocuSeal attribution, `GET /source`.
- Docker image on top of the pinned upstream image with build-time guards and a health check.
- Local stack (`docker-compose.yml`, PostgreSQL 16) and an end-to-end test covering
  validation, template creation, submissions, signing page, API completion, HMAC-signed
  webhooks (`form.viewed`, `form.completed`, `form.declined`, `submission.completed`,
  `submission.expired`) and signed PDFs.
- CI with hadolint, ShellCheck, actionlint, ruff, RuboCop, Trivy (filesystem and image),
  end-to-end test and GHCR push on `main`; Dependabot and pre-commit configuration.
- Documentation: README (API and webhook reference), architecture, ADRs 0001–0003, webhook
  payload reference, AGENTS.md, backlog.
- Cloud Run storage recipe: default disk storage with a Cloud Storage FUSE volume at
  `/data/docuseal/attachments` (no service account key); the end-to-end test runs with that
  layout (separate mount owned by 2000:2000).

### Security

- The container runs as the unprivileged user `docuseal` (`USER 2000:2000`) instead of
  starting as root like upstream; `/data/docuseal` is owned by 2000 at build time and nothing
  changes ownership at boot. The end-to-end test asserts that Puma and `redis-server` run
  with uid 2000; the Trivy DS-0002 exception is gone.

[0.1.0]: https://github.com/MaherAID/docuseal-pdf-api/releases/tag/v0.1.0
