# Dotfiles

Personal terminal and development configuration for macOS and Linux.

## What's included

- **Shell:** Zsh, Oh My Zsh, a custom theme, autosuggestions, and syntax highlighting
- **Terminal:** Ghostty, tmux, TPM, and Catppuccin
- **Editor:** Neovim with LSP, Treesitter, Telescope, Mason, and completion
- **CLI tools:** `gmon`, uv, NVM/Node.js, Hugging Face CLI, Claude Code, and OpenAI Codex
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

## Prerequisites

The installer checks for `zsh`, `git`, `curl`, and `rsync`. On Linux, it installs missing prerequisites through `apt-get` when passwordless sudo is available; otherwise it prints the commands that still need to be installed. A minimal installation also expects tmux to be available. The full installer installs tmux through Homebrew or `apt-get` where supported.

## Safety and update behavior

- Neovim, Ghostty, and `gmon` are symlinked into the home directory.
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
├── bin/                 # Personal command-line tools
├── vscode/              # VS Code keybindings
├── archive/             # Older configurations kept for reference
└── fonts/               # Font assets
```

## Customization

- Edit `jungwoo.zsh-theme` for prompt colors and layout.
- Edit `nvim/lua/config/` and `nvim/lua/plugins/` for Neovim behavior.
- Edit `.zshrc`, `.tmux.conf`, or `ghostty/config.ghostty` for terminal behavior.
