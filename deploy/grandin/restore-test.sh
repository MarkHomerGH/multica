#!/usr/bin/env bash
set -euo pipefail

usage() { echo 'usage: restore-test.sh [--dry-run] <backup-set-dir>'; }
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
dry_run=false
if [[ ${1:-} == --dry-run ]]; then dry_run=true; shift; fi
if [[ $# -ne 1 ]]; then usage >&2; exit 2; fi
readonly PROJECT="multica-restoretest"
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
set_dir=$(cd "$1" && pwd -P)
[[ -f $set_dir/SHA256SUMS ]] || { echo 'FAIL: missing SHA256SUMS' >&2; exit 1; }
printf 'Verifying backup checksums\n'
if ! (cd "$set_dir" && shasum -a 256 -c SHA256SUMS >/dev/null); then
  echo 'FAIL: backup checksums' >&2
  exit 1
fi
echo 'PASS: backup checksums'
for file in db.dump uploads.tar env manifest.txt; do
  [[ -f $set_dir/$file ]] || { echo "FAIL: missing $file" >&2; exit 1; }
  if ! awk -v name="$file" '$2==name && length($1)==64 && $1 !~ /[^0-9a-fA-F]/ {found=1} END {exit !found}' "$set_dir/SHA256SUMS"; then
    echo "FAIL: $file is not listed in SHA256SUMS" >&2
    exit 1
  fi
done

# Read only the values needed for Compose interpolation; never source the env file.
env_value() {
  local value
  value=$(awk -v key="$1" 'index($0,key"=")==1 {print substr($0,length(key)+2); exit}' "$set_dir/env")
  if [[ $value == \"*\" || $value == \'*\' ]]; then value=${value:1:${#value}-2}; fi
  printf '%s' "$value"
}
GRANDIN_PIN=$(env_value GRANDIN_PIN)
JWT_SECRET=$(env_value JWT_SECRET)
POSTGRES_PASSWORD=$(env_value POSTGRES_PASSWORD)
[[ -n $GRANDIN_PIN && -n $JWT_SECRET ]] || { echo 'FAIL: backup env lacks required stack values' >&2; exit 1; }
# The scratch database can use its own password when the backup env omits one.
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-restoretest-local-only}
export GRANDIN_PIN JWT_SECRET POSTGRES_PASSWORD
# The base stack requires these values at interpolation time. The override below
# replaces the resulting service origins with loopback addresses.
TAILNET_ORIGIN=http://127.0.0.1:13000
TAILNET_ORIGINS=http://127.0.0.1:13000
ALLOWED_EMAILS=alice@example.test
export TAILNET_ORIGIN TAILNET_ORIGINS ALLOWED_EMAILS

MC=${MC:-$REPO_ROOT/deploy/grandin/mc}
read -r -a mc_cmd <<< "$MC"
[[ ${#mc_cmd[@]} -gt 0 ]] || { echo 'FAIL: empty MC seam' >&2; exit 1; }
tmp_dir=$(mktemp -d)
override=$tmp_dir/restore.yml
cat > "$override" <<'YAML'
services:
  backend:
    ports: !override
      - "127.0.0.1:18080:8080"
    environment:
      FRONTEND_ORIGIN: "http://127.0.0.1:13000"
      CORS_ALLOWED_ORIGINS: "http://127.0.0.1:13000"
      MULTICA_APP_URL: "http://127.0.0.1:13000"
      MULTICA_PUBLIC_URL: ""
      DO_NOT_TRACK: "1"
  frontend:
    ports: !override
      - "127.0.0.1:13000:3000"
YAML
compose=("${mc_cmd[@]}" -p "$PROJECT" --env-file "$set_dir/env" -f "$override")
if [[ -n ${PSQL_CMD:-} ]]; then
  read -r -a psql_cmd <<< "$PSQL_CMD"
else
  psql_cmd=("${compose[@]}" exec -T postgres psql -U multica -d multica -v ON_ERROR_STOP=1 -Atq)
fi
if [[ -n ${UPLOADS_SH:-} ]]; then
  read -r -a uploads_cmd <<< "$UPLOADS_SH"
else
  uploads_cmd=("${compose[@]}" run --rm --no-deps -T --entrypoint sh backend -c)
fi
[[ ${#psql_cmd[@]} -gt 0 && ${#uploads_cmd[@]} -gt 0 ]] || { echo 'FAIL: empty command seam' >&2; exit 1; }
cleanup() {
  local status=$?
  trap - EXIT
  if [[ $dry_run == false ]]; then
    if ! "${compose[@]}" down -v >/dev/null; then
      echo 'FAIL: scratch stack teardown' >&2
      status=1
    fi
  fi
  rm -rf "$tmp_dir"
  exit "$status"
}
trap cleanup EXIT

if [[ $dry_run == true ]]; then
  printf -v compose_plan '%q ' "${compose[@]}"
  printf -v uploads_plan '%q ' "${uploads_cmd[@]}"
  printf 'PLAN: override backend ports 127.0.0.1:18080:8080; frontend ports 127.0.0.1:13000:3000; no Caddy or Tailnet origin\n'
  printf 'PLAN: %sup -d --wait --no-build postgres\n' "$compose_plan"
  printf 'PLAN: %sexec -T postgres pg_restore --exit-on-error --no-owner --no-acl -U multica -d multica < db.dump\n' "$compose_plan"
  printf 'PLAN: %s"mkdir -p %s && tar -C %s -xf -" < uploads.tar\n' "$uploads_plan" "${UPLOADS_ROOT:-/app/data/uploads}" "${UPLOADS_ROOT:-/app/data/uploads}"
  printf 'PLAN: %sup -d --no-build backend\n' "$compose_plan"
  echo 'PLAN: wait up to 120s for http://127.0.0.1:18080/health'
  printf 'PLAN: %sup -d --no-build frontend\n' "$compose_plan"
  echo 'PLAN: compare four row counts and max migration version with manifest.txt'
  echo 'PLAN: test one restored upload file per workspace with attachments'
  printf 'PLAN: %sdown -v\n' "$compose_plan"
  exit 0
fi

printf 'Starting scratch PostgreSQL\n'
"${compose[@]}" up -d --wait --no-build postgres
printf 'Restoring database\n'
"${compose[@]}" exec -T postgres pg_restore --exit-on-error --no-owner --no-acl -U multica -d multica < "$set_dir/db.dump"
printf 'Restoring uploads\n'
uploads_root=${UPLOADS_ROOT:-/app/data/uploads}
uploads_root_q=$(printf '%q' "$uploads_root")
cat "$set_dir/uploads.tar" | "${uploads_cmd[@]}" "mkdir -p $uploads_root_q && tar -C $uploads_root_q -xf -"
printf 'Starting scratch backend\n'
"${compose[@]}" up -d --no-build backend
ready=false
for ((second=0; second<120; second++)); do
  if curl -fs -o /dev/null --max-time 2 http://127.0.0.1:18080/health; then ready=true; break; fi
  sleep 1
done
[[ $ready == true ]] || { echo 'FAIL: backend health (120s)' >&2; exit 1; }
echo 'PASS: backend health'
"${compose[@]}" up -d --no-build frontend

manifest_value() { awk -v key="$1" 'index($0,key"=")==1 {print substr($0,length(key)+2); exit}' "$set_dir/manifest.txt"; }
query() { printf '%s\n' "$1" | "${psql_cmd[@]}"; }
failed=0
for table in workspace issue comment attachment; do
  expected=$(manifest_value "count.$table")
  actual=$(query "SELECT count(*) FROM $table;")
  [[ $expected =~ ^[0-9]+$ && $actual =~ ^[0-9]+$ ]] || { echo "FAIL: invalid count for $table" >&2; exit 1; }
  if [[ $actual == "$expected" ]]; then echo "PASS: count.$table=$actual"; else echo "FAIL: count.$table expected=$expected actual=$actual"; failed=1; fi
done
expected=$(manifest_value schema_migrations.max_version)
actual=$(query 'SELECT max(version) FROM schema_migrations;')
[[ -n $actual ]] || actual=none
if [[ -n $expected && $actual == "$expected" ]]; then
  echo "PASS: schema_migrations.max_version=$actual"
else
  echo "FAIL: schema_migrations.max_version mismatch"; failed=1
fi

# Local storage URLs have /uploads/<key>; check the object through the scratch
# backend volume because HTTP downloads require authentication.
attachments=$(query 'SELECT DISTINCT ON (workspace_id) workspace_id::text || chr(124) || url FROM attachment ORDER BY workspace_id, id;')
if [[ -z $attachments ]]; then
  echo 'PASS: attachment files (none to check)'
else
  while IFS='|' read -r workspace url; do
    key=${url#*/uploads/}
    key=${key%%\?*}
    if [[ $key == "$url" || ! $key =~ ^(workspaces|users)/[A-Za-z0-9._/-]+$ || $key == *..* ]]; then
      echo "FAIL: attachment file for workspace $workspace has an invalid local key"
      failed=1
      continue
    fi
    if "${uploads_cmd[@]}" "test -f $uploads_root_q/$key"; then
      echo "PASS: attachment file for workspace $workspace"
    else
      echo "FAIL: attachment file for workspace $workspace"
      failed=1
    fi
  done <<< "$attachments"
fi
[[ $failed -eq 0 ]] || exit 1
echo 'PASS: scratch restore'
