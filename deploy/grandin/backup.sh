#!/usr/bin/env bash
set -euo pipefail

usage() { echo 'usage: backup.sh [--daemon-state DIR]'; }
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
if [[ $# -gt 0 && ( $# -ne 2 || $1 != --daemon-state ) ]]; then usage >&2; exit 2; fi

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
ENV_FILE=${ENV_FILE:-$REPO_ROOT/.env}
dest=${MULTICA_BACKUP_DIR:-$HOME/multica-backups}
# Resolve symlinks and missing path components before creating anything.
dest=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$dest")
case "$dest/" in
  "$REPO_ROOT/"*) echo 'FAIL: backup destination is inside the checkout' >&2; exit 1 ;;
esac
[[ -r $ENV_FILE && -f $ENV_FILE ]] || { echo 'FAIL: env file is unreadable' >&2; exit 1; }

MC=${MC:-$REPO_ROOT/deploy/grandin/mc}
PSQL_CMD=${PSQL_CMD:-$MC exec -T postgres psql -U multica -d multica -v ON_ERROR_STOP=1 -Atq}
PG_DUMP_CMD=${PG_DUMP_CMD:-$MC exec -T postgres pg_dump -U multica -d multica -Fc}
UPLOADS_SH=${UPLOADS_SH:-$MC exec -T backend sh -c}
UPLOADS_ROOT=${UPLOADS_ROOT:-/app/data/uploads}
read -r -a psql_cmd <<< "$PSQL_CMD"
read -r -a dump_cmd <<< "$PG_DUMP_CMD"
read -r -a uploads_cmd <<< "$UPLOADS_SH"
[[ ${#psql_cmd[@]} -gt 0 && ${#dump_cmd[@]} -gt 0 && ${#uploads_cmd[@]} -gt 0 ]] || { echo 'FAIL: empty command seam' >&2; exit 1; }

umask 077
mkdir -p "$dest"
set_dir="$dest/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir "$set_dir"
trap 'echo "FAIL: backup incomplete: $set_dir" >&2' ERR
printf 'Backing up database\n'
"${dump_cmd[@]}" > "$set_dir/db.dump"
printf 'Backing up uploads\n'
# The root is a configured container path; pass it as a shell argument safely.
uploads_root_q=$(printf '%q' "$UPLOADS_ROOT")
"${uploads_cmd[@]}" "tar -C $uploads_root_q -cf - ." > "$set_dir/uploads.tar"
printf 'Recording database counts\n'
query() { printf '%s\n' "$1" | "${psql_cmd[@]}"; }
for table in workspace issue comment attachment; do
  value=$(query "SELECT count(*) FROM $table;")
  [[ $value =~ ^[0-9]+$ ]] || { echo "FAIL: invalid $table count" >&2; exit 1; }
  printf -v "count_$table" '%s' "$value"
done
version=$(query 'SELECT max(version) FROM schema_migrations;')
[[ $version != *$'\n'* && $version != *'='* ]] || { echo 'FAIL: invalid migration version' >&2; exit 1; }
[[ -n $version ]] || version=none
pin=$(awk 'index($0,"GRANDIN_PIN=")==1 {print substr($0,13); exit}' "$ENV_FILE")
pin=${pin%\"}; pin=${pin#\"}
[[ -n $pin ]] || pin=unknown
cp "$ENV_FILE" "$set_dir/env"
chmod 600 "$set_dir/env"

daemon_state='skipped: no --daemon-state directory supplied'
if [[ $# -eq 2 ]]; then
  if [[ ! -d $2 || ! -r $2 || ! -x $2 ]]; then
    daemon_state='skipped: directory unreadable'
  else
    printf 'Backing up daemon state\n'
    if tar -C "$2" --exclude='*/logs' -cf "$set_dir/daemon-state.tar" .; then
      daemon_state=captured
    else
      rm -f "$set_dir/daemon-state.tar"
      daemon_state='skipped: copy failed'
    fi
  fi
fi
cat > "$set_dir/manifest.txt" <<MANIFEST
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
grandin_pin=$pin
count.workspace=$count_workspace
count.issue=$count_issue
count.comment=$count_comment
count.attachment=$count_attachment
schema_migrations.max_version=$version
daemon_state=$daemon_state
MANIFEST
(
  cd "$set_dir"
  files=(db.dump uploads.tar env manifest.txt)
  [[ ! -f daemon-state.tar ]] || files+=(daemon-state.tar)
  shasum -a 256 "${files[@]}" > SHA256SUMS
  shasum -a 256 -c SHA256SUMS >/dev/null
)
trap - ERR
printf 'PASS: backup set %s\n' "$set_dir"
