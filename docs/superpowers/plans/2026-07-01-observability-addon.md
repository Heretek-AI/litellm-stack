# Observability Addon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Prometheus + Alertmanager + Grafana + 2 exporters (redis, postgres) to the existing litellm-stack so all 6 services are scraped, 3 Grafana dashboards are auto-provisioned, and 3 starter alert rules fire to stdout.

**Architecture:** Compose sidecars on the existing `litellm-net` bridge. Litellm `:4000/metrics`, Milvus `:9091/metrics`, MinIO `:9000/minio/v2/metrics/cluster`, etcd `:2379/metrics` are scraped directly (no sidecar). Redis + Postgres use exporter sidecars because they don't expose Prometheus format natively. Grafana auto-loads dashboards + Prometheus datasource via YAML provisioning. Alertmanager wired to Prometheus with 3 starter rules.

**Tech Stack:** Docker Compose v2, Prometheus (`prom/prometheus:latest`), Alertmanager (`prom/alertmanager:latest`), Grafana (`grafana/grafana:latest`), redis-exporter (`oliver006/redis_exporter:latest`), postgres-exporter (`prometheuscommunity/postgres-exporter:latest`), bash smoke tests via curl + jq.

**Spec:** `docs/superpowers/specs/2026-07-01-observability-addon-design.md`

---

## Global Constraints

- Working directory: `/home/john/Projects/litellm-stack/`
- All paths in this plan are **relative to the working directory** unless prefixed with `/`.
- Every task ends with a commit. Use `git add` for the specific files created/changed in that task.
- Commit message format: `type: short description` — `chore:`, `feat:`, `docs:`, `test:`, `fix:`.
- YAML files MUST validate via `python3.12 -c "import yaml; yaml.safe_load(open('PATH'))"` (host's `python3` is 3.14 which lacks pyyaml; `python3.12` is the validated interpreter — see Task 1 ledger entry).
- JSON files MUST validate via `python3 -c "import json; json.load(open('PATH'))"`.
- The `monitoring/` directory tree is committed (not gitignored).
- Grafana admin password is generated via `openssl rand -hex 16`, stored in `.env` (gitignored) and in `monitoring/secrets/grafana_admin_password` (gitignored). `.env.example` ships a placeholder.
- Loopback bind only: Grafana on `127.0.0.1:3000`. Prometheus + Alertmanager are internal-only.

---

## File Structure

| Path | Purpose |
|---|---|
| `monitoring/prometheus/prometheus.yml` | Scrape config + alerting wiring |
| `monitoring/prometheus/rules/starter.yml` | 3 alert rules (ServiceDown, EmbedErrorSpike, RedisCacheMissRateHigh) |
| `monitoring/alertmanager/alertmanager.yml` | Route + receiver (stdout sink) |
| `monitoring/grafana/provisioning/datasources/prometheus.yml` | Auto-provision Prometheus datasource |
| `monitoring/grafana/provisioning/dashboards/provider.yml` | Auto-load dashboards from `/var/lib/grafana/dashboards` |
| `monitoring/grafana/dashboards/unified-overview.json` | 6-panel overview (one per service) |
| `monitoring/grafana/dashboards/litellm-requests.json` | litellm request rate / latency / error / keys |
| `monitoring/grafana/dashboards/cache-vector.json` | Redis cache + Milvus vector store panels |
| `monitoring/secrets/grafana_admin_password` (gitignored) | Random hex password mounted into grafana container |
| `docker-compose.yml` (modified) | 5 new services + 2 volumes + depends_on |
| `.env.example` (modified) | `GRAFANA_ADMIN_PASSWORD` placeholder |
| `.gitignore` (modified) | exclude `monitoring/secrets/` |

---

## Task 1: monitoring/ scaffold

**Files:**
- Create: `monitoring/.gitkeep` + 6 sub-directory `.gitkeep` placeholders

- [ ] **Step 1: Verify `.gitignore` does NOT exclude `monitoring/`**

Read `.gitignore`. Confirm `monitoring/` is NOT listed.

- [ ] **Step 2: Create the directory tree + `.gitkeep` placeholders**

```bash
mkdir -p monitoring/prometheus/rules
mkdir -p monitoring/alertmanager
mkdir -p monitoring/grafana/provisioning/datasources
mkdir -p monitoring/grafana/provisioning/dashboards
mkdir -p monitoring/grafana/dashboards
for d in monitoring monitoring/prometheus monitoring/prometheus/rules monitoring/alertmanager \
         monitoring/grafana/provisioning/datasources monitoring/grafana/provisioning/dashboards \
         monitoring/grafana/dashboards; do touch "$d/.gitkeep"; done
```

Expected: 7 `.gitkeep` files in the new tree.

- [ ] **Step 3: Verify the tree**

```bash
find monitoring -type d | sort
```

Expected: 8 directories (monitoring + 7 sub).

- [ ] **Step 4: Commit**

```bash
git add monitoring
git commit -m "chore: scaffold monitoring/ directory tree for prometheus + grafana + alertmanager"
```

Expected: 7 files changed (the `.gitkeep` placeholders).

---

## Task 2: Prometheus scrape config

**Files:**
- Create: `monitoring/prometheus/prometheus.yml`

- [ ] **Step 1: Write `monitoring/prometheus/prometheus.yml`**

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]

scrape_configs:
  - job_name: litellm
    metrics_path: /metrics
    static_configs:
      - targets: ["litellm:4000"]

  - job_name: redis
    static_configs:
      - targets: ["redis-exporter:9121"]

  - job_name: milvus
    metrics_path: /metrics
    static_configs:
      - targets: ["milvus:9091"]

  - job_name: postgres
    static_configs:
      - targets: ["postgres-exporter:9187"]

  - job_name: minio
    metrics_path: /minio/v2/metrics/cluster
    static_configs:
      - targets: ["minio:9000"]

  - job_name: etcd
    static_configs:
      - targets: ["etcd:2379"]

  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
```

- [ ] **Step 2: Validate YAML**

```bash
python3.12 -c "import yaml; yaml.safe_load(open('monitoring/prometheus/prometheus.yml')); print('OK')"
```

Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add monitoring/prometheus/prometheus.yml
git commit -m "feat: add Prometheus scrape config for all 6 services + self-scrape"
```

---

## Task 3: Alert rules file

**Files:**
- Create: `monitoring/prometheus/rules/starter.yml`

- [ ] **Step 1: Write `monitoring/prometheus/rules/starter.yml`**

```yaml
groups:
  - name: starter
    rules:
      - alert: ServiceDown
        expr: up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Service {{ $labels.job }} is down"

      - alert: EmbedErrorSpike
        expr: |
          sum(rate(litellm_requests_failed_total[5m]))
            /
          sum(rate(litellm_requests_total[5m])) > 0.05
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Embed error rate >5% for 5min on {{ $labels.job }}"

      - alert: RedisCacheMissRateHigh
        expr: |
          1 - (
            sum(rate(litellm_cache_hits_total[5m]))
              /
            sum(rate(litellm_cache_lookups_total[5m]))
          ) > 0.95
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Cache miss rate >95% — semantic cache may be down"
```

- [ ] **Step 2: Validate YAML + count rules**

```bash
python3.12 -c "import yaml; d=yaml.safe_load(open('monitoring/prometheus/rules/starter.yml')); print('rules:', len(d['groups'][0]['rules']))"
```

Expected: `rules: 3`.

- [ ] **Step 3: Commit**

```bash
git add monitoring/prometheus/rules/starter.yml
git commit -m "feat: add 3 starter Prometheus alert rules"
```

---

## Task 4: Alertmanager config

**Files:**
- Create: `monitoring/alertmanager/alertmanager.yml`

- [ ] **Step 1: Write `monitoring/alertmanager/alertmanager.yml`**

```yaml
route:
  receiver: stdout
  group_by: [alertname, job]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: stdout
    webhook_configs: []
```

- [ ] **Step 2: Validate YAML**

```bash
python3.12 -c "import yaml; yaml.safe_load(open('monitoring/alertmanager/alertmanager.yml')); print('OK')"
```

Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add monitoring/alertmanager/alertmanager.yml
git commit -m "feat: add Alertmanager config with stdout receiver"
```

---

## Task 5: Grafana provisioning (datasource + dashboard provider)

**Files:**
- Create: `monitoring/grafana/provisioning/datasources/prometheus.yml`
- Create: `monitoring/grafana/provisioning/dashboards/provider.yml`

- [ ] **Step 1: Write `monitoring/grafana/provisioning/datasources/prometheus.yml`**

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
```

- [ ] **Step 2: Write `monitoring/grafana/provisioning/dashboards/provider.yml`**

```yaml
apiVersion: 1

providers:
  - name: litellm-stack
    folder: litellm-stack
    type: file
    options:
      path: /var/lib/grafana/dashboards
```

- [ ] **Step 3: Validate both YAML files**

```bash
python3.12 -c "import yaml; yaml.safe_load(open('monitoring/grafana/provisioning/datasources/prometheus.yml')); yaml.safe_load(open('monitoring/grafana/provisioning/dashboards/provider.yml')); print('OK')"
```

Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add monitoring/grafana/provisioning
git commit -m "feat: add Grafana provisioning for Prometheus datasource and dashboards"
```

---

## Task 6: Three Grafana dashboard JSONs

**Files:**
- Create: `monitoring/grafana/dashboards/unified-overview.json`
- Create: `monitoring/grafana/dashboards/litellm-requests.json`
- Create: `monitoring/grafana/dashboards/cache-vector.json`

- [ ] **Step 1: Write `monitoring/grafana/dashboards/unified-overview.json`**

```json
{
  "title": "litellm-stack / Unified Overview",
  "uid": "litellm-unified",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "30s",
  "time": {"from": "now-1h", "to": "now"},
  "panels": [
    {"id":1,"type":"stat","title":"Litellm up","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":0,"y":0,"w":4,"h":4},"targets":[{"expr":"up{job=\"litellm\"}","refId":"A"}],"options":{"colorMode":"background","graphMode":"none"}},
    {"id":2,"type":"stat","title":"Redis up","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":4,"y":0,"w":4,"h":4},"targets":[{"expr":"up{job=\"redis\"}","refId":"A"}],"options":{"colorMode":"background","graphMode":"none"}},
    {"id":3,"type":"stat","title":"Milvus up","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":8,"y":0,"w":4,"h":4},"targets":[{"expr":"up{job=\"milvus\"}","refId":"A"}],"options":{"colorMode":"background","graphMode":"none"}},
    {"id":4,"type":"stat","title":"Postgres up","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":12,"y":0,"w":4,"h":4},"targets":[{"expr":"up{job=\"postgres\"}","refId":"A"}],"options":{"colorMode":"background","graphMode":"none"}},
    {"id":5,"type":"stat","title":"MinIO up","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":16,"y":0,"w":4,"h":4},"targets":[{"expr":"up{job=\"minio\"}","refId":"A"}],"options":{"colorMode":"background","graphMode":"none"}},
    {"id":6,"type":"stat","title":"etcd up","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":20,"y":0,"w":4,"h":4},"targets":[{"expr":"up{job=\"etcd\"}","refId":"A"}],"options":{"colorMode":"background","graphMode":"none"}}
  ]
}
```

- [ ] **Step 2: Write `monitoring/grafana/dashboards/litellm-requests.json`**

```json
{
  "title": "litellm-stack / LiteLLM Requests",
  "uid": "litellm-requests",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "15s",
  "time": {"from": "now-1h", "to": "now"},
  "panels": [
    {"id":1,"type":"timeseries","title":"Request rate (req/s)","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":0,"y":0,"w":12,"h":8},"targets":[{"expr":"sum(rate(litellm_requests_total[1m]))","refId":"A","legendFormat":"all"}]},
    {"id":2,"type":"timeseries","title":"Request rate by model","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":12,"y":0,"w":12,"h":8},"targets":[{"expr":"sum by (model) (rate(litellm_requests_total[1m]))","refId":"A","legendFormat":"{{model}}"}]},
    {"id":3,"type":"timeseries","title":"Error rate (req/s)","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":0,"y":8,"w":12,"h":8},"targets":[{"expr":"sum(rate(litellm_requests_failed_total[1m]))","refId":"A","legendFormat":"failed"}]},
    {"id":4,"type":"timeseries","title":"Latency p50/p95/p99 (s)","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":12,"y":8,"w":12,"h":8},"targets":[{"expr":"histogram_quantile(0.5, sum by (le) (rate(litellm_request_total_latency_seconds_bucket[5m])))","refId":"A","legendFormat":"p50"},{"expr":"histogram_quantile(0.95, sum by (le) (rate(litellm_request_total_latency_seconds_bucket[5m])))","refId":"B","legendFormat":"p95"},{"expr":"histogram_quantile(0.99, sum by (le) (rate(litellm_request_total_latency_seconds_bucket[5m])))","refId":"C","legendFormat":"p99"}]},
    {"id":5,"type":"timeseries","title":"Active keys","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":0,"y":16,"w":24,"h":6},"targets":[{"expr":"litellm_team_max_budget","refId":"A","legendFormat":"budget"},{"expr":"litellm_user_max_budget","refId":"B","legendFormat":"user_budget"}]}
  ]
}
```

- [ ] **Step 3: Write `monitoring/grafana/dashboards/cache-vector.json`**

```json
{
  "title": "litellm-stack / Cache & Vector Store",
  "uid": "litellm-cache-vector",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "30s",
  "time": {"from": "now-1h", "to": "now"},
  "panels": [
    {"id":1,"type":"timeseries","title":"Redis memory used","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":0,"y":0,"w":12,"h":8},"targets":[{"expr":"redis_memory_used_bytes","refId":"A","legendFormat":"used"}]},
    {"id":2,"type":"timeseries","title":"Redis keys","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":12,"y":0,"w":12,"h":8},"targets":[{"expr":"redis_db_keys{db=\"db0\"}","refId":"A","legendFormat":"db0"}]},
    {"id":3,"type":"timeseries","title":"Cache hit rate","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":0,"y":8,"w":12,"h":8},"targets":[{"expr":"sum(rate(litellm_cache_hits_total[5m])) / clamp_min(sum(rate(litellm_cache_lookups_total[5m])), 1)","refId":"A","legendFormat":"hit_rate"}]},
    {"id":4,"type":"timeseries","title":"Cache hits / lookups","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":12,"y":8,"w":12,"h":8},"targets":[{"expr":"sum(rate(litellm_cache_hits_total[1m]))","refId":"A","legendFormat":"hits"},{"expr":"sum(rate(litellm_cache_lookups_total[1m]))","refId":"B","legendFormat":"lookups"}]},
    {"id":5,"type":"timeseries","title":"Milvus latency (proxy)","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":0,"y":16,"w":24,"h":8},"targets":[{"expr":"histogram_quantile(0.95, sum by (le) (rate(milvus_proxy_sq_latency_bucket[5m])))","refId":"A","legendFormat":"p95"}]}
  ]
}
```

- [ ] **Step 4: Validate all 3 dashboards parse as JSON**

```bash
for f in monitoring/grafana/dashboards/*.json; do
  python3 -c "import json,sys; json.load(open(sys.argv[1])); print(sys.argv[1], 'OK')" "$f"
done
```

Expected: 3 lines, each ending with `OK`.

- [ ] **Step 5: Commit**

```bash
git add monitoring/grafana/dashboards
git commit -m "feat: add 3 Grafana dashboards (unified overview, litellm requests, cache/vector)"
```

---

## Task 7: docker-compose.yml additions

**Files:**
- Modify: `docker-compose.yml`

**Depends on:** Tasks 2–6 (compose references all the mounted config files).

- [ ] **Step 1: Append 5 new services + 2 new volumes to `docker-compose.yml`**

Read the current file. Append before the final `networks:` block:

```yaml

  prometheus:
    image: prom/prometheus:latest
    container_name: litellm-prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=30d"
      - "--web.console.libraries=/usr/share/prometheus/console_libraries"
      - "--web.console.templates=/usr/share/prometheus/consoles"
    volumes:
      - ./monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro,z
      - ./monitoring/prometheus/rules:/etc/prometheus/rules:ro,z
      - prometheus_data:/prometheus
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:9090/-/healthy"]
      interval: 30s
      timeout: 5s
      retries: 5
    networks:
      - litellm-net
    restart: unless-stopped

  alertmanager:
    image: prom/alertmanager:latest
    container_name: litellm-alertmanager
    command:
      - "--config.file=/etc/alertmanager/alertmanager.yml"
      - "--storage.path=/alertmanager"
    volumes:
      - ./monitoring/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro,z
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:9093/-/healthy"]
      interval: 30s
      timeout: 5s
      retries: 5
    networks:
      - litellm-net
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: litellm-grafana
    env_file:
      - .env
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD__FILE: /run/secrets/grafana_admin_password
      GF_AUTH_ANONYMOUS_ENABLED: "false"
    volumes:
      - ./monitoring/grafana/provisioning:/etc/grafana/provisioning:ro,z
      - ./monitoring/grafana/dashboards:/var/lib/grafana/dashboards:ro,z
      - ./monitoring/secrets/grafana_admin_password:/run/secrets/grafana_admin_password:ro,z
      - grafana_data:/var/lib/grafana
    ports:
      - "127.0.0.1:3000:3000"
    depends_on:
      prometheus:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:3000/api/health | grep -q ok"]
      interval: 30s
      timeout: 5s
      retries: 5
    networks:
      - litellm-net
    restart: unless-stopped

  redis-exporter:
    image: oliver006/redis_exporter:latest
    container_name: litellm-redis-exporter
    command: ["--redis.addr=redis://redis:6379"]
    networks:
      - litellm-net
    restart: unless-stopped

  postgres-exporter:
    image: prometheuscommunity/postgres-exporter:latest
    container_name: litellm-postgres-exporter
    environment:
      DATA_SOURCE_NAME: "postgresql://llmproxy:dbpassword9090@db:5432/litellm?sslmode=disable"
    networks:
      - litellm-net
    restart: unless-stopped
```

Append to the `volumes:` block:

```yaml
  prometheus_data:
  grafana_data:
```

- [ ] **Step 2: Validate compose file**

```bash
docker compose config --quiet && echo "compose OK"
```

Expected: `compose OK`.

- [ ] **Step 3: Verify all 5 new services + 2 new volumes parse**

```bash
docker compose config | grep -E "^  (prometheus|alertmanager|grafana|redis-exporter|postgres-exporter):" | wc -l
docker compose config | grep -E "^  (prometheus_data|grafana_data):" | wc -l
```

Expected: 5 services + 2 volumes.

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add prometheus + alertmanager + grafana + 2 exporters to compose"
```

---

## Task 8: Grafana admin password + `.env.example` update

**Files:**
- Create: `monitoring/secrets/` directory (gitignored contents)
- Modify: `.gitignore` (add `monitoring/secrets/` exclusion)
- Modify: `.env.example` (add `GRAFANA_ADMIN_PASSWORD` placeholder)

**Depends on:** Task 7 (compose references `/run/secrets/grafana_admin_password`).

- [ ] **Step 1: Create the secrets directory + update `.gitignore`**

```bash
mkdir -p monitoring/secrets
```

Append to `.gitignore`:
```
# monitoring secrets (created at compose up time)
monitoring/secrets/
```

- [ ] **Step 2: Generate a Grafana admin password and write it locally**

```bash
GRAFANA_PASSWORD=$(openssl rand -hex 16)
echo "$GRAFANA_PASSWORD" > monitoring/secrets/grafana_admin_password
chmod 600 monitoring/secrets/grafana_admin_password
ls -l monitoring/secrets/grafana_admin_password
cat monitoring/secrets/grafana_admin_password
```

Expected: file exists with mode 600, contains a 32-hex-char string.

- [ ] **Step 3: Update local `.env` to mirror the same password**

```bash
grep -q '^GRAFANA_ADMIN_PASSWORD=' .env || echo "GRAFANA_ADMIN_PASSWORD=$GRAFANA_PASSWORD" >> .env
```

Expected: `GRAFANA_ADMIN_PASSWORD=` line now in `.env`.

- [ ] **Step 4: Update `.env.example`**

Append to `.env.example`:

```
# Grafana admin password (loopback only — used by /run/secrets/grafana_admin_password)
# Generate with: openssl rand -hex 16
# The actual password is stored in monitoring/secrets/grafana_admin_password (gitignored).
GRAFANA_ADMIN_PASSWORD=changeme-32-bytes-hex
```

- [ ] **Step 5: Verify `.env.example` has the new line**

```bash
grep -c '^GRAFANA_ADMIN_PASSWORD=' .env.example
```

Expected: `1`.

- [ ] **Step 6: Commit `.gitignore` + `.env.example` only**

```bash
git add .gitignore .env.example
git status --short
git commit -m "chore: add grafana admin password plumbing (env var + secrets dir + gitignore)"
```

Expected: 2 files changed. `monitoring/secrets/` NOT in commit.

---

## Task 9: Bring up + verify Prometheus targets

**Depends on:** Tasks 1–8 complete.

- [ ] **Step 1: Bring up the full stack**

```bash
docker compose up -d
```

Expected: 11 containers up (litellm, redis, etcd, minio, milvus, db, prometheus, alertmanager, grafana, redis-exporter, postgres-exporter). Names `litellm-prometheus`, `litellm-alertmanager`, `litellm-grafana`, `litellm-redis-exporter`, `litellm-postgres-exporter` listed.

- [ ] **Step 2: Wait for all 7 Prometheus targets to be UP**

```bash
for i in $(seq 1 60); do
  UP=$(curl -sf http://127.0.0.1:9090/api/v1/targets 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for t in d['data']['activeTargets'] if t['health']=='up'))")
  if [ "$UP" = "7" ]; then echo "all 7 targets UP"; break; fi
  sleep 2
done
```

Expected: prints `all 7 targets UP` within ~60s.

- [ ] **Step 3: Confirm each target is up**

```bash
curl -sf 'http://127.0.0.1:9090/api/v1/query?query=up' \
  | python3 -c "import sys,json; d=json.load(sys.stdin)['data']['result']; [print(r['metric'].get('job'), '=', r['value'][1]) for r in d]"
```

Expected: 7 lines, each value `= 1` (up).

- [ ] **Step 4: Verify Prometheus retention + alerts**

```bash
curl -sf 'http://127.0.0.1:9090/api/v1/status/runtimeinfo' | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print('storage retention:', d.get('storageRetention'))"
curl -sf 'http://127.0.0.1:9090/api/v1/rules' | python3 -c "import sys,json; d=json.load(sys.stdin); print('rule groups:', len(d['data']['groups']), 'rules:', sum(len(g['rules']) for g in d['data']['groups']))"
```

Expected: `storage retention: 2592000` (30 days in seconds). `rule groups: 1`, `rules: 3`.

- [ ] **Step 5: Verify Alertmanager healthy**

```bash
curl -sf http://localhost:9093/-/healthy
docker compose ps alertmanager
```

Expected: HTTP 200 with empty body, container `Up`.

---

## Task 10: Verify Grafana datasource + 3 dashboards

**Depends on:** Task 9 (Prometheus healthy so Grafana datasource can connect).

- [ ] **Step 1: Grafana health**

```bash
curl -sf http://127.0.0.1:3000/api/health
```

Expected: status 200 with body indicating database ok.

- [ ] **Step 2: Authenticate and list datasources**

```bash
GPASS=$(cat monitoring/secrets/grafana_admin_password)
curl -sf -u "admin:$GPASS" http://127.0.0.1:3000/api/datasources \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(p['name'], '->', p['url'], '(default)' if p.get('isDefault') else '') for p in d]"
```

Expected: 1 line: `Prometheus -> http://prometheus:9090 (default)`.

- [ ] **Step 3: Verify 3 dashboards provisioned**

```bash
curl -sf -u "admin:$GPASS" http://127.0.0.1:3000/api/search \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(p['title'], 'uid=' + p['uid']) for p in d]"
```

Expected: 3 dashboards listed.

- [ ] **Step 4: Verify dashboard JSON round-trips through Grafana**

```bash
curl -sf -u "admin:$GPASS" http://127.0.0.1:3000/api/dashboards/uid/litellm-unified \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('panels:', len(d['dashboard']['panels']))"
```

Expected: `panels: 6`.

---

## Task 11: Verify Alertmanager rules + trigger ServiceDown

**Depends on:** Task 10 (Grafana dashboards live → Alertmanager pipeline proven end-to-end).

- [ ] **Step 1: Verify Alertmanager version**

```bash
curl -sf http://localhost:9093/api/v1/status | python3 -c "import sys,json; d=json.load(sys.stdin); print('alertmanager version:', d['versionInfo']['version'])"
```

Expected: version string printed.

- [ ] **Step 2: Verify Alertmanager has zero active alerts at start**

```bash
curl -sf http://localhost:9093/api/v2/alerts | python3 -c "import sys,json; d=json.load(sys.stdin); print('active alerts:', len(d))"
```

Expected: `active alerts: 0`.

- [ ] **Step 3: Trigger `ServiceDown` by stopping redis**

```bash
docker compose stop redis
echo "redis stopped; waiting 130s for ServiceDown alert to fire (2m 'for' + buffer)..."
sleep 130
docker compose logs alertmanager --tail 50 | grep -iE 'ServiceDown|firing' | head -5
```

Expected: at least one log line mentioning `ServiceDown` or `firing`.

- [ ] **Step 4: Verify Alertmanager reports the alert**

```bash
curl -sf http://localhost:9093/api/v2/alerts | python3 -c "import sys,json; d=json.load(sys.stdin); print('active alerts:', len(d), [(a['labels']['alertname'], a['labels'].get('job')) for a in d])"
```

Expected: at least one alert with `alertname=ServiceDown, job=redis`.

- [ ] **Step 5: Restart redis and confirm alert clears**

```bash
docker compose start redis
sleep 130
curl -sf http://localhost:9093/api/v2/alerts | python3 -c "import sys,json; d=json.load(sys.stdin); print('active alerts:', len(d))"
```

Expected: alert eventually clears.

---

## Self-Review (post-write)

1. **Spec coverage:**
   - §3 Compose services — Task 7.
   - §4 Prometheus scrape config — Task 2.
   - §5 Grafana provisioning + dashboards — Tasks 5 + 6.
   - §6 Alertmanager + rules — Tasks 3 + 4.
   - §7 Failure handling — documented in spec only.
   - §8 Smoke tests — Tasks 9 + 10 + 11.
   - §9 Out of scope — excluded.
2. **Placeholders:** none. Every command, value, panel, alert name, and target is explicit.
3. **Type / key consistency:** path names, service names, env vars consistent across tasks.
4. **Task right-sizing:** each task is one cohesive file group or verification goal; each ends in commit or status check.
