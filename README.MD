# Dispatcharr Full Deploy Script

An end-to-end, re-runnable installer for [Dispatcharr](https://github.com/Dispatcharr/Dispatcharr) on a **low-RAM (~2 GB) Debian box**.

The official installer works great on a machine with enough memory, but on a small VPS or a lean home VM the frontend build (Vite) tends to run out of memory and abort partway through, leaving you with a half-installed system. This script wraps the official installer, works around the out-of-memory build, and finishes the job — services, nginx, and all — so you end up with a running instance instead of a stack trace.

## What it does

`deploy_dispatcharr_full.sh` performs a complete install in eight stages:

0. **System prep** — updates packages and installs prerequisites (`git`, `curl`).
1. **Swap** — creates and enables a 4 GB swap file. This is what actually lets the memory-hungry frontend build succeed on a 2 GB box, and it also repairs the common `read swap header failed` error from a broken prior swap file.
2. **User** — ensures the `dispatcharr` user and group exist.
3. **Clone** — clones the Dispatcharr repo (skips if already present).
4. **Patched install** — runs the project's official `debian_install.sh` (packages, PostgreSQL, Python environment), but first patches its frontend build line so Vite gets a large Node heap (`--max-old-space-size`).
5. **Repair & finish** — if the installer's build still ran out of memory, the script detects the missing build and builds the frontend manually with the heap flag inline. It then ensures `.env` (with a generated Django secret key), creates the data directories, and runs migrations plus `collectstatic`.
6. **Services** — writes systemd units for uWSGI, Celery worker, Celery beat, and Daphne (ASGI/WebSockets).
7. **Web server** — writes the nginx site config and starts everything.
8. **Summary** — prints service status and the exact command to create your admin account.

The script is **idempotent** — every step checks before it acts, so you can safely re-run it if something fails partway through.

## Why the workarounds exist

These aren't arbitrary; each one solves a specific failure that shows up on small machines:

- **The swap file** is the core fix. The Vite production build allocates more memory than a 2 GB box has, and without swap it gets killed by the OOM killer mid-build. 4 GB of swap gives it room to finish.
- **The Node heap flag** (`NODE_OPTIONS=--max-old-space-size=3072`) stops Node itself from capping its heap too low and failing even when system memory is available.
- **The manual rebuild fallback** exists because the official installer's `git reset` can revert the patched build line, so the build can still fail inside the installer. The script checks whether the frontend actually built and, if not, builds it directly — the reliable path.
- **Creating the admin from the terminal** is required because on a public-IP VPS the browser-based setup page is blocked by default. `createsuperuser` needs an interactive prompt, so it can't be fully automated and is left as a final manual step.

## Requirements

- A **fresh Debian install** (tested against the low-RAM small-VPS case).
- **Root access** — the script must be run as root and will exit if it isn't.
- Network access to GitHub and the Debian package mirrors.
- ~2 GB RAM minimum. The swap file compensates for the rest.

## Usage

Copy the script onto the target machine, then:

```bash
chmod +x deploy_dispatcharr_full.sh
./deploy_dispatcharr_full.sh
```

During the run, the official installer will print a disclaimer and wait for you to type:

```
I understand
```

Type it and press Enter to continue.

When the script finishes, it prints your instance URL and the commands to create your admin account. Run those:

```bash
su - dispatcharr
cd /opt/dispatcharr
set -a; source .env; set +a
export POSTGRES_DB=dispatcharr POSTGRES_USER=dispatch POSTGRES_PASSWORD=secret POSTGRES_HOST=localhost
env/bin/python manage.py createsuperuser
```

Enter a username, an optional email, and a password when prompted, then type `exit` and reload the web page. You're in.

## Configuration

The tunables live in a block near the top of the script. Edit them before running if the defaults don't suit you:

| Variable | Default | Purpose |
|---|---|---|
| `SWAP_SIZE_GB` | `4` | Size of the swap file created in step 1. |
| `NODE_HEAP_MB` | `3072` | Node heap size (MB) for the Vite build. |
| `CLONE_DIR` | `/root/Dispatcharr` | Where the repo is cloned. |
| `APP_DIR` | `/opt/dispatcharr` | Where the app is installed. |
| `POSTGRES_DB` | `dispatcharr` | Database name. |
| `POSTGRES_USER` | `dispatch` | Database user. |
| `POSTGRES_PASSWORD` | `secret` | Database password. |
| `HTTP_PORT` | `9191` | Port nginx serves the web UI on. |
| `WS_PORT` | `8001` | Port Daphne serves WebSockets on. |

> **Change `POSTGRES_PASSWORD` before deploying anything you care about.** The default `secret` is fine for a throwaway test box but should not be used on a real install. Note that the database credentials are also written into the systemd unit files, so if you change them here, re-run the script so the units are rewritten to match.

## After install

Access the web UI at:

```
http://<server-ip>:9191
```

The install creates five services. Check they're all active with:

```bash
systemctl is-active dispatcharr dispatcharr-celery dispatcharr-celerybeat dispatcharr-daphne nginx
```

| Service | Role |
|---|---|
| `dispatcharr` | uWSGI application server |
| `dispatcharr-celery` | Background task worker |
| `dispatcharr-celerybeat` | Scheduled task runner |
| `dispatcharr-daphne` | ASGI server for WebSockets |
| `nginx` | Reverse proxy / static file server |

## Troubleshooting

If anything isn't `active`, check its logs:

```bash
journalctl -u dispatcharr -n 50 --no-pager
```

Swap the unit name for whichever service is failing (`dispatcharr-celery`, `dispatcharr-daphne`, etc.).

A few common cases:

- **Frontend fails to build even with swap** — confirm the swap file is actually active with `free -h` and `swapon --show`. If it's missing, a previous broken `/swapfile` may have blocked it; the script removes and recreates it, so re-running usually clears this.
- **Web UI loads but styling/assets are missing** — the frontend build or `collectstatic` didn't complete. Re-run the script; step 5 will rebuild what's missing.
- **`dispatcharr` service won't start** — usually PostgreSQL isn't ready or the DB credentials in the systemd unit don't match. The unit waits on `pg_isready`, but check the journal to confirm.
- **Re-running the script** is safe at any point. Idempotent steps skip work that's already done and only repair what's missing.

## Notes

This is a community convenience wrapper around the official Dispatcharr installer, not a replacement for it. It exists to make the small-machine install path reliable. For the application itself, its features, and general documentation, see the [upstream Dispatcharr project](https://github.com/Dispatcharr/Dispatcharr).
