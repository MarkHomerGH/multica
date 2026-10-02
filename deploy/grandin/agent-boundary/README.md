# Grandin Multica agent boundary (macOS)

This directory adds a Seatbelt filesystem boundary around the `multica-agent`
LaunchDaemon and a separate pf anchor. Both layers restrict the daemon's TCP
destinations to the local Multica backend (127.0.0.1:8080) and Ollama
(127.0.0.1:11434). It does not modify Hazmat's `agent` anchor or files.

## Files

| File | Purpose |
| --- | --- |
| `multica-agent.sb` | Default-deny Seatbelt profile: system startup reads, named agent state and workspaces writes, destination-scoped outbound sockets, and final credential denies. |
| `pf.anchor` | Per-user TCP allowlist and TCP/UDP block. |
| `com.markhomer.multica-agent-daemon.plist` | The existing daemon arguments and environment, with `sandbox-exec` in front. |
| `install.sh` | Records a timestamped receipt, installs both layers and the pf boot job, waits for bootouts before bootstrapping, then confirms both jobs loaded. Its dry-run parse-checks pf and exercises the live rule verifier. |
| `rollback.sh` | Restores the saved daemon plist and removes only this anchor's pf.conf stanza and installed files. |
| `proof-test.sh` | Prints a PASS/FAIL or INCONCLUSIVE result for daemon, pf, filesystem, and network probes. |

The named writable home paths come from
`deploy/grandin/setup-agent-account.sh:53-54` (`.config/opencode`),
`server/internal/cli/config.go:13` (`.multica/config.json`), and Hazmat
`hazmat/containment/agent_home_manifest.go:164,175,198` (`.cache`,
`.config/opencode`, `.opencode`). OpenCode's XDG data and state directories are
`~/.local/share/opencode` and `~/.local/state/opencode`. The installer creates
the named directories before restarting the daemon. No home-root write grant
exists.

## Operator sequence

Run these from this directory after the account and local services exist:

```sh
bash install.sh --dry-run
sudo bash install.sh
sudo bash proof-test.sh
```

The installer prints its receipt path under
`/var/root/multica-boundary-receipts/<UTC timestamp>/`. It records the prior
pf status, main rules, Hazmat `agent` rules, daemon state and plist, the pf
enable token, effective Multica anchor rules, and the account's temp path.
The plist in this repository contains `__MULTICA_AGENT_TMP__` twice. During
installation, `sudo -u multica-agent /usr/bin/getconf DARWIN_USER_TEMP_DIR`
provides the account's actual temp directory. `install.sh` substitutes that
path, resolved through `/var`'s symlink, in both the Seatbelt `-D TMP=`
argument and `TMPDIR` environment variable.
The profile itself uses only `HOME`, `WORKROOT`, and `TMP` parameters for
agent-specific paths. The daemon starts in `multica_workspaces`; the proof
runs agent probes there, with an additional OpenCode version probe from HOME.
The proof reads `TMPDIR` from the installed daemon plist to use the same
temporary directory. The daemon's PATH selects `/usr/bin/git` from Command
Line Tools. The pf boot job runs `/sbin/pfctl -E -f /etc/pf.conf` at load, so
pf is enabled after a reboot.

## Live-sitting finding and fix

On the Studio, all boundary denials passed and pf rules were verified, but the
daemon exited with `failed to register runtimes for any of the 1 workspace(s)`.
Seatbelt logged OpenCode and `path_helper` being denied reads under the agent
HOME, plus a `vfs.disk-space` system-info denial. It also denied listing
`/Users`, as intended. The daemon's OpenCode version probe ran from HOME;
OpenCode exited with `An unknown error occurred (Unexpected)` when it could
not read that directory. After install, `launchctl print` could not find the
daemon job; a manual bootstrap succeeded, consistent with a bootout/bootstrap
race. The proof script's inherited cwd and temp environment made two checks
unrepresentative of the daemon.

The profile now permits read access to the literal HOME directory entry and
read-only system information. It grants no read access to `/Users` contents;
the final credential-path denies still apply beneath HOME. The plist starts
the daemon in `multica_workspaces`. The installer waits up to 15 seconds for
each booted-out job to disappear, then confirms each bootstrap with
`launchctl print`. The proof runs agent commands with `sudo -H`, the installed
TMPDIR, and an explicit cwd; it checks OpenCode from both the workspace and
HOME, confirms the daemon process exists, and scans the structured log and
launchd stderr from positions recorded before this install. If those log
positions cannot be checked, the result is INCONCLUSIVE.

pf resolves `user multica-agent` to the account's numeric UID when it loads
the anchor. The installer and proof test use `id -u multica-agent` to verify
the UID shown by `pfctl`. The dry-run prints `pf self-test: PASS` only after
parsing a temporary main pf.conf that loads the shipped anchor and checking
all four rendered rules with the real-install verifier. If any step from
appending the stanza through live rule verification fails, the installer
surgically removes its stanza and marker, removes its anchor file, restores
any anchor file that was present before this attempt, reloads `/etc/pf.conf`,
and exits with an error. Re-running `install.sh` is safe and idempotent.

For rollback, use the printed receipt explicitly when possible:

```sh
bash rollback.sh --dry-run --receipt /var/root/multica-boundary-receipts/<UTC timestamp>
sudo bash rollback.sh --receipt /var/root/multica-boundary-receipts/<UTC timestamp>
```

With no `--receipt`, real rollback selects the earliest completed install
receipt that added the anchor stanza. Incomplete installs are not selected.
A receipt from a later install cannot remove a stanza it did not add; pass the
original receipt when choosing one explicitly. Rollback
removes only the exact Multica pf.conf lines and reloads pf; it does not disable
pf or replace pf.conf with an older whole-file backup. A failed install-time pf
parse, load, enable, or rule check removes the install's pf changes before
exiting.

## Known limits

- Apple has deprecated `sandbox-exec`, though it remains present on macOS 27.
  Hazmat uses the same SBPL language through `sandbox_init` in a compiled
  helper. This implementation uses the CLI because this host has no Go
  toolchain for building such a helper.
- Seatbelt and pf share the same kernel as the services they protect. They are
  operating-system controls, not a separate virtual machine.
- The profile deliberately permits executing tools in `/bin`, `/usr/bin`, and
  `/usr/libexec` because a coding agent runs shell tools. Directory-service
  tools such as `dscl` can enumerate account names even though direct listing
  of `/Users` is denied. This reveals names, not home contents.
- The daemon can listen on loopback for its health endpoint (default port
  `127.0.0.1:19514`). On this macOS, Seatbelt denies binding the board's and
  Ollama's ports (`8080` and `11434`) on both `127.0.0.1` and `0.0.0.0`.
  Binding `0.0.0.0` on other ports is allowed; it opens a listener but reaches
  nothing new. Re-verify this behavior after any macOS upgrade.
- pf `user` matching applies only to TCP and UDP. ICMP is not filtered by this
  per-user rule. Both Seatbelt and pf restrict direct TCP connections to the
  board and Ollama ports. Seatbelt's two destination-scoped outbound rules
  also block DNS lookups for other names. macOS brokers ordinary DNS through
  mDNSResponder, so pf cannot see that resolver traffic as `multica-agent`.
  Any URL used by the daemon or OpenCode must use `127.0.0.1` or `localhost`;
  a hostname that requires DNS fails by design. The board is reachable by
  both `127.0.0.1` and `localhost` from `/etc/hosts`.
- Hazmat rollback copies **its** saved pf.conf over the current file and can
  silently remove the Multica anchor lines. Re-run `install.sh` after any
  `hazmat rollback`, then run `proof-test.sh` again. `hazmat check` and
  `hazmat doctor` belong to Hazmat and are not part of this proof.
- Positive health checks require the Multica backend and Ollama to be running
  locally. Every negative network probe first runs the same command outside
  the denying layer: as the agent without Seatbelt for DNS, or as root outside
  the agent's pf user rule for TCP. If that control fails, the proof reports
  FAIL because the denial is inconclusive. The Desk probe uses its
  tailnet listener at `100.108.29.78:8760`; the database probe uses
  `127.0.0.1:54322`. DNS denial is evidence for Seatbelt only, never pf.

## Deviations

The worker sandbox rejected `sandbox_apply` with `Operation not permitted`
when invoking `/usr/bin/sandbox-exec`, so runtime Seatbelt probes could not
run here. The profile parsed far enough to reach `sandbox_apply`; the external
check must execute its success and denial probes outside this worker sandbox.
No privileged install, pf, launchctl, or account-changing command was run.
The live-sitting results above came from the Studio run before these fixes;
this worktree cannot establish that the revised daemon registers a runtime.

### Live sitting 2 (2026-10-02): working directory back to HOME

Starting the daemon in `multica_workspaces` made it refuse with `daemon start is not available inside a
daemon-managed task`: Multica walks up from the working directory looking for
`.multica/daemon_task_context.json` (`server/cmd/multica/cmd_agent.go` `daemonTaskContextMarkerPath`), and a
task marker lives under the workspaces root. The daemon starts in HOME again; the profile's
`(allow file-read* (literal (param "HOME")))` is what lets OpenCode's runtime check run from there.
