# Odysseus per-app — DESIGN.md

> This is the per-app design document for Odysseus. It is written by the LLM agent (or a human) when the per-app is created or updated. It captures the per-app-specific decisions that don't belong in the standard.

## Overview

Odysseus is a self-hosted AI workspace — a webapp that provides chat, agent, deep research, documents, memory, notes, calendar, email, and other features. It is an open source project at [github.com/pewdiepie-archdaemon/odysseus](https://github.com/pewdiepie-archdaemon/odysseus).

This per-app packages Odysseus as a self-contained macOS `.app` so users can run it as a native application rather than a browser tab.

## Source layout (upstream)

The upstream Odysseus repo contains:

- `app.py` — FastAPI entry point (`app:app`)
- `core/`, `src/`, `routes/`, `services/`, `static/`, `mcp_servers/` — the webapp's Python source
- `requirements.txt` — Python dependencies
- `setup.py` — first-run setup (creates `data/`, initializes the database, etc.)
- `start-macos.sh` — the original macOS launcher (used during prototyping, replaced by the `.app` for the production install)

The entire upstream repo is bundled into the `.app` at `Contents/Resources/app/`. We do **not** modify the upstream source. We do **not** fork the upstream.

## Server lifecycle

- **Runtime:** Python 3.11. Bundled as a relocatable Python distribution from [python-build-standalone](https://github.com/indygreg/python-build-standalone).
- **Site-packages:** Dependencies are installed to `Contents/Resources/runtime/site-packages/` (NOT a venv, because venv + python-build-standalone has dyld/libpython symlink issues on macOS — see `apps/odysseus/build-runtime.sh` for the full explanation). The wrapper sets `PYTHONPATH=./runtime/site-packages` so uvicorn finds the installed packages.
- **Start command:** `uvicorn app:app --host 127.0.0.1 --port $PORT`
- **Port:** 7860 (the upstream default; macOS AirPlay Receiver holds port 7000, so we use 7860 to avoid conflicts)
- **URL:** `/` (the FastAPI app's root, which redirects to `/login` on first visit)
- **Data location:** `~/Library/Application Support/com.pewdiepie-archdaemon.odysseus/`
  - The wrapper passes `DATA_DIR` as an env var. The upstream Odysseus reads this env var to find its database, memory, uploads, etc.
  - **Note:** upstream Odysseus currently has hardcoded paths to `./data/`. We patch this at build time: the `start_command` runs `setup.py` if `DATA_DIR` is empty, then runs uvicorn with `DATA_DIR` set. v1.1 will improve this by submitting a PR upstream to read `DATA_DIR` from env.

## First-run flow

On first launch, the wrapper detects that `DATA_DIR` is empty and:

1. Runs `python setup.py` in the bundled source dir, which creates the database and prompts the user for admin credentials.
2. Reads the admin username and password from the in-app wizard (`webappify.yaml`'s `first_run`).
3. Passes them to `setup.py` via env vars (`ODYSSEUS_ADMIN_USER`, `ODYSSEUS_ADMIN_PASSWORD`).
4. After setup completes, starts uvicorn as usual.

For v1, the first-run flow is **deferred** — the per-app launches uvicorn directly, and the user is redirected to Odysseus's own first-run flow (which currently expects `setup.py` to be run manually in Terminal). v1.1 implements the in-app wizard.

## Custom UI

The standard menu bar is sufficient for v1. Future customizations could include:

- A "View Server Logs" menu item (opens the live tail of `LOGS_DIR/server.log`)
- An "Open MCP Servers Folder" menu item (MCP servers are a key Odysseus concept)
- A "Restart Server" menu item (useful when the user changes settings that require a restart)

These are deferred to v1.1.

## Update feed

v1: no automatic update check. The `update_feed` field in `webappify.yaml` is not set. v1.1 will add Sparkle and a hosted appcast.

## Known quirks

- **ChromaDB.** Odysseus uses ChromaDB for vector memory. In the Docker version of Odysseus, ChromaDB runs as a sidecar container. In the native version, ChromaDB is expected to be available at `localhost:8100`. The per-app does NOT bundle ChromaDB — it expects the user to run it separately. v1.1 may bundle ChromaDB or detect it.
- **MCP servers.** Odysseus spawns several MCP servers as Python subprocesses. These are spawned by the upstream code from inside `Contents/Resources/app/mcp_servers/`. The bundled Python interpreter in `Contents/Resources/runtime/python/bin/python3` is used. The wrapper sets `PYTHONPATH=./runtime/site-packages` so the MCP servers can find their dependencies.
- **Port 7860 collision.** Some webapps (Gradio, Streamlit) default to 7860. If the user installs another per-app on the same port, the second one will fail to bind. Future versions may auto-detect free ports. v1: not implemented; document the port in `webappify.yaml`.
- **Cardinal Rule: hardcoded data path (PATCHED in v0.2.0).** Upstream Odysseus hardcodes its data path to `./data/` relative to the working directory. The wrapper sets the working directory to `Contents/Resources/app/`, which would have caused user data (the SQLite database, scheduled emails, etc.) to land inside the `.app` bundle at `Contents/Resources/app/data/`. This violated the Cardinal Rule. The build script now patches the relevant Python files at build time:
  - `core/constants.py`, `src/constants.py`, `setup.py`: `os.path.join(BASE_DIR, "data")` → `os.environ.get("DATA_DIR", os.path.join(BASE_DIR, "data"))`
  - `core/database.py`: `sqlite:///./data/app.db` → `sqlite:///" + os.path.join($DATA_DIR, "app.db")`
  - `setup.py`, `routes/personal_routes.py`, `routes/embedding_routes.py`: similar replacements for `logs` and `uploads` paths
  The wrapper also sets `DATABASE_URL` explicitly, so the patched `core/database.py` is a fallback in case the env var isn't set.

  The patch is idempotent and applied at build time from a fresh `git clone` of the upstream source.

  **Long-term fix:** the LLM agent should file a PR upstream to make Odysseus read `DATA_DIR` (or `XDG_DATA_HOME`) when set, falling back to the current behavior. Once that lands, remove the patch from `build-runtime.sh` and re-test.

  As of v0.2.0, the `.app` is fully functional AND passes the Cardinal Rule test AND the lift-and-shift test. The `.dmg` can be distributed.

## Recent changes (LLM agent log)

This section is maintained by the LLM agent when it syncs the per-app with the upstream.

_(none yet — this is the initial version)_
