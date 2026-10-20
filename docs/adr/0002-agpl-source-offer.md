# ADR 0002: Offering the corresponding source (AGPL-3.0 section 13)

- Status: accepted
- Date: 2026-10-20

## Context

DocuSeal is licensed under the AGPL-3.0 plus an additional term under section 7(b): "a covered
work must retain the original DocuSeal attribution in interactive user interfaces". This
project modifies DocuSeal (new API endpoint), so:

- **Section 13:** whoever runs a modified version must prominently offer every user who
  interacts with it over a network the Corresponding Source of that version, free of charge
  from a network server.
- **Section 5:** conveyed source must carry prominent notices that it was modified (with a
  date) and that it is under the AGPL including the section 7 terms.
- **Section 6:** conveying the Docker image (GHCR) requires the corresponding source to be
  available, with clear directions next to the object code.
- **7(b) term:** the DocuSeal attribution must stay.

Who interacts with an instance over the network:

1. **Signers** (customers of the operator) – signing form, completed/declined/expired pages,
   start forms, submission previews. All of them render the partial `shared/_attribution`
   ("Powered by DocuSeal – open source documents software").
2. **API clients** (e.g. AutoContract) – never see HTML.
3. **Staff** in the admin UI – employees of the operator, which already has the source; the
   settings page links to the upstream GitHub repository.
4. **Signers of an embedded form** (`<docuseal-form>` web component inside the operator's own
   page) – the Vue component renders upstream's attribution; changing it needs a rebuild of the
   JavaScript bundle.

## Options

1. **Only a `/source` route and the README.** Least code, but a signer would never learn about
   it – not a "prominent" offer.
2. **Source link next to the attribution (view override) + `/source` route.** The upstream
   partial `shared/_attribution` is a one-line wrapper around `shared/_powered_by`. A partial
   with the same name in a view path that is searched first renders the unmodified
   `shared/_powered_by` and adds one line "Source code (AGPL-3.0)" below. `GET /source`
   redirects to the same URL for API clients and documentation. Upstream files stay untouched.
3. **Layout override, banner, HTTP `Link` header or JavaScript injection.** A layout override
   copies a much larger upstream file (high drift risk); a header is not visible to users;
   injecting JavaScript or rebuilding the asset bundle is invasive.

## Decision

Option 2.

- `vendor/docuseal_pdf_api/views/shared/_attribution.html.erb` (prepended view path) renders
  `shared/_powered_by` with the same locals as upstream and a link labelled
  "Source code (AGPL-3.0)" in 14 languages. The Dockerfile checks the sha256 of upstream's
  `shared/_attribution.html.erb`; if upstream changes it, the build fails until the override is
  reviewed.
- The link and `GET /source` point to `https://github.com/MaherAID/docuseal-pdf-api/tree/<commit>`
  (commit baked into the image by CI via `SOURCE_REVISION`), falling back to the repository
  root; `SOURCE_CODE_URL` overrides it for forks/mirrors.
- Notices: [NOTICE](../../NOTICE) (what was modified, when, by whom), a header in every
  overlay file, the README statement, upstream `LICENSE` and `LICENSE_ADDITIONAL_TERMS`
  shipped unchanged, OCI labels `org.opencontainers.image.source`/`revision`/`licenses`.
- The DocuSeal attribution and branding are not changed anywhere.

## Consequences

- Signers see the offer on every server-rendered signing page; the end-to-end test asserts that
  both the upstream attribution and the source link are present.
- The repository must be public before an instance is exposed to external users, and every
  deployed commit must stay reachable (no force-pushes over released commits).
- Embedded web-component forms do not show the link. An operator who embeds forms in its own
  pages must show the source offer there (e.g. a "Source code" link to `/source`).
- Staff in the admin UI see upstream's GitHub link; as employees of the licensee they are not
  third parties, and `/source` is available.
- Section 6: the corresponding source of the unmodified part is DocuSeal at tag `3.3.3`
  (commit `8f8f69f0bc6a`), hosted by upstream. Mirroring that tag is in the backlog so the
  source stays available even if upstream removes it.
- This ADR is an engineering assessment, not legal advice.
