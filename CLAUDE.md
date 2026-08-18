# Agent instructions

## CRITICAL: Never modify the host system

This project builds and runs ComfyUI **inside Docker**. The agent may be running on the developer's host machine, not inside the container. You cannot reliably tell which one you're in.

Therefore: **NEVER install, upgrade, remove, or reconfigure anything outside this repository's working tree.** All system-level changes must be expressed as edits to:

- `Dockerfile`
- `docker-compose.yml`
- `entrypoint.sh`
- `constraints.txt` / `requirements.txt` files inside the repo
- `custom_nodes/` or other in-repo configuration

### Forbidden on the host (without explicit, per-action user approval)

- `apt`, `apt-get`, `dpkg`, `snap`, `yum`, `dnf`, `pacman`, `brew`, `port` — any system package manager
- `pip install`, `pip3 install`, `pipx install`, `uv pip install`, `conda install`, `poetry add` run outside a container
- Activating or writing into `./venv/` (it is the **container's** venv, mounted from the host — touching it from the host corrupts the container environment)
- `systemctl`, `service`, `update-alternatives`, `ldconfig`, modifying `/etc/**`, `/usr/**`, `/opt/**`, `~/.bashrc`, `~/.profile`, shell rc files, global git config
- `nvidia-smi`-adjacent tooling, driver/CUDA toolkit installs, kernel modules
- `docker system prune`, `docker volume rm`, removing images or volumes the user didn't name
- Anything that writes outside `/home/dr-vij/WorkProjects/ComfyDocker/` (except for the user's explicit ask)

### How to actually change the environment

If you need a new system package, Python package, CUDA library, custom node, model path, or env var: **edit the Dockerfile / compose file / entrypoint and tell the user to rebuild** (`docker compose build comfyui` or similar). Do not "just install it quickly to test" — the host is not the runtime.

### Allowed on the host

- Read anything in the repo.
- Edit files inside the repo.
- Run `git`, `docker`, `docker compose` commands.
- Run read-only diagnostics (`ls`, `cat` via Read, `grep`, `docker logs`, `docker compose ps`, `git status`, etc.).
- Run the official build/run flow the project already defines.

When in doubt: **ask the user before any command that writes outside this repo.**
