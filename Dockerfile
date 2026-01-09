FROM nvcr.io/nvidia/cuda:13.0.2-devel-ubuntu24.04
LABEL authors="dr-vij"

# Install Python and dependencies (Ubuntu 24.04 has Python 3.12 by default)
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    git \
    && rm -rf /var/lib/apt/lists/*


ENV CUDA_HOME=/usr/local/cuda-13.0
ENV PATH="$CUDA_HOME/bin:${PATH}"
ENV LD_LIBRARY_PATH="$CUDA_HOME/lib64:${LD_LIBRARY_PATH}"
ENV TORCH_CUDA_ARCH_LIST="12.1+PTX"

RUN pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu130 --break-system-packages

# Set working directory
WORKDIR /workspace

# Set PATH for venv (venv will be created at runtime in entrypoint)
ENV PATH="/workspace/venv/bin:$PATH"

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
