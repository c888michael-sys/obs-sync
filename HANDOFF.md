# obs-sync — implementation handoff

**Audience:** the build agent (Sonnet) that will implement this. **Architecture & rationale:**
see [README.md](README.md) — read it first. This file is the executable spec: what to do, in what
order, what must be true at each gate, and what you must **not** touch.

---

## Mission

Stand up a free, real-time, end-to-end-encrypted replacement for Obsidian Sync on the user's
**existing, already-in-use GCP VM**: CouchDB in Docker, reachable **only over Tailscale**, syncing
**markdown only** (attachments excluded for now), with both of the user's **Windows 11** machines
(desktop + laptop) connected. The scaffold already exists in this repo — use it, don't reinvent it.

## Definition of done

- [ ] `obsidian-couchdb` container is running on the VM and survives reboot (`restart: unless-stopped`).
- [ ] Its port is bound to the **VM's Tailscale IP only** — verified not on `0.0.0.0` / not public.
- [ ] System DBs (`_users`, `_replicator`, `_global_changes`) exist; LiveSync can create its `obsidian` DB.
- [ ] Desktop **and** laptop have Tailscale + the Self-hosted LiveSync plugin, the **same E2E passphrase**,
      and point at `http://<TS_IP>:<port>`.
- [ ] `.syncignore` is in the vault root and attachments are not syncing.
- [ ] Acceptance test passes: edit on laptop with desktop **closed** → reopen desktop → change appears.
- [ ] **No other service on the VM was disturbed.**
- [ ] Hand-back report (template at the bottom) is filled in and returned to the user.

---

## Hard constraints — this is a SHARED VM, do no harm

1. **Do not** restart or upgrade the Docker daemon, the OS, or any container/stack that is not ours.
2. **Do not** open any public firewall port (GCP or host). CouchDB is reached via Tailscale only.
3. **Do not** run `tailscale up` if Tailscale is already connected — detect with `tailscale status`
   first. Re-running can re-authenticate or change routes the VM's other services rely on.
4. **Do not** add swap if swap already exists or RAM is ample. The setup script already guards this.
5. **Namespace everything** under the `obs-sync` compose project. Only ever touch `obsidian-couchdb`.
6. **Port:** if `5984` is already taken, pick a free one, set `COUCHDB_PORT` in `.env`, and use it
   everywhere (the plugin URI too). Don't assume 5984 is free.
7. **Secrets:** `.env` holds the password — it is gitignored. Never commit it, never echo it into logs.
8. If anything is ambiguous or a step would risk an existing service, **stop and ask the user** rather
   than guessing.

## Access / prerequisites (confirm before starting)

- SSH/shell access to the VM. If you cannot reach it, stop and ask the user how to connect.
- This repo cloned onto the VM.
- A Tailscale account the user controls; the two Windows machines available for the device-side steps
  (those are GUI steps on Windows — you'll relay instructions for the user to perform).

---

## Step 1 — Pre-flight discovery (record everything for the report)

On the VM, gather and note:
```bash
free -h                       # RAM + existing swap
df -h .                       # free disk
docker --version || true      # is Docker already here? (it probably is)
docker ps                     # what else is running — do not disturb these
ss -ltn | grep -E ':5984$'    # is 5984 free? if not, choose another port
tailscale status || true      # already connected? if so, DO NOT run `tailscale up`
tailscale ip -4 || true       # the address devices will use
```
Decide from the results: which **port** to use, whether **swap** is needed (script handles), whether
Docker/Tailscale **install** is needed (script handles), and the **Tailscale IP**.

## Step 2 — Configure

```bash
cp .env.example .env
# Edit .env: set a strong COUCHDB_PASSWORD (generate 32+ random chars).
# Set COUCHDB_PORT only if 5984 is taken. Leave BIND_ADDR — the script fills it with the TS IP.
```

## Step 3 — Bring up CouchDB

Preferred: run the guarded script (idempotent, shared-VM-safe — read it once before running):
```bash
./scripts/setup-vm.sh
```
It does only: optional swap (if low + none) → Docker (if missing) → Tailscale (install if missing,
`up` only if not connected) → set `BIND_ADDR` to the TS IP → `docker compose up -d` for the
`obs-sync` project → create system DBs.

**Gate (must all pass before Step 4):**
```bash
curl -fsS http://127.0.0.1:<port>/                       # CouchDB welcome JSON
curl -fsS http://127.0.0.1:<port>/_up                    # {"status":"ok"}
curl -fsS http://USER:PASS@127.0.0.1:<port>/_all_dbs     # includes _users,_replicator,_global_changes
docker ps --filter name=obsidian-couchdb                 # Up
```

## Step 4 — Security verification (MUST pass)

```bash
ss -ltnp | grep ':<port>'     # MUST show the Tailscale IP (100.x.y.z), NEVER 0.0.0.0 or a public IP
```
- Confirm there is **no** GCP firewall rule exposing `<port>`. Check; do **not** create one.
- If the bind shows `0.0.0.0`, fix `BIND_ADDR` in `.env` to the TS IP and `docker compose up -d` again.
- Optional hardening (only if the user wants HTTPS / a stable hostname): expose CouchDB over the
  tailnet with `tailscale serve` instead of an IP:port. The exact flags are version-specific —
  check `tailscale serve --help` on the installed version before using it. Not required for two
  desktop clients over the encrypted tailnet.

## Step 5 — Device setup (relay to the user; these are Windows GUI steps)

Do the **desktop first**, then the laptop:
1. Install **Tailscale for Windows**, sign in to the **same** tailnet, confirm the VM is visible.
2. In Obsidian: Community plugins → install & enable **Self-hosted LiveSync**.
3. In the plugin's setup:
   - **URI:** `http://<TS_IP>:<port>`
   - **Username / password:** from `.env`
   - **Database name:** `obsidian`
   - **End-to-end encryption passphrase:** set one (encrypts content stored in CouchDB) — must be
     **identical** on both devices.
   - **Sync mode:** LiveSync (real-time).
4. Copy `obsidian/syncignore.txt` into the **vault root**, rename to `.syncignore`, and enable the
   plugin's **"use ignore files"** option pointing at it (attachments stay local — expected).
5. On the second device, use the first device's **"Copy setup URI"** and paste it in, so the config
   (including the E2E passphrase) is byte-identical. Mismatched passphrases = no sync.

## Step 6 — Acceptance tests (this is the proof, not "it looks fine")

1. **Seed:** push the existing vault from the desktop; on the laptop confirm note count matches.
2. **Server-middleman test:** close Obsidian on the desktop, edit a note on the laptop, wait for the
   plugin to report synced, reopen the desktop → the edit appears. (Proves the two devices never need
   to be online together.)
3. **Attachments-off check:** add a note embedding an image on the desktop → on the laptop the *text*
   syncs and the image shows as a missing-attachment placeholder. Expected; confirms the ignore works.
4. **Compaction:** run `./scripts/compact.sh` → DB size stays small; no errors.

## Step 7 — Backups & upkeep

- Add a weekly cron on the VM for compaction:
  `0 4 * * 0  <repo>/scripts/compact.sh`
- Schedule a backup of `data/` (tar to off-box storage, or a GCP disk snapshot). E2E means backups
  are encrypted at rest.

## Rollback / clean removal (leaves other services untouched)

```bash
docker compose -p obs-sync down     # removes ONLY obsidian-couchdb + its network
# data/ holds the database — delete only if intentionally wiping.
# The only OS-level change we may have made is /swapfile + its /etc/fstab line; revert if undesired.
```

## Out of scope

- Mobile/iOS (the user has two Windows machines only).
- Public HTTPS / a domain (Tailscale provides reach).
- Syncing attachments (deferred by the user — re-enable later by editing `.syncignore`).
- Migrating to a home box (covered in README §7; not part of this build).

---

## Hand-back report — fill in and return to the user

```
VM pre-flight:   RAM ___  swap ___  disk ___  Docker ___  Tailscale ___
Port used:       _____ (5984 unless taken)
Tailscale IP:    100._____
Bind verified:   listener on TS IP, not 0.0.0.0?  yes / no
System DBs:      _users / _replicator / _global_changes present?  yes / no
Devices done:    desktop ___  laptop ___  (same E2E passphrase confirmed?)
.syncignore:     in vault + "use ignore files" enabled?  yes / no
Tests:           seed ___  middleman ___  attachments-off ___  compaction ___
Deviations:      ____________________________________________
Follow-ups:      ____________________________________________
```

## Reference files in this repo

- `docker-compose.yml` — CouchDB service (port bound to `BIND_ADDR` = TS IP).
- `couchdb/local.ini` — CouchDB settings LiveSync needs.
- `.env.example` → `.env` — credentials + bind address + port.
- `scripts/setup-vm.sh` — guarded, idempotent bring-up.
- `scripts/compact.sh` — storage reclamation.
- `obsidian/syncignore.txt` — copy to vault root as `.syncignore`.
