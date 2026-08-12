#!/bin/bash
set -eo pipefail
[ "$DEBUG" == 'true' ] && set -x

cd "$(dirname "$0")"

DRY_RUN=${DRY_RUN:-false}
WITH_GITCONFIG=${WITH_GITCONFIG:-false}
UPGRADE_NVIM=${UPGRADE_NVIM:-false}
# Which set of steps to run. 'minimal' and 'full' were always profiles — named
# lists of steps, with full composing minimal — but they used to be selected by
# a MINIMAL=true boolean, which could express exactly two. Adding one now costs
# a single profile_<name> function and nothing else.
#
# Note before adding one: install_mac_tools and install_linux_tools already
# skip themselves on the wrong OS, so a profile is only worth writing when the
# difference is something other than the platform.
PROFILE=${PROFILE:-full}

TPM_PATH="$HOME/.tmux/plugins/tpm"

is_linux() { [ "$(uname)" = "Linux" ]; }
is_mac()   { [ "$(uname)" = "Darwin" ]; }
has_sudo() { command -v sudo >/dev/null && sudo -n true 2>/dev/null; }

if [ -t 1 ]; then
    C_HDR='\033[1;34m'
    C_RESET='\033[0m'
else
    C_HDR='' C_RESET=''
fi

STEP_NUM=0
step() {
    STEP_NUM=$((STEP_NUM + 1))
    printf "\n${C_HDR}==> [%d] %s${C_RESET}\n" "$STEP_NUM" "$*"
}

ensure_prerequisites() {
    step "Prerequisites (zsh, git, curl, rsync)"

    local missing=()
    local command_name
    for command_name in zsh git curl rsync; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        echo "  Prerequisites already installed"
        return 0
    fi

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install/check: ${missing[*]}"
        return 0
    fi

    if is_linux && command -v apt-get >/dev/null 2>&1 && has_sudo; then
        echo "  Installing missing prerequisites: ${missing[*]}"
        sudo apt-get update
        sudo apt-get install -y "${missing[@]}"
        return 0
    fi

    echo "  ERROR: Missing required commands: ${missing[*]}"
    echo "  Install them with your system package manager, then run this script again."
    return 1
}

install_tmux_plugins() {
    step "tmux plugins (TPM)"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install TPM and plugins"
        return 0
    fi

    if [ ! -d "$TPM_PATH" ]; then
        if ! git clone https://github.com/tmux-plugins/tpm "$TPM_PATH"; then
            echo "  ERROR: Failed to clone TPM"
            return 1
        fi
    else
        echo "  TPM already installed, skipping..."
    fi

    if [ ! -x "$TPM_PATH/bin/install_plugins" ]; then
        echo "  ERROR: TPM plugin installer is missing"
        return 1
    fi

    local install_session="dotfiles-install-$$"
    local install_failed=false

    if ! tmux new-session -d -s "$install_session"; then
        echo "  ERROR: Failed to start a temporary tmux session"
        return 1
    fi

    tmux source-file "$HOME/.tmux.conf" || install_failed=true
    "$TPM_PATH/bin/install_plugins" || install_failed=true
    tmux kill-session -t "$install_session" 2>/dev/null || true

    if [ "$install_failed" = "true" ]; then
        echo "  ERROR: Failed to install Tmux plugins"
        return 1
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
    if [ ! -d "$TARGET" ]; then
        if ! git clone https://github.com/zsh-users/zsh-autosuggestions "$TARGET"; then
            echo "  ERROR: Failed to install zsh-autosuggestions"
            return 1
        fi
    else
        echo "  Zsh autosuggestions plugin already installed, skipping..."
    fi

    TARGET="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting"
    if [ ! -d "$TARGET" ]; then
        if ! git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$TARGET"; then
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

    if [ -z "${XDG_CONFIG_HOME-}" ]; then
        export NVM_DIR="${HOME}/.nvm"
    else
        export NVM_DIR="${XDG_CONFIG_HOME}/nvm"
    fi
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        \. "$NVM_DIR/nvm.sh"
        #nvm install --lts >/dev/null 2>&1 || echo "  WARNING: nvm install --lts failed"
        nvm install --lts || echo "  WARNING: nvm install --lts failed"
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
        echo "  Homebrew not found, installing..."
        if ! /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
            echo "  ERROR: Failed to install Homebrew"
            return 1
        fi
        if [ -x /opt/homebrew/bin/brew ]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [ -x /usr/local/bin/brew ]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
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

install_uv() {
    step "uv (Python package manager)"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install uv via astral.sh installer"
        return 0
    fi

    if command -v uv >/dev/null 2>&1; then
        echo "  uv already installed: $(command -v uv)"
        return 0
    fi

    if ! curl -LsSf https://astral.sh/uv/install.sh | sh; then
        echo "  ERROR: Failed to install uv"
        return 1
    fi
}

install_hf_cli() {
    step "HuggingFace CLI"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install HuggingFace CLI"
        return 0
    fi

    if command -v hf >/dev/null 2>&1; then
        echo "  HuggingFace CLI already installed: $(command -v hf)"
        return 0
    fi

    if ! curl -LsSf https://hf.co/cli/install.sh | bash; then
        echo "  ERROR: Failed to install HuggingFace CLI"
        return 1
    fi
}

install_claude_code() {
    step "Claude Code CLI"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install Claude Code CLI"
        return 0
    fi

    if command -v claude >/dev/null 2>&1; then
        echo "  Claude Code already installed: $(command -v claude)"
        return 0
    fi

    if ! curl -fsSL https://claude.ai/install.sh | bash; then
        echo "  ERROR: Failed to install Claude Code"
        return 1
    fi
}

install_codex_cli() {
    step "OpenAI Codex CLI"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install Codex CLI with the official standalone installer"
        return 0
    fi

    if command -v codex >/dev/null 2>&1; then
        echo "  Codex CLI already installed: $(command -v codex)"
        return 0
    fi

    if ! curl -fsSL https://chatgpt.com/codex/install.sh | sh; then
        echo "  ERROR: Failed to install Codex CLI"
        return 1
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

    local target
    target="$(pwd)/git/gitconfig"
    if git config --global --get-all include.path 2>/dev/null | grep -Fxq "$target"; then
        echo "  include.path already points to $target"
    else
        git config --global --add include.path "$target"
        echo "  Added include.path = $target"
    fi
}

# A profile_<name> function is a profile; install_<name> is a single step.
# Separating the namespaces is what lets the list be derived rather than kept
# in step by hand — matching on install_* swept up install_nvm and install_uv.
profiles() {
    declare -F | sed -n 's/^declare -f profile_\([a-z]*\)$/\1/p' | sort | tr '\n' ' '
}

profile_minimal() {
    local errors=0

    install_oh_my_zsh    || (( ++errors ))
    install_zsh_plugins  || (( ++errors ))
    sync_configs         || (( ++errors ))
    install_tmux_plugins || (( ++errors ))

    return $errors
}

profile_full() {
    local errors=0

    install_mac_tools    || (( ++errors ))
    install_linux_tools  || (( ++errors ))
    profile_minimal      || (( errors += $? ))
    install_nvm          || (( ++errors ))
    install_extra_tools  || (( ++errors ))
    install_uv           || (( ++errors ))
    install_hf_cli       || (( ++errors ))
    install_claude_code  || (( ++errors ))
    install_codex_cli    || (( ++errors ))

    return $errors
}

install() {
    local errors=0

    if ! ensure_prerequisites; then
        return 1
    fi

    # Naming the profile wrong should say so, not quietly install everything.
    if ! declare -F "profile_$PROFILE" >/dev/null; then
        echo "  ERROR: unknown profile '$PROFILE' (available: $(profiles))"
        return 1
    fi
    echo "Running $PROFILE install..."
    "profile_$PROFILE" || (( errors += $? ))

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
