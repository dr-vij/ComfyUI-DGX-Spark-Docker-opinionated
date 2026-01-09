#!/bin/bash

# Check if venv exists and is writable, recreate if not
python3 -m venv --system-site-packages /workspace/venv

# Activate venv
source /workspace/venv/bin/activate

# Install/check requirements
pip install -r /workspace/ComfyUI/requirements.txt

# Run ComfyUI
python /workspace/ComfyUI/main.py --listen 0.0.0.0 --port ${COMFY_PORT:-8188}
