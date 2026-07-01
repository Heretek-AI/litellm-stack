# LiteLLM Stack — Design

**Date:** 2026-06-30
**Status:** Approved — ready for implementation plan
**Scope:** Compose stack wiring a LiteLLM proxy to a lemonade-server OpenAI-compatible embedding backend, with Redis Semantic cache and Milvus standalone as the RAG vector store.

---

## 1. Goal & Non-Goals

**Goal.** A local Docker Compose stack that:
- Serves `harrier-oss-v1-0.6b` as an embedding model through the LiteLLM proxy.
- Caches embeddings semantically in Redis (so semantically equivalent prompts hit cache).
- Stores vector-store (RAG) documents in a self-contained Milvus standalone instance.
- Exposes the LiteLLM proxy + admin UI on `127.0.0.1:4000`, gated by a master key from `.env`.

**Non-goals.**
- Chat completions are not wired yet. The lemonade server currently exposes `/v1/embeddings` only; chat will be added in a follow-on spec once `/v1/chat/completions` is enabled upstream.
- Multi-tenant / DB-backed per-user keys. Single master key + UI is sufficient for local use.
- High availability. Single-node Redis + single-node Milvus + etcd+MinIO singletons — fine for local dev.

---

## 2. Decisions (resolved in brainstorming)

| # | Decision                | Value                                                                 |
|---|-------------------------|-----------------------------------------------------------------------|
| 1 | Cache mode              | Redis Semantic (`type: redis-semantic`)                               |
| 2 | Redis                   | Latest official `redis` image, fresh install in compose                |
| 3 | Milvus use              | RAG vector store only (not cache)                                     |
| 4 | Proxy auth              | Master key + LiteLLM UI                                               |
| 5 | Model alias             | Pass-through: clients call `harrier-oss-v1-0.6b` directly              |
| 6 | Container → lemonade    | Bridge network + `extra_hosts: host.docker.internal:${LEMONADE_HOST_IP:-192.168.31.246}` (Fedora-safe; docker0 bridge is `linkdown` so `host-gateway` resolves to an unreachable IP — hardcode the lemonade host IP via env var with a sensible default instead) |
| 7 | Embeddings source       | lemonade `/v1/embeddings`, model id `harrier-oss-v1-0.6b`             |
| 8 | Chat model              | Deferred — `model_list` currently contains the embed model only; add chat entries under `model_list` when lemonade exposes `/v1/chat/completions` |
| 9 | Approach                | A — minimal stack, embed-only now                                     |

---

## 3. File Layout

```
litellm-stack/
├── .env                       # secrets + host config (gitignored)
├── .env.example               # template, safe to commit
├── .gitignore                 # ignore .env, data/, *.log, mitm_*.db
├── docker-compose.yml         # litellm + redis + milvus triplet
├── config/
│   └── config.yaml            # litellm proxy config
├── data/                      # gitignored; volume mounts
└── README.md                  # how to bring it up + smoke tests
```

---

## 4. Compose Services

All on a single user-defined bridge network `litellm-net`.

| Service  | Image                              | Purpose                       | Host port |
|----------|------------------------------------|-------------------------------|-----------|
| litellm  | `ghcr.io/berriai/litellm:latest`   | Proxy + UI                    | `127.0.0.1:4000` |
| redis    | `redis:latest`                     | Semantic cache backend        | (internal) |
| etcd     | `quay.io/coreos/etcd:v3.5.5`       | Milvus metadata               | (internal) |
| minio    | `minio/minio:latest`               | Milvus object storage         | (internal) |
| milvus   | `milvusdb/milvus:v2.4.x`           | Vector DB                     | (internal) |

**Dependencies & healthchecks**
- `redis` healthcheck: `redis-cli ping`.
- `milvus` healthcheck: `curl -sf http://localhost:9091/healthz` (Milvus built-in).
- `litellm` depends_on redis + milvus with `condition: service_healthy`.

**Volumes**
- `redis_data` → `/data` — Redis persistence (RDB).
- `milvus_data` → `/var/lib/milvus` — collections + indexes.
- `minio_data` → `/data` — object storage for Milvus.
- `./config` → `/app/config` (read-only) — config.yaml mount.

---

## 5. config/config.yaml

```yaml
# Chat models — empty until lemonade exposes /v1/chat/completions.
model_list:
  # Embedding model — referenced by Redis Semantic cache + Milvus vector store.
  - model_name: harrier-oss-v1-0.6b
    litellm_params:
      model: openai/harrier-oss-v1-0.6b
      # Hostname literal; compose's `extra_hosts` maps `host.docker.internal`
      # to LEMONADE_HOST_IP at container startup. LiteLLM's config loader
      # supports os.environ/FOO substitution but not shell-style ${VAR:-default}
      # interpolation, so the URL stays literal here.
      api_base: http://host.docker.internal:13305/v1
      api_key: dummy-not-used

# Redis Semantic cache — uses the embed model above to compare query vectors.
litellm_settings:
  cache: true
  # Cache embedding probe runs during config load (before router is built),
  # so provide litellm-level api_base/api_key rather than relying on router
  # resolution. Model is fully provider-prefixed.
  api_base: http://host.docker.internal:13305/v1
  api_key: dummy-not-used
  cache_params:
    type: redis-semantic
    redis_url: redis://redis:6379
    similarity_threshold: 0.8
    ttl: 600
    redis_semantic_cache_embedding_model: openai/harrier-oss-v1-0.6b
    redis_semantic_cache_index_name: litellm_semantic_cache

# Milvus — RAG vector store. Collection auto-created on first write.
vector_stores:
  - name: milvus_rag
    type: milvus
    uri: http://milvus:19530
    collection_name: litellm_rag
    embedding_model: openai/harrier-oss-v1-0.6b
    api_base: http://host.docker.internal:13305/v1
    api_key: dummy-not-used

# Proxy + UI
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  ui: litellm-ui
```

**Note on prior Redis failure.** The `redis_semantic_cache_embedding_model` + `litellm_settings.api_base` pairing is the most commonly missed piece. Without an embedding model registered in `model_list`, Redis Semantic cannot compute query vectors and silently disables caching. Without `litellm_settings.api_base`, the eager probe fails before router resolution. With both set, cache will hit for `/v1/chat/completions`; for `/v1/embeddings` see the upstream limitation note below.

**Known upstream limitation (verified 2026-06-30):** The Redis Semantic cache **write side works** for `/v1/embeddings` (vectors stored under `litellm_semantic_cache:` index), but the **read-side semantic lookup is not triggered** through the LiteLLM proxy embedding route. Hash-key lookup short-circuits with `Cache_hit=None`, so paraphrased input never reaches the `RedisSemanticCache.get_cache` semantic branch. Confirmed by dropping `similarity_threshold` to `0.5` and using a near-identical input pair (cosine ≫ 0.5) — still no HIT. Workarounds: (a) use `/v1/chat/completions` for cache verification — semantic cache is known to work for that route; (b) file an issue against `BerriAI/litellm` documenting the embedding-route bypass. This does not affect Milvus RAG vector stores or completion routes.

**Note on LiteLLM config-schema gotchas** (validated against the working stack, not just the docs):
- **Embedding model placement.** Embedding models live in `model_list:` — `embedding_models:` is not a top-level key in current LiteLLM. The model entry in `model_list` doubles as the embed source for `redis_semantic_cache_embedding_model` and Milvus. (Earlier draft had a separate `embedding_models:` top-level key; abandoned because LiteLLM rejected it.)
- **`cache_params` embed-model key.** `cache_params.embedding_model` collides with `Cache(**cache_params)`'s leading `embedding_model` kwarg, producing `TypeError: got multiple values for keyword argument 'embedding_model'`. Use `cache_params.redis_semantic_cache_embedding_model` (upstream-supported key). (Earlier draft used the colliding `embedding_model:`; abandoned because the proxy crashed on startup.)
- **Eager cache probe.** Cache's eager embed probe runs **before** the router is built, so per-deployment credentials aren't available yet. Supply `litellm_settings.api_base` + `api_key` so the probe can authenticate against lemonade.
- **Compose command.** The `litellm` Docker image's entrypoint already invokes `litellm "$@"`. Compose's `command:` should pass argv only (e.g. `["--config", "/app/config/config.yaml", "--port", "4000", "--detailed_debug"]`), NOT `["litellm", "--config", ...]` — the leading `litellm` causes `Unknown command: litellm`.
- **Eager-probe env creds.** The openai-compat client needs `OPENAI_API_KEY` + `OPENAI_API_BASE` in the environment even though per-deployment `api_key` is set — they back the eager probe before router resolution.
- **`extra_hosts` portability.** On Fedora (and any host with `linkdown` docker0 bridge), `extra_hosts: host.docker.internal:host-gateway` resolves to an unreachable IP. Wire `extra_hosts` to `${LEMONADE_HOST_IP:-192.168.31.246}` so the IP is configurable via `.env`. Use `host-gateway` only on hosts where docker0 is up.

---

## 6. .env / .env.example

```
# .env (gitignored)
LITELLM_MASTER_KEY=sk-local-<generated-32-bytes>

LEMONADE_BASE_URL=http://192.168.31.246:13305/v1

REDIS_URL=redis://redis:6379
MILVUS_URI=http://milvus:19530
MILVUS_COLLECTION=litellm_rag
CACHE_SIMILARITY_THRESHOLD=0.8
CACHE_TTL=600

MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=minioadmin       # local-only; rotate if exposed

# OpenAI-compatible client creds (used by litellm's eager cache embed probe;
# lemonade ignores the key but the openai-compat client requires it set).
OPENAI_API_KEY=dummy-not-used
OPENAI_API_BASE=http://host.docker.internal:13305/v1
```

`.env.example` ships with the same keys, placeholder values, and a comment block instructing users to copy and fill.

---

## 7. Networking

- Bridge network `litellm-net`. All five services attached.
- `litellm` `extra_hosts: ["host.docker.internal:${LEMONADE_HOST_IP:-192.168.31.246}"]` so the container resolves the LAN address of lemonade at the IP set in `.env` (default `192.168.31.246:13305`). **On hosts where the docker0 bridge is `linkdown` (Fedora 45 confirmed), `host-gateway` resolves to an unreachable IP — use the `LEMONADE_HOST_IP` env var instead, with `192.168.31.246` as the default fallback.** A portability note is captured in §5 "Note on LiteLLM config-schema gotchas".
- Bind mounts on Fedora SELinux Enforcing mode need `:z` relabel so nonroot containers can read them (e.g. `./config:/app/config:ro,z`). Without `:z`, litellm logs `Config file not found` even though the file exists at the path.
- Redis and Milvus are reachable by service name from `litellm` — no host port mapping needed.
- Host port binding is `127.0.0.1:4000:4000` (loopback only). Remove `127.0.0.1` if exposing on the LAN.

---

## 8. Failure Handling

| Failure                          | Behavior                                                                          |
|----------------------------------|-----------------------------------------------------------------------------------|
| Redis down                       | LiteLLM logs error, serves request uncached. No 5xx.                              |
| Milvus down                      | Vector-store calls error to caller. Cache continues working.                     |
| Lemonade `/embeddings` 5xx       | Embed call fails → cache lookup degrades to miss; upstream call may also fail.    |
| Lemonade unreachable             | First embed call surfaces the error; UI shows proxy unhealthy until restored.     |
| Master key missing from env      | LiteLLM refuses to start (built-in check). Loud failure, no silent default key.   |
| Milvus `/health` returns 404     | Expected — Milvus v2.4 serves gRPC on 19530; HTTP frontend returns 404 for `/health`-style paths. Verify via TCP probe (`socket.create_connection(('milvus',19530),5)`) and `[GIN]` log entries showing requests from the litellm container IP. |

Cache failures are non-fatal by LiteLLM default. Milvus failures are surfaced to the caller because the operation cannot silently degrade. UI health status reflects redis + lemonade reachability.

---

## 9. Smoke Tests

See [README.md → Smoke tests](../../../../README.md#smoke-tests). The plan-section draft of these tests is no longer maintained here — the README is the source of truth, including the upstream-limitation note (Redis Semantic cache read-side bypass for `/v1/embeddings`) and the Milvus gRPC-only port caveat.

---

## 10. Out of Scope / Follow-ons

- Chat model registration (when lemonade exposes `/v1/chat/completions`).
- TLS / reverse proxy for LAN exposure (currently bound to loopback).
- CI lint / schema validation for `config.yaml`.
- Backup/restore for Milvus collections and Redis RDB.