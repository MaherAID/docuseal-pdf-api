# docuseal-pdf-api: the official DocuSeal image plus a small overlay that adds
# POST /api/templates/pdf (see overlay/ and docs/adr/0001-overlay-on-upstream-image.md).
#
# The base image is pinned by tag AND digest; Dependabot proposes updates of both.
# USER, ENTRYPOINT and CMD are inherited unchanged from upstream: the container starts as
# root and config/dotenv.rb of DocuSeal chowns /data/docuseal and switches the effective
# user to docuseal (2000:2000) before the app boots (see docs/adr/0001).
FROM docuseal/docuseal:3.3.3@sha256:28d0ca583860e2c73e5b068756023a93a325799a22da1f788355d566865dd051

# Commit of this repository; the source code link offered under AGPL-3.0 section 13 then
# points to exactly this revision. CI passes it, local builds may leave it empty.
ARG SOURCE_REVISION=""

LABEL org.opencontainers.image.title="docuseal-pdf-api" \
      org.opencontainers.image.description="DocuSeal with POST /api/templates/pdf - a modified version of DocuSeal" \
      org.opencontainers.image.source="https://github.com/MaherAID/docuseal-pdf-api" \
      org.opencontainers.image.url="https://github.com/MaherAID/docuseal-pdf-api" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.vendor="Auto-i-DAT AG" \
      org.opencontainers.image.revision="${SOURCE_REVISION}" \
      org.opencontainers.image.base.name="docker.io/docuseal/docuseal:3.3.3"

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# Guard against silent breakage when the base image is bumped:
#  1. the overlay may only ADD files, never replace an upstream file;
#  2. config/routes.rb must still run the :routes load hook the overlay uses;
#  3. the upstream attribution partial wrapped by the overlay must be unchanged.
RUN --mount=type=bind,source=overlay,target=/overlay \
    find /overlay -type f | while read -r file; do \
      target="/app/${file#/overlay/}"; \
      if [ -e "$target" ]; then echo "overlay must not replace upstream file $target" >&2; exit 1; fi; \
    done && \
    grep -q "ActiveSupport.run_load_hooks(:routes, self)" /app/config/routes.rb && \
    echo "47b952e99187c8df22a24beb58b8cbe7ab2f8ecf89527a9ad7fd7962c4d87381  /app/app/views/shared/_attribution.html.erb" \
      | sha256sum -c -

COPY overlay/ /app/

ENV DOCUSEAL_PDF_API_REVISION=${SOURCE_REVISION}

# Upstream defines no health check. /up is the Rails health endpoint of DocuSeal; with
# FORCE_SSL set, config.assume_ssl keeps it from redirecting plain HTTP probes.
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --start-interval=5s --retries=3 \
  CMD ["/bin/ash", "-c", "wget -q -O /dev/null http://127.0.0.1:${PORT:-3000}/up || exit 1"]
