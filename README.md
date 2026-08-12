# Dotfiles

Personal terminal and development configuration for macOS and Linux.

## What's included

- **Shell:** Zsh, Oh My Zsh, a custom theme, autosuggestions, and syntax highlighting
- **Terminal:** Ghostty, tmux, TPM, and Catppuccin
- **Editor:** Neovim with LSP, Treesitter, Telescope, Mason, and completion
- **CLI tools:** `gmon`, `cdx`, uv, NVM/Node.js, Hugging Face CLI, Claude Code, and OpenAI Codex
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
cdx ssh baram use work # drive another machine's accounts over SSH
```

Accounts live in `~/.codex-profiles/<name>`, holding only credentials and logs. Everything shareable — config, conversation history, memories, and the ~1.7 GB of binary and plugin caches — lives once in `~/.codex-profiles/.store`, which is not an account and is symlinked into each one. That keeps each account a few hundred KB, lets `resume` see your work whichever account is active, and means any account can be renamed or deleted without disturbing the rest. `cdx link` rebuilds those symlinks if Codex ever overwrites one.

The listing shows how much of each account's weekly quota is spent, so you can see where to switch before you hit a limit. The figure comes from the same OpenAI endpoint the Codex CLI polls for its own `/status`, asked once per account and cached inside it. Listing never waits on the network: it calls out only to fill an empty cache, reuses the stored figure afterwards, and says how old that figure is. `--refresh` takes a live reading, `--no-usage` (or `CDX_USAGE=off`) skips quota entirely, and `CDX_USAGE=auto` restores refresh-when-stale (`CDX_USAGE_TTL`, default 900s), where an unreachable endpoint falls back to the last known number marked `~`. It doubles as a health check — an account whose refresh token has died shows `re-login` rather than a percentage, which token expiry dates cannot tell you, since Codex leaves expired `id_token`s in place on perfectly working accounts.

Run `cdx -h` for the full command list, and `make test` for the regression suite. `cdx` needs `codex` and `python3` on `PATH` and refuses to run without either.

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
