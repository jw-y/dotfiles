#!/bin/bash
set -e
[ "$DEBUG" == 'true' ] && set -x

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
    if [ ! -d "$TPM_PATH" ]; then
        git clone https://github.com/tmux-plugins/tpm $TPM_PATH
    else
        echo "  TPM already installed, skipping..."
    fi

    # Start a new Tmux session to install plugins
    if [ ! -f "$TPM_PATH/scripts/install_plugins.sh" ]; then
        tmux start-server && \
            tmux new-session -d && \
            sleep 1 && \
            $TPM_PATH/scripts/install_plugins.sh && \
            tmux kill-server
    else
        echo "  Tmux plugins already installed, skipping..."
    fi
}

# Function to install Oh My Zsh
install_oh_my_zsh() {
    echo "Installing Oh My Zsh..."
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" &
        wait $!
    else
        echo "  Oh My Zsh already installed, skipping..."
    fi
}

# Function to install Zsh plugins
install_zsh_plugins() {
    echo "Installing zsh plugins..."

    # Install zsh-autosuggestions
    TARGET="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions"
    if [ ! -d $TARGET ]; then
        git clone https://github.com/zsh-users/zsh-autosuggestions $TARGET
    else
        echo "  Zsh autosuggestions plugin already installed, skipping..."
    fi

    # Install zsh-syntax-highlighting
    TARGET="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting"
    if [ ! -d $TARGET ]; then
        git clone https://github.com/zsh-users/zsh-syntax-highlighting.git $TARGET
    else
        echo "  Zsh syntax highlighting plugin already installed, skipping..."
    fi
}

# install theme, must go after oh-my-zsh
install_theme() {
    echo "Installing jungwoo theme..."
    install_file $THEME_FILE $THEME_PATH
}

install_nvm() {
    echo "Installing NVM..."
    latest=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$latest/install.sh | bash
    export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm
    nvm install --lts
}

install_conda() {
    echo "Installing Miniconda..."
    
    # Determine the operating system
    OS=$(uname)
    ARCH=$(uname -m)
    
    echo "Detected OS: $OS"
    echo "Detected Architecture: $ARCH"
    
    # Set installer URL based on OS and architecture
    if [ "$OS" = "Linux" ]; then
        case "$ARCH" in
            x86_64)
                CONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
                ;;
            aarch64|arm64)
                CONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh"
                ;;
            *)
                echo "Unsupported Linux architecture: $ARCH"
                return 1
                ;;
        esac
    elif [ "$OS" = "Darwin" ]; then
        case "$ARCH" in
            x86_64)
                CONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-x86_64.sh"
                ;;
            arm64)
                CONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh"
                ;;
            *)
                echo "Unsupported macOS architecture: $ARCH"
                return 1
                ;;
        esac
    else
        echo "Unsupported operating system: $OS"
        return 1
    fi
    
    echo "Using installer URL: $CONDA_URL"
    
    # Download the installer
    curl -O "$CONDA_URL"
    
    # Extract the installer filename
    INSTALLER=$(basename "$CONDA_URL")
    
    bash "$INSTALLER"
    
    # Remove the installer file after installation
    rm -f "$INSTALLER"
    
    echo "Miniconda installation completed successfully."
}

install_ubuntu_tools() {
    echo "Installing Ubuntu-specific tools..."
    
    # Install tldr (command examples)
    if command -v npm &> /dev/null; then
        echo "Installing tldr..."
        npm install -g tldr
    else
        echo "  npm not found, skipping tldr installation"
    fi
    
    # Install xsel (clipboard support)
    if command -v apt-get &> /dev/null; then
        echo "Installing xsel..."
        sudo apt-get install -y xsel
    else
        echo "  apt-get not found, skipping xsel installation"
    fi
}

install() {
    install_files_to_home
    install_tmux_plugins
    install_oh_my_zsh
    install_zsh_plugins
    install_theme
    install_nvm
    install_conda
    install_ubuntu_tools
}

install
