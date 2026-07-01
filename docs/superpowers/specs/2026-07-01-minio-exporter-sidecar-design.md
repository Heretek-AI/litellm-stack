# Minio Exporter Sidecar — Design

**Date:** 2026-07-01
**Status:** Approved — ready for implementation plan
**Scope:** Add `quay.io/minio/minio-exporter` sidecar to the existing litellm-stack observability addon to close the only remaining Prometheus scrape gap (minio). Wire prometheus.yml to scrape the sidecar. Drop the broken direct-scrape path.

---

## 1. Goal & Non-Goals

**Goal.** The minio Prometheus scrape target comes UP. Stack goes from 6/7 → 7/7 Prometheus targets.

**Non-goals.**
- Replacing minio or restructuring its storage layout.
- Adding metric labels or changing what metrics are exposed (just sidecar-proxy what's already there).
- New notification channels (ServiceDown alert clears on its own once minio target comes UP).

---

## 2. Decisions (resolved in brainstorming)

| # | Decision                    | Value                                                          |
|---|-----------------------------|----------------------------------------------------------------|
| 1 | Direction                   | minio-exporter sidecar to close 6/7 → 7/7 scrape gap         |
| 2 | Exporter image              | `quay.io/minio/minio-exporter:latest`                          |
| 3 | Auth                        | Existing `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` from `.env`   |
| 4 | Scrape URL                  | `http://minio-exporter:9000/minio/v2/metrics/cluster`         |
| 5 | Host port mapping           | None (internal-only)                                           |

---

## 3. Compose addition

Add 1 service to existing `docker-compose.yml`, on `litellm-net`:

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

Notes:
- Image is internal-only (no host port mapping).
- Auths via existing `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` from `.env` — no new secrets.
- Healthcheck probes its own `/minio/v2/metrics/cluster` to confirm it can reach + authenticate against minio.

---

## 4. Prometheus scrape config update

Replace the `minio` job in `monitoring/prometheus/prometheus.yml`. Currently scrapes `minio:9000/minio/v2/metrics/cluster` directly with basic_auth (broken — AWS4 required). Replace with:

```yaml
  - job_name: minio
    static_configs:
      - targets: ["minio-exporter:9000"]
    metrics_path: /minio/v2/metrics/cluster
```

The sidecar handles AWS4 signing internally; prometheus sees plain Prometheus text format.

---

## 5. Failure handling

| Failure                       | Behavior                                                                          |
|-------------------------------|-----------------------------------------------------------------------------------|
| minio-exporter down           | `up{job="minio"}` flips to 0 → `ServiceDown` fires. Minio is otherwise unaffected. |
| minio down                    | minio-exporter logs auth-fail errors; scrape returns 401; `up{job="minio"}` flips to 0. |
| AWS4 signature drift          | Sidecar logs signature mismatch; prometheus scrape fails. Re-create minio-exporter. |
| Wrong `MINIO_ENDPOINT`        | Sidecar can't reach minio; container logs connection refused; `up{job="minio"}` = 0. |

---

## 6. Smoke test

```bash
# After docker compose up -d
docker compose exec litellm-prometheus wget -qO- \
  "http://prometheus:9090/api/v1/targets" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(t['labels']['job'], '=', t['health']) for t in d['data']['activeTargets']]"
# Expected: 7/7 UP. minio = up (was down).

# Sanity check: scrape response has minio metrics
curl -s http://minio-exporter:9000/minio/v2/metrics/cluster | head -5
# Expected: prometheus text format with minio_* metrics.

# ServiceDown alert should clear on its own within `for: 2m` after target comes UP
docker compose exec alertmanager wget -qO- http://localhost:9093/api/v2/alerts \
  | python3 -c "import sys,json; print('active:', len(json.load(sys.stdin)))"
# Expected: 0 active alerts (was 2: ServiceDown litellm + ServiceDown minio).
```

---

## 7. Known limitations removed (after this spec)

- `Known limitations` section in `docs/superpowers/specs/2026-07-01-observability-addon-design.md` previously documented the minio AWS4 problem. After this spec lands, that entry becomes stale and should be removed.

---

## 8. Out of scope

- Replacing minio or its storage backend.
- Adding new alert rules (the existing ServiceDown rule is sufficient).
- Exposing minio-exporter on host port 9001 (intentionally internal-only).