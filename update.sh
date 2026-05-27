#!/bin/bash
set -e

cd "$(dirname "$0")"
DOTFILES_DIR="$(pwd)"

DRY_RUN=${DRY_RUN:-false}

TARGET=$HOME
NVIM_PATH=$HOME/.config
THEME_PATH=$HOME/.oh-my-zsh/themes

FILES=(
    ".zshrc"
    ".tmux.conf"
    ".pdbrc"
    ".ipdb"
)

# link nvim config
if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY RUN] Would create nvim symlink"
else
    if [ ! -L ~/.config/nvim ]; then
        mkdir -p ~/.config
        ln -s "$DOTFILES_DIR/nvim" ~/.config/nvim
        echo "Created nvim symlink"
    else
        echo "nvim symlink already exists"
    fi
fi

# link ghostty config
if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY RUN] Would link ghostty config"
elif [ -L ~/.config/ghostty ]; then
    echo "ghostty symlink already exists"
elif [ -d ~/.config/ghostty ]; then
    ln -sf "$DOTFILES_DIR/ghostty/config.ghostty" ~/.config/ghostty/config.ghostty
    echo "Linked ghostty config.ghostty"
else
    mkdir -p ~/.config
    ln -s "$DOTFILES_DIR/ghostty" ~/.config/ghostty
    echo "Created ghostty symlink"
fi

for f in "${FILES[@]}"
do
    echo "checking $f"
    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would sync $f"
    else
        rsync -ai "$f" "$TARGET/"
    fi
done

echo "checking jungwoo.zsh-theme"
if [ "$DRY_RUN" = "true" ]; then
    echo "  [DRY RUN] Would sync jungwoo.zsh-theme"
else
    rsync -ai jungwoo.zsh-theme "$THEME_PATH/"
fi

# link gmon to ~/.local/bin
mkdir -p "$HOME/.local/bin"
if [ "$DRY_RUN" = "true" ]; then
    echo "  [DRY RUN] Would link gmon to ~/.local/bin/"
elif [ ! -L "$HOME/.local/bin/gmon" ]; then
    ln -s "$DOTFILES_DIR/bin/gmon" "$HOME/.local/bin/gmon"
    echo "Linked gmon to ~/.local/bin/"
else
    echo "gmon symlink already exists"
fi
