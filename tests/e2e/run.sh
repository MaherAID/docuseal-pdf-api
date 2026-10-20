#!/usr/bin/env bash
# End-to-end test of docuseal-pdf-api (local and CI).
#
#   tests/e2e/run.sh
#
# Builds the image, starts app + PostgreSQL + webhook receiver as the compose project
# "docuseal-pdf-api-e2e", checks that the app runs as uid 2000, bootstraps an
# account/admin/API token through `rails runner`, runs tests/e2e/test_e2e.py in a container
# and tears everything down again. The attachments directory is a separate mount owned by
# 2000:2000 (tests/e2e/compose.attachments-mount.yml), as on Cloud Run with Cloud Storage FUSE.
#
# Environment:
#   E2E_SKIP_APP_BUILD=1  use an existing image (IMAGE, default docuseal-pdf-api:local)
#   E2E_KEEP=1            keep the stack running afterwards (inspect at 127.0.0.1:$E2E_APP_PORT)
#   E2E_APP_PORT          host port of the app (default 3090)
#   SOURCE_REVISION       commit baked into the image when building (default: git HEAD)
#
# Generated secrets live only in .e2e/ (gitignored) and in process environments; nothing
# secret is printed.
set -euo pipefail

# Git Bash on Windows would rewrite container paths such as /app/bin/rails.
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/../.."

PROJECT=docuseal-pdf-api-e2e
STATE_DIR=.e2e
ENV_FILE="$STATE_DIR/e2e.env"
export IMAGE="${IMAGE:-docuseal-pdf-api:local}"
REPOSITORY_URL=https://github.com/MaherAID/docuseal-pdf-api
WEBHOOK_URL=http://webhook-receiver:8080/hooks/docuseal

random_hex() {
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

COMPOSE_FILES=(-f docker-compose.yml -f tests/e2e/compose.attachments-mount.yml)

compose() {
  docker compose -p "$PROJECT" "${COMPOSE_FILES[@]}" --env-file "$ENV_FILE" --profile test "$@"
}

log() {
  printf '\n[e2e] %s\n' "$*"
}

cleanup() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    log "FAILED (exit $status) - last app log lines:"
    compose logs --no-color --tail=150 app || true
  fi
  if [ "${E2E_KEEP:-0}" = "1" ]; then
    log "E2E_KEEP=1: stack left running (docker compose -p $PROJECT ${COMPOSE_FILES[*]} --env-file $ENV_FILE --profile test down -v)"
  else
    compose down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  exit "$status"
}

mkdir -p "$STATE_DIR/out"
chmod 0777 "$STATE_DIR/out"

# Start from a clean slate: a stack left over by E2E_KEEP=1 still uses the old secrets.
if [ -f "$ENV_FILE" ]; then
  compose down -v --remove-orphans >/dev/null 2>&1 || true
fi

(
  umask 077
  {
    echo "POSTGRES_PASSWORD=$(random_hex 24)"
    echo "SECRET_KEY_BASE=$(random_hex 64)"
    echo "APP_URL=http://app:3000"
    echo "APP_PORT=${E2E_APP_PORT:-3090}"
  } >"$ENV_FILE"
)

E2E_WEBHOOK_SECRET="$(random_hex 24)"
E2E_WEBHOOK_HMAC_SECRET="whsec_$(random_hex 24)"
export E2E_WEBHOOK_SECRET E2E_WEBHOOK_HMAC_SECRET

trap cleanup EXIT

if [ "${E2E_SKIP_APP_BUILD:-0}" != "1" ]; then
  SOURCE_REVISION="${SOURCE_REVISION:-$(git rev-parse --verify -q HEAD 2>/dev/null || true)}"
  export SOURCE_REVISION
  log "building $IMAGE (revision ${SOURCE_REVISION:-none})"
  compose build app
fi
log "building test image"
compose build webhook-receiver

revision="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$IMAGE")"
if [[ "$revision" =~ ^[0-9a-f]{7,40}$ ]]; then
  EXPECTED_SOURCE_URL="$REPOSITORY_URL/tree/$revision"
else
  EXPECTED_SOURCE_URL="$REPOSITORY_URL"
fi
export EXPECTED_SOURCE_URL

log "starting app, database and webhook receiver"
compose up -d --wait --wait-timeout 420 db app webhook-receiver

log "checking that Puma (PID 1) and the embedded redis-server run as 2000 (real, effective, saved, fs uid)"
# shellcheck disable=SC2016 # expanded inside the container
process_uids="$(compose exec -T app sh -c \
  'for pid in 1 $(pidof redis-server); do echo "$pid $(grep "^Uid:" "/proc/$pid/status" | cut -f2-)"; done')"
printf '%s\n' "$process_uids"
if ! printf '%s\n' "$process_uids" |
  awk 'NF == 5 { n++; for (i = 2; i <= 5; i++) if ($i != 2000) bad = 1 } END { exit (bad || n < 2) }'; then
  echo "[e2e] the app must run as uid 2000 (Puma and redis-server)" >&2
  exit 1
fi

log "checking that /data/docuseal/attachments is a separate mount owned by 2000:2000"
mount_entry="$(compose exec -T app sh -c 'grep " /data/docuseal/attachments " /proc/mounts | cut -d" " -f1-3')"
mount_owner="$(compose exec -T app stat -c '%u:%g' /data/docuseal/attachments)"
printf '%s (owner %s)\n' "${mount_entry:-no mount}" "$mount_owner"
if [ -z "$mount_entry" ] || [ "$mount_owner" != "2000:2000" ]; then
  echo "[e2e] expected a separate attachments mount owned by 2000:2000" >&2
  exit 1
fi

log "bootstrapping account, admin user, webhook and API token"
bootstrap_output="$(compose exec -T -e E2E_WEBHOOK_URL="$WEBHOOK_URL" -e E2E_WEBHOOK_SECRET -e E2E_WEBHOOK_HMAC_SECRET \
  app /app/bin/rails runner - <tests/e2e/bootstrap.rb)"
E2E_API_TOKEN="$(printf '%s\n' "$bootstrap_output" | sed -n 's/^E2E_API_TOKEN=//p' | tail -n 1)"
unset bootstrap_output
if [ -z "$E2E_API_TOKEN" ]; then
  echo "[e2e] bootstrap did not return an API token" >&2
  exit 1
fi
export E2E_API_TOKEN
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  echo "::add-mask::$E2E_API_TOKEN"
  echo "::add-mask::$E2E_WEBHOOK_SECRET"
  echo "::add-mask::$E2E_WEBHOOK_HMAC_SECRET"
fi

log "running tests/e2e/test_e2e.py"
compose run --rm e2e

stored_files="$(compose exec -T app sh -c 'find /data/docuseal/attachments -type f | wc -l')"
log "files stored on the attachments mount: $stored_files"
if [ "$stored_files" -lt 1 ]; then
  echo "[e2e] documents were not stored on the attachments mount" >&2
  exit 1
fi
