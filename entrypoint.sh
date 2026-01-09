#!/bin/bash

VENV_PATH="/workspace/venv"

# Create venv if not exists (first run only)
if [ ! -f "$VENV_PATH/bin/activate" ]; then
    echo "Creating virtual environment..."
    python3 -m venv "$VENV_PATH"
fi

# Update base packages (every run)
echo "Checking/updating base packages..."
pip install --upgrade pip
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu130
pip install sageattention || true

# Install onnxruntime-gpu from pre-built wheel (built in Docker image for CUDA 13.0)
echo "Installing onnxruntime-gpu from pre-built wheel..."
pip install /opt/onnxruntime/onnxruntime_gpu-*.whl

# Update ComfyUI repository if UPDATE_DEPS is true
if [ "${UPDATE_DEPS}" = "true" ]; then
    echo "Updating ComfyUI repository..."
    cd /workspace/ComfyUI || exit
    git pull
fi

# Install ComfyUI requirements
pip install -r /workspace/ComfyUI/requirements.txt

# Clone custom nodes from list
cd /workspace/ComfyUI/custom_nodes || exit
while IFS= read -r repo || [ -n "$repo" ]; do
    [[ -z "$repo" || "$repo" =~ ^# ]] && continue
    dir=$(basename "$repo" .git)
    [ -d "$dir" ] || git clone "$repo"
    # Update existing custom node if UPDATE_DEPS is true
    if [ "${UPDATE_DEPS}" = "true" ] && [ -d "$dir" ]; then
        echo "Updating custom node: $dir"
        cd "$dir" || exit
        git pull
        cd ..
    fi
    [ -f "$dir/requirements.txt" ] && pip install -r "$dir/requirements.txt"
done < /workspace/ComfyUI/custom_nodes/custom_nodes.txt

# Run ComfyUI
python /workspace/ComfyUI/main.py --listen 0.0.0.0 --port "${COMFY_PORT:-8188}"
