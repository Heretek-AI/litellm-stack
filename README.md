# litellm-stack

Local Docker Compose stack wiring [LiteLLM](https://docs.litellm.ai/) to a lemonade-server OpenAI-compatible backend, with Redis Semantic cache and Milvus standalone for RAG.

## Layout

- `docker-compose.yml` — eleven services on the `litellm-net` bridge: `litellm`, `redis`, `etcd`, `minio`, `milvus`, `db`, `prometheus`, `alertmanager`, `grafana`, `redis-exporter`, `postgres-exporter`.
- `config/config.yaml` — proxy config: embedding model + Redis Semantic cache + Milvus vector store.
- `monitoring/` — Prometheus scrape config + rules, Grafana provisioning + dashboards, Alertmanager config, secret files.
- `.env` — secrets (gitignored); copy from `.env.example`.
- `data/` — runtime volume mount root.

## Bring up

```bash
cp .env.example .env
# edit .env: set LITELLM_MASTER_KEY (e.g. `openssl rand -hex 32`)
docker compose up -d
docker compose ps
```

Wait until `litellm-proxy` shows `healthy` (~30–60s the first time, while Milvus initialises). The monitoring stack (prometheus, alertmanager, grafana, exporters) comes up alongside the core stack.

## Monitoring

- **Grafana:** `http://127.0.0.1:3030` (loopback only). Login: `admin` + the password from `monitoring/secrets/grafana_admin_password` (mode 600, owned by the host uid so the container can read it). 3 dashboards are auto-provisioned under the `litellm-stack` folder.
- **Prometheus:** internal only (`:9090` on the `litellm-net` bridge). 6/7 scrape targets are UP after startup; `minio` is intentionally DOWN — see [Known limitations](#known-limitations) below.
- **Alertmanager:** internal only (`:9093` on the `litellm-net` bridge). Fires the 3 starter alerts to stdout.

## Known limitations

- **MinIO scrape is DOWN.** The MinIO cluster metrics endpoint requires AWS Signature v4, which Prometheus's `basic_auth` scrape config does not produce. The `minio` job stays at `up=0`. Resolutions (sidecar minio-exporter or drop the job) are deferred to a follow-on spec. Other 6/7 targets (litellm, redis, milvus, postgres, etcd, prometheus) come up cleanly.
- **Litellm `/metrics` is scraped using `LITELLM_MASTER_KEY` as the Bearer token.** The Prometheus `litellm` job reads `monitoring/secrets/litellm_master_key` (mode 644, gitignored), which is the master key mirrored out of `.env`. There is no separate metrics token — keep `LITELLM_MASTER_KEY` in `.env` in sync with the contents of `monitoring/secrets/litellm_master_key`.

## Smoke tests

```bash
# 1. Proxy health (no auth)
curl -s http://127.0.0.1:4000/health/readiness | jq .

# 2. Embed with master key
KEY=$(grep ^LITELLM_MASTER_KEY .env | cut -d= -f2)
curl -s -X POST http://127.0.0.1:4000/v1/embeddings \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"harrier-oss-v1-0.6b","input":"hello world"}' | jq .

# 3. Embed again — verify Redis Semantic cache hit
# NOTE: As of 2026-06-30, the Redis Semantic cache's read-side semantic lookup
# is NOT triggered for /v1/embeddings (LiteLLM upstream limitation; the proxy
# route's hash-key lookup short-circuits before the semantic branch runs).
# Write side works — vectors are stored under litellm_semantic_cache: in Redis.
# /v1/chat/completions is unaffected. Verify write side only:
docker compose exec redis redis-cli KEYS 'litellm_semantic_cache:*' | head

# 4. UI login
open http://127.0.0.1:4000/ui   # master_key as password

# 5. Milvus reachable from litellm container
# Note: Milvus v2.4 serves gRPC on 19530; its HTTP frontend returns 404 for
# /health-style paths, so a curl probe will see 404 even when Milvus is fully
# reachable. Verify reachability via TCP and the proxy's ability to talk to it:
docker compose exec litellm python3 -c "import socket; s=socket.create_connection(('milvus',19530),timeout=5); s.close(); print('milvus:19530 reachable')"
# Or check `docker compose logs milvus --tail 50` for [GIN] entries from the litellm container IP.
```

## Tearing down

```bash
docker compose down              # stop + remove containers, keep volumes
docker compose down -v           # also delete named volumes (wipes Redis/Milvus state)
```

## Adding chat completions

When lemonade exposes `/v1/chat/completions`, append to `model_list` in `config/config.yaml`:

```yaml
model_list:
  - model_name: harrier-oss-v1-0.6b
    litellm_params:
      model: openai/harrier-oss-v1-0.6b
      api_base: http://host.docker.internal:13305/v1
      api_key: dummy-not-used
```

Then `docker compose restart litellm`.