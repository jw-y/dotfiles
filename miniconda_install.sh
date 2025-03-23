#!/bin/bash

# Determine the operating system
OS=$(uname)
ARCH=$(uname -m)

echo "Detected OS: $OS"
echo "Detected Architecture: $ARCH"

# Set installer URL based on OS and architecture
if [ "$OS" = "Linux" ]; then
    case "$ARCH" in
        x86_64)
            CONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-py39_24.1.2-0-Linux-x86_64.sh"
            ;;
        aarch64|arm64)
            CONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-py39_24.1.2-0-Linux-aarch64.sh"
            ;;
        *)
            echo "Unsupported Linux architecture: $ARCH"
            exit 1
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
            exit 1
            ;;
    esac
else
    echo "Unsupported operating system: $OS"
    exit 1
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
