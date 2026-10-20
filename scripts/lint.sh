#!/usr/bin/env bash
# Runs the lint and scan steps of CI locally. Only Docker (and bash) are required: every tool
# runs from a container image pinned by digest.
#
#   scripts/lint.sh            # lint + Trivy filesystem scan
#   scripts/lint.sh --image    # additionally scan the local image docuseal-pdf-api:local
set -euo pipefail
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
workdir="$(pwd -W 2>/dev/null || pwd)"

HADOLINT="hadolint/hadolint:v2.15.1@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d"
SHELLCHECK="koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d"
RUFF="ghcr.io/astral-sh/ruff:0.16.10@sha256:e1675e92fe4d38ce10ab6cabaf4ab20f209b84433b789cfd1b683c028aa391e2"
ACTIONLINT="rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667"
TRIVY="aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa"

run() {
  printf '\n== %s\n' "$1"
  shift
  "$@"
}

in_repo() {
  docker run --rm -v "$workdir:/work" -w /work "$@"
}

for dockerfile in Dockerfile tests/e2e/Dockerfile; do
  run "hadolint $dockerfile" docker run --rm -i "$HADOLINT" hadolint --failure-threshold info - <"$dockerfile"
done
run "shellcheck" in_repo "$SHELLCHECK" -x tests/e2e/run.sh scripts/lint.sh scripts/rubocop.sh
run "actionlint" in_repo "$ACTIONLINT" -color
run "ruff check" in_repo "$RUFF" check tests/e2e
run "ruff format --check" in_repo "$RUFF" format --check tests/e2e
run "rubocop" scripts/rubocop.sh
run "trivy fs (vulnerabilities, secrets, misconfigurations)" \
  in_repo -v docuseal-pdf-api-trivy-cache:/root/.cache/trivy "$TRIVY" fs --quiet --exit-code 1 \
  --scanners vuln,secret,misconfig --severity HIGH,CRITICAL --ignorefile .trivyignore.yaml --skip-dirs .e2e .

if [ "${1:-}" = "--image" ]; then
  run "trivy image docuseal-pdf-api:local (fixable CRITICAL)" \
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$workdir:/work" -w /work \
    -v docuseal-pdf-api-trivy-cache:/root/.cache/trivy "$TRIVY" image --quiet --exit-code 1 --scanners vuln \
    --severity CRITICAL --ignore-unfixed --ignorefile .trivyignore.yaml docuseal-pdf-api:local
fi

printf '\nall checks passed\n'
