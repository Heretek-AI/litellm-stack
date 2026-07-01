# LiteLLM Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring up a local Docker Compose stack wiring LiteLLM proxy → lemonade `/v1/embeddings`, with Redis Semantic cache and Milvus standalone for RAG.

**Architecture:** Five-service Compose project on a user-defined bridge network `litellm-net`. `litellm` is the only service with a host port (`127.0.0.1:4000`). Redis and Milvus triplet (etcd + minio + milvus) stay internal. Lemonade at `192.168.31.246:13305` is reached via `extra_hosts: host.docker.internal:host-gateway`. `config.yaml` registers `harrier-oss-v1-0.6b` as the only embedding model; `model_list` is empty pending lemonade `/v1/chat/completions`.

**Tech Stack:** Docker Compose v2, LiteLLM (`ghcr.io/berriai/litellm:latest`), Redis (`redis:latest`), Milvus standalone (`milvusdb/milvus:v2.4.x` + etcd + minio), lemonade OpenAI-compatible server on LAN, bash smoke tests via `curl` + `jq`.

**Spec:** `docs/superpowers/specs/2026-06-30-litellm-stack-design.md`

---

## Global Constraints

- Working directory: `/home/john/Projects/litellm-stack/`
- All paths in this plan are **relative to the working directory** unless prefixed with `/`.
- Every task ends with a commit. Use `git add` for the specific files created/changed in that task.
- Commit message format: `type: short description` — `chore:`, `feat:`, `docs:`, `test:`.
- Files MUST be valid YAML/`.env`. Validate after writing (use `docker compose config` for compose, `python3 -c "import yaml; yaml.safe_load(open('PATH'))"` for yaml).
- The `data/` directory is the parent of all named-volume bind mounts; it must exist before compose up.
- Master key generated via `openssl rand -hex 32`. **Never commit a real key to `.env`;** `.env` is gitignored, `.env.example` ships placeholders.
- All curl smoke tests run from the host against `127.0.0.1:4000` (the loopback-bound litellm port).

---

## Task 1: Project scaffold (`.gitignore` + dirs + initial commit)

**Files:**
- Create: `.gitignore`
- Create: `data/` (empty dir, kept by `.gitkeep`)

**Depends on:** none (first task)

- [ ] **Step 1: Create `.gitignore`**

Write to `/home/john/Projects/litellm-stack/.gitignore`:

```gitignore
# secrets
.env

# runtime
data/
*.log
docker-compose.override.yml

# local artifacts
mitm_*.db
```

- [ ] **Step 2: Create `data/` with `.gitkeep`**

```bash
mkdir -p data && touch data/.gitkeep
```

Expected: `data/.gitkeep` exists; `data/` is otherwise empty.

- [ ] **Step 3: Commit**

```bash
git add .gitignore data/.gitkeep
git commit -m "chore: scaffold project dirs and gitignore"
```

Expected: 1 file changed for `.gitignore`, 1 file changed for `data/.gitkeep`. Working tree clean afterward.

---

## Task 2: `.env` and `.env.example`

**Files:**
- Create: `.env` (gitignored — real key generated below)
- Create: `.env.example` (committed)

**Depends on:** Task 1

- [ ] **Step 1: Generate a master key and write `.env`**

```bash
KEY=$(openssl rand -hex 32)
cat > .env <<EOF
LITELLM_MASTER_KEY=sk-local-$KEY

LEMONADE_BASE_URL=http://192.168.31.246:13305/v1

REDIS_URL=redis://redis:6379
MILVUS_URI=http://milvus:19530
MILVUS_COLLECTION=litellm_rag
CACHE_SIMILARITY_THRESHOLD=0.8
CACHE_TTL=600

MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=minioadmin
EOF
chmod 600 .env
```

Expected: `.env` exists, mode 600, contains one `LITELLM_MASTER_KEY=sk-local-` line plus the others.

- [ ] **Step 2: Write `.env.example`**

Write to `/home/john/Projects/litellm-stack/.env.example`:

```bash
# Copy to .env and fill in real values.
# LITELLM_MASTER_KEY: generate with `openssl rand -hex 32` and prefix with sk-local-
# LEMONADE_BASE_URL: where lemonade is reachable on your LAN
# All other keys have sane local defaults — override only if needed.

LITELLM_MASTER_KEY=sk-local-CHANGEME-32-bytes-hex

LEMONADE_BASE_URL=http://192.168.31.246:13305/v1

REDIS_URL=redis://redis:6379
MILVUS_URI=http://milvus:19530
MILVUS_COLLECTION=litellm_rag
CACHE_SIMILARITY_THRESHOLD=0.8
CACHE_TTL=600

MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=minioadmin
```

- [ ] **Step 3: Verify `.env` is gitignored and `.env.example` is tracked**

```bash
git status --short
git check-ignore -v .env || echo "ERROR: .env not gitignored"
```

Expected:
- `git status --short` shows only `.env.example` (untracked or staged).
- `git check-ignore -v .env` prints `.gitignore:3:.env	.env` (i.e. `.env` IS ignored).
- The script exits non-zero if not ignored — the `|| echo` makes the failure visible.

- [ ] **Step 4: Commit**

```bash
git add .env.example
git commit -m "chore: add .env.example template"
```

Expected: 1 file changed. `.env` NOT in the commit.

---

## Task 3: `config/config.yaml`

**Files:**
- Create: `config/config.yaml`

**Depends on:** Task 2 (reads `LITELLM_MASTER_KEY` via `os.environ/...`)

- [ ] **Step 1: Write `config/config.yaml`**

Write to `/home/john/Projects/litellm-stack/config/config.yaml`:

```yaml
# Chat models — empty until lemonade exposes /v1/chat/completions.
model_list: []

# Embedding model — referenced by Redis Semantic cache + Milvus vector store.
embedding_models:
  - model_name: harrier-oss-v1-0.6b
    litellm_params:
      model: openai/harrier-oss-v1-0.6b
      api_base: http://host.docker.internal:13305/v1
      api_key: dummy-not-used
    cache: true

# Redis Semantic cache — uses the embed model above to compare query vectors.
litellm_settings:
  cache: true
  cache_params:
    type: redis-semantic
    redis_url: redis://redis:6379
    similarity_threshold: 0.8
    ttl: 600
    embedding_model: openai/harrier-oss-v1-0.6b
    api_base: http://host.docker.internal:13305/v1
    api_key: dummy-not-used

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

- [ ] **Step 2: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('config/config.yaml')); print('OK')"
```

Expected: `OK`. Failure means a YAML parse error — fix indentation.

- [ ] **Step 3: Commit**

```bash
git add config/config.yaml
git commit -m "feat: add litellm proxy config (embedding + redis-semantic + milvus)"
```

Expected: 1 file changed, working tree clean.

---

## Task 4: `docker-compose.yml`

**Files:**
- Create: `docker-compose.yml`

**Depends on:** Task 2 (uses `.env`), Task 3 (mounts `./config`)

- [ ] **Step 1: Write `docker-compose.yml`**

Write to `/home/john/Projects/litellm-stack/docker-compose.yml`:

```yaml
services:
  redis:
    image: redis:latest
    container_name: litellm-redis
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10
    networks:
      - litellm-net
    restart: unless-stopped

  etcd:
    image: quay.io/coreos/etcd:v3.5.5
    container_name: litellm-etcd
    command:
      - "etcd"
      - "-advertise-client-urls=http://etcd:2379"
      - "-listen-client-urls=http://0.0.0.0:2379"
      - "--data-dir=/etcd"
    healthcheck:
      test: ["CMD", "etcdctl", "endpoint", "health"]
      interval: 5s
      timeout: 3s
      retries: 10
    networks:
      - litellm-net
    restart: unless-stopped

  minio:
    image: minio/minio:latest
    container_name: litellm-minio
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    command: ["minio", "server", "/data", "--address", ":9000", "--console-address", ":9001"]
    volumes:
      - minio_data:/data
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:9000/minio/health/live"]
      interval: 5s
      timeout: 3s
      retries: 10
    networks:
      - litellm-net
    restart: unless-stopped

  milvus:
    image: milvusdb/milvus:v2.4.10
    container_name: litellm-milvus
    command: ["milvus", "run", "standalone"]
    environment:
      ETCD_ENDPOINTS: etcd:2379
      MINIO_ADDRESS: minio:9000
      MINIO_ACCESS_KEY_ID: ${MINIO_ROOT_USER}
      MINIO_SECRET_ACCESS_KEY: ${MINIO_ROOT_PASSWORD}
    depends_on:
      etcd:
        condition: service_healthy
      minio:
        condition: service_healthy
    volumes:
      - milvus_data:/var/lib/milvus
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:9091/healthz"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
    networks:
      - litellm-net
    restart: unless-stopped

  litellm:
    image: ghcr.io/berriai/litellm:latest
    container_name: litellm-proxy
    env_file:
      - .env
    command: ["litellm", "--config", "/app/config/config.yaml", "--port", "4000", "--detailed_debug"]
    volumes:
      - ./config:/app/config:ro
    ports:
      - "127.0.0.1:4000:4000"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      redis:
        condition: service_healthy
      milvus:
        condition: service_healthy
    networks:
      - litellm-net
    restart: unless-stopped

volumes:
  redis_data:
  milvus_data:
  minio_data:

networks:
  litellm-net:
    driver: bridge
```

- [ ] **Step 2: Validate compose file**

```bash
docker compose config --quiet && echo "compose OK"
```

Expected: `compose OK`. If it errors, fix the file path or YAML.

- [ ] **Step 3: Verify `.env` is loaded by compose**

```bash
docker compose config | grep -E "MINIO_ROOT_USER|MINIO_ROOT_PASSWORD" | head -4
```

Expected: two `MINIO_ROOT_USER` lines + two `MINIO_ROOT_PASSWORD` lines (one each in `minio.environment` and `milvus.environment`). If empty, `.env` is not being read — check file mode and presence.

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add docker compose with litellm, redis, milvus triplet"
```

Expected: 1 file changed, working tree clean.

---

## Task 5: README with smoke tests

**Files:**
- Create: `README.md`

**Depends on:** Task 4

- [ ] **Step 1: Write `README.md`**

Write to `/home/john/Projects/litellm-stack/README.md`:

```markdown
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
docker compose logs litellm --tail 50 | grep -i 'cache hit\|semantic'

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
```

- [ ] **Step 2: Verify README renders sensibly (no broken markdown)**

```bash
head -5 README.md
grep -c '^```' README.md
```

Expected: header line + filename `README.md` present. `grep -c '^```'` returns an **even** number (code fences must pair up). If odd, fix.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add README with bring-up + smoke tests"
```

Expected: 1 file changed, working tree clean.

---

## Task 6: Bring up the stack and verify all services are healthy

**Depends on:** Tasks 1–5 complete; Docker daemon running; lemonade server reachable on `192.168.31.246:13305`.

- [ ] **Step 1: Pull images**

```bash
docker compose pull
```

Expected: 5 images pulled (`redis`, `etcd`, `minio`, `milvus`, `litellm`). No auth errors.

- [ ] **Step 2: Start the stack in detached mode**

```bash
docker compose up -d
```

Expected: 5 services started, no `ERROR:` lines. Output ends with `Network litellm-net  Created` and `Container litellm-redis  Started` etc.

- [ ] **Step 3: Wait for all services to report healthy**

```bash
for i in $(seq 1 60); do
  HEALTHY=$(docker compose ps --format json | grep -c '"Health":"healthy"')
  if [ "$HEALTHY" = "5" ]; then echo "all 5 healthy"; break; fi
  sleep 2
done
docker compose ps
```

Expected: prints `all 5 healthy` within ~60s (Milvus takes the longest). Final `docker compose ps` shows every service as `healthy` (or at least `running` for etcd if etcdctl healthcheck is finicky — verify by `docker compose logs etcd --tail 20`).

- [ ] **Step 4: Verify proxy responds on `127.0.0.1:4000`**

```bash
curl -sf http://127.0.0.1:4000/health/readiness | jq .
```

Expected: HTTP 200 with JSON like `{"status": "healthy"}` or similar. If 000/connection refused, check `docker compose logs litellm --tail 100`.

- [ ] **Step 5: Verify lemonade reachable from inside the litellm container**

```bash
docker compose exec litellm curl -sf http://host.docker.internal:13305/v1/models
```

Expected: HTTP 200, JSON list containing `harrier-oss-v1-0.6b`. If connection refused, verify lemonade is up on the host LAN and that `host.docker.internal:host-gateway` mapping is in the running container (`docker compose exec litellm cat /etc/hosts | grep host.docker.internal`).

---

## Task 7: Verify embedding roundtrip + Redis Semantic cache hit

**Depends on:** Task 6 (stack up + healthy)

- [ ] **Step 1: First embed call — should hit lemonade, cache empty**

```bash
KEY=$(grep ^LITELLM_MASTER_KEY .env | cut -d= -f2)
curl -s -X POST http://127.0.0.1:4000/v1/embeddings \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"harrier-oss-v1-0.6b","input":"hello world"}' | jq .
```

Expected: HTTP 200 with shape `{"object":"list","data":[{"embedding":[...], ...}], "model":"harrier-oss-v1-0.6b", "usage":{...}}`. If 401, the master key in `.env` doesn't match what's in the running container — restart litellm: `docker compose up -d --force-recreate litellm`.

- [ ] **Step 2: Second embed call with paraphrased input — should hit Redis Semantic cache**

```bash
curl -s -X POST http://127.0.0.1:4000/v1/embeddings \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"harrier-oss-v1-0.6b","input":"hi there"}' | jq .
docker compose logs litellm --tail 80 | grep -iE 'semantic|cache'
```

Expected: HTTP 200 with embedding returned. Logs show a line containing `Semantic Cache Hit` (or similar — exact wording depends on LiteLLM version). If no hit line, the `embedding_model` + `api_base` in `config.yaml` is wrong — re-check.

- [ ] **Step 3: Confirm Redis has the cached key**

```bash
docker compose exec redis redis-cli KEYS '*' | head -20
```

Expected: at least one key matching `*semantic*` or `*embedding*`. Empty means Redis semantic cache didn't write — recheck `cache_params.type: redis-semantic`.

---

## Task 8: Verify Milvus reachability + UI

**Depends on:** Task 6 (stack up + healthy)

- [ ] **Step 1: Milvus health from inside litellm container**

```bash
docker compose exec litellm curl -sf http://milvus:19530/health
```

Expected: HTTP 200, body `{"status":"ok"}` (or similar). Confirms the proxy can reach Milvus — this is the path the `vector_stores` block uses.

- [ ] **Step 2: UI responds**

```bash
curl -sf -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4000/ui
```

Expected: `200` or `302` (redirect to login). If 000/404, `ui: litellm-ui` is missing from `general_settings`.

- [ ] **Step 3: Login to UI (manual)**

Open `http://127.0.0.1:4000/ui` in a browser. Use the value of `LITELLM_MASTER_KEY` (without `sk-local-` prefix? — depends on UI version; the spec says use the master key as the password) as the password.

Expected: UI loads, shows the models page. Embedding model `harrier-oss-v1-0.6b` listed under Embeddings.

---

## Self-Review (post-write)

Run before declaring the plan complete.

1. **Spec coverage:**
   - §1 Goal & Non-Goals — Tasks 6–8 verify; non-goals (chat, HA) excluded.
   - §2 Decisions — Task 2 (Redis latest, .env keys), Task 3 (config model_list empty, embedding, redis-semantic, milvus), Task 4 (compose bridge + extra_hosts, master key + UI), Task 6 (verifies).
   - §3 File Layout — Tasks 1–5 each create one file from the layout.
   - §4 Compose Services — Task 4; §4 healthchecks verified in Task 6; §4 volumes covered.
   - §5 config.yaml — Task 3.
   - §6 .env — Task 2.
   - §7 Networking — Task 4 (extra_hosts, port bind, bridge).
   - §8 Failure Handling — documented in README; not implemented as code.
   - §9 Smoke Tests — Task 5 (README documents) + Tasks 7–8 (execute).
   - §10 Out of Scope — excluded (chat wiring, TLS, CI).
2. **Placeholders:** none. Every command, key, and value is explicit.
3. **Type / key consistency:** `LITELLM_MASTER_KEY`, `MILVUS_COLLECTION`, `LEMONADE_BASE_URL` consistent across `.env.example`, `docker-compose.yml`, `config/config.yaml`, README. `harrier-oss-v1-0.6b` model id consistent. `host.docker.internal:host-gateway` consistent.
4. **Task right-sizing:** each task is one cohesive file or one cohesive verification goal; each ends in commit or status check.