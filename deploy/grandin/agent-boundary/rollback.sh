#!/bin/bash
set -euo pipefail

DRY=0
RECEIPT=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --receipt) [[ $# -ge 2 ]] || { echo '--receipt needs a directory' >&2; exit 2; }; RECEIPT=$2; shift 2 ;;
    *) echo 'usage: bash rollback.sh [--dry-run] [--receipt RECEIPT_DIR]' >&2; exit 2 ;;
  esac
done
if [[ $DRY -eq 0 && $EUID -ne 0 ]]; then echo 'run with sudo' >&2; exit 1; fi
if [[ -z $RECEIPT ]]; then
  if [[ $DRY -eq 1 ]]; then
    RECEIPT=/var/root/multica-boundary-receipts/original-install
  else
    for candidate in /var/root/multica-boundary-receipts/*; do
      if [[ -f $candidate/anchor-appended && -f $candidate/daemon-before.plist && -f $candidate/install-complete ]]; then
        RECEIPT=$candidate
        break
      fi
    done
    [[ -n $RECEIPT ]] || { echo 'no original install receipt found; pass --receipt' >&2; exit 1; }
  fi
fi
DAEMON_PLIST=/Library/LaunchDaemons/com.markhomer.multica-agent-daemon.plist
BOOT_PLIST=/Library/LaunchDaemons/com.markhomer.pf-multica.plist
say() { printf '+ %s\n' "$*"; }
run() { say "$*"; if [[ $DRY -eq 0 ]]; then "$@"; fi; }

[[ $DRY -eq 1 || -f $RECEIPT/daemon-before.plist ]] || {
  echo "missing daemon backup: $RECEIPT/daemon-before.plist" >&2; exit 1;
}
[[ $DRY -eq 1 || -f $RECEIPT/anchor-appended ]] || {
  echo "receipt did not add the pf.conf stanza: $RECEIPT; use the original install receipt" >&2; exit 1;
}
[[ $DRY -eq 1 || -f $RECEIPT/install-complete ]] || {
  echo "install did not complete: $RECEIPT" >&2; exit 1;
}

say 'launchctl bootout system/com.markhomer.multica-agent-daemon (not-loaded tolerated)'
if [[ $DRY -eq 0 ]]; then launchctl bootout system/com.markhomer.multica-agent-daemon 2>/dev/null || true; fi
run install -o root -g wheel -m 0644 "$RECEIPT/daemon-before.plist" "$DAEMON_PLIST"
run launchctl bootstrap system "$DAEMON_PLIST"

say 'launchctl bootout system/com.markhomer.pf-multica (not-loaded tolerated)'
if [[ $DRY -eq 0 ]]; then launchctl bootout system/com.markhomer.pf-multica 2>/dev/null || true; fi

# Remove only the exact three-line anchor stanza and its two marker comments.
# Never restore a saved whole pf.conf: another owner's anchors may have changed.
say 'mktemp /etc/pf.conf.multica-rollback.XXXXXX'
say "sed -e '/^# BEGIN multica-agent anchor$/d' -e '/^anchor \"multica-agent\"$/d' -e '/^load anchor \"multica-agent\" from \"\/etc\/pf.anchors\/multica-agent\"$/d' -e '/^# END multica-agent anchor$/d' /etc/pf.conf > <temporary pf.conf>"
if [[ $DRY -eq 0 ]]; then
  PF_TMP=$(mktemp /etc/pf.conf.multica-rollback.XXXXXX)
  trap 'rm -f "$PF_TMP"' EXIT
  sed -e '/^# BEGIN multica-agent anchor$/d' \
      -e '/^anchor "multica-agent"$/d' \
      -e '/^load anchor "multica-agent" from "\/etc\/pf.anchors\/multica-agent"$/d' \
      -e '/^# END multica-agent anchor$/d' \
      /etc/pf.conf > "$PF_TMP"
else
  PF_TMP='<temporary pf.conf>'
fi
run pfctl -nf "$PF_TMP"
run install -o root -g wheel -m 0644 "$PF_TMP" /etc/pf.conf
run rm -f /etc/pf.anchors/multica-agent
run rm -f "$BOOT_PLIST"
run pfctl -f /etc/pf.conf
echo "restored daemon from $RECEIPT; pf remains enabled"
