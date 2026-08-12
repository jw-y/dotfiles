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

# bin/<name> linked to ~/.local/bin/<name>. Listed rather than globbed, so a
# half-written script in bin/ cannot install itself onto $PATH; anything here
# but unlisted is reported at the end instead.
TOOLS=(
    gmon
    cdx
    smux
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

for tool in "${TOOLS[@]}"; do
    if [ ! -f "$DOTFILES_DIR/bin/$tool" ]; then
        echo "  WARNING: TOOLS lists '$tool' but bin/$tool does not exist"
        continue
    fi
    link_path "$DOTFILES_DIR/bin/$tool" "$HOME/.local/bin/$tool" "$tool"
done

# Naming a tool is the deliberate step, so forgetting it is the likely mistake.
# Say so rather than installing it: silence would leave a tool that works in the
# repo and is missing on every machine.
for path in "$DOTFILES_DIR"/bin/*; do
    [ -f "$path" ] && [ -x "$path" ] || continue
    tool="$(basename "$path")"
    case " ${TOOLS[*]} " in
        *" $tool "*) ;;
        *) echo "  note: bin/$tool is executable but not listed in TOOLS — not installed" ;;
    esac
done
