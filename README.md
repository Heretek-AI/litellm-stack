# litellm-stack

Local Docker Compose stack wiring [LiteLLM](https://docs.litellm.ai/) to a lemonade-server OpenAI-compatible backend, with Redis Semantic cache and Milvus standalone for RAG.

## Layout

- `docker-compose.yml` — eleven services on the `litellm-net` bridge: `litellm`, `redis`, `etcd`, `minio`, `milvus`, `db`, `prometheus`, `alertmanager`, `grafana`, `redis-exporter`, `postgres-exporter`.
- `config/config.yaml` — proxy config: embedding model + Redis Semantic cache + Milvus vector store.
- `monitoring/` — Prometheus scrape config + rules, Grafana provisioning + dashboards, Alertmanager config, secret files.
- `.env` — secrets (gitignored); copy from `.env.example`.
- `data/` — runtime volume mount root.

## Scripts

```bash
./scripts/up.sh             # first-time bootstrap (refuses if .env exists)
./scripts/up.sh --reset     # full wipe + re-bootstrap
./scripts/up.sh --dry-run   # print plan, don't execute
./scripts/smoke.sh          # re-run the smoke suite anytime
```

`up.sh` is the happy path for bringing the stack up. It enforces strict clean-slate (refuses to overwrite `.env` unless `--reset` is passed), generates secrets, brings the compose stack up, waits for services to be healthy, and runs the smoke suite at the end. `smoke.sh` is callable independently to re-verify an already-up stack.

See `docs/superpowers/specs/2026-07-01-local-deploy-and-test-design.md` for the full design.

## Manual fallback

The scripts above handle the happy path. If `scripts/up.sh` is unavailable (e.g. partial clone), the raw `docker compose` commands still work:

```bash
cp .env.example .env
# edit .env: set LITELLM_MASTER_KEY (e.g. `openssl rand -hex 32`)
docker compose up -d
docker compose ps
```

Wait until `litellm-proxy` shows `healthy` (~30–60s the first time, while Milvus initialises). The monitoring stack (prometheus, alertmanager, grafana, exporters) comes up alongside the core stack.

### Smoke tests

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

## Monitoring

- **Grafana:** `http://127.0.0.1:3030` (loopback only). Login: `admin` + the password from `monitoring/secrets/grafana_admin_password` (mode 600, owned by the host uid so the container can read it). 3 dashboards are auto-provisioned under the `litellm-stack` folder.
- **Prometheus:** internal only (`:9090` on the `litellm-net` bridge). 6/7 scrape targets are UP after startup; `minio` is intentionally DOWN — see [Known limitations](#known-limitations) below.
- **Alertmanager:** internal only (`:9093` on the `litellm-net` bridge). Fires the 3 starter alerts to stdout.

## Known limitations

- **Litellm `/metrics` is scraped using `LITELLM_MASTER_KEY` as the Bearer token.** The Prometheus `litellm` job reads `monitoring/secrets/litellm_master_key` (mode 644, gitignored), which is the master key mirrored out of `.env`. There is no separate metrics token — keep `LITELLM_MASTER_KEY` in `.env` in sync with the contents of `monitoring/secrets/litellm_master_key`.
- **Chat completions depend on the lemonade backend.** `harrier-oss-v1-0.6b` is currently embedding-only on the lemonade server at `${LEMONADE_HOST_IP:-192.168.31.246}:13305` — `t_chat_round_trip` and `t_semantic_cache_hit` in the smoke suite will hard-fail until lemonade exposes `/v1/chat/completions` for this model. Embedding tests (`t_embed`, `t_redis_cache_write`) work today.
- **UI login is browser-only.** `ghcr.io/berriai/litellm:latest` serves a Swagger UI at `/ui` that requires DB-backed auth (Prisma init). Programmatic `POST /ui/login` returns 405; `POST /login` returns 400 with "Not connected to DB" until Prisma is initialized against the configured Postgres. The smoke suite asserts `GET /ui` returns 200/302/307 (UI reachable); bearer-token auth is validated separately by `t_embed`.

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