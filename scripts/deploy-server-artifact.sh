#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="${AI_NOVEL_APP_ROOT:-/opt/AI-Novel-Writing-Assistant}"
SERVICE_NAME="${AI_NOVEL_SERVICE_NAME:-ai-novel.service}"
HEALTH_URL="${AI_NOVEL_HEALTH_URL:-http://127.0.0.1:3000/api/health}"
VERIFY_ONLY=false

usage() {
  echo "Usage: $0 [--verify-only] <artifact.tar.gz>"
}

if [[ "${1:-}" == "--verify-only" ]]; then
  VERIFY_ONLY=true
  shift
fi
if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

ARTIFACT="$(realpath "$1")"
[[ -f "$ARTIFACT" ]] || { echo "Artifact not found: $ARTIFACT" >&2; exit 1; }

for command in tar mktemp realpath; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done

mapfile -t archive_paths < <(tar -tzf "$ARTIFACT")
[[ ${#archive_paths[@]} -gt 0 ]] || { echo "Artifact is empty." >&2; exit 1; }
for path in "${archive_paths[@]}"; do
  if [[ "$path" == /* || "$path" == ".." || "$path" == ../* || "$path" == */../* || "$path" == */.. ]]; then
    echo "Artifact contains an unsafe path: $path" >&2
    exit 1
  fi
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
  client/dist/index.html
  shared/dist/index.js
)
for path in "${required[@]}"; do
  [[ -s "$TEMP_DIR/$path" ]] || { echo "Artifact is missing: $path" >&2; exit 1; }
done

REVISION="$(tr -d '\r\n' < "$TEMP_DIR/REVISION")"
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid artifact revision." >&2; exit 1; }

if $VERIFY_ONLY; then
  echo "Artifact verified: $REVISION"
  exit 0
fi

for command in sqlite3 systemctl curl; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
[[ -d "$APP_ROOT/.git" ]] || { echo "Not a Git checkout: $APP_ROOT" >&2; exit 1; }
CURRENT_REVISION="$(git -C "$APP_ROOT" rev-parse HEAD)"
[[ "$CURRENT_REVISION" == "$REVISION" ]] || {
  echo "Artifact revision $REVISION does not match checkout $CURRENT_REVISION." >&2
  exit 1
}
cmp -s "$TEMP_DIR/pnpm-lock.yaml" "$APP_ROOT/pnpm-lock.yaml" || {
  echo "Artifact lockfile does not match the checkout." >&2
  exit 1
}

DATABASE="$APP_ROOT/server/dev.db"
BACKUP_DIR="$APP_ROOT/server/tmp/db-backups"
mkdir -p "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/dev_before_artifact_${REVISION:0:12}.db"
if [[ -f "$DATABASE" ]]; then
  sqlite3 "$DATABASE" ".backup '$BACKUP'"
  [[ "$(sqlite3 "$BACKUP" 'PRAGMA quick_check;')" == "ok" ]] || {
    echo "Database backup validation failed: $BACKUP" >&2
    exit 1
  }
fi

ROLLBACK_ROOT="$APP_ROOT/.deploy-rollback-${REVISION:0:12}"
[[ ! -e "$ROLLBACK_ROOT" ]] || {
  echo "Rollback directory already exists: $ROLLBACK_ROOT" >&2
  exit 1
}
mkdir "$ROLLBACK_ROOT"

swapped=false
rollback() {
  status=$?
  if [[ $status -ne 0 && "$swapped" == true ]]; then
    echo "Deployment failed; restoring previous build." >&2
    for component in server client shared; do
      rm -rf -- "$APP_ROOT/$component/dist"
      if [[ -d "$ROLLBACK_ROOT/$component-dist" ]]; then
        mv "$ROLLBACK_ROOT/$component-dist" "$APP_ROOT/$component/dist"
      fi
    done
    systemctl restart "$SERVICE_NAME" || true
  fi
  exit "$status"
}
trap rollback ERR

for component in server client shared; do
  if [[ -d "$APP_ROOT/$component/dist" ]]; then
    mv "$APP_ROOT/$component/dist" "$ROLLBACK_ROOT/$component-dist"
  fi
  cp -a "$TEMP_DIR/$component/dist" "$APP_ROOT/$component/dist"
done
swapped=true

systemctl restart "$SERVICE_NAME"
for _ in {1..30}; do
  if curl -fsS "$HEALTH_URL" >/dev/null; then
    rm -rf -- "$ROLLBACK_ROOT"
    swapped=false
    echo "Deployed $REVISION; health check passed."
    exit 0
  fi
  sleep 1
done

echo "Health check timed out: $HEALTH_URL" >&2
false
