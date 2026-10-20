# ADR 0001: Overlay on the official DocuSeal image

- Status: accepted (amended 2026-10-20: the image runs as non-root `USER 2000:2000`, DPA-007)
- Date: 2026-10-20
- Deciders: Auto-i-DAT AG (owner approval to build and publish under AGPL-3.0)

## Context

AutoContract renders its own contract PDFs and needs DocuSeal to turn such a PDF plus known
field positions into a signable template. The free DocuSeal edition has no API for that
(`POST /api/templates/pdf` is a Pro feature). DocuSeal is AGPL-3.0 licensed, so a modified
version may be run and published under the same license.

Constraints: follow upstream releases (weekly) with little effort, keep the upstream signing
UI, webhooks and storage behaviour, keep the DocuSeal attribution (section 7(b) term), stay
deployable as one container (Cloud Run), and run as a non-root user (owner guideline).

Facts at tag 3.3.3 (verified in the source and image):

- `config/routes.rb` ends its draw block with `ActiveSupport.run_load_hooks(:routes, self)`;
  an initializer can add routes with `ActiveSupport.on_load(:routes)`.
- `config.autoload_lib` autoloads `lib/`; files added to `app/` and `lib/` are picked up by
  Zeitwerk and eager loading without touching any upstream file.
- The web upload uses `Templates::CreateAttachments` → `Templates::ProcessDocument` (stores the
  blob, PDF metadata, page previews); `Templates::SerializeForApi` renders `GET /api/templates/:id`.
- The upstream image creates the user `docuseal` (2000:2000) but has no `USER` instruction and
  no ENTRYPOINT; CMD is `bundle exec puma`. Started as root, `config/dotenv.rb` (required by
  `config/puma.rb`) chowns `/data/docuseal` to 2000:2000 if it is not owned by 2000, writes a
  generated `docuseal.env` as root with mode 0600 when `SECRET_KEY_BASE` is missing, and then
  switches only the effective uid/gid to 2000 – real and saved uid stay 0 (observed:
  `Uid: 0 2000 0 2000` for PID 1). All three blocks run only if `Process.uid.zero?` and rescue
  their errors. `/app/tmp`, `/app/tmp/cache`, `/app/log` and `/home/docuseal` already belong to
  `docuseal`; only `/data/docuseal` is root-owned in the image.

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
services, ability checks, API base controller and serializer. ENTRYPOINT and CMD stay as
upstream defines them; the image adds a `HEALTHCHECK` on `/up` (upstream has none; `wget` is
available in the Alpine base).

The image runs as `USER 2000:2000`. `/data/docuseal` is chowned to 2000:2000 (mode 0750) at
build time instead of at boot, so the root-only code of `config/dotenv.rb` is skipped and Puma
and the embedded `redis-server` run with real, effective, saved and filesystem uid 2000. Overlay
files stay owned by root (read-only for the app).

Upgrade safety is enforced at build time: the Dockerfile fails if an overlay file would
replace an upstream file, if `config/routes.rb` no longer runs the `:routes` load hook, or if
the wrapped attribution partial changed (sha256). Behaviour is enforced by the end-to-end test,
which every Dependabot bump has to pass; it also checks the process uids and runs with
`/data/docuseal/attachments` on a separate mount owned by 2000:2000.

## Consequences

- Positive: tiny diff to audit, fast builds, upstream fixes arrive with a digest bump, the
  corresponding source is easy to identify (upstream tag + this repository).
- Positive: no root process at all; Trivy's DS-0002 passes without an exception. Pre-existing
  mounts owned by 2000 where chown/chmod is impossible (Cloud Storage FUSE on Cloud Run) work,
  because nothing at boot changes ownership or modes and Active Storage's disk service only
  creates directories and writes, reads and deletes files.
- Negative: internal upstream APIs (`Templates::CreateAttachments.handle_pdf_or_image`,
  `Templates::SerializeForApi`, `Pdfium::Document`) are not a public contract; a refactoring
  upstream breaks the build or the end-to-end test and needs a code change here.
- Compatibility (tested with SQLite and named volumes):
  - volumes first used by the upstream image work unchanged (upstream already chowned them);
  - a `docuseal.env` that upstream generated (root, 0600, because `SECRET_KEY_BASE` was not
    set) cannot be read: the container stops with `Permission denied … docuseal.env`. Fix:
    provide `SECRET_KEY_BASE`/`DATABASE_URL` as environment variables (then the file is not
    read) or `chown 2000:2000` it once;
  - bind mounts must be owned by 2000:2000 (upstream used to chown them at boot);
  - `--user 0:0` restores upstream's root start and works with this image.
- Images are built for linux/amd64 only (upstream also ships arm64).
