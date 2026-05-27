#!/bin/bash
set -e
[ "$DEBUG" == 'true' ] && set -x

cd "$(dirname "$0")"

DRY_RUN=${DRY_RUN:-false}
WITH_GITCONFIG=${WITH_GITCONFIG:-false}
UPGRADE_NVIM=${UPGRADE_NVIM:-false}

TPM_PATH="$HOME/.tmux/plugins/tpm"

is_linux() { [ "$(uname)" = "Linux" ]; }
is_mac()   { [ "$(uname)" = "Darwin" ]; }
has_sudo() { command -v sudo >/dev/null && sudo -n true 2>/dev/null; }

if [ -t 1 ]; then
    C_HDR='\033[1;34m'
    C_OK='\033[0;32m'
    C_WARN='\033[0;33m'
    C_RESET='\033[0m'
else
    C_HDR='' C_OK='' C_WARN='' C_RESET=''
fi

STEP_NUM=0
step() {
    STEP_NUM=$((STEP_NUM + 1))
    printf "\n${C_HDR}==> [%d] %s${C_RESET}\n" "$STEP_NUM" "$*"
}

if ! command -v zsh &> /dev/null; then
    echo "'zsh' is not found! Try 'sudo apt install zsh'."
    exit
fi

install_tmux_plugins() {
    step "tmux plugins (TPM)"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install TPM and plugins"
        return 0
    fi

    if [ ! -d "$TPM_PATH" ]; then
        if ! git clone https://github.com/tmux-plugins/tpm $TPM_PATH; then
            echo "  ERROR: Failed to clone TPM"
            return 1
        fi
    else
        echo "  TPM already installed, skipping..."
    fi

    if [ ! -f "$TPM_PATH/scripts/install_plugins.sh" ]; then
        if ! (tmux start-server && \
            tmux new-session -d && \
            sleep 1 && \
            $TPM_PATH/scripts/install_plugins.sh && \
            tmux kill-server); then
            echo "  ERROR: Failed to install Tmux plugins"
            return 1
        fi
    else
        echo "  Tmux plugins already installed, skipping..."
    fi
}

install_oh_my_zsh() {
    step "Oh My Zsh"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install Oh My Zsh"
        return 0
    fi

    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        if ! sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended; then
            echo "  ERROR: Failed to install Oh My Zsh"
            return 1
        fi
    else
        echo "  Oh My Zsh already installed, skipping..."
    fi
}

install_zsh_plugins() {
    step "zsh plugins (autosuggestions, syntax-highlighting)"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install zsh plugins"
        return 0
    fi

    TARGET="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions"
    if [ ! -d $TARGET ]; then
        if ! git clone https://github.com/zsh-users/zsh-autosuggestions $TARGET; then
            echo "  ERROR: Failed to install zsh-autosuggestions"
            return 1
        fi
    else
        echo "  Zsh autosuggestions plugin already installed, skipping..."
    fi

    TARGET="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting"
    if [ ! -d $TARGET ]; then
        if ! git clone https://github.com/zsh-users/zsh-syntax-highlighting.git $TARGET; then
            echo "  ERROR: Failed to install zsh-syntax-highlighting"
            return 1
        fi
    else
        echo "  Zsh syntax highlighting plugin already installed, skipping..."
    fi
}

install_nvm() {
    step "NVM + Node LTS"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install NVM and Node.js LTS"
        return 0
    fi

    if [ ! -d "$HOME/.nvm" ]; then
        latest=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -z "$latest" ]; then
            echo "  ERROR: Failed to fetch NVM version"
            return 1
        fi
        if ! curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$latest/install.sh | bash; then
            echo "  ERROR: Failed to install NVM"
            return 1
        fi
    else
        echo "  NVM already present"
    fi

    export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        \. "$NVM_DIR/nvm.sh"
        nvm install --lts >/dev/null 2>&1 || echo "  WARNING: nvm install --lts failed"
        nvm alias default 'lts/*' >/dev/null 2>&1
    fi
}

install_mac_tools() {
    is_mac || return 0
    step "Mac tools (Brewfile)"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would run: brew bundle --file=Brewfile"
        return 0
    fi

    if ! command -v brew >/dev/null; then
        echo "  WARNING: brew not found. Install Homebrew first, then re-run."
        return 0
    fi

    brew bundle --file=Brewfile
}

install_linux_tools() {
    is_linux || return 0
    step "Linux tools (nvim, tmux, fzf)"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would download nvim, apt-install tmux + fzf (if sudo)"
        return 0
    fi

    if [ "$UPGRADE_NVIM" = "true" ] || ! command -v nvim >/dev/null; then
        echo "  Downloading nvim (latest release)..."
        mkdir -p "$HOME/.local"
        if curl -fsSL "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz" \
            | tar xz --strip-components=1 -C "$HOME/.local"; then
            echo "  nvim installed to ~/.local/bin/nvim"
        else
            echo "  WARNING: failed to download nvim"
        fi
    else
        echo "  nvim already installed: $(command -v nvim)"
    fi

    if ! command -v tmux >/dev/null; then
        if has_sudo && command -v apt-get >/dev/null; then
            sudo apt-get install -y tmux
        else
            echo "  WARNING: tmux not installed. Run 'sudo apt install tmux' when you have sudo."
        fi
    else
        echo "  tmux already installed"
    fi

    if ! command -v fzf >/dev/null; then
        echo "  Installing fzf via git clone (apt's fzf is too old for 'fzf --zsh')..."
        if [ ! -d "$HOME/.fzf" ]; then
            git clone --depth 1 https://github.com/junegunn/fzf.git "$HOME/.fzf"
        fi
        "$HOME/.fzf/install" --bin
        mkdir -p "$HOME/.local/bin"
        ln -sf "$HOME/.fzf/bin/fzf" "$HOME/.local/bin/fzf"
        echo "  fzf installed to ~/.local/bin/fzf"
    else
        echo "  fzf already installed"
    fi
}

install_extra_tools() {
    step "Extra tools (tldr via npm)"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install extra tools (tldr)"
        return 0
    fi

    if command -v npm &> /dev/null; then
        echo "Installing tldr..."
        if ! npm install -g tldr; then
            echo "  WARNING: Failed to install tldr"
        fi
    else
        echo "  npm not found, skipping tldr installation"
    fi
}

sync_configs() {
    step "Syncing configs to \$HOME (via update.sh)"
    if ! DRY_RUN="$DRY_RUN" ./update.sh; then
        echo "  ERROR: update.sh failed"
        return 1
    fi
}

bootstrap_gitconfig() {
    step "Git include bootstrap (~/.gitconfig)"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would add include.path to ~/.gitconfig"
        return 0
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo "  git not found, skipping"
        return 0
    fi

    local target="$(pwd)/git/gitconfig"
    if git config --global --get-all include.path 2>/dev/null | grep -Fxq "$target"; then
        echo "  include.path already points to $target"
    else
        git config --global --add include.path "$target"
        echo "  Added include.path = $target"
    fi
}

install() {
    local errors=0

    install_mac_tools    || (( ++errors ))
    install_linux_tools  || (( ++errors ))
    install_oh_my_zsh    || (( ++errors ))
    install_zsh_plugins  || (( ++errors ))
    sync_configs         || (( ++errors ))
    install_tmux_plugins || (( ++errors ))
    install_nvm          || (( ++errors ))
    install_extra_tools  || (( ++errors ))

    if [ "$WITH_GITCONFIG" = "true" ]; then
        bootstrap_gitconfig || (( ++errors ))
    fi

    if [ $errors -gt 0 ]; then
        echo "Installation completed with $errors error(s)."
        return 1
    else
        echo "Installation completed successfully!"
        return 0
    fi
}

install
