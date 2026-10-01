#!/bin/bash
# Grandin: create the dedicated, unprivileged macOS account that runs the
# Multica agent daemon (audit condition A5; homer-workspace
# docs/audit/multica/REVIEW.md). Run ONCE as an administrator:
#
#   sudo bash setup-agent-account.sh /Users/mark/.local/share/multica-grandin-stage
#
# The stage dir (prepared by the operator session, mode 700) must hold:
#   multica            daemon CLI, built from the pinned fork commit
#   opencode           OpenCode CLI binary
#   opencode.json      OpenCode config: local Ollama provider only
#   daemon-token       Multica personal access token for the synthetic workspace
#
# Idempotent: re-running repairs config and restarts the service.
set -euo pipefail

STAGE="${1:?usage: sudo bash setup-agent-account.sh <stage-dir>}"
U=multica-agent
G=multica-agent
H=/Users/$U
BIN=/usr/local/multica-agent/bin
PLIST=/Library/LaunchDaemons/com.markhomer.multica-agent-daemon.plist
MODEL="ollama/qwen3.6:35b"

[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
for f in multica opencode opencode.json daemon-token; do
  [[ -s "$STAGE/$f" ]] || { echo "missing $STAGE/$f"; exit 1; }
done

echo "== 1. group + hidden standard user with its OWN primary group (not staff)"
if ! dscl . -read /Groups/$G >/dev/null 2>&1; then
  dseditgroup -o create -r "Multica agent (Grandin spike)" $G
fi
GID=$(dscl . -read /Groups/$G PrimaryGroupID | awk '{print $2}')
if ! id $U >/dev/null 2>&1; then
  # Random password nobody knows; the account is never logged into interactively.
  sysadminctl -addUser $U -fullName "Multica Agent (Grandin spike)" \
    -shell /bin/zsh -home $H -password "$(openssl rand -base64 33)"
fi
dscl . -create /Users/$U PrimaryGroupID "$GID"
dscl . -create /Users/$U IsHidden 1
dseditgroup -o edit -d $U -t user staff 2>/dev/null || true
dseditgroup -o edit -d $U -t user admin 2>/dev/null || true
createhomedir -c -u $U >/dev/null 2>&1 || true
chown -R $U:$G $H
chmod 700 $H

echo "== 2. root-owned binaries the agent can run but not modify"
install -d -o root -g wheel -m 755 $BIN
install -o root -g wheel -m 755 "$STAGE/multica" "$STAGE/opencode" $BIN/

echo "== 3. OpenCode config: local Ollama only, pinned model, no autoupdate/share"
install -d -o $U -g $G -m 700 $H/.config $H/.config/opencode
install -o $U -g $G -m 600 "$STAGE/opencode.json" $H/.config/opencode/opencode.json

echo "== 4. Multica CLI config + token (loopback server; token never on argv)"
run_as() { sudo -u $U -H env HOME=$H PATH=$BIN:/usr/bin:/bin "$@"; }
run_as $BIN/multica config set server_url http://127.0.0.1:8080
run_as $BIN/multica config set app_url http://homer-studio:8780
TOKEN_TMP=$(mktemp "$H/.tok.XXXXXX"); cat "$STAGE/daemon-token" > "$TOKEN_TMP"
chown $U:$G "$TOKEN_TMP"; chmod 600 "$TOKEN_TMP"
run_as /bin/sh -c "$BIN/multica login --token=\"\$(cat '$TOKEN_TMP')\"" >/dev/null
rm -f "$TOKEN_TMP" "$STAGE/daemon-token"

echo "== 5. LaunchDaemon running as $U (auto-update off, only OpenCode on PATH)"
cat > $PLIST <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.markhomer.multica-agent-daemon</string>
  <key>UserName</key><string>$U</string>
  <key>GroupName</key><string>$G</string>
  <key>WorkingDirectory</key><string>$H</string>
  <key>ProgramArguments</key><array>
    <string>$BIN/multica</string><string>daemon</string><string>start</string>
    <string>--foreground</string><string>--no-auto-update</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>$H</string>
    <key>PATH</key><string>$BIN:/usr/bin:/bin</string>
    <key>MULTICA_DAEMON_AUTO_UPDATE</key><string>false</string>
    <key>MULTICA_OPENCODE_PATH</key><string>$BIN/opencode</string>
    <key>MULTICA_OPENCODE_MODEL</key><string>$MODEL</string>
    <key>OPENCODE_DISABLE_AUTOUPDATE</key><string>true</string>
    <key>OPENCODE_DISABLE_SHARE</key><string>true</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$H/multica-daemon.out.log</string>
  <key>StandardErrorPath</key><string>$H/multica-daemon.err.log</string>
</dict></plist>
PL
chown root:wheel $PLIST; chmod 644 $PLIST
launchctl bootout system $PLIST 2>/dev/null || true
launchctl bootstrap system $PLIST

echo "== 6. proofs (each line must say DENIED / ABSENT)"
id $U
probe() { if run_as /bin/sh -c "$2" >/dev/null 2>&1; then echo "FAIL  $1 (agent CAN do this)"; else echo "DENIED $1"; fi; }
probe "list /Users/mark"              "ls /Users/mark"
probe "read Mark's SSH dir"           "ls /Users/mark/.ssh"
probe "read Mark's gh login"          "cat /Users/mark/.config/gh/hosts.yml"
probe "list /Users/beth"              "ls /Users/beth"
probe "write the agent binaries"      "touch $BIN/multica"
for c in claude codex gh ssh-agent; do
  if run_as /bin/sh -c "command -v $c" >/dev/null 2>&1; then echo "PRESENT $c on agent PATH"; else echo "ABSENT $c on agent PATH"; fi
done
ls -A $H/.ssh 2>/dev/null && echo "FAIL agent has .ssh" || echo "ABSENT agent ~/.ssh"
sleep 3; launchctl print system/com.markhomer.multica-agent-daemon | grep -E "state|pid" | head -3
echo "done."
