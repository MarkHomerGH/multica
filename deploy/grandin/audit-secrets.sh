#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --help && $# -eq 1 ]]; then
  echo 'usage: audit-secrets.sh'
  exit 0
fi
if (( $# != 0 )); then
  echo 'usage: audit-secrets.sh' >&2
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
if (( ${#psql_cmd[@]} == 0 )); then
  echo 'ERROR: PSQL_CMD is empty' >&2
  exit 2
fi

echo 'Checking Multica DB for secrets'
if ! results=$("${psql_cmd[@]}" 2>/dev/null <<'SQL'
SELECT 'agent.custom_env', count(*) FROM agent WHERE custom_env IS NOT NULL AND custom_env <> '{}'::jsonb
UNION ALL SELECT 'agent.mcp_config', count(*) FROM agent WHERE mcp_config IS NOT NULL AND mcp_config NOT IN ('null'::jsonb,'{}'::jsonb)
UNION ALL SELECT 'agent.runtime_config.gateway.token', count(*) FROM agent WHERE coalesce(runtime_config#>>'{gateway,token}','')<>''
UNION ALL SELECT 'workspace_mcp_server', count(*) FROM workspace_mcp_server
UNION ALL SELECT 'agent_task_queue.runtime_mcp_overlay', count(*) FROM agent_task_queue WHERE runtime_mcp_overlay IS NOT NULL
UNION ALL SELECT 'autopilot_trigger.signing_secret', count(*) FROM autopilot_trigger WHERE coalesce(signing_secret,'')<>''
UNION ALL SELECT 'autopilot_trigger.webhook_token', count(*) FROM autopilot_trigger WHERE coalesce(webhook_token,'')<>''
UNION ALL SELECT 'agent.custom_args', count(*) FROM agent WHERE custom_args::text ~* '(key|token|secret|password)';
SQL
); then
  echo 'ERROR: secret audit query failed' >&2
  exit 2
fi

expected=(
  agent.custom_env
  agent.mcp_config
  agent.runtime_config.gateway.token
  workspace_mcp_server
  agent_task_queue.runtime_mcp_overlay
  autopilot_trigger.signing_secret
  autopilot_trigger.webhook_token
  agent.custom_args
)
found=()
lines=0
while IFS= read -r line; do
  if [[ ! $line =~ ^([^\|]+)\|([0-9]+)$ ]]; then
    echo 'ERROR: invalid secret audit result' >&2
    exit 2
  fi
  name=${BASH_REMATCH[1]}
  count=${BASH_REMATCH[2]}
  if (( lines >= ${#expected[@]} )) || [[ $name != "${expected[lines]}" ]]; then
    echo 'ERROR: unexpected secret audit check' >&2
    exit 2
  fi
  echo "$name $count"
  if [[ $count != 0 ]]; then
    found+=("$name")
  fi
  (( lines += 1 ))
done <<< "$results"
if (( lines != ${#expected[@]} )); then
  echo 'ERROR: incomplete secret audit result' >&2
  exit 2
fi

if (( ${#found[@]} > 0 )); then
  echo "FOUND: ${found[*]}"
  exit 1
fi
echo 'OK: no secrets in Multica DB'
