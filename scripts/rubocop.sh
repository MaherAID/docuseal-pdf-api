#!/usr/bin/env bash
# RuboCop for the overlay Ruby files. Uses a local Ruby/Bundler when available, otherwise
# a pinned Ruby container (gems cached in the Docker volume docuseal-pdf-api-lint-bundle).
# Extra arguments are passed to rubocop (e.g. file names from pre-commit, or -a).
set -euo pipefail
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."

RUBY_IMAGE="ruby:4.0.5-alpine@sha256:f48938e9ae72a4d32e728b03c306e7a7ff21f0cb6c2ed33f44a078c700b2aea6"

if command -v bundle >/dev/null 2>&1 && ruby -e 'exit(RUBY_VERSION >= "4.0" ? 0 : 1)' 2>/dev/null; then
  bundle install --quiet
  exec bundle exec rubocop "$@"
fi

workdir="$(pwd -W 2>/dev/null || pwd)"
exec docker run --rm -v "$workdir:/work" -v docuseal-pdf-api-lint-bundle:/usr/local/bundle -w /work "$RUBY_IMAGE" \
  sh -c 'apk add --no-cache build-base yaml-dev >/dev/null && bundle install --quiet && bundle exec rubocop "$@"' \
  rubocop "$@"
