# Dotfiles

Personal terminal and development configuration for macOS and Linux.

## What's included

- **Shell:** Zsh, Oh My Zsh, a custom theme, autosuggestions, and syntax highlighting
- **Terminal:** Ghostty, tmux, TPM, and Catppuccin
- **Editor:** Neovim with LSP, Treesitter, Telescope, Mason, and completion
- **CLI tools:** `gmon`, `smux`, `cdx`, uv, NVM/Node.js, Hugging Face CLI, Claude Code, and OpenAI Codex
- **Development:** Git, Python debugger/linter settings, and VS Code keybindings

## Quick start

```bash
git clone https://github.com/jw-y/dotfiles.git ~/dotfiles
cd ~/dotfiles
make install
```

The full installer sets up platform tools, shell and editor configuration, CLI tools, Claude Code, and the OpenAI Codex CLI. Codex uses OpenAI's official standalone installer for macOS and Linux.

For shell, tmux, and dotfile configuration without the language and AI tools:

```bash
make minimal
```

To sync configuration changes later:

```bash
make update
```

Preview either workflow without changing your home directory:

```bash
make dry-run
```

Run `make help` for all targets and environment-variable overrides.

## Switching Codex accounts (`cdx`)

Every Codex client — CLI, desktop app, VS Code, and the app's SSH remote — reads `~/.codex`. `cdx` makes that path a symlink, so activating an account is just re-pointing it and no client needs configuring.

```bash
cdx                    # list accounts with quota; '*' marks the active one
cdx --refresh          # re-ask OpenAI for each account's quota
cdx init               # one-time: make ~/.codex switchable
cdx add work           # create an account and log in (device auth over SSH)
cdx use work           # activate it, restarting clients that cached the old account
cdx work resume        # run one command as 'work' without switching
cdx status work        # inspect one account without switching to it
cdx ssh baram use work # drive another machine's accounts over SSH
```

Accounts live in `~/.codex-profiles/<name>`, holding only credentials and logs. Everything shareable — config, conversation history, memories, and the ~1.7 GB of binary and plugin caches — lives once in `~/.codex-profiles/.store`, which is not an account and is symlinked into each one. That keeps each account a few hundred KB, lets `resume` see your work whichever account is active, and means any account can be renamed or deleted without disturbing the rest. `cdx link` rebuilds those symlinks if Codex ever overwrites one.

The listing shows how much of each account's weekly quota is spent, so you can see where to switch before you hit a limit. The figure comes from the same OpenAI endpoint the Codex CLI polls for its own `/status`, asked once per account and cached inside it. Listing never waits on the network: it calls out only to fill an empty cache, reuses the stored figure afterwards, and says how old that figure is. `--refresh` takes a live reading, `--no-usage` (or `CDX_USAGE=off`) skips quota entirely, and `CDX_USAGE=auto` restores refresh-when-stale (`CDX_USAGE_TTL`, default 900s), where an unreachable endpoint falls back to the last known number marked `~`. It doubles as a health check — an account whose refresh token has died shows `re-login` rather than a percentage, which token expiry dates cannot tell you, since Codex leaves expired `id_token`s in place on perfectly working accounts.

A percentage is not the only way to run out. An account can sit at 16% and still refuse to work, because an admin-set spend budget is exhausted — every rate-limit field reports fine and only `spend_control.reached` says otherwise. Such an account shows `spend limit` in place of its percentage, is never suggested as the one with the most room, and is called out when you switch to it. `cdx status <name>` gives the long form for any account, active or not: both limits, what the plan reports about credits, and whether the running clients match. Only the Account section follows the name — storage and running clients always describe this machine.

Run `cdx -h` for the command map and `cdx <command> -h` for one command's detail, and `make test` for the regression suite. `cdx` needs `codex` and `python3` on `PATH` and refuses to run without either.

## Multiplexing independent Slurm clusters (`smux`)

`smux` submits and inspects jobs across several independent Slurm controllers
through existing SSH aliases. Real hosts and job history are deliberately kept
outside this public repository.

```bash
smux init                         # create ~/.config/smux/hosts
smux edit                         # add one SSH alias per line
smux status                       # Slurm version, partitions, and job counts
smux gpus                         # GPU occupancy plus Slurm GRES type by index
smux jobs                         # aggregate your jobs across configured hosts
smux submit gpu-a job.sbatch      # uploads local script, then prints gpu-a:1234
smux show gpu-a 1234
smux logs gpu-a 1234              # tail Slurm stdout
smux logs gpu-a 1234 --follow
smux cancel gpu-a 1234            # explicit job ID required
smux cleanup gpu-a                # dry-run stale uploaded-script cleanup
smux cleanup gpu-a --apply
smux wait gpu-a 1234
smux submit gpu-a job.sbatch --wait   # submit, then block on the handle
smux jobs --watch                     # redraw the queue until interrupted
smux history                          # submissions smux has recorded
```

Use the reserved alias `local` for the current machine. A private host file
might contain `local`, `gpu-a`, and `gpu-b`, one per line; these are names from
your own `~/.ssh/config`. Submission records live in
`~/.local/state/smux/jobs.jsonl`. Override those paths with `SMUX_HOSTS` and
`SMUX_STATE` when needed. `smux submit` copies only the selected local Slurm
script to `~/.local/state/smux/scripts/` on the target, verifies its SHA-256,
and submits that immutable content-addressed copy. Use `--remote` only
when the script is deliberately pre-positioned. `smux` does not copy project
code, credentials, or data, and it never stores SSH keys.

`smux jobs` includes elapsed time, remaining time, and Slurm's expected end
time. `smux logs` discovers the job's `StdOut` path through `scontrol`, so no
cluster-specific log directory is assumed. `smux cleanup` is restricted to the
managed upload directory and is a dry run unless `--apply` is supplied.

`smux gpus` ends with a one-line summary — `4 GPUs free  (pado:0  byul:1,2,3)`
— because the table says what every GPU is doing and that line says where to
go. Connections are reused between commands (`ControlPersist`), so a `status`
followed by a `gpus` across five clusters costs one round of handshakes rather
than two. `smux submit` refuses a host with no `sbatch` before uploading
anything, since a machine can have GPUs and no scheduler.

`smux gpus` joins `nvidia-smi` occupancy with Slurm's `gres.conf` mapping. An
idle physical GPU can therefore still be identified as a restricted type such
as `debug`; submit it through the matching Slurm partition/GRES rather than
launching a process directly.

## Prerequisites

The installer checks for `zsh`, `git`, `curl`, and `rsync`. On Linux, it installs missing prerequisites through `apt-get` when passwordless sudo is available; otherwise it prints the commands that still need to be installed. A minimal installation also expects tmux to be available. The full installer installs tmux through Homebrew or `apt-get` where supported.

## Safety and update behavior

- Neovim, Ghostty, `gmon`, and `cdx` are symlinked into the home directory.
- An existing file, directory, or incorrect symlink is moved to a timestamped `*.dotfiles-backup-YYYYMMDD-HHMMSS` path before replacement.
- Copied shell, theme, and Claude files use the same timestamped backup suffix when their contents change.
- Dry-run mode performs no filesystem writes.
- Git identity is deliberately excluded; `make gitconfig` opts into the shareable Git settings.

## Repository layout

```text
dotfiles/
├── install.sh          # Idempotent machine bootstrap
├── update.sh           # Safe config sync and symlink management
├── Makefile            # Friendly install/update targets
├── .zshrc              # Zsh configuration
├── .tmux.conf          # tmux configuration
├── nvim/               # Neovim configuration and plugin lockfile
├── ghostty/             # Ghostty configuration
├── claude/              # Claude settings and status line
├── git/                 # Shareable Git configuration
├── bin/                 # Personal command-line tools (gmon, cdx)
├── tests/               # Test suite for bin/ tools (make test)
├── vscode/              # VS Code keybindings
├── archive/             # Older configurations kept for reference
└── fonts/               # Font assets
```

## Customization

- Edit `jungwoo.zsh-theme` for prompt colors and layout.
- Edit `nvim/lua/config/` and `nvim/lua/plugins/` for Neovim behavior.
- Edit `.zshrc`, `.tmux.conf`, or `ghostty/config.ghostty` for terminal behavior.
