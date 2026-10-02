#!/bin/bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo 'run with sudo' >&2; exit 1; }
PROFILE=/usr/local/multica-agent/multica-agent.sb
AGENT_UID=$(id -u multica-agent)
HOME_DIR=/Users/multica-agent
WORKROOT=$HOME_DIR/multica_workspaces
AGENT_TMP=$(sudo -u multica-agent /usr/bin/getconf DARWIN_USER_TEMP_DIR)
AGENT_TMP=$(cd "$AGENT_TMP" && pwd -P)
FAILURES=0
SUFFIX="multica-boundary-proof-$$"
cleanup() {
  rm -f "$WORKROOT/$SUFFIX" "$AGENT_TMP/$SUFFIX" \
    "$HOME_DIR/.local/share/opencode/$SUFFIX" "$HOME_DIR/$SUFFIX" \
    "/Users/Shared/$SUFFIX" "/private/tmp/$SUFFIX"
}
trap cleanup EXIT

check() {
  local name=$1 expected=$2; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [[ ($expected == success && $rc -eq 0) || ($expected == fail && $rc -ne 0) ]]; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s (exit %s; expected %s)\n' "$name" "$rc" "$expected"
    FAILURES=$((FAILURES + 1))
  fi
}
as_agent() {
  sudo -u multica-agent -H env HOME="$HOME_DIR" TMPDIR="$AGENT_TMP" \
    /bin/sh -c "$1"
}
in_profile() {
  sudo -u multica-agent -H env HOME="$HOME_DIR" TMPDIR="$AGENT_TMP" \
    /usr/bin/sandbox-exec -f "$PROFILE" \
    -D HOME="$HOME_DIR" -D WORKROOT="$WORKROOT" -D TMP="$AGENT_TMP" \
    /bin/sh -c "$1"
}
check_network_denied() {
  local name=$1 runner=$2 probe=$3 control=${4:-outside_agent_rule} rc=0
  # For DNS, use the same agent without Seatbelt: pf cannot see brokered
  # resolver traffic. For pf refusals, use root outside its user rule.
  if [[ $control == as_agent ]]; then
    as_agent "$probe" >/dev/null 2>&1 || rc=$?
  else
    /bin/sh -c "$probe" >/dev/null 2>&1 || rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    printf 'FAIL %s (positive control failed; denial inconclusive)\n' "$name"
    FAILURES=$((FAILURES + 1))
    return
  fi
  rc=0
  "$runner" "$probe" >/dev/null 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s (probe succeeded; expected refusal)\n' "$name"
    FAILURES=$((FAILURES + 1))
  fi
}

check 'daemon runs under sandbox-exec' success /bin/sh -c \
  'launchctl print system/com.markhomer.multica-agent-daemon | grep -Eq "program = /usr/bin/sandbox-exec" && launchctl print system/com.markhomer.multica-agent-daemon | grep -Eq "state = running"'
check 'pf enabled' success /bin/sh -c 'pfctl -s info | grep -q "Status: Enabled"'
PF_RULES=$(pfctl -a multica-agent -sr | sed -E 's/[[:space:]]*=[[:space:]]*/ /g')
pf_rule_present() { grep -Eq "$1" <<< "$PF_RULES"; }
check 'pf pass rule 8080' success pf_rule_present \
  "pass out quick.*proto tcp.*127[.]0[.]0[.]1.*8080.*user[[:space:]]+$AGENT_UID([^[:digit:]]|$)"
check 'pf pass rule 11434' success pf_rule_present \
  "pass out quick.*proto tcp.*127[.]0[.]0[.]1.*11434.*user[[:space:]]+$AGENT_UID([^[:digit:]]|$)"
check 'pf block TCP' success pf_rule_present \
  "block return out quick.*proto.*tcp.*user[[:space:]]+$AGENT_UID([^[:digit:]]|$)"
check 'pf block UDP' success pf_rule_present \
  "block return out quick.*proto.*udp.*user[[:space:]]+$AGENT_UID([^[:digit:]]|$)"

check 'sandbox starts Multica CLI' success in_profile '/usr/local/multica-agent/bin/multica --version'
check 'sandbox starts OpenCode' success in_profile '/usr/local/multica-agent/bin/opencode --version'
check 'sandbox starts git' success in_profile '/usr/bin/git --version'
check 'sandbox reads system hosts' success in_profile 'cat /etc/hosts >/dev/null'
check 'sandbox denies Mark home' fail in_profile 'ls /Users/mark'
check 'sandbox denies Beth home' fail in_profile 'ls /Users/beth'
check 'sandbox denies Hazmat agent home' fail in_profile 'ls /Users/agent'
check_network_denied 'sandbox+pf denies database 54322' in_profile 'nc -z -w 3 127.0.0.1 54322'
check_network_denied 'sandbox+pf denies Desk 8760' in_profile 'nc -z -w 3 100.108.29.78 8760'
check_network_denied 'sandbox+pf denies HTTPS internet' in_profile "curl --noproxy '*' -s -m 5 -o /dev/null https://example.com"
check_network_denied 'sandbox+pf denies public HTTP' in_profile "curl --noproxy '*' -s -m 5 -o /dev/null http://1.1.1.1/"
check_network_denied 'sandbox+pf denies public DNS' in_profile 'dscacheutil -q host -a name example.com | grep -q ip_address' as_agent
check 'sandbox+pf permits board health' success in_profile "curl --noproxy '*' -fsS -m 5 http://127.0.0.1:8080/health"
check 'sandbox+pf permits board via localhost' success in_profile "curl --noproxy '*' -fsS -m 5 http://localhost:8080/health"
check 'sandbox+pf permits Ollama' success in_profile "curl --noproxy '*' -fsS -m 5 http://127.0.0.1:11434/api/tags"
check 'sandbox permits workroot write' success in_profile ": > '$WORKROOT/$SUFFIX' && rm -f '$WORKROOT/$SUFFIX'"
check 'sandbox permits temp write' success in_profile ": > '$AGENT_TMP/$SUFFIX' && rm -f '$AGENT_TMP/$SUFFIX'"
check 'sandbox permits OpenCode data write' success in_profile ": > '$HOME_DIR/.local/share/opencode/$SUFFIX' && rm -f '$HOME_DIR/.local/share/opencode/$SUFFIX'"
check 'sandbox denies home-root write' fail in_profile ": > '$HOME_DIR/$SUFFIX'"
check 'sandbox denies Shared write' fail in_profile ": > '/Users/Shared/$SUFFIX'"
check 'sandbox denies global tmp write' fail in_profile ": > '/private/tmp/$SUFFIX'"

# Repeat the network matrix without Seatbelt: these checks isolate pf's effect.
check_network_denied 'pf alone denies database 54322' as_agent 'nc -z -w 3 127.0.0.1 54322'
check_network_denied 'pf alone denies Desk 8760' as_agent 'nc -z -w 3 100.108.29.78 8760'
check_network_denied 'pf alone denies HTTPS internet' as_agent "curl --noproxy '*' -s -m 5 -o /dev/null https://example.com"
check_network_denied 'pf alone denies public TCP' as_agent 'nc -z -w 3 1.1.1.1 443'
check_network_denied 'pf alone denies public HTTP' as_agent "curl --noproxy '*' -s -m 5 -o /dev/null http://1.1.1.1/"
echo 'INFO pf cannot block brokered DNS; Seatbelt denies DNS in the profile check above'
check 'pf alone permits board health' success as_agent "curl --noproxy '*' -fsS -m 5 http://127.0.0.1:8080/health"
check 'pf alone permits board via localhost' success as_agent "curl --noproxy '*' -fsS -m 5 http://localhost:8080/health"
check 'pf alone permits Ollama' success as_agent "curl --noproxy '*' -fsS -m 5 http://127.0.0.1:11434/api/tags"

if [[ $FAILURES -ne 0 ]]; then echo "$FAILURES proof checks failed" >&2; exit 1; fi
echo 'all proof checks passed'
