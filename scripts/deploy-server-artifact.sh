#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="${AI_NOVEL_APP_ROOT:-/opt/AI-Novel-Writing-Assistant}"
SERVICE_NAME="${AI_NOVEL_SERVICE_NAME:-ai-novel.service}"
HEALTH_URL="${AI_NOVEL_HEALTH_URL:-http://127.0.0.1:3000/api/health}"
VERIFY_ONLY=false

usage() {
  printf 'Usage: %s [--verify-only] <artifact.tar.gz>\n' "$0"
}

if [[ "${1:-}" == "--verify-only" ]]; then
  VERIFY_ONLY=true
  shift
fi
if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

ARTIFACT="$(realpath -- "$1")"
[[ -f "$ARTIFACT" ]] || { printf 'Artifact not found: %s\n' "$ARTIFACT" >&2; exit 1; }

for command in tar mktemp realpath; do
  command -v "$command" >/dev/null || { printf 'Missing command: %s\n' "$command" >&2; exit 1; }
done

mapfile -t archive_paths < <(tar -tzf "$ARTIFACT")
[[ ${#archive_paths[@]} -gt 0 ]] || { printf 'Artifact is empty.\n' >&2; exit 1; }
for path in "${archive_paths[@]}"; do
  [[ -n "$path" ]] || continue
  case "$path" in
    /*|..|../*|*/../*|*/..) printf 'Artifact contains an unsafe path: %s\n' "$path" >&2; exit 1 ;;
  esac
done

TEMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

tar -xzf "$ARTIFACT" -C "$TEMP_DIR"

required=(
  REVISION
  package.json
  pnpm-lock.yaml
  pnpm-workspace.yaml
  server/package.json
  server/dist/app.js
  server/prisma/schema.sqlite.prisma
  server/prisma/migrations.sqlite/migration_lock.toml
  server/node_modules/@prisma/client/default.js
  server/node_modules/.prisma/client/default.js
  client/dist/index.html
  shared/dist/index.js
)
for path in "${required[@]}"; do
  [[ -s "$TEMP_DIR/$path" ]] || { printf 'Artifact is missing: %s\n' "$path" >&2; exit 1; }
done

REVISION="$(tr -d '\r\n' < "$TEMP_DIR/REVISION")"
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || { printf 'Invalid artifact revision.\n' >&2; exit 1; }

if "$VERIFY_ONLY"; then
  printf 'Artifact verified: %s\n' "$REVISION"
  exit 0
fi

for command in cmp sqlite3 systemctl curl pnpm; do
  command -v "$command" >/dev/null || { printf 'Missing command: %s\n' "$command" >&2; exit 1; }
done
[[ -d "$APP_ROOT" ]] || { printf 'Application root not found: %s\n' "$APP_ROOT" >&2; exit 1; }

# The artifact intentionally updates runtime output without a Git pull. Keep
# dependency declarations aligned with the host's existing Node 22 install.
for path in package.json pnpm-lock.yaml pnpm-workspace.yaml server/package.json; do
  cmp -s "$TEMP_DIR/$path" "$APP_ROOT/$path" || {
    printf 'Artifact %s does not match the host checkout. Refusing deployment.\n' "$path" >&2
    exit 1
  }
done

PATH_SPECS=(
  'server/dist|server-dist'
  'client/dist|client-dist'
  'shared/dist|shared-dist'
  'server/src/prisma|server-prisma'
  'server/node_modules/@prisma/client|prisma-client'
  'server/node_modules/.prisma/client|prisma-generated'
)

SERVICE_STOPPED=false
SERVICE_WAS_ACTIVE=false
DB_BACKUP_CREATED=false
INSTALL_STARTED=false
ROLLBACK_ROOT=""
BACKUP=""
DATABASE="$APP_ROOT/server/dev.db"

restore_old_paths() {
  [[ -n "$ROLLBACK_ROOT" && -d "$ROLLBACK_ROOT" ]] || return 0
  for spec in "${PATH_SPECS[@]}"; do
    rel="${spec%%|*}"
    key="${spec#*|}"
    marker="$ROLLBACK_ROOT/$key.present"
    [[ -f "$marker" ]] || continue
    present="$(< "$marker")"
    if "$INSTALL_STARTED"; then
      rm -rf -- "$APP_ROOT/$rel"
    fi
    if [[ "$present" == 1 && -e "$ROLLBACK_ROOT/$key" ]]; then
      mkdir -p -- "$(dirname "$APP_ROOT/$rel")"
      mv -- "$ROLLBACK_ROOT/$key" "$APP_ROOT/$rel"
    fi
  done
}

rollback() {
  status=$?
  trap - ERR
  if "$SERVICE_STOPPED"; then
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  restore_old_paths || true
  if "$DB_BACKUP_CREATED" && [[ -f "$BACKUP" ]]; then
    cp -f -- "$BACKUP" "$DATABASE" || true
    rm -f -- "${DATABASE}-wal" "${DATABASE}-shm" || true
  fi
  if "$SERVICE_WAS_ACTIVE"; then
    systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  [[ -z "$ROLLBACK_ROOT" ]] || rm -rf -- "$ROLLBACK_ROOT"
  printf 'Deployment failed; previous build and database were restored (status %s).\n' "$status" >&2
  exit "$status"
}
trap rollback ERR

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  printf 'Service is not active: %s; refusing an online artifact deployment.\n' "$SERVICE_NAME" >&2
  exit 1
fi
SERVICE_WAS_ACTIVE=true
systemctl stop "$SERVICE_NAME"
SERVICE_STOPPED=true
for _ in {1..20}; do
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    break
  fi
  sleep 1
done
if systemctl is-active --quiet "$SERVICE_NAME"; then
  printf 'Service did not stop cleanly: %s\n' "$SERVICE_NAME" >&2
  false
fi

BACKUP_DIR="$APP_ROOT/server/tmp/db-backups"
mkdir -p -- "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/dev_before_artifact_${REVISION:0:12}_$(date +%Y%m%d_%H%M%S).db"
if [[ -f "$DATABASE" ]]; then
  sqlite3 "$DATABASE" ".backup '$BACKUP'"
  [[ "$(sqlite3 "$BACKUP" 'PRAGMA quick_check;')" == ok ]] || {
    printf 'Database backup validation failed: %s\n' "$BACKUP" >&2
    false
  }
  DB_BACKUP_CREATED=true
fi

ROLLBACK_ROOT="$APP_ROOT/.deploy-rollback-${REVISION:0:12}"
[[ ! -e "$ROLLBACK_ROOT" ]] || {
  printf 'Rollback directory already exists: %s\n' "$ROLLBACK_ROOT" >&2
  false
}
mkdir -- "$ROLLBACK_ROOT"

for spec in "${PATH_SPECS[@]}"; do
  rel="${spec%%|*}"
  key="${spec#*|}"
  src="$APP_ROOT/$rel"
  dest="$ROLLBACK_ROOT/$key"
  if [[ -e "$src" || -L "$src" ]]; then
    mv -- "$src" "$dest"
    printf '1\n' > "$dest.present"
  else
    printf '0\n' > "$dest.present"
  fi
done

INSTALL_STARTED=true
mkdir -p -- "$APP_ROOT/server/node_modules/@prisma" "$APP_ROOT/server/node_modules/.prisma"
cp -a -- "$TEMP_DIR/server/dist" "$APP_ROOT/server/"
cp -a -- "$TEMP_DIR/client/dist" "$APP_ROOT/client/"
cp -a -- "$TEMP_DIR/shared/dist" "$APP_ROOT/shared/"
cp -a -- "$TEMP_DIR/server/prisma" "$APP_ROOT/server/src/prisma"
cp -a -- "$TEMP_DIR/server/node_modules/@prisma/client" "$APP_ROOT/server/node_modules/@prisma/client"
cp -a -- "$TEMP_DIR/server/node_modules/.prisma/client" "$APP_ROOT/server/node_modules/.prisma/client"

# Apply only migrations shipped in the verified GitHub artifact, while the
# service is stopped. The backup above makes a failed migration recoverable.
(
  cd "$APP_ROOT/server"
  pnpm run prisma:deploy
)

systemctl start "$SERVICE_NAME"
for _ in {1..30}; do
  if curl -fsS "$HEALTH_URL" >/dev/null; then
    rm -rf -- "$ROLLBACK_ROOT"
    trap - ERR
    printf 'Deployed %s; migrations applied; health check passed.\n' "$REVISION"
    exit 0
  fi
  sleep 1
done

printf 'Health check timed out: %s\n' "$HEALTH_URL" >&2
false
