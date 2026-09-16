#!/usr/bin/env bash
#
# deploy_dispatcharr_full.sh
#
# End-to-end Dispatcharr install for a low-RAM (~2 GB) Debian box, working
# around the frontend build (vite) running out of memory.
#
# It handles everything discovered the hard way:
#  1. Creates/repairs a 4 GB swap file (fixes "read swap header failed").
#  2. Ensures the 'dispatcharr' user/group exist.
#  3. Clones the repo.
#  4. Runs the official installer's early steps (packages, postgres, python env)
#     by invoking debian_install.sh — BUT patches its frontend build line first
#     so vite gets a big Node heap. If the installer's build still OOMs (its
#     git reset can revert the patch), we detect the missing build afterward and
#     build the frontend manually with the flag inline.
#  5. Ensures .env, data dirs, migrations, collectstatic.
#  6. Writes systemd services + nginx and starts everything.
#  7. Points you at the createsuperuser command (needs an interactive TTY).
#
# Run as root on a fresh Debian install:
#   chmod +x deploy_dispatcharr_full.sh && ./deploy_dispatcharr_full.sh
#
# Re-runnable: every step is idempotent.

set -uo pipefail   # NB: not -e; we handle the installer's build failure ourselves

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Run this as root." >&2
  exit 1
fi

# Some shells this script gets invoked from (su without '-', pct enter, a
# stripped-down container entrypoint, etc.) hand us a PATH that's missing
# /sbin and /usr/sbin, even though the binaries that live there (mkswap,
# swapon, locale-gen, ...) are genuinely installed. Force them onto PATH
# unconditionally so 'command -v' and the bare calls later in this script
# actually find them.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# --- Tunables -----------------------------------------------------------------
SWAP_SIZE_GB=4
NODE_HEAP_MB=3072
CLONE_DIR="/root/Dispatcharr"
APP_DIR="/opt/dispatcharr"
POSTGRES_DB="dispatcharr"
POSTGRES_USER="dispatch"
POSTGRES_PASSWORD="secret"
HTTP_PORT=9191
WS_PORT=8001
LOCALE="en_US.UTF-8"   # locale to generate if none is active; change if you want another
# ------------------------------------------------------------------------------

log() { echo -e "\n>>> $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# Re-check that a command actually resolves, even when its package is
# reportedly installed. On some images (containers, LXC 'pct enter' shells,
# minimal cloud templates) PATH doesn't include every directory a package
# installs into, so 'dpkg -l' can say a package is present while 'command -v'
# still comes up empty. Walk through increasingly forceful fixes:
#   1) is it just a PATH problem? -> find it with dpkg -L and symlink it
#      into /usr/local/bin, which we've already forced onto PATH above.
#   2) is the package itself missing/broken? -> (re)install it, then repeat
#      the dpkg -L / symlink check.
# Only if both of those fail do we give up and tell the user what to run by hand.
require_cmd() {
  local cmd="$1" pkg="$2" found=""

  _link_if_found() {
    found="$(dpkg -L "$pkg" 2>/dev/null | grep -E "/${cmd}\$" | head -n1)"
    if [[ -n "$found" && -x "$found" ]]; then
      ln -sf "$found" "/usr/local/bin/${cmd}"
      hash -r
    fi
  }

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "  '$cmd' not on PATH yet — checking whether $pkg already provides it..."
    _link_if_found
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "  Not found via $pkg yet — installing/reinstalling $pkg..."
      apt install -y --reinstall "$pkg" || apt install -y "$pkg" || true
      _link_if_found
    fi
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is still unavailable after installing '$pkg' and searching its file list. Run 'dpkg -S $cmd' (or 'dpkg -L $pkg | grep bin/') by hand to find it, then either add its directory to PATH or 'ln -s <path> /usr/local/bin/$cmd', and re-run this script."
    echo "  '$cmd' resolved to $(command -v "$cmd")"
  fi
}

########################################
# 0) System prep
########################################
log "[0/8] Updating system and installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y git curl util-linux-extra locales

log "Verifying swap/locale tooling is actually present..."
require_cmd mkswap util-linux-extra
require_cmd swapon util-linux-extra
require_cmd locale-gen locales

log "Ensuring a usable locale (${LOCALE}) is generated and active..."
# Uncomment it in /etc/locale.gen if present, otherwise append it. Safe to
# re-run: locale-gen skips locales that are already built.
sed -i "s/^# *${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen 2>/dev/null || true
grep -q "^${LOCALE} UTF-8" /etc/locale.gen 2>/dev/null || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen || die "locale-gen failed — see the error above."
update-locale LANG="${LOCALE}" 2>/dev/null || true

########################################
# 1) Swap
########################################
log "[1/8] Setting up ${SWAP_SIZE_GB} GB swap..."
if swapon --show | grep -q '/swapfile'; then
  echo "Swap already active, skipping."
else
  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile
  fallocate -l "${SWAP_SIZE_GB}G" /swapfile 2>/dev/null || \
    dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB * 1024))
  chmod 600 /swapfile
  mkswap /swapfile || die "mkswap failed — see the error above."
  swapon /swapfile || die "swapon failed — see the error above."
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "Swap enabled."
fi
free -h

########################################
# 2) dispatcharr user
########################################
log "[2/8] Ensuring 'dispatcharr' user/group exist..."
getent group dispatcharr >/dev/null || groupadd dispatcharr
id -u dispatcharr >/dev/null 2>&1 || useradd -m -g dispatcharr -s /bin/bash dispatcharr

########################################
# 3) Clone repo
########################################
log "[3/8] Cloning Dispatcharr repo (if needed)..."
cd /root
if [[ ! -d "$CLONE_DIR/.git" ]]; then
  rm -rf "$CLONE_DIR"
  git clone https://github.com/Dispatcharr/Dispatcharr.git "$CLONE_DIR" || {
    echo "[ERROR] git clone failed. Is git installed and network up?"; exit 1; }
fi
cd "$CLONE_DIR"

########################################
# 4) Patch installer build line, then run installer
########################################
log "[4/8] Patching installer so the frontend build gets a ${NODE_HEAP_MB} MB heap..."
if ! grep -q 'NODE_OPTIONS=.*npm run build' debian_install.sh; then
  sed -i "s/^npm run build/NODE_OPTIONS=--max-old-space-size=${NODE_HEAP_MB} npm run build/" debian_install.sh
fi
grep -n 'npm run build' debian_install.sh || true

log "Running the official installer..."
echo "=================================================================="
echo " The installer prints a disclaimer and waits for you to type:"
echo "     I understand"
echo " Type it and press Enter when prompted."
echo "=================================================================="
# The installer uses 'set -e' internally; if the frontend build OOMs it will
# abort. We tolerate that here and repair the build ourselves in step 5.
bash debian_install.sh || echo "[WARN] Installer exited non-zero (likely the frontend build OOM). Continuing with manual repair..."

########################################
# 5) Repair: build frontend if missing, ensure .env, dirs, migrate, static
########################################
log "[5/8] Verifying frontend build..."
if [[ ! -d "$APP_DIR/frontend/dist/assets" ]]; then
  echo "Frontend not built — building manually with ${NODE_HEAP_MB} MB heap (this is the reliable path)..."
  su - dispatcharr -c "cd $APP_DIR/frontend && NODE_OPTIONS=--max-old-space-size=${NODE_HEAP_MB} npm run build" || {
    echo "[ERROR] Manual frontend build failed. Check output above."; exit 1; }
else
  echo "Frontend build present."
fi

log "Ensuring .env with Django secret key..."
su - dispatcharr <<EOSU
set -euo pipefail
cd "$APP_DIR"
touch .env
chmod 600 .env
if ! grep -q '^DJANGO_SECRET_KEY=' .env; then
  echo "DJANGO_SECRET_KEY=\$(env/bin/python -c 'import secrets; print(secrets.token_urlsafe(64))')" >> .env
fi
EOSU

log "Creating data directories..."
mkdir -p /data/logos /data/recordings /data/uploads/m3us /data/uploads/epgs \
         /data/m3us /data/epgs /data/plugins /data/db
chown -R dispatcharr:dispatcharr /data
chown -R postgres:postgres /data/db
chmod +x /data
mkdir -p "$APP_DIR/logo_cache" "$APP_DIR/media"
chown -R dispatcharr:dispatcharr "$APP_DIR/logo_cache" "$APP_DIR/media"

log "Running migrations + collectstatic..."
su - dispatcharr <<EOSU
set -euo pipefail
cd "$APP_DIR"
set -a; source .env; set +a
export POSTGRES_DB="$POSTGRES_DB"
export POSTGRES_USER="$POSTGRES_USER"
export POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
export POSTGRES_HOST=localhost
env/bin/python manage.py migrate --noinput
env/bin/python manage.py collectstatic --noinput
EOSU

########################################
# 6) systemd services
########################################
log "[6/8] Writing systemd services and uwsgi config..."
cat > "$APP_DIR/uwsgi-debian.ini" <<'EOF'
[uwsgi]
chdir = /opt/dispatcharr
module = dispatcharr.wsgi:application
virtualenv = /opt/dispatcharr/env
master = true
workers = 4
socket = /run/dispatcharr/dispatcharr.sock
chmod-socket = 666
vacuum = true
die-on-term = true
gevent = 100
gevent-early-monkey-patch = true
import = dispatcharr.gevent_patch
lazy-apps = true
buffer-size = 65536
socket-timeout = 600
thunder-lock = true
EOF
chown dispatcharr:dispatcharr "$APP_DIR/uwsgi-debian.ini"

cat > /etc/systemd/system/dispatcharr.service <<'EOF'
[Unit]
Description=uWSGI for Dispatcharr
After=network.target postgresql.service redis-server.service

[Service]
User=dispatcharr
Group=dispatcharr
WorkingDirectory=/opt/dispatcharr
RuntimeDirectory=dispatcharr
RuntimeDirectoryMode=0775
EnvironmentFile=/opt/dispatcharr/.env
Environment="PATH=/opt/dispatcharr/env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"
Environment="POSTGRES_DB=dispatcharr"
Environment="POSTGRES_USER=dispatch"
Environment="POSTGRES_PASSWORD=secret"
Environment="POSTGRES_HOST=localhost"
ExecStartPre=/usr/bin/bash -c 'until pg_isready -h localhost -U dispatch; do sleep 1; done'
ExecStart=/opt/dispatcharr/env/bin/uwsgi --ini /opt/dispatcharr/uwsgi-debian.ini
Restart=always
KillMode=mixed
SyslogIdentifier=dispatcharr
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/dispatcharr-celery.service <<'EOF'
[Unit]
Description=Celery Worker for Dispatcharr
After=network.target redis-server.service
Requires=dispatcharr.service

[Service]
User=dispatcharr
Group=dispatcharr
WorkingDirectory=/opt/dispatcharr
EnvironmentFile=/opt/dispatcharr/.env
Environment="PATH=/opt/dispatcharr/env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"
Environment="POSTGRES_DB=dispatcharr"
Environment="POSTGRES_USER=dispatch"
Environment="POSTGRES_PASSWORD=secret"
Environment="POSTGRES_HOST=localhost"
Environment="CELERY_BROKER_URL=redis://localhost:6379/0"
ExecStart=/opt/dispatcharr/env/bin/celery -A dispatcharr worker -l info
Restart=always
KillMode=mixed
SyslogIdentifier=dispatcharr-celery
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/dispatcharr-celerybeat.service <<'EOF'
[Unit]
Description=Celery Beat Scheduler for Dispatcharr
After=network.target redis-server.service
Requires=dispatcharr.service

[Service]
User=dispatcharr
Group=dispatcharr
WorkingDirectory=/opt/dispatcharr
EnvironmentFile=/opt/dispatcharr/.env
Environment="PATH=/opt/dispatcharr/env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"
Environment="POSTGRES_DB=dispatcharr"
Environment="POSTGRES_USER=dispatch"
Environment="POSTGRES_PASSWORD=secret"
Environment="POSTGRES_HOST=localhost"
Environment="CELERY_BROKER_URL=redis://localhost:6379/0"
ExecStart=/opt/dispatcharr/env/bin/celery -A dispatcharr beat -l info
Restart=always
KillMode=mixed
SyslogIdentifier=dispatcharr-celerybeat
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/dispatcharr-daphne.service <<'EOF'
[Unit]
Description=Daphne for Dispatcharr (ASGI/WebSockets)
After=network.target
Requires=dispatcharr.service

[Service]
User=dispatcharr
Group=dispatcharr
WorkingDirectory=/opt/dispatcharr
EnvironmentFile=/opt/dispatcharr/.env
Environment="PATH=/opt/dispatcharr/env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"
Environment="POSTGRES_DB=dispatcharr"
Environment="POSTGRES_USER=dispatch"
Environment="POSTGRES_PASSWORD=secret"
Environment="POSTGRES_HOST=localhost"
ExecStart=/opt/dispatcharr/env/bin/daphne -b 0.0.0.0 -p 8001 dispatcharr.asgi:application
Restart=always
KillMode=mixed
SyslogIdentifier=dispatcharr-daphne
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

########################################
# 7) nginx + start
########################################
log "[7/8] Writing nginx site and starting services..."
cat > /etc/nginx/sites-available/dispatcharr.conf <<'EOF'
server {
    listen 9191;
    client_max_body_size 0;

    location / {
        include uwsgi_params;
        uwsgi_param HTTP_X_REAL_IP $remote_addr;
        uwsgi_read_timeout 600;
        uwsgi_send_timeout 600;
        uwsgi_pass unix:/run/dispatcharr/dispatcharr.sock;
    }

    location /static/ { alias /opt/dispatcharr/static/; }
    location /assets/ { alias /opt/dispatcharr/frontend/dist/assets/; }
    location /media/  { alias /opt/dispatcharr/media/; }

    location /ws/ {
        proxy_pass http://127.0.0.1:8001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Host $host;
    }
}
EOF
ln -sf /etc/nginx/sites-available/dispatcharr.conf /etc/nginx/sites-enabled/dispatcharr.conf
[ -f /etc/nginx/sites-enabled/default ] && rm /etc/nginx/sites-enabled/default
nginx -t
systemctl restart nginx
systemctl enable nginx

systemctl daemon-reload
systemctl enable --now dispatcharr dispatcharr-celery dispatcharr-celerybeat dispatcharr-daphne

########################################
# 8) Summary + admin instructions
########################################
server_ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')

log "[8/8] Done. Service status:"
systemctl is-active dispatcharr dispatcharr-celery dispatcharr-celerybeat dispatcharr-daphne nginx | \
  paste -d' ' <(printf 'dispatcharr\ncelery\ncelerybeat\ndaphne\nnginx\n') -

cat <<EOF

==================================================================
 Dispatcharr is installed and running.

 URL: http://${server_ip}:${HTTP_PORT}

 CREATE YOUR ADMIN ACCOUNT (needs an interactive prompt, so it is
 NOT done automatically). Run these lines now:

   su - dispatcharr
   cd /opt/dispatcharr
   set -a; source .env; set +a
   export POSTGRES_DB=dispatcharr POSTGRES_USER=dispatch POSTGRES_PASSWORD=secret POSTGRES_HOST=localhost
   env/bin/python manage.py createsuperuser

 Enter a username, email (optional), and password when prompted,
 then type 'exit' to return to root and reload the web page.

 (On a public-IP VPS the browser setup page is blocked by default,
 which is why we create the admin from the terminal.)

 Logs if anything is not 'active':
   journalctl -u dispatcharr -n 50 --no-pager
==================================================================
EOF
