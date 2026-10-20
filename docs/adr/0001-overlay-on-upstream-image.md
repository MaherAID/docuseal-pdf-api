# ADR 0001: Overlay on the official DocuSeal image

- Status: accepted
- Date: 2026-10-20
- Deciders: Auto-i-DAT AG (owner approval to build and publish under AGPL-3.0)

## Context

AutoContract renders its own contract PDFs and needs DocuSeal to turn such a PDF plus known
field positions into a signable template. The free DocuSeal edition has no API for that
(`POST /api/templates/pdf` is a Pro feature). DocuSeal is AGPL-3.0 licensed, so a modified
version may be run and published under the same license.

Constraints: follow upstream releases (weekly) with little effort, keep the upstream signing
UI, webhooks and storage behaviour, keep the DocuSeal attribution (section 7(b) term), and stay
deployable as one container (Cloud Run).

Facts at tag 3.3.3 (verified in the source and image):

- `config/routes.rb` ends its draw block with `ActiveSupport.run_load_hooks(:routes, self)`;
  an initializer can add routes with `ActiveSupport.on_load(:routes)`.
- `config.autoload_lib` autoloads `lib/`; files added to `app/` and `lib/` are picked up by
  Zeitwerk and eager loading without touching any upstream file.
- The web upload uses `Templates::CreateAttachments` → `Templates::ProcessDocument` (stores the
  blob, PDF metadata, page previews); `Templates::SerializeForApi` renders `GET /api/templates/:id`.
- The image has no `USER`: it starts as root, `config/dotenv.rb` chowns `/data/docuseal` to
  2000:2000 and switches the effective uid/gid to 2000 before the app boots.

## Options

1. **Fork DocuSeal and build the image from source.** Full control, but every upstream release
   must be merged, the JavaScript build adds ~10 minutes per image, and our Dockerfile drifts
   from upstream's.
2. **Overlay: `FROM docuseal/docuseal:<tag>@<digest>` + added files only.** A few hundred lines
   of Ruby, builds in seconds, upgrades are a digest bump. Depends on upstream internals
   (service objects, serializer, load hook) that may change.
3. **Separate service writing into DocuSeal's database/storage.** No change to the image, but
   it would duplicate upload processing (preview images, metadata), bypass model callbacks and
   break silently on schema changes.

## Decision

Option 2. The overlay adds files under `/app` (controller, `lib/docuseal_pdf_api/`, an
initializer, a locale file, one partial in a prepended view path) and reuses the upstream
services, ability checks, API base controller and serializer. USER, ENTRYPOINT and CMD stay as
upstream defines them; the image only adds a `HEALTHCHECK` on `/up` (upstream has none; `wget`
is available in the Alpine base).

Upgrade safety is enforced at build time: the Dockerfile fails if an overlay file would
replace an upstream file, if `config/routes.rb` no longer runs the `:routes` load hook, or if
the wrapped attribution partial changed (sha256). Behaviour is enforced by the end-to-end test,
which every Dependabot bump has to pass.

## Consequences

- Positive: tiny diff to audit, fast builds, upstream fixes arrive with a digest bump, the
  corresponding source is easy to identify (upstream tag + this repository).
- Negative: internal upstream APIs (`Templates::CreateAttachments.handle_pdf_or_image`,
  `Templates::SerializeForApi`, `Pdfium::Document`) are not a public contract; a refactoring
  upstream breaks the build or the end-to-end test and needs a code change here.
- The container still starts as root (upstream design; it drops to uid 2000 in-process, but
  the real uid stays 0). Trivy rule DS-0002 is accepted in `.trivyignore.yaml`; running with
  `USER 2000` is tracked in the backlog because it changes the ownership handling of existing
  volumes and bind mounts.
- Images are built for linux/amd64 only (upstream also ships arm64).
