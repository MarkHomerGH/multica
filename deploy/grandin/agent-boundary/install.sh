#!/bin/bash
set -euo pipefail
set -o errtrace

DRY=0
case "${1:-}" in
  --dry-run) DRY=1; shift ;;
  '') ;;
  *) echo "usage: bash install.sh [--dry-run]" >&2; exit 2 ;;
esac
[[ $# -eq 0 ]] || { echo "usage: bash install.sh [--dry-run]" >&2; exit 2; }
if [[ $DRY -eq 0 && $EUID -ne 0 ]]; then echo 'run with sudo' >&2; exit 1; fi

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TS=$(date -u +%Y%m%dT%H%M%SZ)
RECEIPT=/var/root/multica-boundary-receipts/$TS
PF_BACKUP=/etc/pf.conf.multica-backup.$TS
DAEMON_PLIST=/Library/LaunchDaemons/com.markhomer.multica-agent-daemon.plist
BOOT_PLIST=/Library/LaunchDaemons/com.markhomer.pf-multica.plist
PROFILE=/usr/local/multica-agent/multica-agent.sb
AGENT_UID=$(id -u multica-agent)

say() { printf '+ %s\n' "$*"; }
run() { say "$*"; if [[ $DRY -eq 0 ]]; then "$@"; fi; }
capture() {
  local file=$1; shift
  say "$* > $file"
  if [[ $DRY -eq 0 ]]; then "$@" > "$file" 2>&1; fi
}
wait_for_service_gone() {
  local label=$1 elapsed
  say "wait for launchctl print system/$label to report service gone (15s timeout)"
  [[ $DRY -eq 0 ]] || return 0
  for ((elapsed=0; elapsed<15; elapsed++)); do
    if ! launchctl print "system/$label" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "timed out waiting for system/$label to unload after bootout" >&2
  return 1
}
confirm_service_loaded() {
  local label=$1
  say "launchctl print system/$label (confirm loaded)"
  [[ $DRY -eq 0 ]] || return 0
  if ! launchctl print "system/$label" >/dev/null 2>&1; then
    echo "bootstrap returned but system/$label is not loaded" >&2
    return 1
  fi
}

verify_pf_rules() {
  local rules=$1 normalized
  normalized=$(sed -E 's/[[:space:]]*=[[:space:]]*/ /g' "$rules") || return 1
  grep -Eq "pass out quick.*proto tcp.*127[.]0[.]0[.]1.*8080.*user[[:space:]]+$AGENT_UID([^[:digit:]]|$)" <<< "$normalized" || {
    echo 'missing TCP 8080 pass rule' >&2; return 1;
  }
  grep -Eq "pass out quick.*proto tcp.*127[.]0[.]0[.]1.*11434.*user[[:space:]]+$AGENT_UID([^[:digit:]]|$)" <<< "$normalized" || {
    echo 'missing TCP 11434 pass rule' >&2; return 1;
  }
  local protocol
  for protocol in tcp udp; do
    grep -Eq "block return out quick.*proto.*$protocol.*user[[:space:]]+$AGENT_UID([^[:digit:]]|$)" <<< "$normalized" || {
      echo "missing $protocol block rule" >&2; return 1;
    }
  done
}

# Exercise the same verifier against pfctl's numeric-UID rendering without
# changing the live firewall or touching /etc.
if [[ $DRY -eq 1 ]]; then
  PF_SELFTEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/multica-pf-selftest.XXXXXX")
  trap 'rm -rf "$PF_SELFTEST_DIR"' EXIT
  cat > "$PF_SELFTEST_DIR/main.conf" <<PF_SELFTEST
anchor "multica-agent"
load anchor "multica-agent" from "$HERE/pf.anchor"
PF_SELFTEST
  if ! /sbin/pfctl -nvf "$PF_SELFTEST_DIR/main.conf" > "$PF_SELFTEST_DIR/rules.txt"; then
    echo 'pf self-test: FAIL (parse)' >&2; exit 1
  fi
  if ! verify_pf_rules "$PF_SELFTEST_DIR/rules.txt"; then
    echo 'pf self-test: FAIL (rules)' >&2; exit 1
  fi
  echo 'pf self-test: PASS'
fi

rollback_pf_after_verification_failure() {
  local pf_tmp
  echo "pf setup or verification failed; removing this install's pf changes" >&2
  if [[ ${PF_STANZA_APPENDED:-0} -eq 1 || -f $RECEIPT/anchor-appended ]]; then
    pf_tmp=$(mktemp /etc/pf.conf.multica-verify.XXXXXX) || return 1
    sed -e '/^# BEGIN multica-agent anchor$/d' \
        -e '/^anchor "multica-agent"$/d' \
        -e '/^load anchor "multica-agent" from "\/etc\/pf.anchors\/multica-agent"$/d' \
        -e '/^# END multica-agent anchor$/d' \
        /etc/pf.conf > "$pf_tmp" || { rm -f "$pf_tmp"; return 1; }
    install -o root -g wheel -m 0644 "$pf_tmp" /etc/pf.conf || { rm -f "$pf_tmp"; return 1; }
    rm -f "$pf_tmp" || echo "could not remove temporary pf.conf file: $pf_tmp" >&2
  fi
  rm -f /etc/pf.anchors/multica-agent || return 1
  if [[ -f $RECEIPT/anchor-before ]]; then
    install -o root -g wheel -m 0644 "$RECEIPT/anchor-before" /etc/pf.anchors/multica-agent || return 1
  fi
  /sbin/pfctl -f /etc/pf.conf || return 1
  rm -f "$RECEIPT/anchor-appended" || return 1
  echo 'pf changes removed and pf.conf reloaded' >&2
}

fail_pf_install() {
  trap - ERR
  if ! rollback_pf_after_verification_failure; then
    echo 'pf cleanup failed; inspect /etc/pf.conf before retrying' >&2
  fi
  echo 'install failed; re-running install.sh is safe and idempotent' >&2
  exit 1
}

# (a) Snapshot effective state before the first machine write.
run mkdir -p "$RECEIPT"
capture "$RECEIPT/pf-info.txt" pfctl -s info
capture "$RECEIPT/pf-rules.txt" pfctl -sr
capture "$RECEIPT/hazmat-agent-rules.txt" pfctl -a agent -sr
say "launchctl print system/com.markhomer.multica-agent-daemon > $RECEIPT/daemon-before.txt"
if [[ $DRY -eq 0 ]]; then
  launchctl print system/com.markhomer.multica-agent-daemon > "$RECEIPT/daemon-before.txt" 2>&1 || true
fi

# (b)-(d) Preserve pf.conf, install only our anchor, append only our own lines.
run cp /etc/pf.conf "$PF_BACKUP"
if [[ $DRY -eq 0 && -f /etc/pf.anchors/multica-agent ]]; then
  cp /etc/pf.anchors/multica-agent "$RECEIPT/anchor-before"
fi
run install -o root -g wheel -m 0644 "$HERE/pf.anchor" /etc/pf.anchors/multica-agent
PF_STANZA_APPENDED=0
if [[ $DRY -eq 0 ]]; then trap 'fail_pf_install' ERR; fi
say "grep -q 'anchor \"multica-agent\"' /etc/pf.conf"
if [[ $DRY -eq 1 ]] || ! grep -q 'anchor "multica-agent"' /etc/pf.conf; then
  say "cat >> /etc/pf.conf <<'PF_MULTICA'"
  if [[ $DRY -eq 0 ]]; then
    PF_STANZA_APPENDED=1
    cat >> /etc/pf.conf <<'PF_MULTICA'
# BEGIN multica-agent anchor
anchor "multica-agent"
load anchor "multica-agent" from "/etc/pf.anchors/multica-agent"
# END multica-agent anchor
PF_MULTICA
  fi
  run touch "$RECEIPT/anchor-appended"
else
  # An anchor declaration without our load line would pass the guard but
  # leave the policy empty after pfctl -f. Stop before reloading pf.
  grep -Fxq 'load anchor "multica-agent" from "/etc/pf.anchors/multica-agent"' /etc/pf.conf || {
    echo 'multica-agent anchor exists without its load line' >&2; exit 1;
  }
fi

# (e) Parse before loading. Any failure through verification surgically removes
# this attempt's pf changes; rollback.sh does the same after a successful install.
say 'pfctl -nf /etc/pf.conf'
if [[ $DRY -eq 0 ]]; then pfctl -nf /etc/pf.conf; fi

# (f)-(h) Load, enable, record the enable token, and verify both allow/deny rules.
run pfctl -f /etc/pf.conf
capture "$RECEIPT/pf-enable-token.txt" pfctl -E
say "cat $RECEIPT/pf-enable-token.txt"
if [[ $DRY -eq 0 ]]; then cat "$RECEIPT/pf-enable-token.txt"; fi
say "pfctl -a multica-agent -sr > $RECEIPT/multica-agent-rules.txt"
if [[ $DRY -eq 0 ]]; then
  pfctl -a multica-agent -sr > "$RECEIPT/multica-agent-rules.txt" 2>&1
  cat "$RECEIPT/multica-agent-rules.txt"
  verify_pf_rules "$RECEIPT/multica-agent-rules.txt"
  trap - ERR
fi

# (i) Install the profile and the named, agent-owned state directories.
run install -o root -g wheel -m 0644 "$HERE/multica-agent.sb" "$PROFILE"
run install -d -o multica-agent -g multica-agent -m 0700 /Users/multica-agent/multica_workspaces /Users/multica-agent/.config /Users/multica-agent/.config/opencode /Users/multica-agent/.local /Users/multica-agent/.local/share /Users/multica-agent/.local/share/opencode /Users/multica-agent/.local/state /Users/multica-agent/.local/state/opencode /Users/multica-agent/.cache /Users/multica-agent/.multica /Users/multica-agent/.opencode

# (j) Preserve the old daemon, substitute the account's Darwin temp directory,
# and install a separate boot job that ENABLES pf (Hazmat's job only loads it).
say "cp $DAEMON_PLIST $RECEIPT/daemon-before.plist"
if [[ $DRY -eq 0 ]]; then cp "$DAEMON_PLIST" "$RECEIPT/daemon-before.plist"; fi
say 'sudo -u multica-agent /usr/bin/getconf DARWIN_USER_TEMP_DIR'
if [[ $DRY -eq 0 ]]; then
  AGENT_TMP=$(sudo -u multica-agent /usr/bin/getconf DARWIN_USER_TEMP_DIR)
  AGENT_TMP=$(cd "$AGENT_TMP" && pwd -P)
  [[ $AGENT_TMP =~ ^/private/var/folders/[A-Za-z0-9_./-]+$ ]] || { echo 'invalid agent temp directory' >&2; exit 1; }
  printf '%s\n' "$AGENT_TMP" > "$RECEIPT/agent-temp-dir.txt"
  sed "s|__MULTICA_AGENT_TMP__|$AGENT_TMP|g" "$HERE/com.markhomer.multica-agent-daemon.plist" > "$RECEIPT/daemon-installed.plist"
fi
say "sed 's|__MULTICA_AGENT_TMP__|<account DARWIN_USER_TEMP_DIR>|g' $HERE/com.markhomer.multica-agent-daemon.plist > $RECEIPT/daemon-installed.plist"
run install -o root -g wheel -m 0644 "$RECEIPT/daemon-installed.plist" "$DAEMON_PLIST"
say "cat > $RECEIPT/pf-boot.plist <<'PLIST'"
if [[ $DRY -eq 0 ]]; then
  cat > "$RECEIPT/pf-boot.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.markhomer.pf-multica</string>
  <key>ProgramArguments</key><array>
    <string>/sbin/pfctl</string><string>-E</string><string>-f</string><string>/etc/pf.conf</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
fi
run install -o root -g wheel -m 0644 "$RECEIPT/pf-boot.plist" "$BOOT_PLIST"
say 'launchctl bootout system/com.markhomer.pf-multica (not-loaded tolerated)'
if [[ $DRY -eq 0 ]]; then launchctl bootout system/com.markhomer.pf-multica 2>/dev/null || true; fi
wait_for_service_gone com.markhomer.pf-multica
run launchctl bootstrap system "$BOOT_PLIST"
confirm_service_loaded com.markhomer.pf-multica

# (k) The old service may be stopped already; all other errors are fatal.
say 'launchctl bootout system/com.markhomer.multica-agent-daemon (not-loaded tolerated)'
if [[ $DRY -eq 0 ]]; then launchctl bootout system/com.markhomer.multica-agent-daemon 2>/dev/null || true; fi
wait_for_service_gone com.markhomer.multica-agent-daemon
# Record log positions before this daemon starts. The proof checks only new
# bytes and reports inconclusive if rotation obscures a baseline.
say "record $RECEIPT/daemon-log-baseline.txt and daemon-stderr-baseline.txt"
if [[ $DRY -eq 0 ]]; then
  DAEMON_LOG=/Users/multica-agent/.multica/daemon.log
  if [[ -f $DAEMON_LOG ]]; then
    stat -f '%i %z' "$DAEMON_LOG" > "$RECEIPT/daemon-log-baseline.txt"
  else
    echo missing > "$RECEIPT/daemon-log-baseline.txt"
  fi
  DAEMON_STDERR=/Users/multica-agent/multica-daemon.err.log
  if [[ -f $DAEMON_STDERR ]]; then
    stat -f '%i %z' "$DAEMON_STDERR" > "$RECEIPT/daemon-stderr-baseline.txt"
  else
    echo missing > "$RECEIPT/daemon-stderr-baseline.txt"
  fi
fi
run launchctl bootstrap system "$DAEMON_PLIST"
confirm_service_loaded com.markhomer.multica-agent-daemon

# (l) Keep receipts for rollback and operator review.
run touch "$RECEIPT/install-complete"
echo "receipt: $RECEIPT"
echo "next: sudo bash $HERE/proof-test.sh"
