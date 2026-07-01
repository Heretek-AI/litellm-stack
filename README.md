# litellm-stack

Local Docker Compose stack wiring [LiteLLM](https://docs.litellm.ai/) to a lemonade-server OpenAI-compatible backend, with Redis Semantic cache and Milvus standalone for RAG.

## Layout

- `docker-compose.yml` — five services on the `litellm-net` bridge: `litellm`, `redis`, `etcd`, `minio`, `milvus`.
- `config/config.yaml` — proxy config: embedding model + Redis Semantic cache + Milvus vector store.
- `.env` — secrets (gitignored); copy from `.env.example`.
- `data/` — runtime volume mount root.

## Bring up

```bash
cp .env.example .env
# edit .env: set LITELLM_MASTER_KEY (e.g. `openssl rand -hex 32`)
docker compose up -d
docker compose ps
```

Wait until `litellm-proxy` shows `healthy` (~30–60s the first time, while Milvus initialises).

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
docker compose exec litellm curl -sf http://milvus:19530/health
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