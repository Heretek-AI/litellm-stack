# Minio Exporter Sidecar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `quay.io/minio/minio-exporter` sidecar so the minio Prometheus scrape target comes UP. Stack goes from 6/7 → 7/7 targets. The existing `ServiceDown` alert on `job=minio` clears within ~2m of the target coming UP.

**Architecture:** Compose service `minio-exporter` on `litellm-net` that authenticates to minio with AWS4-HMAC-SHA256 (signing the `/minio/v2/metrics/cluster` request internally) and exposes the same metrics path as Prometheus text format on port 9000. Replace the broken direct-scrape (`basic_auth` against `minio:9000`) with `targets: ["minio-exporter:9000"]` + same `metrics_path`. Update the observability spec to drop the now-stale minio AWS4 entry from the Known Limitations section.

**Tech Stack:** Docker Compose v2, `quay.io/minio/minio-exporter:latest`, Prometheus, Alertmanager. Bash smoke tests via `wget` inside the prometheus + alertmanager containers.

**Spec:** `docs/superpowers/specs/2026-07-01-minio-exporter-sidecar-design.md`

---

## Global Constraints

- Working directory: `/home/john/Projects/litellm-stack/`
- All paths in this plan are **relative to the working directory** unless prefixed with `/`.
- Every task ends with a commit. Use `git add` for the specific files created/changed in that task.
- Commit message format: `type: short description` — `chore:`, `feat:`, `docs:`, `test:`, `fix:`.
- YAML files MUST validate via `python3.12 -c "import yaml; yaml.safe_load(open('PATH'))"` (host's `python3` is 3.14 which lacks pyyaml; `python3.12` is the validated interpreter — see prior task ledger).
- Docker Compose MUST validate via `docker compose config --quiet`.
- Use `docker compose up -d <service>` (not `restart`) when adding new bind mounts or new services — restart does not pick up new mounts.
- Loopback bind only on ports that need host exposure (none for this plan).

---

## File Structure

| Path | Purpose |
|---|---|
| `docker-compose.yml` (modified) | Add `minio-exporter` service block (inside `services:`) |
| `monitoring/prometheus/prometheus.yml` (modified) | Replace `minio` job with sidecar target |
| `docs/superpowers/specs/2026-07-01-observability-addon-design.md` (modified) | Remove stale minio AWS4 entry from Known Limitations |

---

## Task 1: Add minio-exporter service + replace prometheus scrape job

**Files:**
- Modify: `docker-compose.yml`
- Modify: `monitoring/prometheus/prometheus.yml`

**Depends on:** Existing compose services (minio running with `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` from `.env`); existing 7 scrape jobs in prometheus.yml.

- [ ] **Step 1: Read current `docker-compose.yml` to confirm service block layout**

Read the file. Find the spot just BEFORE the final `networks:` block to insert the new service.

- [ ] **Step 2: Append `minio-exporter` service to `docker-compose.yml`**

Insert this block just before the final `networks:` block:

```yaml

  minio-exporter:
    image: quay.io/minio/minio-exporter:latest
    container_name: litellm-minio-exporter
    environment:
      MINIO_ACCESS_KEY: ${MINIO_ROOT_USER}
      MINIO_SECRET_KEY: ${MINIO_ROOT_PASSWORD}
      MINIO_ENDPOINT: http://minio:9000
    healthcheck:
      test: ["CMD", "/bin/sh", "-c", "wget -qO- http://localhost:9000/minio/v2/metrics/cluster | grep -q minio"]
      interval: 30s
      timeout: 5s
      retries: 5
    networks:
      - litellm-net
    restart: unless-stopped
```

- [ ] **Step 3: Validate compose**

```bash
docker compose config --quiet && echo "compose OK"
```

Expected: `compose OK`. Confirm the new service parses by counting services:
```bash
docker compose config --services | wc -l
```

Expected: `12` (was 11).

- [ ] **Step 4: Read current `monitoring/prometheus/prometheus.yml` and find the `minio` job block**

The current `minio` job looks like:
```yaml
  - job_name: minio
    metrics_path: /minio/v2/metrics/cluster
    basic_auth:
      username_file: /run/secrets/minio_metrics_user
      password_file: /run/secrets/minio_metrics_pass
    static_configs:
      - targets: ["minio:9000"]
```

- [ ] **Step 5: Replace the `minio` job block with the sidecar target**

Replace it with:
```yaml
  - job_name: minio
    metrics_path: /minio/v2/metrics/cluster
    static_configs:
      - targets: ["minio-exporter:9000"]
```

- [ ] **Step 6: Validate the prometheus YAML**

```bash
python3.12 -c "import yaml; yaml.safe_load(open('monitoring/prometheus/prometheus.yml')); print('OK')"
```

Expected: `OK`.

- [ ] **Step 7: Bring up the new service + restart prometheus (use `up -d`, not `restart`)**

```bash
docker compose up -d minio-exporter
docker compose up -d prometheus
```

`up -d` (not `restart`) so prometheus picks up the new scrape target even though its config didn't change.

- [ ] **Step 8: Wait ~30s for minio-exporter to come up + for prometheus to start scraping it**

```bash
sleep 30
docker compose ps minio-exporter
```

Expected: `litellm-minio-exporter Up 30 seconds (healthy)`. If healthcheck is failing, capture logs:
```bash
docker compose logs minio-exporter --tail 50
```
And report BLOCKED with the log excerpt.

- [ ] **Step 9: Verify minio target now scrapes via the sidecar**

```bash
docker compose exec litellm-prometheus wget -qO- http://localhost:9090/api/v1/targets \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(t['labels']['job'], '=', t['health'], 'lastError=' + t.get('lastError','')[:60]) for t in d['data']['activeTargets']]"
```

Expected: a line `minio = up` (was `minio = down` before). All 7 targets should print `= up`.

- [ ] **Step 10: Verify the scrape body actually contains minio metrics**

```bash
docker compose exec litellm-prometheus wget -qO- http://minio-exporter:9000/minio/v2/metrics/cluster | head -10
```

Expected: prometheus text format starting with `# HELP` and `# TYPE` lines for `minio_*` metrics (e.g., `minio_node_disk_used_bytes`, `minio_node_disk_free_bytes`).

- [ ] **Step 11: Commit both file changes**

```bash
git add docker-compose.yml monitoring/prometheus/prometheus.yml
git commit -m "feat: add minio-exporter sidecar to close 6/7 -> 7/7 scrape gap

Adds quay.io/minio/minio-exporter as a sidecar that signs AWS4-HMAC-SHA256
on behalf of Prometheus. The minio /minio/v2/metrics/cluster endpoint
requires AWS4 signing that basic_auth cannot provide; the sidecar handles
signing internally and exposes the same metrics as plain Prometheus text.

Replaces the broken direct-scrape job (basic_auth against minio:9000) with
a target of minio-exporter:9000."
```

Expected: 2 files changed.

---

## Task 2: Remove stale minio entry from observability spec

**Files:**
- Modify: `docs/superpowers/specs/2026-07-01-observability-addon-design.md`

**Depends on:** Task 1 (so the removal is accurate — the limitation no longer applies).

- [ ] **Step 1: Find the minio AWS4 entry in the observability spec**

```bash
grep -n -i 'minio' docs/superpowers/specs/2026-07-01-observability-addon-design.md
```

Expected: at least one mention in the "Known Limitations" section. Identify the line range to remove.

- [ ] **Step 2: Remove the minio entry from Known Limitations**

Open the file. Locate the bullet point about minio (something like "minio /minio/v2/metrics/cluster requires AWS4-HMAC-SHA256…"). Delete that single bullet, leaving the other entries (Redis cache hit upstream limitation, /health 404 vs Milvus port, etc.) intact.

If the entry is the ONLY bullet in a numbered list, renumber the remaining bullets.

- [ ] **Step 3: Add a one-line cross-reference in its place**

After the deletion, add a brief replacement note pointing at the new minio-exporter sidecar (so a future reader knows the resolution lives elsewhere):

```markdown
- **minio /minio/v2/metrics/cluster requires AWS4-HMAC-SHA256** — RESOLVED by the `minio-exporter` sidecar added in `2026-07-01-minio-exporter-sidecar-design.md`. The sidecar signs requests internally and exposes plain Prometheus text on `:9000`.
```

(Place this at the bottom of the Known Limitations list or replace the deleted bullet.)

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-07-01-observability-addon-design.md
git commit -m "docs: mark minio AWS4 limitation resolved by minio-exporter sidecar"
```

Expected: 1 file changed.

---

## Task 3: Verify ServiceDown alert clears + final smoke

**Depends on:** Tasks 1–2 complete. The alert `for: 2m` window means ServiceDown may still be firing for a few minutes after the target came UP — that's expected, not a defect.

- [ ] **Step 1: Confirm 7/7 targets UP (re-run for posterity)**

```bash
docker compose exec litellm-prometheus wget -qO- http://localhost:9090/api/v1/targets \
  | python3 -c "import sys,json; d=json.load(sys.stdin); up=sum(1 for t in d['data']['activeTargets'] if t['health']=='up'); total=len(d['data']['activeTargets']); print(f'{up}/{total} targets UP')"
```

Expected: `7/7 targets UP`.

- [ ] **Step 2: Wait ~150s for the ServiceDown alert to clear**

The ServiceDown rule has `for: 2m` — once `up{job="minio"}` is consistently 1 for 2 minutes, the alert transitions to `resolved`.

```bash
echo "waiting 150s for ServiceDown alert on job=minio to clear..."
sleep 150
```

- [ ] **Step 3: Verify alertmanager reports 0 active alerts**

```bash
docker compose exec alertmanager wget -qO- http://localhost:9093/api/v2/alerts \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'active alerts: {len(d)}'); [print(f\"  {a['labels'].get('alertname')} job={a['labels'].get('job')} state={a.get('status',{}).get('state','?')}\") for a in d]"
```

Expected: `active alerts: 0`. If any alerts remain, inspect with `docker compose logs alertmanager --tail 50 | grep -iE 'ServiceDown|firing|resolved'`.

- [ ] **Step 4: Verify ServiceDown would re-fire on a new outage (defensive check, optional)**

```bash
docker compose stop minio
sleep 130
docker compose exec alertmanager wget -qO- http://localhost:9093/api/v2/alerts \
  | python3 -c "import sys,json; d=json.load(sys.stdin); fired=[a for a in d if a.get('status',{}).get('state')=='active']; print(f'active alerts (after minio stop): {len(fired)}'); [print(f\"  {a['labels'].get('alertname')} job={a['labels'].get('job')}\") for a in fired]"
docker compose start minio
```

Expected: at least 1 active `ServiceDown job=minio` alert after the 130s wait. This proves the alert pipeline still works for the now-UP target.

- [ ] **Step 5: Commit (only if any uncommitted changes; this task is verification-only)**

```bash
git status --short
```

If empty (most likely — this task only verified state), no commit needed. If something changed during the optional step 4 (e.g. a config tweak), commit that.

- [ ] **Step 6: Append a one-line summary to the progress ledger**

```bash
cat >> .superpowers/sdd/progress.md <<EOF

### Minio exporter sidecar (3-task plan)

- minio scrape target: 6/7 -> 7/7 UP after quay.io/minio/minio-exporter sidecar.
- ServiceDown alert on job=minio clears within ~2m of target coming UP.
- 3 commits: feat (compose + prometheus), docs (spec cleanup), no further.
EOF
```

- [ ] **Step 7: Push to GitHub**

```bash
git push origin master
```

Expected: `master -> master` (or similar). 3 commits ahead of origin.

---

## Self-Review (post-write)

1. **Spec coverage:**
   - §3 Compose addition — Task 1 Step 2.
   - §4 Prometheus scrape config — Task 1 Steps 4-5.
   - §5 Failure handling — Task 3 Step 4 (re-fire defensive check).
   - §6 Smoke test — Task 1 Steps 8-10 + Task 3 Step 1.
   - §7 Known limitations removed — Task 2.
   - §8 Out of scope — excluded.
2. **Placeholders:** none. Every command, env var, service name, target, and path is explicit.
3. **Type / key consistency:** `minio-exporter` service name + container name + prometheus scrape target all consistent. `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` / `MINIO_ENDPOINT` env vars are the official minio-exporter contract (matches upstream image docs). `metrics_path: /minio/v2/metrics/cluster` consistent in spec §4, Task 1 Step 5, and Task 3 Step 4.
4. **Task right-sizing:** Task 1 is the substantive code change (compose + prometheus + bring-up). Task 2 is a 3-line doc fix. Task 3 is verification. Each ends in commit or status check.