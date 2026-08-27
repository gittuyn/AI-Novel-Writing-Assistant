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
  server/node_modules/@prisma/client-runtime-utils/package.json
  server/node_modules/@prisma/client-runtime-utils/dist/index.js
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
  'server/node_modules/@prisma/client-runtime-utils|prisma-runtime-utils'
  'server/node_modules/.prisma/client|prisma-generated'
)

SERVICE_STOPPED=false
SERVICE_WAS_ACTIVE=false
DB_BACKUP_CREATED=false
INSTALL_STARTED=false
MIGRATION_LEDGER_PRESENT=false
ROLLBACK_ROOT=""
BACKUP=""
DATABASE="$APP_ROOT/server/dev.db"

save_path() {
  local spec="$1"
  local rel="${spec%%|*}"
  local key="${spec#*|}"
  local src="$APP_ROOT/$rel"
  local dest="$ROLLBACK_ROOT/$key"
  local kind_file="$ROLLBACK_ROOT/$key.kind"

  mkdir -p -- "$(dirname "$dest")"
  if [[ -L "$src" ]]; then
    printf 'symlink\n' > "$kind_file"
    readlink "$src" > "$ROLLBACK_ROOT/$key.target"
    rm -f -- "$src"
  elif [[ -e "$src" ]]; then
    mv -- "$src" "$dest"
    printf 'regular\n' > "$kind_file"
  else
    printf 'absent\n' > "$kind_file"
  fi
}

restore_old_paths() {
  [[ -n "$ROLLBACK_ROOT" && -d "$ROLLBACK_ROOT" ]] || return 0
  for spec in "${PATH_SPECS[@]}"; do
    rel="${spec%%|*}"
    key="${spec#*|}"
    kind_file="$ROLLBACK_ROOT/$key.kind"
    [[ -f "$kind_file" ]] || continue
    kind="$(< "$kind_file")"
    if "$INSTALL_STARTED"; then
      rm -rf -- "$APP_ROOT/$rel"
    fi
    case "$kind" in
      symlink)
        mkdir -p -- "$(dirname "$APP_ROOT/$rel")"
        ln -s "$(< "$ROLLBACK_ROOT/$key.target")" "$APP_ROOT/$rel"
        ;;
      regular)
        if [[ -e "$ROLLBACK_ROOT/$key" ]]; then
          mkdir -p -- "$(dirname "$APP_ROOT/$rel")"
          mv -- "$ROLLBACK_ROOT/$key" "$APP_ROOT/$rel"
        fi
        ;;
      absent) ;;
      *) printf 'Unknown rollback entry type: %s\n' "$kind" >&2; return 1 ;;
    esac
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
  if [[ "$(sqlite3 "$DATABASE" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='_prisma_migrations';")" != 0 ]]; then
    MIGRATION_LEDGER_PRESENT=true
  fi
fi

ROLLBACK_ROOT="$APP_ROOT/.deploy-rollback-${REVISION:0:12}"
[[ ! -e "$ROLLBACK_ROOT" ]] || {
  printf 'Rollback directory already exists: %s\n' "$ROLLBACK_ROOT" >&2
  false
}
mkdir -- "$ROLLBACK_ROOT"

for spec in "${PATH_SPECS[@]}"; do
  save_path "$spec"
done

INSTALL_STARTED=true
mkdir -p -- "$APP_ROOT/server/node_modules/@prisma" "$APP_ROOT/server/node_modules/.prisma"
cp -a -- "$TEMP_DIR/server/dist" "$APP_ROOT/server/"
cp -a -- "$TEMP_DIR/client/dist" "$APP_ROOT/client/"
cp -a -- "$TEMP_DIR/shared/dist" "$APP_ROOT/shared/"
cp -a -- "$TEMP_DIR/server/prisma" "$APP_ROOT/server/src/prisma"
cp -a -- "$TEMP_DIR/server/node_modules/@prisma/client" "$APP_ROOT/server/node_modules/@prisma/client"
cp -a -- "$TEMP_DIR/server/node_modules/@prisma/client-runtime-utils" "$APP_ROOT/server/node_modules/@prisma/client-runtime-utils"
cp -a -- "$TEMP_DIR/server/node_modules/.prisma/client" "$APP_ROOT/server/node_modules/.prisma/client"

if "$MIGRATION_LEDGER_PRESENT"; then
  (
    trap - ERR
    cd "$APP_ROOT/server"
    pnpm run prisma:deploy
  )
else
  printf 'No Prisma migration ledger found; synchronizing the existing database with the artifact schema.\n'
  (
    trap - ERR
    cd "$APP_ROOT/server"
    pnpm exec prisma db push --config prisma.config.ts
    new_migrations=()
    for migration_path in src/prisma/migrations.sqlite/*; do
      [[ -d "$migration_path" ]] || continue
      new_migrations+=("${migration_path##*/}")
    done
    printf 'Recording %s synchronized migrations as applied.\n' "${#new_migrations[@]}"
    for migration in "${new_migrations[@]}"; do
      pnpm exec prisma migrate resolve --applied "$migration" --config prisma.config.ts
    done
  )
fi

systemctl start "$SERVICE_NAME"
for _ in {1..30}; do
  if curl -fsS "$HEALTH_URL" >/dev/null; then
    rm -rf -- "$ROLLBACK_ROOT"
    trap - ERR
    printf 'Deployed %s; database synchronized; health check passed.\n' "$REVISION"
    exit 0
  fi
  sleep 1
done

printf 'Health check timed out: %s\n' "$HEALTH_URL" >&2
false
