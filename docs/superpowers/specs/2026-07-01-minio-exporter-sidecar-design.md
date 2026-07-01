# Minio Public-Metrics Pivot — Design

**Date:** 2026-07-01
**Status:** Approved — pivot from sidecar approach to env-var approach
**Scope:** Set `MINIO_PROMETHEUS_AUTH_TYPE=public` on the existing minio service so `/minio/v2/metrics/cluster` becomes publicly readable. Drop the broken `basic_auth` direct-scrape and the proposed `quay.io/minio/minio-exporter` sidecar (image doesn't exist on Docker Hub). prometheus.yml scrapes `minio:9000` directly with no auth.

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
| 1 | Direction                   | `MINIO_PROMETHEUS_AUTH_TYPE=public` on existing minio service   |
| 2 | Exporter image              | None — no new container                                         |
| 3 | Auth                        | None — `/minio/v2/metrics/cluster` is publicly readable          |
| 4 | Scrape URL                  | `http://minio:9000/minio/v2/metrics/cluster`                    |
| 5 | Host port mapping           | None (internal-only)                                            |

---

## 3. Compose change

Modify the existing `minio` service in `docker-compose.yml` to add a single environment variable `MINIO_PROMETHEUS_AUTH_TYPE=public` to its `environment:` block. Keep existing `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` / `MINIO_VOLUMES` / healthcheck / network / restart unchanged. **No new service. No new container.**

```yaml
  minio:
    image: minio/minio:latest
    container_name: litellm-minio
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
      MINIO_PROMETHEUS_AUTH_TYPE: public
    command: ["minio", "server", "/data", "--address", ":9000", "--console-address", ":9001"]
    # ...rest unchanged
```

Notes:
- `MINIO_PROMETHEUS_AUTH_TYPE=public` is a minio-native toggle. The `/minio/v2/metrics/cluster` endpoint becomes publicly readable inside the `litellm-net` Docker network; it is **not** exposed on the host (no host port mapping for 9000).
- The env var requires a recent minio image (`minio/minio:latest` is sufficient; verified 2026-07-01).
- Restart the container (`docker compose up -d minio`) so the new env var is picked up — env vars are read at process start.

---

## 4. Prometheus scrape config update

Replace the `minio` job in `monitoring/prometheus/prometheus.yml`. Currently scrapes `minio:9000/minio/v2/metrics/cluster` directly with `basic_auth` (broken — AWS4 required). Replace with:

```yaml
  - job_name: minio
    metrics_path: /minio/v2/metrics/cluster
    static_configs:
      - targets: ["minio:9000"]
```

Drop the `basic_auth:` block entirely (no auth needed when `MINIO_PROMETHEUS_AUTH_TYPE=public`). Keep `metrics_path` and `targets: ["minio:9000"]`.

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
- **Pivot note (2026-07-01):** The originally proposed `quay.io/minio/minio-exporter` sidecar was abandoned — the image does not exist on Docker Hub (verified 2026-07-01, returns 401 on pull). The new approach uses minio's built-in `MINIO_PROMETHEUS_AUTH_TYPE=public` env var to expose metrics without auth. No new container, no new image, no new secrets.

---

## 8. Out of scope

- Replacing minio or its storage backend.
- Adding new alert rules (the existing ServiceDown rule is sufficient).
- Exposing minio-exporter on host port 9001 (intentionally internal-only).