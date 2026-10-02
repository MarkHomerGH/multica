#!/bin/bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo 'run with sudo' >&2; exit 1; }
PROFILE=/usr/local/multica-agent/multica-agent.sb
DAEMON_PLIST=/Library/LaunchDaemons/com.markhomer.multica-agent-daemon.plist
DAEMON_LOG=/Users/multica-agent/.multica/daemon.log
DAEMON_STDERR=/Users/multica-agent/multica-daemon.err.log
RECEIPT_ROOT=/var/root/multica-boundary-receipts
AGENT_UID=$(id -u multica-agent)
HOME_DIR=/Users/multica-agent
WORKROOT=$HOME_DIR/multica_workspaces
AGENT_TMP=$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:TMPDIR' "$DAEMON_PLIST")
AGENT_TMP=$(cd "$AGENT_TMP" && pwd -P)
[[ $AGENT_TMP =~ ^/private/var/folders/[A-Za-z0-9_./-]+$ ]] || {
  echo 'installed daemon plist has an invalid agent temp directory' >&2; exit 1;
}
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
run_as_agent_from() {
  local cwd=$1; shift
  sudo -H -u multica-agent env HOME="$HOME_DIR" TMPDIR="$AGENT_TMP" \
    /bin/sh -c 'cd "$1" || exit 1; shift; exec "$@"' sh "$cwd" "$@"
}
as_agent() {
  run_as_agent_from "$WORKROOT" /bin/sh -c "$1"
}
in_profile_from() {
  local cwd=$1 command=$2
  run_as_agent_from "$cwd" \
    /usr/bin/sandbox-exec -f "$PROFILE" \
    -D HOME="$HOME_DIR" -D WORKROOT="$WORKROOT" -D TMP="$AGENT_TMP" \
    /bin/sh -c "$command"
}
in_profile() {
  in_profile_from "$WORKROOT" "$1"
}
scan_new_log_bytes() {
  local log=$1 baseline=$2 required=$3
  local baseline_inode='' baseline_size='' current_inode='' current_size=''
  local final_inode='' final_size=''
  local statuses
  [[ -f $baseline ]] || return 2
  read -r baseline_inode baseline_size < "$baseline" || return 2
  if [[ ! -f $log ]]; then
    [[ $required == optional && $baseline_inode == missing ]] && return 0
    return 2
  fi
  read -r current_inode current_size < <(stat -f '%i %z' "$log") || return 2
  [[ $current_inode =~ ^[0-9]+$ && $current_size =~ ^[0-9]+$ ]] || return 2
  if [[ $baseline_inode == missing ]]; then
    baseline_size=0
  elif [[ ! $baseline_inode =~ ^[0-9]+$ || ! $baseline_size =~ ^[0-9]+$ ||
          $baseline_inode != "$current_inode" || $current_size -lt $baseline_size ]]; then
    return 2
  fi
  [[ $required == optional || $current_size -gt $baseline_size ]] || return 2
  [[ $current_size -gt $baseline_size ]] || return 0
  set +e
  tail -c "+$((baseline_size + 1))" "$log" | grep -F 'failed to register runtimes' >/dev/null
  statuses=("${PIPESTATUS[@]}")
  set -e
  [[ ${statuses[0]} -eq 0 && ${statuses[1]} -le 1 ]] || return 2
  read -r final_inode final_size < <(stat -f '%i %z' "$log") || return 2
  [[ $final_inode == "$current_inode" && $final_size =~ ^[0-9]+$ &&
     $final_size -ge $current_size ]] || return 2
  [[ ${statuses[1]} -ne 0 ]] || return 1
}
check_daemon_log() {
  local receipt='' candidate log_rc=0 stderr_rc=0
  for candidate in "$RECEIPT_ROOT"/*; do
    [[ -f $candidate/install-complete ]] || continue
    if [[ -z $receipt || $candidate > $receipt ]]; then receipt=$candidate; fi
  done
  if [[ -z $receipt ]]; then
    echo 'INCONCLUSIVE daemon runtime registration log (completed install receipt unavailable)'
    FAILURES=$((FAILURES + 1)); return
  fi
  scan_new_log_bytes "$DAEMON_LOG" "$receipt/daemon-log-baseline.txt" required || log_rc=$?
  scan_new_log_bytes "$DAEMON_STDERR" "$receipt/daemon-stderr-baseline.txt" optional || stderr_rc=$?
  if [[ $log_rc -eq 1 ]]; then
    echo 'FAIL daemon runtime registration log (failure after install in daemon.log)'
    FAILURES=$((FAILURES + 1)); return
  elif [[ $stderr_rc -eq 1 ]]; then
    echo 'FAIL daemon runtime registration log (failure after install in launchd stderr)'
    FAILURES=$((FAILURES + 1)); return
  elif [[ $log_rc -ne 0 ]]; then
    echo 'INCONCLUSIVE daemon runtime registration log (daemon.log missing, rotated, or unchanged)'
    FAILURES=$((FAILURES + 1)); return
  elif [[ $stderr_rc -ne 0 ]]; then
    echo 'INCONCLUSIVE daemon runtime registration log (launchd stderr rotated or unreadable)'
    FAILURES=$((FAILURES + 1)); return
  fi
  echo 'PASS daemon runtime registration log (no failure after install)'
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
check 'daemon process is running' success /usr/bin/pgrep -u multica-agent -f 'multica daemon start'
check_daemon_log
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
check 'sandbox starts OpenCode from HOME' success in_profile_from "$HOME_DIR" '/usr/local/multica-agent/bin/opencode --version'
check 'sandbox starts git' success in_profile '/usr/bin/git --version'
check 'sandbox reads system hosts' success in_profile 'cat /etc/hosts >/dev/null'
check 'sandbox lists agent HOME' success in_profile "ls '$HOME_DIR' >/dev/null"
check 'sandbox denies Users listing' fail in_profile 'ls /Users'
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
