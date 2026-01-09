FROM nvcr.io/nvidia/cuda:13.0.2-devel-ubuntu24.04
ARG DEBIAN_FRONTEND=noninteractive

# Install Python and dependencies (Ubuntu 24.04 has Python 3.12 by default)
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    git \
    ninja-build \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxrender1 \
    libxext6 \
    && rm -rf /var/lib/apt/lists/*

ENV CUDA_HOME=/usr/local/cuda-13.0
ENV PATH="$CUDA_HOME/bin:${PATH}"
ENV LD_LIBRARY_PATH="$CUDA_HOME/lib64:${LD_LIBRARY_PATH}"
ENV LIBRARY_PATH="$CUDA_HOME/targets/sbsa-linux/lib:${LIBRARY_PATH}"
ENV TORCH_CUDA_ARCH_LIST="12.1+PTX"

RUN pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu130 --break-system-packages

# Set working directory
WORKDIR /workspace

# Set PATH for venv (venv will be created at runtime in entrypoint)
ENV PATH="/workspace/venv/bin:$PATH"

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
LABEL authors="dr-vij"