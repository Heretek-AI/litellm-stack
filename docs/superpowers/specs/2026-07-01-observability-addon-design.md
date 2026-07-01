# Observability Addon — Design

**Date:** 2026-07-01
**Status:** Approved — ready for implementation plan
**Scope:** Add Prometheus + Grafana + Alertmanager to the existing litellm-stack, scraping all 6 services. Three auto-provisioned Grafana dashboards. Three starter alert rules.

---

## 1. Goal & Non-Goals

**Goal.** A local Docker Compose addon that gives the litellm-stack full observability:
- Prometheus scrapes all 6 services and stores 30 days of metrics.
- Grafana serves 3 auto-provisioned dashboards (unified overview, litellm deep-dive, cache + vector store).
- Alertmanager fires 3 starter alerts (service down, embed error spike, cache miss rate high) to stdout.

**Non-goals.**
- Long-term metric storage (Prometheus TSDB only, no Thanos/Mimir).
- Auth integration with litellm's Postgres (Grafana is independent).
- Notification sink beyond stdout (no SMTP, no PagerDuty, no Slack webhook).
- Custom metric exporters beyond the 2 standard ones (no lemonade exporter — lemonade has no Prometheus endpoint).
- Auto-remediation of alerts.

---

## 2. Decisions (resolved in brainstorming)

| # | Decision              | Value                                                                 |
|---|------------------------|-----------------------------------------------------------------------|
| 1 | Metric sources         | All 6 services (litellm, redis, milvus, postgres, minio, etcd)         |
| 2 | Dashboards             | 3: Unified overview + litellm deep-dive + cache/vector store           |
| 3 | Retention              | 30 days                                                                |
| 4 | Grafana auth           | Random password via `${GRAFANA_ADMIN_PASSWORD}` in .env (gitignored)   |
| 5 | Grafana port           | `127.0.0.1:3030` (loopback only)                                       |
| 6 | Alerting               | Alertmanager + 3 starter rules, stdout sink only                       |
| 7 | Network                | Single shared `litellm-net` (no separate `monitoring-net`)            |
| 8 | Approach               | A — Compose sidecars on `litellm-net`                                  |

---

## 3. Compose Services (new)

5 new services + 2 exporters added to existing `docker-compose.yml`, all on `litellm-net`.

| Service              | Image                                                  | Purpose                                  | Host port          |
|----------------------|--------------------------------------------------------|------------------------------------------|--------------------|
| prometheus           | `prom/prometheus:latest`                                | Metrics scrape + storage (30d retention)  | (internal)         |
| alertmanager         | `prom/alertmanager:latest`                              | Alert routing (stdout sink)              | (internal)         |
| grafana              | `grafana/grafana:latest`                                | Dashboards (3 auto-provisioned)          | `127.0.0.1:3030`   |
| redis-exporter       | `oliver006/redis_exporter:latest`                       | Redis metrics sidecar                    | (internal)         |
| postgres-exporter    | `prometheuscommunity/postgres-exporter:latest`          | Postgres metrics sidecar                 | (internal)         |

**Litellm `:4000/metrics`, Milvus `:9091/metrics`, MinIO `:9000/minio/v2/metrics/cluster`, etcd `:2379/metrics`** are scraped directly (no sidecar).

**Volumes**
- `prometheus_data:/prometheus` — TSDB storage (30d retention)
- `grafana_data:/var/lib/grafana` — dashboards, datasources, settings

**Depends_on**
- `grafana` waits on `prometheus` healthy (so datasource provisioning succeeds).

**Grafana env isolation.** The `grafana` service deliberately does **not** declare `env_file: .env`. The shared `.env` contains `DATABASE_URL=postgresql://llmproxy:dbpassword9090@db:5432/litellm` (intended for the `litellm` service); if that var leaks into the Grafana container, the Grafana image switches its auth backend from internal sqlite to external Postgres, which silently breaks the `GF_SECURITY_ADMIN_PASSWORD__FILE` flow (the seeded admin user no longer matches the file-sourced password, so Grafana falls back to default `admin/admin`). The grafana service uses only its explicit `environment:` block (`GF_SECURITY_ADMIN_USER`, `GF_SECURITY_ADMIN_PASSWORD__FILE`, `GF_AUTH_ANONYMOUS_ENABLED`, `GF_SERVER_HTTP_PORT`) plus the `monitoring/secrets/grafana_admin_password` mount. Other services (litellm, prometheus exporters via secret files, etc.) retain their normal env handling.

---

## 4. Prometheus scrape config

`monitoring/prometheus/prometheus.yml` (mounted at `/etc/prometheus/prometheus.yml`):

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

Prometheus command: `--config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus --storage.tsdb.retention.time=30d`.

---

## 5. Grafana provisioning

`monitoring/grafana/provisioning/datasources/prometheus.yml`:
```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
```

`monitoring/grafana/provisioning/dashboards/provider.yml`:
```yaml
apiVersion: 1
providers:
  - name: litellm-stack
    folder: litellm-stack
    type: file
    options:
      path: /var/lib/grafana/dashboards
```

**Dashboards** (JSON files in `monitoring/grafana/dashboards/`):

1. **unified-overview.json** — single row of 6 panels, one per service: `up{job=...}` status, basic resource panel per service. ~6 panels.
2. **litellm-requests.json** — request rate, p50/p95/p99 latency, error rate (4xx/5xx), active keys, model-group throughput. ~10 panels.
3. **cache-vector.json** — Redis: cache hit rate, memory used, key count. Milvus: collection row count, query latency. ~8 panels.

**Random admin password**: `${GRAFANA_ADMIN_PASSWORD}` env var in `.env` (gitignored). If unset, compose generates a fresh random via `${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -hex 16)}` at up-time — but this means the password changes on each `up`. Recommended approach: user sets `GRAFANA_ADMIN_PASSWORD` in `.env` explicitly.

---

## 6. Alertmanager + 3 starter alerts

`monitoring/alertmanager/alertmanager.yml`:
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

`monitoring/prometheus/rules/starter.yml`:
```yaml
groups:
  - name: starter
    rules:
      - alert: ServiceDown
        expr: up == 0
        for: 2m
        labels: { severity: critical }
        annotations:
          summary: "Service {{ $labels.job }} is down"

      - alert: EmbedErrorSpike
        expr: |
          sum(rate(litellm_requests_failed_total[5m]))
            / sum(rate(litellm_requests_total[5m])) > 0.05
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "Embed error rate >5% for 5min on {{ $labels.job }}"

      - alert: RedisCacheMissRateHigh
        expr: |
          1 - (sum(rate(litellm_cache_hits_total[5m]))
                / sum(rate(litellm_cache_lookups_total[5m]))) > 0.95
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "Cache miss rate >95% — semantic cache may be down"
```

---

## 7. Failure handling

| Failure                       | Behavior                                                                          |
|-------------------------------|-----------------------------------------------------------------------------------|
| Prometheus down               | Grafana shows "datasource unavailable" banner. Stack continues working.            |
| Grafana down                  | Prometheus still scrapes; alerts still fire (visible in alertmanager logs).        |
| Alertmanager down              | Prometheus fires alerts but they go to dead-letter. Recover on restart.            |
| redis-exporter down           | `up{job="redis"}` flips to 0; `ServiceDown` alert fires. Stack still works.        |
| Scrape target returns 404    | Prometheus logs scrape error; `up{}` becomes 0. Subsequent scrapes retry.          |
| Litellm `:4000/metrics` not exposed | `up{job="litellm"}` = 0; `ServiceDown` alert fires. (Litellm enables this by default.) |
| Grafana admin password lost   | `docker compose down` + delete `grafana_data` volume + `up` (regenerates).         |

Prometheus + Grafana + Alertmanager are isolated from the request path. Their failures don't impact litellm → lemonade embeddings.

---

## 8. Smoke tests

```bash
# 1. Bring up
docker compose up -d

# 2. Wait for Prometheus targets to be UP
for i in $(seq 1 30); do
  UP=$(curl -sf http://127.0.0.1:9090/api/v1/targets 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for t in d['data']['activeTargets'] if t['health']=='up'))")
  if [ "$UP" = "7" ]; then echo "all 7 targets UP"; break; fi
  sleep 2
done

# 3. Each target has at least one scrape
curl -sf 'http://127.0.0.1:9090/api/v1/query?query=up' | python3 -m json.tool

# 4. Grafana health + datasource live
curl -sf http://127.0.0.1:3030/api/health
curl -sf -u admin:$GRAFANA_ADMIN_PASSWORD http://127.0.0.1:3030/api/datasources | python3 -m json.tool

# 5. Dashboards provisioned (3 expected)
curl -sf -u admin:$GRAFANA_ADMIN_PASSWORD http://127.0.0.1:3030/api/search | python3 -m json.tool

# 6. Alerts load
curl -sf http://127.0.0.1:9090/api/v1/rules | python3 -c "import sys,json; print(len(json.load(sys.stdin)['data']['groups'][0]['rules']), 'rules loaded')"

# 7. Trigger ServiceDown by stopping redis (manual)
docker compose stop redis
sleep 130
docker compose logs alertmanager | grep ServiceDown
docker compose start redis
```

---

## 9. Out of scope

- TLS / reverse proxy for Grafana exposure.
- Auth integration with litellm's Postgres (Grafana stays independent).
- Notification sinks beyond stdout.
- Custom metric exporters (e.g. lemonade).
- Auto-remediation of alerts.
- Dashboard editing/export tooling (use Grafana UI directly).
- Long-term storage (Thanos / Mimir).

---

## Known limitations

### MinIO scrape requires AWS Signature v4 — basic auth does not work

The MinIO cluster metrics endpoint (`/minio/v2/metrics/cluster`) does **not**
accept HTTP basic auth. MinIO's API requires AWS4-HMAC-SHA256 signature
authentication, which Prometheus's `basic_auth` scrape config does not produce.
As a result, the `minio` scrape job returns HTTP 400 (Invalid Request) on every
scrape and `up{job="minio"}` stays at 0 — even though the target itself is
reachable.

**Current state.** With `telemetry: True` enabled on litellm, all other targets
come up cleanly and Prometheus reports **6/7 targets UP** (litellm, redis,
milvus, postgres, etcd, prometheus). The `minio` job is left in the scrape
config but is not expected to come UP until one of the resolutions below is
implemented in a follow-on spec.

**Two viable resolutions (for a follow-on spec):**

1. **Sidecar minio-exporter.** Add a `minio/mc`-driven sidecar (e.g. the
   community `minio-exporter` image, or a small custom container that wraps
   `mc admin prometheus generate`) which signs AWS4 requests and exposes a
   plain Prometheus endpoint on its own port. Repoint the `minio` scrape job
   at the sidecar. Requires keeping `mc` credentials in
   `monitoring/secrets/minio_metrics_user` / `..._pass` and rotating them
   when MinIO creds change.
2. **Drop MinIO from the Prometheus scrape jobs.** Remove the `minio` job
   from `monitoring/prometheus/prometheus.yml` entirely. Acceptable because
   Milvus is the primary S3-backed service in this stack and has its own
   `/metrics` endpoint — direct MinIO visibility is not load-bearing for the
   three provisioned dashboards or the three starter alerts.

Resolution choice is deferred to a follow-on spec; this design ships with
6/7 targets UP and the MinIO job documented here as a known gap.
