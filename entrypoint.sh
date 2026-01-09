#!/bin/bash

# Setup venv
python3 -m venv --system-site-packages /workspace/venv
source /workspace/venv/bin/activate

# Install ComfyUI requirements
pip install -r /workspace/ComfyUI/requirements.txt

# Clone custom nodes from list
cd /workspace/ComfyUI/custom_nodes
while IFS= read -r repo || [ -n "$repo" ]; do
    [[ -z "$repo" || "$repo" =~ ^# ]] && continue
    dir=$(basename "$repo" .git)
    [ -d "$dir" ] || git clone "$repo"
    [ -f "$dir/requirements.txt" ] && pip install -r "$dir/requirements.txt"
done < /workspace/ComfyUI/custom_nodes/custom_nodes.txt

# Run ComfyUI
python /workspace/ComfyUI/main.py --listen 0.0.0.0 --port ${COMFY_PORT:-8188}
