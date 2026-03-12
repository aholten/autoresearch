#!/usr/bin/env bash
# =============================================================================
# wsl_setup.sh — Complete WSL2 + Docker + NVIDIA GPU setup for autoresearch
# =============================================================================
#
# This script IS the guide. Each command is preceded by comments explaining
# what it does and why. Run it from inside your WSL2 Ubuntu instance:
#
#   bash wsl_setup.sh
#
# Prerequisites (do these on WINDOWS before running this script):
#
#   1. Install WSL2 (from PowerShell as admin):
#        wsl --install -d Ubuntu-22.04
#      Or if WSL is already installed, ensure you're on WSL2:
#        wsl --set-version Ubuntu-22.04 2
#
#   2. Install the NVIDIA GPU driver ON WINDOWS (not inside WSL!):
#      Download from: https://www.nvidia.com/drivers/
#      You need driver version >= 570 for CUDA 12.8 support.
#
#      IMPORTANT: Do NOT install cuda-toolkit or nvidia-driver packages inside
#      WSL. The Windows driver automatically exposes the GPU to WSL2 via the
#      /dev/dxg virtual device. Installing a Linux driver inside WSL will
#      CONFLICT with the Windows driver and break GPU passthrough.
#
#   3. Reboot Windows after installing the NVIDIA driver.
#
# After those Windows-side steps, open your WSL2 terminal and run this script.
# =============================================================================

set -euo pipefail  # Exit on error, undefined var, or pipe failure

echo "==========================================="
echo " autoresearch WSL2 + Docker + GPU Setup"
echo "==========================================="
echo ""

# =============================================================================
# Step 1: Verify we're running inside WSL2
# =============================================================================
# WSL2 uses a real Linux kernel (unlike WSL1 which translates syscalls).
# Docker and GPU passthrough require WSL2 specifically.
# The /proc/version file contains "microsoft" on WSL systems.
# =============================================================================
echo "[1/7] Checking WSL2 environment..."

if ! grep -qi "microsoft" /proc/version 2>/dev/null; then
    echo "WARNING: This doesn't appear to be WSL. The script will continue,"
    echo "         but Docker GPU setup may work differently on native Linux."
    echo "         (On native Linux, just install nvidia-container-toolkit.)"
    echo ""
fi

# =============================================================================
# Step 2: Verify NVIDIA GPU is visible
# =============================================================================
# nvidia-smi should work inside WSL2 *without* installing anything, because
# the Windows NVIDIA driver exposes it. If this fails, your Windows driver is
# either not installed, too old, or you're on WSL1.
#
# We check for this early because everything else depends on GPU access.
# =============================================================================
echo "[2/7] Verifying NVIDIA GPU access..."

if command -v nvidia-smi &>/dev/null; then
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
    echo "  GPU detected successfully."
    echo ""
else
    echo "ERROR: nvidia-smi not found."
    echo ""
    echo "This means either:"
    echo "  1. NVIDIA driver is not installed on Windows (install from nvidia.com/drivers)"
    echo "  2. You're on WSL1 instead of WSL2 (run 'wsl --set-version Ubuntu-22.04 2')"
    echo "  3. You need to restart WSL after driver install ('wsl --shutdown' from PowerShell)"
    echo ""
    echo "Fix the above and re-run this script."
    exit 1
fi

# =============================================================================
# Step 3: Install Docker Engine
# =============================================================================
# We install Docker Engine directly in WSL2, NOT Docker Desktop.
#
# Why not Docker Desktop?
#   - Docker Desktop runs its own WSL2 VM, adding overhead and complexity.
#   - GPU passthrough is more reliable with Docker Engine installed directly.
#   - Docker Desktop requires a paid license for companies > 250 employees.
#   - Direct install gives you the same Docker experience as native Linux.
#
# If you already have Docker Desktop and it works, that's fine too — skip this
# step. The docker-compose.yml works with either approach.
#
# We follow Docker's official install docs for Ubuntu:
# https://docs.docker.com/engine/install/ubuntu/
# =============================================================================
echo "[3/7] Installing Docker Engine..."

if command -v docker &>/dev/null; then
    echo "  Docker is already installed: $(docker --version)"
    echo ""
else
    # Remove any old/conflicting Docker packages
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        sudo apt-get remove -y "$pkg" 2>/dev/null || true
    done

    # Add Docker's official GPG key and repository
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add current user to the docker group so you don't need sudo for every
    # docker command. You'll need to log out and back in (or run `newgrp docker`)
    # for this to take effect.
    sudo usermod -aG docker "$USER"

    echo "  Docker installed successfully."
    echo "  NOTE: Run 'newgrp docker' or restart your WSL session for group changes."
    echo ""
fi

# =============================================================================
# Step 4: Start Docker daemon
# =============================================================================
# WSL2 doesn't use systemd by default (though newer versions support it).
# We start dockerd manually if it's not already running.
#
# If your WSL2 distro has systemd enabled (check /etc/wsl.conf for
# [boot] systemd=true), Docker will auto-start on boot.
# =============================================================================
echo "[4/7] Starting Docker daemon..."

if docker info &>/dev/null 2>&1; then
    echo "  Docker daemon is already running."
    echo ""
else
    # Start dockerd in the background. The `--host` flags allow both socket
    # and TCP connections (TCP is optional, socket is what we use).
    sudo dockerd &>/dev/null &
    sleep 3  # Give the daemon a moment to start

    if docker info &>/dev/null 2>&1; then
        echo "  Docker daemon started."
        echo ""
    else
        echo "ERROR: Could not start Docker daemon."
        echo "  Try: sudo service docker start"
        echo "  Or enable systemd in /etc/wsl.conf and restart WSL."
        exit 1
    fi
fi

# =============================================================================
# Step 5: Install NVIDIA Container Toolkit
# =============================================================================
# This is the bridge between Docker and your GPU. Without it, Docker has no
# idea how to map GPU devices into containers.
#
# What it does:
#   - Provides the "nvidia" container runtime for Docker
#   - Maps /dev/nvidia* devices into the container
#   - Mounts the NVIDIA driver libraries into the container
#   - Handles CUDA version negotiation between host driver and container toolkit
#
# The deploy.resources.reservations section in docker-compose.yml relies on
# this toolkit being installed and configured.
#
# Docs: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
# =============================================================================
echo "[5/7] Installing NVIDIA Container Toolkit..."

if dpkg -l nvidia-container-toolkit &>/dev/null 2>&1; then
    echo "  nvidia-container-toolkit is already installed."
    echo ""
else
    # Add NVIDIA's package repository
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit

    # Configure Docker to use the nvidia runtime. This modifies
    # /etc/docker/daemon.json to register the "nvidia" runtime.
    sudo nvidia-ctk runtime configure --runtime=docker

    # Restart Docker to pick up the new runtime configuration.
    # Without this restart, Docker won't recognize the nvidia runtime
    # and GPU reservation in docker-compose.yml will fail.
    sudo systemctl restart docker 2>/dev/null || sudo service docker restart 2>/dev/null || true

    echo "  nvidia-container-toolkit installed and configured."
    echo ""
fi

# =============================================================================
# Step 6: Verify GPU access inside Docker
# =============================================================================
# This is the moment of truth. We run nvidia-smi inside a container to confirm
# the entire stack works: Windows driver -> WSL2 -> Docker -> Container -> GPU.
#
# If this fails, the most common causes are:
#   - nvidia-container-toolkit not installed (step 5)
#   - Docker daemon not restarted after toolkit install
#   - Windows NVIDIA driver too old (need >= 570)
#   - WSL1 instead of WSL2
# =============================================================================
echo "[6/7] Verifying GPU access inside Docker..."

if docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu22.04 nvidia-smi; then
    echo ""
    echo "  GPU is accessible inside Docker containers."
    echo ""
else
    echo ""
    echo "ERROR: GPU not accessible inside Docker."
    echo "  Common fixes:"
    echo "    - Restart Docker: sudo service docker restart"
    echo "    - Restart WSL: wsl --shutdown (from PowerShell), then reopen"
    echo "    - Update Windows NVIDIA driver to >= 570"
    exit 1
fi

# =============================================================================
# Step 7: Clone and build autoresearch
# =============================================================================
# We create a persistent data cache directory, clone the repo (if needed),
# build the Docker image, and run data preparation.
#
# The ~/.cache/autoresearch directory is mounted into the container by
# docker-compose.yml so training data persists across container rebuilds.
# =============================================================================
echo "[7/7] Setting up autoresearch..."

# Create persistent cache directory for training data
# prepare.py stores downloaded shards and the trained tokenizer here
mkdir -p ~/.cache/autoresearch

REPO_DIR="$HOME/autoresearch"

if [ -d "$REPO_DIR" ]; then
    echo "  Repository already exists at $REPO_DIR"
    cd "$REPO_DIR"
    git pull || true
else
    echo "  Cloning autoresearch..."
    git clone https://github.com/anthonix/autoresearch.git "$REPO_DIR"
    cd "$REPO_DIR"
fi

echo ""
echo "  Building Docker image (this will take a while on first run)..."
echo "  The slowest part is Flash Attention 3 compilation (~5-10 min)."
echo ""
docker compose build

echo ""
echo "  Downloading training data..."
echo ""
docker compose run --rm autoresearch uv run prepare.py

echo ""
echo "==========================================="
echo " Setup complete!"
echo "==========================================="
echo ""
echo " To start training:"
echo "   cd $REPO_DIR"
echo "   docker compose up"
echo ""
echo " Training will log val_bpb (bits per byte) — lower is better."
echo " Press Ctrl+C to stop training at any time."
echo ""
echo " Useful commands:"
echo "   docker compose up -d              # run in background"
echo "   docker compose logs -f            # follow logs"
echo "   docker exec -it autoresearch bash # shell into container"
echo "   docker compose down               # stop and remove container"
echo ""
echo " GPU memory considerations:"
echo "   - RTX 4090: 24 GB VRAM — works out of the box"
echo "   - RTX 3090: 24 GB VRAM — works, but FA3 needs Ada/Hopper arch"
echo "   - If you hit OOM, the model/batch size in train.py may need tuning"
echo "   - Monitor GPU usage: watch nvidia-smi"
echo ""
