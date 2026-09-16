# Dispatcharr Full Deploy Script

End-to-end, re-runnable installers for [Dispatcharr](https://github.com/Dispatcharr/Dispatcharr) on a **low-RAM (~2 GB) Debian box**.

The official installer works great on a machine with enough memory, but on a small VPS or a lean home VM the frontend build (Vite) tends to run out of memory and abort partway through, leaving you with a half-installed system. These scripts wrap the official installer, work around the out-of-memory build, and finish the job — services, nginx, and all — so you end up with a running instance instead of a stack trace.

## Which script do I want?

There are two scripts in this repo now:

| Script | Swap handling | Use it if... |
|---|---|---|
| [`Deploy_dispatcharr_full-v4.sh`](Deploy_dispatcharr_full-v4.sh) | **Optional.** Asks at runtime (or takes a flag) whether to create the swapfile. | This is the one you want in almost all cases — it does everything the swap-only script does, plus you can skip swap entirely if your box already has enough RAM or manages its own swap. |
| [`Deploy_dispatcharr_full-swapp.sh`](Deploy_dispatcharr_full-swapp.sh) | **Always on.** Always creates/repairs a swapfile, no way to opt out. | You specifically want the simpler, swap-always behavior with no prompts and no flags — e.g. scripting a fleet of small VPSes that all need the same swap workaround every time. |

Both scripts perform the same 8-stage install described below and are equally idempotent/re-runnable. The rest of this README applies to both unless a section says otherwise.

## What it does

Each script performs a complete install in eight stages:

0. **System prep** — updates packages and installs prerequisites (`git`, `curl`, plus — see "Extra robustness" below — the tooling needed for swap and locale generation to actually work).
1. **Swap** — creates and enables a 4 GB swap file (skippable in `-v4`, always-on in `-swapp`). This is what actually lets the memory-hungry frontend build succeed on a 2 GB box, and it also repairs the common `read swap header failed` error from a broken prior swap file.
2. **User** — ensures the `dispatcharr` user and group exist.
3. **Clone** — clones the Dispatcharr repo (skips if already present).
4. **Patched install** — runs the project's official `debian_install.sh` (packages, PostgreSQL, Python environment), but first patches its frontend build line so Vite gets a large Node heap (`--max-old-space-size`).
5. **Repair & finish** — if the installer's build still ran out of memory, the script detects the missing build and builds the frontend manually with the heap flag inline. It then ensures `.env` (with a generated Django secret key), creates the data directories, and runs migrations plus `collectstatic`.
6. **Services** — writes systemd units for uWSGI, Celery worker, Celery beat, and Daphne (ASGI/WebSockets).
7. **Web server** — writes the nginx site config and starts everything.
8. **Summary** — prints service status and the exact command to create your admin account.

Every step is idempotent — you can safely re-run either script if something fails partway through.

## Extra robustness (both scripts)

Beyond what Dispatcharr's own official installer does, these scripts also:

- **Force `/usr/sbin`, `/sbin`, etc. onto `PATH`** before doing anything else. Some shells (`su` without `-`, `pct enter` on Proxmox, minimal containers) hand you a `PATH` that's missing those directories even though the binaries in them are genuinely installed — which otherwise shows up as confusing "command not found" errors for things like `mkswap` or `locale-gen`.
- **Install and verify `util-linux-extra` and `locales`**, then double-check with `command -v` that `mkswap`, `swapon`, and `locale-gen` actually resolve — rather than trusting apt's "already installed" message. Debian trixie split several admin tools (`mkswap`, `swapon`, `fdisk`, ...) out of the base `util-linux` package into `util-linux-extra`, and minimal/cloud images don't always pull it in.
- **Self-heal missing commands**: if a required tool still isn't found after installing its package, the script looks it up with `dpkg -L` and symlinks it onto `PATH` itself instead of just failing.
- **Generate and activate a locale (`en_US.UTF-8` by default) up front**, so the official installer's own `locale-gen` call has something to work with.
- **Treat a failed `mkswap`/`swapon` as fatal** — stops the script with a clear error instead of printing "Swap enabled" regardless of whether it actually was.

## Requirements

- A **fresh Debian install** (tested against the low-RAM small-VPS case).
- **Root access** — the scripts must be run as root and will exit if not.
- Network access to GitHub and the Debian package mirrors.
- ~2 GB RAM minimum if you're using swap. If you plan to run `-v4` with swap disabled, make sure the box has enough real RAM to spare for the frontend build's Node heap (3072 MB by default) on top of everything else running.

## Usage

### `Deploy_dispatcharr_full-v4.sh` (recommended)

```bash
chmod +x Deploy_dispatcharr_full-v4.sh
./Deploy_dispatcharr_full-v4.sh
```

Before touching the system, it shows a settings summary (swap plan, Node heap, install paths, DB credentials, ports, locale) and asks you to confirm. If you didn't pass a swap flag, it asks a dedicated Y/n question about creating the swapfile first, then folds your answer into that summary.

Options:

| Flag / env var | Effect |
|---|---|
| `--no-swap` | Skip creating/using the swapfile entirely. Use this if the box already has enough RAM, already manages its own swap, or is a container/VM where swapfiles aren't wanted. |
| `SKIP_SWAP=1` | Same as `--no-swap`, set as an environment variable instead — handy for non-interactive/remote runs, e.g. `SKIP_SWAP=1 bash Deploy_dispatcharr_full-v4.sh`. |
| `-y`, `--yes` | Skip the settings summary/confirmation prompt (and the swap Y/n prompt, if swap wasn't already decided via flag/env) and just proceed. |
| `-h`, `--help` | Print usage and exit — no root required. |

If the script is run non-interactively (piped in, cron, CI — no real terminal attached), it can't prompt, so it prints the settings summary, notes that it's proceeding automatically, and continues with whatever `--no-swap`/`SKIP_SWAP`/`-y` you did or didn't pass.

### `Deploy_dispatcharr_full-swapp.sh`

```bash
chmod +x Deploy_dispatcharr_full-swapp.sh
./Deploy_dispatcharr_full-swapp.sh
```

No flags, no prompts about swap — it always creates/repairs the 4 GB swapfile and proceeds straight through all 8 stages.

### Both scripts

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

The tunables live in a block near the top of each script. Edit them before running if the defaults don't suit you:

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
| `LOCALE` (`-v4` only) | `en_US.UTF-8` | Locale generated/activated in step 0 before the official installer runs. |

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

- **Frontend fails to build even with swap** — confirm the swap file is actually active with `free -h` and `swapon --show`. If it's missing, a previous broken `/swapfile` may have blocked it; both scripts remove and recreate it, so re-running usually clears this.
- **Frontend fails to build with swap disabled (`-v4 --no-swap`)** — the box likely doesn't have enough real RAM for the Node heap. Either re-run with swap enabled, or lower `NODE_HEAP_MB`.
- **`mkswap`/`swapon`/`locale-gen`: command not found** — both scripts now install `util-linux-extra`/`locales` and self-heal `PATH`/missing symlinks automatically in step 0. If it still can't find a tool, it'll tell you exactly what it tried (`dpkg -L <pkg>`) and what to run by hand.
- **Web UI loads but styling/assets are missing** — the frontend build or `collectstatic` didn't complete. Re-run the script; step 5 will rebuild what's missing.
- **`dispatcharr` service won't start** — usually PostgreSQL isn't ready or the DB credentials in the systemd unit don't match. The unit waits on `pg_isready`, but check the journal to confirm.
- **Re-running either script** is safe at any point. Idempotent steps skip work that's already done and only repair what's missing.

## Notes

This is a community convenience wrapper around the official Dispatcharr installer, not a replacement for it. It exists to make the small-machine install path reliable. For the application itself, its features, and general documentation, see the [upstream Dispatcharr project](https://github.com/Dispatcharr/Dispatcharr).
