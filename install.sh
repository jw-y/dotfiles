#!/bin/bash
set -e
[ "$DEBUG" == 'true' ] && set -x

cd "$(dirname "$0")"

DRY_RUN=${DRY_RUN:-false}
WITH_GITCONFIG=${WITH_GITCONFIG:-false}

TPM_PATH="$HOME/.tmux/plugins/tpm"

if ! command -v zsh &> /dev/null; then
    echo "'zsh' is not found! Try 'sudo apt install zsh'."
    exit
fi

install_tmux_plugins() {
    echo "Installing Tmux plugins..."

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
    echo "Installing Oh My Zsh..."

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
    echo "Installing zsh plugins..."

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
    echo "Installing NVM..."

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install NVM and Node.js LTS"
        return 0
    fi

    if [ -d "$HOME/.nvm" ]; then
        echo "  NVM already installed, skipping..."
        return 0
    fi

    latest=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$latest" ]; then
        echo "  ERROR: Failed to fetch NVM version"
        return 1
    fi

    if ! curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$latest/install.sh | bash; then
        echo "  ERROR: Failed to install NVM"
        return 1
    fi

    export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    if ! nvm install --lts; then
        echo "  WARNING: Failed to install Node.js LTS"
        return 1
    fi
}

install_extra_tools() {
    echo "Installing extra tools..."

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
    echo "Syncing configs via update.sh..."
    if ! DRY_RUN="$DRY_RUN" ./update.sh; then
        echo "  ERROR: update.sh failed"
        return 1
    fi
}

bootstrap_gitconfig() {
    echo "Bootstrapping git include..."

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
