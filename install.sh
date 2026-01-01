#!/bin/bash
set -e
[ "$DEBUG" == 'true' ] && set -x

# Add dry-run mode
DRY_RUN=${DRY_RUN:-false}

INSTALL_PATH=$HOME
THEME_FILE=jungwoo.zsh-theme
THEME_PATH=$HOME/.oh-my-zsh/themes/
TPM_PATH="$HOME/.tmux/plugins/tpm" 

FILES=( 
    ".zshrc"
    ".tmux.conf"
    ".pdbrc"
    ".ipdb"
) 

if ! command -v zsh &> /dev/null; then
    echo "'zsh' is not found! Try 'sudo apt install zsh'."
    exit
fi

# Function to log file updates
log_file_update() {
    local file_name="$1"
    local rsync_output="$2"

    if [[ "$rsync_output" =~ ">" ]]; then
        echo "  $file_name was updated or copied."
    else
        echo "  $file_name is latest"
    fi
}

install_file() {
    local SRC="$1"
    local DEST="$2"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install $SRC -> $DEST"
        return 0
    fi

    local output=$(rsync -ahu --itemize-changes "$SRC" "$DEST")
    log_file_update "$SRC" "$output"
}

# Function to install files
install_files_to_home() {
    echo "Installing files..."
    for f in "${FILES[@]}"; do
        install_file "$f" "$INSTALL_PATH/$f"
    done
}

# Function to install Tmux plugins
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

    # Start a new Tmux session to install plugins
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

# Function to install Oh My Zsh
install_oh_my_zsh() {
    echo "Installing Oh My Zsh..."
    
    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install Oh My Zsh"
        return 0
    fi
    
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        if ! sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"; then
            echo "  ERROR: Failed to install Oh My Zsh"
            return 1
        fi
    else
        echo "  Oh My Zsh already installed, skipping..."
    fi
}

# Function to install Zsh plugins
install_zsh_plugins() {
    echo "Installing zsh plugins..."

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install zsh plugins"
        return 0
    fi

    # Install zsh-autosuggestions
    TARGET="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions"
    if [ ! -d $TARGET ]; then
        if ! git clone https://github.com/zsh-users/zsh-autosuggestions $TARGET; then
            echo "  ERROR: Failed to install zsh-autosuggestions"
            return 1
        fi
    else
        echo "  Zsh autosuggestions plugin already installed, skipping..."
    fi

    # Install zsh-syntax-highlighting
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

# install theme, must go after oh-my-zsh
install_theme() {
    echo "Installing jungwoo theme..."
    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install theme to $THEME_PATH"
        return 0
    fi
    install_file $THEME_FILE $THEME_PATH
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
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm
    
    if ! nvm install --lts; then
        echo "  WARNING: Failed to install Node.js LTS"
        return 1
    fi
}

install_ubuntu_tools() {
    echo "Installing Ubuntu-specific tools..."
    
    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN] Would install Ubuntu-specific tools (tldr, xsel)"
        return 0
    fi
    
    # Install tldr (command examples)
    if command -v npm &> /dev/null; then
        echo "Installing tldr..."
        if ! npm install -g tldr; then
            echo "  WARNING: Failed to install tldr"
        fi
    else
        echo "  npm not found, skipping tldr installation"
    fi
    
    # Install xsel (clipboard support)
    if command -v apt-get &> /dev/null; then
        echo "Installing xsel..."
        if ! sudo apt-get install -y xsel; then
            echo "  WARNING: Failed to install xsel"
        fi
    else
        echo "  apt-get not found, skipping xsel installation"
    fi
}

install() {
    local errors=0
    
    install_files_to_home || ((errors++))
    install_tmux_plugins || ((errors++))
    install_oh_my_zsh || ((errors++))
    install_zsh_plugins || ((errors++))
    install_theme || ((errors++))
    install_nvm || ((errors++))
    install_ubuntu_tools || ((errors++))
    
    if [ $errors -gt 0 ]; then
        echo "Installation completed with $errors error(s)."
        return 1
    else
        echo "Installation completed successfully!"
        return 0
    fi
}

install
