# Dotfiles

Personal dotfiles configuration.

## What's Included

### Core Tools
- **Shell**: Zsh + Oh My Zsh + custom theme + plugins
- **Terminal**: Tmux with TPM
- **Editor**: Neovim (LSP, Treesitter, Telescope, Mason)
- **Languages**: Python (conda), Node.js (nvm), Lua, Rust, TypeScript, YAML

### Development
- **Python**: pylint, pdb/ipdb config
- **Git**: Configuration and tools
- **System**: tldr, xsel (Linux clipboard)

## Quick Start

### First Time Setup
```bash
git clone https://github.com/jw-y/dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh
```

### Update Existing Configs
```bash
./update.sh
```

## Prerequisites

- **zsh** (will be installed if missing)
- **git** and **curl** for downloading tools
- **sudo** access for system package installation

## File Structure

```
dotfiles/
├── install.sh          # Complete setup script
├── update.sh           # Update existing configs
├── .zshrc             # Zsh configuration
├── .tmux.conf         # Tmux configuration
├── nvim/              # Neovim configuration
├── vscode/            # VSCode settings
├── archive/           # Old configs for reference
└── fonts/             # Font files
```

## Customization

- **Theme**: Edit `jungwoo.zsh-theme` for custom colors
- **Neovim**: Modify `nvim/lua/config/` for editor preferences
- **Zsh**: Add aliases and functions to `.zshrc`

## Notes

- Configs are automatically synced to your home directory
- Neovim config is symlinked to `~/.config/nvim`
- Old Vim configurations are preserved in `archive/` for reference