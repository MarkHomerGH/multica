#!/usr/bin/env bash
set -euo pipefail

apply=false
case ${1:-} in
  --help)
    if (( $# == 1 )); then
      echo 'usage: sweep-orphan-uploads.sh [--apply]'
      exit 0
    fi
    ;;
  --apply)
    if (( $# == 1 )); then
      apply=true
    fi
    ;;
  '')
    if (( $# == 0 )); then
      :
    fi
    ;;
esac
if (( $# > 1 )) || { (( $# == 1 )) && [[ ${1:-} != --apply ]]; }; then
  echo 'usage: sweep-orphan-uploads.sh [--apply]' >&2
  exit 2
fi

script_path=${BASH_SOURCE[0]}
case $script_path in
  */*) script_dir=${script_path%/*} ;;
  *) script_dir=. ;;
esac
REPO_ROOT=$(cd "$script_dir/../.." && pwd -P)
MC=${MC:-$REPO_ROOT/deploy/grandin/mc}
read -r -a psql_cmd <<< "${PSQL_CMD:-$MC exec -T postgres psql -U multica -d multica -v ON_ERROR_STOP=1 -Atq}"
read -r -a uploads_sh <<< "${UPLOADS_SH:-$MC exec -T backend sh -c}"
root=${UPLOADS_ROOT-/app/data/uploads}
min_age=${SWEEP_MIN_AGE_MINUTES-60}
if [[ ! $min_age =~ ^[0-9]+$ ]]; then
  echo 'ERROR: SWEEP_MIN_AGE_MINUTES must be a non-negative integer' >&2
  exit 2
fi
while [[ $root == */ && $root != / ]]; do
  root=${root%/}
done
if [[ -z $root || $root == / || $root != /* ]]; then
  echo 'ERROR: unsafe UPLOADS_ROOT' >&2
  exit 2
fi
if (( ${#psql_cmd[@]} == 0 || ${#uploads_sh[@]} == 0 )); then
  echo 'ERROR: command seam is empty' >&2
  exit 2
fi

uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
shell_quote() {
  local value=$1
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}
quoted_root=$(shell_quote "$root")
list_snippet="root=$quoted_root; min_age=$min_age; for path in \"\$root\"/workspaces/*; do [ -d \"\$path\" ] && [ ! -L \"\$path\" ] || continue; if old_path=\$(find \"\$path\" -maxdepth 0 -type d -mmin +\"\$min_age\"); then :; else exit 1; fi; if [ -n \"\$old_path\" ]; then age=old; else age=young; fi; printf '%s|%s\\n' \"\$age\" \"\${path##*/}\"; done"
echo 'Listing workspace upload directories'
if ! directory_rows=$("${uploads_sh[@]}" "$list_snippet" 2>/dev/null); then
  echo 'ERROR: upload directory listing failed; no uploads removed' >&2
  exit 2
fi

directories=()
ages=()
if [[ -n $directory_rows ]]; then
  while IFS='|' read -r age id; do
    if [[ $id =~ $uuid_re ]]; then
      if [[ $age != old && $age != young ]]; then
        echo 'ERROR: invalid upload directory age; no uploads removed' >&2
        exit 2
      fi
      directories+=("$id")
      ages+=("$age")
    fi
  done <<< "$directory_rows"
fi

echo 'Checking live workspaces'
if ! workspace_rows=$("${psql_cmd[@]}" 2>/dev/null <<'SQL'
SELECT id FROM workspace;
SQL
); then
  echo 'ERROR: workspace query failed; no uploads removed' >&2
  exit 2
fi
if [[ -z $workspace_rows ]]; then
  echo 'ERROR: workspace query returned zero ids; no uploads removed' >&2
  exit 2
fi
workspace_ids=()
while IFS= read -r id; do
  if [[ ! $id =~ $uuid_re ]]; then
    echo 'ERROR: invalid workspace id; no uploads removed' >&2
    exit 2
  fi
  workspace_ids+=("$id")
done <<< "$workspace_rows"

kept=0
for index in "${!directories[@]}"; do
  id=${directories[$index]}
  live=false
  for workspace_id in "${workspace_ids[@]}"; do
    if [[ $id == "$workspace_id" ]]; then
      live=true
      break
    fi
  done
  if $live; then
    (( kept += 1 ))
    continue
  fi
  echo "orphan $id"
  if [[ ${ages[$index]} == young ]]; then
    echo "skip-young $id"
    continue
  fi
  if $apply; then
    remove_path=$(shell_quote "$root/workspaces/$id")
    if ! "${uploads_sh[@]}" "rm -rf -- $remove_path" 2>/dev/null; then
      echo "ERROR: failed to remove orphan $id" >&2
      exit 2
    fi
    echo "removed $id"
  fi
done
echo "kept $kept live"
