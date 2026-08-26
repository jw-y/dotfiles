# Codex Remote Control on a headless host

This runbook covers a Linux machine reached through SSH, such as `oreo`, that
should remain available through Codex Remote Control. It was verified with the
standalone Codex CLI `0.149.1` on Ubuntu 24.04 on 2026-08-26. The app-server
daemon and Remote Control are experimental.

## Install and authenticate

Use the official standalone installer. Do not keep parallel npm, Homebrew, or
system-package installations on `PATH`.

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
type -a codex
readlink -f "$(command -v codex)"
codex --version
codex doctor
```

The executable should resolve through `~/.local/bin/codex` to
`~/.codex/packages/standalone/current/codex`, and Doctor should report a
consistent installation.

Remote Control enrollment can require a recent ChatGPT login with MFA
assurance. If enrollment reports that MFA is required, enable MFA in ChatGPT
**Settings > Security**, then refresh the CLI login:

```bash
codex logout
codex login
codex login status
```

With `cdx`, the active `~/.codex` profile owns the daemon, credentials, and
Remote Control enrollment. If a verified daemon-managed Remote Control server
is running, `cdx use <profile>` stops it safely and restarts it for the new
profile. If Remote Control was stopped or unmanaged, start it manually after
the switch. Never commit `auth.json`, Codex databases, installation identifiers,
pairing codes, or tokens.

## Start Remote Control before SSH clients

A Codex desktop or IDE connection over SSH can automatically start this
client-owned, ephemeral server on the headless host:

```text
codex -c features.code_mode_host=true app-server --listen unix://
```

It occupies the shared Unix control socket. The Remote Control daemon will not
kill or adopt it because doing so could interrupt active tasks. Start Remote
Control before opening desktop or IDE connections to the host:

```bash
codex remote-control start
codex doctor
```

Doctor should report **Background Server: persistent mode**. A healthy process
list normally contains the Remote-Control server, its updater, and zero or more
client proxies:

```bash
pgrep -af 'codex.*app-server'
```

```text
codex app-server --remote-control --listen unix://
codex app-server daemon pid-update-loop
codex app-server proxy
```

Pair a device with:

```bash
codex remote-control pair
```

Keep the host awake, online, and signed in to the same ChatGPT account and
workspace as the controlling device.

## Normal lifecycle

Use only the high-level commands during normal operation:

```bash
codex remote-control stop
codex remote-control start
codex remote-control pair
```

Do not manually run `codex app-server` or `codex app-server proxy`. Do not put
`codex remote-control start` in `.zshrc`; multiple shells are the wrong
lifecycle owner. After a reboot, start it once from an ordinary SSH shell
before opening Codex clients.

## Recovery

### App-server is running but is not managed

An SSH client started an ephemeral server first. Save active work and fully
close Codex clients connected to the host, then inspect processes:

```bash
pgrep -af 'codex.*app-server'
```

Stop only the specific `app-server --listen unix://` PID. Avoid broad `pkill`
commands because proxies may represent active tasks. Once no server remains,
start Remote Control before reconnecting clients:

```bash
kill <app-server-pid>
codex remote-control start
codex doctor
```

### Remote Control is enabled but the connection is errored

The daemon may be healthy while backend enrollment is rejected. In the
2026-08-26 incident, the hidden cause was:

```text
HTTP 403 Forbidden
{"detail":"Multi-factor authentication required"}
```

Refresh the authenticated session and restart the connection:

```bash
codex remote-control stop
codex logout
codex login
codex remote-control start
```

Complete MFA and select the intended workspace during browser login.

### Bubblewrap warnings

Bubblewrap is the Linux command sandbox. Its warnings are separate from daemon
ownership and Remote Control enrollment. Do not use `danger-full-access` as a
Remote Control repair; troubleshoot the sandbox separately.

## Upstream references

- [Codex CLI installation](https://learn.chatgpt.com/docs/codex/cli)
- [Remote connections](https://learn.chatgpt.com/docs/remote-connections)
- [SSH and Remote Control should share one app-server](https://github.com/openai/codex/issues/33750)
- [Surface MFA enrollment errors](https://github.com/openai/codex/issues/24046)
- [Recover an unmanaged app-server](https://github.com/openai/codex/issues/37893)
