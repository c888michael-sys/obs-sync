# obs-sync

A free, self-hosted, **real-time** replacement for Obsidian's paid Sync service —
built around an always-on server you already have (an existing Google Cloud VM).

> **Building this?** Follow [HANDOFF.md](HANDOFF.md) — the step-by-step implementation spec written
> for a build agent, including the shared-VM safety rules. This README is the architecture + rationale.

---

## 1. Goal & constraints

| Constraint (from you) | Consequence for the design |
|---|---|
| Want **real-time** sync, not interval/manual | Rules out Git-based sync. Use a live server model. |
| **No always-on machine at home** yet | The server lives on a cloud VM (your GCP). It becomes the "always-on machine." |
| **Google Cloud available**, but only a few GB free | Fine — notes are text; a vault is usually tens of MB. We add storage controls so it stays small. |
| Desktop + laptop **sometimes on the same home network** | Real-time works there automatically. |
| **Outside = laptop only** (desktop stays home) | No device-to-device reachability needed on the road; the laptop just syncs to the cloud server. |

**Key insight:** because the server is always on, the desktop and laptop **never need to be
online at the same time.** Laptop edits a note on the train → syncs up to the server → you get
home hours later → desktop pulls it down. When both *are* online together (at home), edits stream
live. This is exactly how the paid Obsidian Sync works internally; we're just hosting the middle box.

---

## 2. Chosen architecture

```
Desktop (Obsidian + LiveSync plugin) ─┐
                                      ├──► CouchDB on GCP e2-micro VM  (always on)
Laptop  (Obsidian + LiveSync plugin) ─┘        reached privately over Tailscale
```

| Piece | Choice | Why |
|---|---|---|
| Sync engine | **Self-hosted LiveSync** (Obsidian community plugin) | The true drop-in for Obsidian Sync: real-time, end-to-end encrypted, cross-platform. |
| Server | **CouchDB 3** in Docker | What LiveSync replicates against. Small, runs fine on a micro VM. |
| Host | **Your existing GCP VM** (already running other services) | No new instance or cost; it's already always-on. CouchDB coexists as one small extra container. |
| Networking | **Tailscale** (free personal tier) | CouchDB is **never exposed to the public internet** — devices reach it over an encrypted private network. No domain, no TLS certificate juggling, no open ports. |

Why Tailscale instead of a public HTTPS endpoint: it removes the entire public attack surface
(a public CouchDB is a well-known way to get your data scraped), needs no domain name, and "just
works" from home or the road. Both laptops join your tailnet and see the server at a stable name.

---

## 3. Does it fit your usage?

| Scenario | What happens |
|---|---|
| Both at home, same network, editing | Live, instant sync between all three (desktop ↔ server ↔ laptop). |
| Outside, editing on laptop only | Laptop syncs each change up to the cloud server immediately (also = off-site backup). |
| Come home after a trip | Desktop pulls everything the moment Obsidian opens. No conflicts, since only the laptop was edited. |
| Server briefly unreachable | Obsidian keeps working on the local copy; queued changes flush on reconnect. |

---

## 4. Cost & storage reality check

- **Cost:** £/$0 — reuses your existing VM, plus the Tailscale free tier and the free plugin.
- **Storage:** we're **excluding images/attachments from sync for now** (your call), so only the
  markdown text replicates. That's tiny — realistically **tens of MB** even with revision history.
  A few GB is far more than enough; storage stops being a concern.
- Trade-off of excluding images — see [Attachments policy](#5-attachments-policy-images-off-for-now)
  below. Short version: image embeds only render on the device that actually holds the file. Easy to
  switch back on later.

---

## 5. Attachments policy (images off for now)

For now we **do not sync images or other attachments** — only `.md` notes replicate. This keeps the
CouchDB tiny and sidesteps the storage limit completely.

**How it's enforced** (set in the LiveSync plugin, Phase 6): a vault ignore file lists the extensions
to skip. Create `.syncignore` (gitignore-style) at the vault root:

```gitignore
# Attachments excluded from sync for now
*.png
*.jpg
*.jpeg
*.gif
*.webp
*.bmp
*.svg
*.pdf
*.mp4
*.mov
*.mp3
```

Then enable the plugin's **"use ignore files"** setting and point it at `.syncignore`. (Alternatively,
LiveSync has a **maximum file size** cap — set it to ~0.5 MB and any large attachment is skipped
automatically. The ignore file is more precise; the size cap is less config. Either works.)

> ⚠️ **The trade-off, so it's not a surprise:** an image lives only on the device where you added it.
> A note that embeds `![[diagram.png]]` will show a **broken/missing-attachment** placeholder on the
> *other* device until that image exists there too. Your *text* is always fully in sync; only the
> visual embeds are local.

**Turning it back on later** is a one-liner: remove the extension lines from `.syncignore` (or raise
the size cap), and LiveSync does a one-time bulk upload of the attachments. Nothing else changes.
That's also the moment to make sure your GCP disk has room, or move to a home box first (Section 7).

---

## 6. Build plan (phased)

### Repository layout (scaffolded)
```
obs-sync/
  docker-compose.yml        CouchDB service (creds from .env)
  couchdb/local.ini         CouchDB settings LiveSync needs
  .env.example              copy to .env, set a strong password
  .gitignore                ignores .env and the data/ volume
  scripts/setup-vm.sh       swap + Docker + Tailscale + start + system DBs
  scripts/compact.sh        reclaim space (run weekly via cron)
  obsidian/syncignore.txt   copy to vault root as .syncignore (attachments off)
```

### Phase 0 — Prerequisites (confirmed)
- [x] Google Cloud = **Compute Engine VM** ✓
- [x] Both machines run **Windows 11** ✓
- [x] Images/attachments **excluded for now** (Section 5) → vault size is a non-issue ✓
- Needed: a GCP account that can create a free-tier `e2-micro`, and a free Tailscale account.

### Phase 1 — Use your existing VM (no new instance)
- This deploys onto the VM you already run. **Shared-VM rule:** don't disturb the other services —
  the setup script only installs what's missing, never restarts the Docker daemon, and never opens a
  public port. See [HANDOFF.md](HANDOFF.md) "Hard constraints".
- Pre-flight before anything else: check free disk, that the chosen port is free, and whether Docker
  and Tailscale are already present (`scripts/setup-vm.sh` prints all of this and adapts).

### Phase 2 + 3 — Software + CouchDB (one script)
Clone this repo onto the VM, then:
```bash
cp .env.example .env          # edit .env, set a strong COUCHDB_PASSWORD
./scripts/setup-vm.sh         # swap + Docker + Tailscale + start CouchDB + create system DBs
```
`scripts/setup-vm.sh` is idempotent and prints the VM's Tailscale IP at the end — that's the
address you'll give the LiveSync plugin (`http://<tailscale-ip>:5984`). The CouchDB service lives in
`docker-compose.yml`, its tuning in `couchdb/local.ini`, and the port is **not** opened in the GCP
firewall (Tailscale-only).

### Phase 4 — Lock it down
- **Do not** add a GCP firewall rule for port 5984. Leave it closed to the internet.
- Access is only via Tailscale (the `100.x.y.z` address). Optionally tighten with Tailscale ACLs.
- Keep the OS updated; consider `fail2ban` on SSH.

### Phase 5 — Devices onto the tailnet
- Install Tailscale on the **desktop** and **laptop**, sign in to the same account.
- Note the VM's Tailscale IP / MagicDNS name (e.g. `obsidian-couchdb` → `http://<tailscale-ip>:5984`).

### Phase 6 — Obsidian Self-hosted LiveSync
- Install the **Self-hosted LiveSync** community plugin on both machines.
- Configure on the desktop first:
  - URI: `http://<vm-tailscale-ip>:5984`
  - Username / password (from the compose file)
  - Database name: `obsidian`
  - Set an **end-to-end encryption passphrase** (encrypts note content stored in CouchDB)
  - Sync mode: **LiveSync** (real-time)
  - **Exclude attachments:** add `.syncignore` to the vault root (see Section 5) and enable the
    plugin's **"use ignore files"** option — or set **maximum file size** to ~0.5 MB.
- Use the plugin's **"Copy setup URI"** to carry the exact same config to the laptop (avoids typos).

### Phase 7 — Initial sync + tests
1. Seed from the desktop (push the existing vault up).
2. Open the laptop, let it pull, confirm notes match.
3. Test: edit on laptop while desktop is **closed** → reopen desktop → change appears (proves the
   "don't need both online" property).
4. Test an offline edit + reconnect.

### Phase 8 — Keep storage small
- In the plugin: cap history/“keep revisions”, enable batched sync.
- Schedule CouchDB compaction on the VM (cron):
  ```bash
  curl -X POST http://obsidian:__PW__@127.0.0.1:5984/obsidian/_compact -H "Content-Type: application/json"
  ```

### Phase 9 — Backups
- Periodic `tar` of the `./data` volume, or a scheduled **GCP disk snapshot**. (E2E means backups
  are encrypted at rest too.)

---

## 7. Migrating later (your "is it easy?" question — yes)

When you get an always-on box at home (old PC, Pi, NAS):
1. Install Docker + Tailscale on it; join the same tailnet.
2. Copy the `./data` folder (the whole CouchDB state) over and start the same compose file.
3. Repoint devices — and if the new box reuses the **same Tailscale hostname**, you change *nothing*
   on the devices. The plugin connects by name, so the move is invisible to Obsidian.

The vault and all history travel in that one `./data` folder. No re-sync from scratch needed.

---

## 8. Zero-cloud alternative (if you'd rather not touch GCP)

Run CouchDB in Docker Desktop **on your Windows desktop** + Tailscale, skip the VM entirely.
Because your desktop is on whenever you're home (the only time both devices are used), the laptop
syncs every time you're back. Trade-offs: no off-site backup, and laptop edits made while travelling
aren't uploaded until you're home (you only edit on the laptop then anyway, so nothing is lost —
just not backed up to a second location until you return).

Recommendation: start with the **GCP VM** (off-site backup + sync-from-anywhere for free), and you
can always collapse to this later using the migration steps above.

---

## 9. Open questions

1. Is "Google Cloud" a **Compute Engine VM**, or Google Drive? (Plan assumes a VM.)
2. Vault size + image/PDF heaviness?
3. Laptop OS?

Answer those three and the next step is to scaffold the actual `docker-compose.yml`, `local.ini`,
and a setup script into this repo so it's copy-paste runnable.
