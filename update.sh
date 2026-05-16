#!/bin/bash
set -e

# Add dry-run mode
DRY_RUN=${DRY_RUN:-false}

TARGET=$HOME
NVIM_PATH=$HOME/.config
THEME_PATH=$HOME/.oh-my-zsh/themes

# Standardize naming to match install.sh
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
        ln -s ~/dotfiles/nvim ~/.config/nvim
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
    ln -sf ~/dotfiles/ghostty/config.ghostty ~/.config/ghostty/config.ghostty
    echo "Linked ghostty config.ghostty"
else
    mkdir -p ~/.config
    ln -s ~/dotfiles/ghostty ~/.config/ghostty
    echo "Created ghostty symlink"
fi

for f in "${FILES[@]}"
do
    echo "checking $f"
    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would sync $f"
    else
        rsync -aui $f $TARGET/
    fi
done

echo "checking jungwoo.zsh-theme"
if [ "$DRY_RUN" = "true" ]; then
    echo "  [DRY RUN] Would sync jungwoo.zsh-theme"
else
    rsync -aui jungwoo.zsh-theme $THEME_PATH/
fi
