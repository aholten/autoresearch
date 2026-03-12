# =============================================================================
# Dockerfile for autoresearch — GPU-accelerated LLM pretraining
# =============================================================================
#
# This Dockerfile doubles as a guide. Every section is heavily commented so you
# can understand *why* each choice was made, not just *what* it does.
#
# Quick start:
#   docker compose build
#   docker compose run autoresearch uv run prepare.py   # download data (once)
#   docker compose up                                    # train
#
# Prerequisites:
#   - NVIDIA GPU with Hopper (H100) or Ada Lovelace (RTX 4090) architecture
#   - NVIDIA driver >= 570 installed on the HOST (not inside the container)
#   - nvidia-container-toolkit installed and configured
#   - If on Windows: WSL2 with GPU passthrough (see wsl_setup.sh)
#
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Base image
# ---------------------------------------------------------------------------
# We use nvidia/cuda:12.8.0-devel-ubuntu22.04 for two reasons:
#
# 1. "12.8.0" — matches the PyTorch cu128 wheel index we pull from in
#    pyproject.toml (`https://download.pytorch.org/whl/cu128`). Mixing CUDA
#    versions between the base image and PyTorch leads to cryptic symbol errors.
#
# 2. "devel" (not "runtime") — the `kernels` package (specifically Flash
#    Attention 3) compiles CUDA kernels at install time via `nvcc`. The runtime
#    image doesn't include nvcc or the CUDA headers, so the build would fail.
#    The tradeoff is a larger image (~8 GB vs ~4 GB), but there's no way around
#    it when you need JIT kernel compilation.
#
# 3. "ubuntu22.04" — broad Python 3.10 support via deadsnakes PPA, and good
#    compatibility with the NVIDIA container stack.
#
# WSL note: The CUDA toolkit inside the container is independent of whatever's
# on your Windows host. The ONLY thing the host needs is the NVIDIA GPU driver
# (which WSL2 automatically exposes to Linux via /dev/dxg). You do NOT install
# cuda-toolkit inside WSL — the container handles that.
# ---------------------------------------------------------------------------
FROM nvidia/cuda:12.8.0-devel-ubuntu22.04

# ---------------------------------------------------------------------------
# Environment variables
# ---------------------------------------------------------------------------
# DEBIAN_FRONTEND=noninteractive — prevents apt from prompting for timezone,
#   keyboard layout, etc. during build. Without this, builds hang forever.
#
# PYTHONUNBUFFERED=1 — forces Python to flush stdout/stderr immediately.
#   Without this, print() output from train.py gets buffered and you won't see
#   training logs in `docker compose up` until the buffer fills (often minutes).
#
# UV_LINK_MODE=copy — uv normally hardlinks packages from its cache into the
#   venv. Inside Docker layers, hardlinks across layers cause subtle breakage.
#   "copy" is slower but reliable.
# ---------------------------------------------------------------------------
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy

# ---------------------------------------------------------------------------
# System dependencies
# ---------------------------------------------------------------------------
# python3.10 + python3.10-venv — pinned to 3.10 to match .python-version.
#   The deadsnakes PPA provides newer Python builds for Ubuntu 22.04.
#
# git — needed by the `kernels` package to clone Flash Attention 3 source.
#
# curl — needed to install uv (the package manager).
#
# build-essential — gcc/g++ for compiling native Python extensions.
#
# We clean up apt caches at the end to keep the layer smaller.
# ---------------------------------------------------------------------------
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        software-properties-common && \
    add-apt-repository -y ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python3.10 \
        python3.10-venv \
        python3.10-dev \
        git \
        curl \
        build-essential && \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Install uv (Python package manager)
# ---------------------------------------------------------------------------
# uv is a fast, Rust-based replacement for pip + virtualenv. This project uses
# it exclusively — there's no requirements.txt or setup.py.
#
# We install it to /usr/local/bin so it's available system-wide in the container.
# The `--default-toolchain` flag is not needed; uv will use whatever python3.10
# is on PATH.
# ---------------------------------------------------------------------------
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    mv /root/.local/bin/uv /usr/local/bin/uv && \
    mv /root/.local/bin/uvx /usr/local/bin/uvx

# ---------------------------------------------------------------------------
# Working directory
# ---------------------------------------------------------------------------
WORKDIR /app

# ---------------------------------------------------------------------------
# Copy dependency files first (layer caching optimization)
# ---------------------------------------------------------------------------
# Docker caches each layer. By copying only pyproject.toml and uv.lock first,
# we ensure that `uv sync` only re-runs when dependencies actually change.
# If you only edit train.py, Docker skips the slow dependency install entirely.
# ---------------------------------------------------------------------------
COPY pyproject.toml uv.lock .python-version ./

# ---------------------------------------------------------------------------
# Install Python dependencies
# ---------------------------------------------------------------------------
# `uv sync` reads pyproject.toml + uv.lock and installs everything into a
# virtualenv at .venv/. Key things it does:
#
# - Pulls PyTorch 2.9.1 from the cu128 index (~2.5 GB wheel)
# - Installs `kernels>=0.11.7` which triggers Flash Attention 3 compilation
#   (this is the slowest step — ~5-10 min on first build, needs nvcc from devel)
# - All other deps: numpy, pandas, tiktoken, rustbpe, etc.
#
# --no-install-project — don't try to install autoresearch itself (it's not a
#   proper package with a build backend, just scripts).
#
# The `|| true` on the first sync is NOT here — if deps fail, the build should
# fail loudly. Don't hide errors.
# ---------------------------------------------------------------------------
RUN uv sync --no-install-project

# ---------------------------------------------------------------------------
# Copy project source
# ---------------------------------------------------------------------------
# Now copy everything else. Changes to train.py or prepare.py only invalidate
# from this layer onward (fast rebuild).
# ---------------------------------------------------------------------------
COPY . .

# ---------------------------------------------------------------------------
# Data preparation is NOT baked into the image
# ---------------------------------------------------------------------------
# You might be tempted to run `uv run prepare.py` here. Don't. Here's why:
#
# 1. The download is ~2 GB and would bloat the image permanently.
# 2. The data should live in a persistent volume so it survives rebuilds.
# 3. Different users may want different --num-shards values.
#
# Instead, run it once with the volume mounted:
#   docker compose run autoresearch uv run prepare.py
#
# The docker-compose.yml mounts ~/.cache/autoresearch into the container so
# prepare.py's output persists across container restarts.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Default entrypoint: training
# ---------------------------------------------------------------------------
# `uv run` activates the .venv and runs train.py. This means `docker compose up`
# immediately starts training — no shell needed.
#
# To run other commands (like prepare.py), override at runtime:
#   docker compose run autoresearch uv run prepare.py
#   docker compose run autoresearch uv run python -c "import torch; print(torch.cuda.is_available())"
# ---------------------------------------------------------------------------
CMD ["uv", "run", "train.py"]
