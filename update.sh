#!/bin/bash
set -eo pipefail

cd "$(dirname "$0")"
DOTFILES_DIR="$(pwd)"

DRY_RUN=${DRY_RUN:-false}
BACKUP_STAMP=$(date +%Y%m%d-%H%M%S)

TARGET=$HOME
THEME_PATH=$HOME/.oh-my-zsh/themes

FILES=(
    ".zshrc"
    ".tmux.conf"
    ".pdbrc"
    ".ipdb"
)

backup_path() {
    local target=$1
    local backup="${target}.dotfiles-backup-${BACKUP_STAMP}"
    echo "  Backing up $target to $backup"
    mv "$target" "$backup"
}

link_path() {
    local source=$1
    local target=$2
    local description=$3

    if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
        echo "$description symlink already correct"
        return 0
    fi

    if [ "$DRY_RUN" = "true" ]; then
        if [ -e "$target" ] || [ -L "$target" ]; then
            echo "[DRY RUN] Would back up existing $target"
        fi
        echo "[DRY RUN] Would link $description: $target -> $source"
        return 0
    fi

    mkdir -p "$(dirname "$target")"
    if [ -e "$target" ] || [ -L "$target" ]; then
        backup_path "$target"
    fi
    ln -s "$source" "$target"
    echo "Linked $description"
}

sync_file() {
    local source=$1
    local target_dir=$2

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would sync $source to $target_dir/"
        return 0
    fi

    mkdir -p "$target_dir"
    rsync -ai --backup --suffix=".dotfiles-backup-${BACKUP_STAMP}" "$source" "$target_dir/"
}

link_path "$DOTFILES_DIR/nvim" "$HOME/.config/nvim" "nvim config"
link_path "$DOTFILES_DIR/ghostty" "$HOME/.config/ghostty" "ghostty config"

for f in "${FILES[@]}"; do
    echo "checking $f"
    sync_file "$f" "$TARGET"
done

echo "checking jungwoo.zsh-theme"
sync_file "jungwoo.zsh-theme" "$THEME_PATH"

echo "checking Claude settings"
sync_file "claude/settings.json" "$HOME/.claude"
sync_file "claude/statusline-command.sh" "$HOME/.claude"

link_path "$DOTFILES_DIR/bin/gmon" "$HOME/.local/bin/gmon" "gmon"
