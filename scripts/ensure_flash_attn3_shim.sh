#!/bin/bash
set -euo pipefail

VENV_PATH="${1:-/workspace/venv}"
PYTHON_BIN="${VENV_PATH}/bin/python"

if [ ! -x "${PYTHON_BIN}" ]; then
    echo "[flash-attn3-shim] python not found in ${VENV_PATH}; skipping"
    exit 0
fi

"${PYTHON_BIN}" - <<'PY'
import importlib.util
import pathlib
import sys

if importlib.util.find_spec("flash_attn") is not None:
    try:
        from flash_attn import flash_attn_func  # noqa: F401
        print("[flash-attn3-shim] flash_attn already available")
        raise SystemExit(0)
    except Exception:
        # Existing module is present but not compatible with ComfyUI expectation.
        print("[flash-attn3-shim] flash_attn exists but flash_attn_func is missing")
        raise SystemExit(1)

if importlib.util.find_spec("flash_attn_interface") is None:
    print("[flash-attn3-shim] flash_attn_interface not found; skipping shim")
    raise SystemExit(0)

site_packages = [pathlib.Path(p) for p in sys.path if p.endswith("site-packages")]
if not site_packages:
    print("[flash-attn3-shim] site-packages path not found")
    raise SystemExit(1)

target_pkg = site_packages[0] / "flash_attn"
target_pkg.mkdir(parents=True, exist_ok=True)
init_file = target_pkg / "__init__.py"
content = (
    '"""Compatibility shim: maps flash-attn3 interface for ComfyUI."""\n'
    "from flash_attn_interface import flash_attn_func\n"
    "__all__ = [\"flash_attn_func\"]\n"
)
init_file.write_text(content, encoding="utf-8")

from flash_attn import flash_attn_func  # noqa: F401
print(f"[flash-attn3-shim] created {init_file}")
PY
