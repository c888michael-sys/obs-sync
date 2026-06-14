#!/usr/bin/env bash
# Run on the SHARED GCP VM. Safe to re-run.
# Touches ONLY this project's container. Never restarts the Docker daemon, never opens a
# public port, never re-auths an already-connected Tailscale, never adds swap if it exists.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

echo "==> Pre-flight"
free -h | awk '/Mem:/{print "    RAM:  "$2" total, "$7" available"}'
free -h | awk '/Swap:/{print "    Swap: "$2" total"}'
df -h "$REPO_DIR" | awk 'NR==2{print "    Disk: "$4" free on "$6}'
command -v docker    >/dev/null 2>&1 && echo "    Docker: $(docker --version)"        || echo "    Docker: not installed"
command -v tailscale >/dev/null 2>&1 && echo "    Tailscale: $(tailscale version | head -1)" || echo "    Tailscale: not installed"

# --- .env required ---
[ -f .env ] || { echo "ERROR: create .env from .env.example first (set a strong password)." >&2; exit 1; }
set -a; . ./.env; set +a
PORT="${COUCHDB_PORT:-5984}"

# --- Port must be free ---
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${PORT}\$"; then
  echo "ERROR: port ${PORT} is already in use on this VM. Set COUCHDB_PORT in .env to a free port and re-run." >&2
  exit 1
fi

# --- Swap only if low AND none of ours exists ---
SWAP_KB="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
if [ "${SWAP_KB:-0}" -lt 1048576 ] && [ ! -f /swapfile ]; then
  echo "==> Low swap and no /swapfile — adding 2 GB swap"
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
else
  echo "==> Swap already present/sufficient — leaving it alone"
fi

# --- Docker only if missing ---
if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker"
  curl -fsSL https://get.docker.com | sh
fi

# --- Tailscale: install if missing; bring up ONLY if not already connected ---
if ! command -v tailscale >/dev/null 2>&1; then
  echo "==> Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if sudo tailscale status >/dev/null 2>&1; then
  echo "==> Tailscale already connected — not touching it"
else
  echo "==> Tailscale not connected — bringing it up (follow the auth link)"
  sudo tailscale up
fi
TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
echo "==> This VM's Tailscale IP: ${TS_IP:-<unknown>}"

# --- Bind CouchDB to the Tailscale IP (auto-fill BIND_ADDR) ---
if [ -n "$TS_IP" ] && { [ -z "${BIND_ADDR:-}" ] || [ "${BIND_ADDR}" = "127.0.0.1" ]; }; then
  echo "==> Setting BIND_ADDR=$TS_IP in .env"
  if grep -q '^BIND_ADDR=' .env; then
    sed -i "s|^BIND_ADDR=.*|BIND_ADDR=$TS_IP|" .env
  else
    echo "BIND_ADDR=$TS_IP" >> .env
  fi
fi

# --- Start ONLY our stack ---
echo "==> Starting CouchDB (compose project: obs-sync)"
sudo docker compose up -d

echo "==> Waiting for CouchDB to respond"
until curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; do sleep 2; done

# --- System databases (idempotent) ---
for db in _users _replicator _global_changes; do
  echo "==> Ensuring system DB: ${db}"
  curl -fsS -X PUT "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@127.0.0.1:${PORT}/${db}" >/dev/null || true
done

echo
echo "Done. CouchDB bound to ${TS_IP:-127.0.0.1}:${PORT} (Tailscale-only)."
echo "LiveSync URI for both devices:  http://${TS_IP:-<tailscale-ip>}:${PORT}"
echo "Verify it is NOT public:  ss -ltnp | grep ${PORT}   (should show ${TS_IP:-100.x.y.z}, never 0.0.0.0)"
