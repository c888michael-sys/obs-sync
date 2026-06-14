#!/usr/bin/env bash
# Reclaim CouchDB disk space by compacting the database.
# Schedule weekly via cron on the VM, e.g.:
#   0 4 * * 0  /home/USER/obs-sync/scripts/compact.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$REPO_DIR/.env"; set +a

DB="${1:-obsidian}"
curl -fsS -X POST "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@127.0.0.1:5984/${DB}/_compact" \
  -H "Content-Type: application/json"
echo "Compaction triggered for '${DB}'."
