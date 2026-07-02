# Local Deploy & Test Scripts — Design

**Date:** 2026-07-01
**Status:** Approved
**Scope:** Two bash scripts (`scripts/up.sh`, `scripts/smoke.sh`) that turn the existing manual `docker compose` workflow into a one-command bootstrap and a programmatic end-to-end smoke test. Plus a README update pointing at the scripts.

---

## 1. Goal & Non-Goals

**Goal.** A fresh clone of this repo, on a host with Docker + curl + jq + openssl, brings the full stack (litellm, redis, etcd, minio, milvus, postgres, prometheus, alertmanager, grafana, exporters) up to a fully-verified green state via one command: `./scripts/up.sh`. Re-runs work cleanly. Re-verification of an already-up stack works via `./scripts/smoke.sh` alone.

**Non-goals.**
- CI / GitHub Actions pipeline. The scripts are local-dev-shaped; CI is a separate spec when needed.
- Migrating to a deployment tool (Ansible, Helm, Compose-as-Terraform). Plain bash + `docker compose` is enough.
- Auto-tear-down (`scripts/down.sh`). README keeps the existing `docker compose down` documentation.
- New monitoring, alerting, or scrape changes. The stack stays as committed.
- Adding or removing services. No compose changes.

---

## 2. Decisions (resolved in brainstorming)

| # | Decision                  | Value                                                                            |
|---|---------------------------|----------------------------------------------------------------------------------|
| 1 | Layout                    | Two scripts under `scripts/`: `up.sh` (bootstrap) + `smoke.sh` (test runner)      |
| 2 | Tooling                   | Bash + `curl` + `jq` + `openssl` + `docker compose`. No new dependencies.        |
| 3 | Shared library            | None. Self-contained scripts; cross-call is `up.sh → smoke.sh` only.              |
| 4 | Re-run policy             | Strict clean-slate. `up.sh` refuses if `.env` exists unless `--reset` is passed. |
| 5 | Flags                     | `up.sh`: `--reset`, `--dry-run`, `--help`. `smoke.sh`: `--help` only.            |
| 6 | Test depth                | Full functional sweep — health + observability + chat round-trip + cache + grafana query. |
| 7 | Functional test policy    | Required (hard-fail). No skipping when lemonade host is unreachable.             |
| 8 | Output format             | Plain ASCII text. `[PASS] <name>` / `[FAIL] <name>` lines + final tally.         |
| 9 | Exit codes                | `0` all-green, `1` any failure (bootstrap or smoke).                              |
| 10| Self-test                 | `shellcheck -s bash` clean. No unit-test framework. Manual `--reset` round-trip.  |

---

## 3. File layout

```
scripts/
  up.sh        # bootstrap: prereq → clean-slate → env → secrets → compose up → wait → smoke
  smoke.sh     # standalone test runner; callable independently of up.sh
```

Both `chmod +x`, both runnable directly. Shebang `#!/usr/bin/env bash`. Both `set -euo pipefail`.

`smoke.sh` knows nothing about bootstrap. `up.sh` is the entrypoint for first-time setup and shells out to `smoke.sh` for verification.

---

## 4. `up.sh` — bootstrap flow

Sequence, fail-fast, in order:

### 4.1 Prereq check

Verify present: `docker`, `docker compose version` (compose plugin), `curl`, `jq`, `openssl`. Any missing → exit 1 with clear `missing: <tool>` message.

### 4.2 Working dir

Script `cd`s to its own parent: `cd "$(dirname "$0")/.."`. From there, `docker-compose.yml` must exist or the script exits with a clear "not in repo root" message.

### 4.3 Clean-slate enforcement

- If `.env` exists AND `--reset` not given: print current state (file mtime, size) and exit 1 with hint to use `--reset`.
- If `--reset` given: `docker compose down -v` (full wipe, including volumes), then continue.
- If `.env` missing: continue.

### 4.4 Env file generation

`cp .env.example .env`. Then for each placeholder value, `sed -i` it to the generated value. Placeholders detected by exact match against the following known strings (verified against `.env.example`):
- `LITELLM_MASTER_KEY` placeholder `sk-local-CHANGEME-32-bytes-hex` → `openssl rand -hex 32`
- `GRAFANA_ADMIN_PASSWORD` placeholder `changeme-32-bytes-hex` → `openssl rand -hex 16` (the same value is also written to the secret file in step 4.5)
- `MINIO_METRICS_USER` placeholder `minioadmin` (default) → if not changed by user, leave as-is; if placeholder detected (`changeme` in the schema), generate 12-char random. **For v1: leave both MINIO_METRICS_USER and MINIO_METRICS_PASS at their `.env.example` defaults** — the Prometheus minio scrape no longer uses basic_auth (per `MINIO_PROMETHEUS_AUTH_TYPE=public`), so the values are vestigial. Just mirror them into secret files for parity.
- `MINIO_ROOT_USER` default `minioadmin` → leave as-is (sane default for dev).
- `MINIO_ROOT_PASSWORD` default `minioadmin` → leave as-is (sane default for dev; rotating it adds a moving part with no security benefit on a loopback single-user dev box).

User-supplied non-placeholder values are never overwritten.

### 4.5 Secret files (mirror to `monitoring/secrets/`)

For each of:
- `LITELLM_MASTER_KEY` value from `.env` → write to `monitoring/secrets/litellm_master_key` mode 644
- `GRAFANA_ADMIN_PASSWORD` value from `.env` → write to `monitoring/secrets/grafana_admin_password` mode 644
- `MINIO_METRICS_USER` value from `.env` → write to `monitoring/secrets/minio_metrics_user` mode 644
- `MINIO_METRICS_PASS` value from `.env` → write to `monitoring/secrets/minio_metrics_pass` mode 644

These are loopback-only single-user dev secrets; mode 644 is acceptable per existing README rationale. `chmod 644` after each write (in case the file pre-existed with different perms). The minio secret files are vestigial post-`MINIO_PROMETHEUS_AUTH_TYPE=public` fix but are still bind-mounted into the Prometheus container, so they must contain the matching values.

### 4.6 Compose up

`docker compose up -d`. Capture stdout/stderr. If any service fails to reach `running` within compose's own start phase (e.g. image pull fail), dump `docker compose ps` and exit 1.

### 4.7 Health-wait loop

Poll `docker compose ps --format json` for `litellm-proxy.State == "running"` AND `Health == "healthy"`. Same for `prometheus`, `grafana`, `alertmanager`, `milvus`, `redis`. Timeout: 120s per service. Print one progress line per poll (`[wait] litellm-proxy healthy (47s)`).

On timeout, dump `docker compose ps` and the failing service's last 50 log lines, then exit 1.

### 4.8 Invoke smoke

`exec scripts/smoke.sh`. Exit code propagated. If smoke fails, `up.sh` returns the same non-zero code.

### 4.9 Flags

```
up.sh                  # strict clean-slate; refuses if .env exists
up.sh --reset          # full wipe + re-bootstrap
up.sh --dry-run        # print plan, no writes, no docker compose, no smoke exec
up.sh --help           # usage to stdout
```

`--dry-run` covers: prereq check (real), env/secrets plan (printed), compose plan (printed), smoke plan (test list printed). No state mutation.

---

## 5. `smoke.sh` — test suite

### 5.1 Shape

Each test is a function `t_<name>` that:
- Exits 0 on pass, non-zero on fail.
- Prints `[PASS] <name>` or `[FAIL] <name>: <reason>` via the runner (function itself just runs the check).
- Optionally prints diagnostic context to stderr (curl status codes, log excerpts, hints).

Runner iterates a list of required tests, counts failures, prints final tally, exits 1 on any failure.

```bash
REQUIRED_TESTS=( t_proxy_ready t_embed ... )

fails=0
for t in "${REQUIRED_TESTS[@]}"; do
  if "$t"; then
    printf '[PASS] %s\n' "${t#t_}"
  else
    printf '[FAIL] %s\n' "${t#t_}"
    fails=$((fails+1))
  fi
done

echo '───'
printf 'Result: %d/%d passed\n' "$(( ${#REQUIRED_TESTS[@]} - fails ))" "${#REQUIRED_TESTS[@]}"
exit $(( fails > 0 ? 1 : 0 ))
```

### 5.2 Required core tests

| # | Function | What it checks |
|---|----------|----------------|
| 1 | `t_proxy_ready` | `GET http://127.0.0.1:4000/health/readiness` returns 200 with JSON status healthy |
| 2 | `t_embed` | `POST /v1/embeddings` with `Authorization: Bearer $LITELLM_MASTER_KEY` returns ≥1 vector (use model `harrier-oss-v1-0.6b` per README) |
| 3 | `t_redis_cache_write` | After `t_embed`, `docker compose exec redis redis-cli KEYS 'litellm_semantic_cache:*'` returns ≥1 key (write side; per README, read-side for embeddings is broken upstream) |
| 4 | `t_ui_login` | `POST http://127.0.0.1:4000/ui/login` with master_key returns 200/302 |
| 5 | `t_milvus_reachable` | TCP connect `milvus:19530` from inside `litellm` container: `docker compose exec litellm python3 -c "import socket; s=socket.create_connection(('milvus',19530),timeout=5); s.close(); print('ok')"` |
| 6 | `t_prometheus_targets_up` | `GET http://prometheus:9090/api/v1/targets` (via `docker compose exec`) — all 7 jobs (`litellm`, `redis`, `milvus`, `postgres`, `etcd`, `prometheus`, `minio`) report `health="up"` |
| 7 | `t_alertmanager_health` | `GET http://alertmanager:9093/api/v2/status` returns `success: true` |
| 8 | `t_grafana_health` | `GET http://grafana:3030/api/health` returns `{"database":"ok", ...}` |
| 9 | `t_redis_exporter` | `GET http://redis-exporter:9121/metrics` returns 200 with `redis_*` metrics |
| 10 | `t_postgres_exporter` | `GET http://postgres-exporter:9187/metrics` returns 200 with `pg_up==1` |

### 5.3 Required functional tests (hard-fail)

| # | Function | What it checks |
|---|----------|----------------|
| 11 | `t_chat_round_trip` | **Pre-check:** TCP connect `${LEMONADE_HOST_IP:-192.168.31.246}:13305` from inside `litellm` container. If unreachable → fail with clear `lemonade backend unreachable at <ip>:<port>` hint. Otherwise: `POST /v1/chat/completions` with `model=harrier-oss-v1-0.6b` and a simple prompt (`"Reply with the single word OK"`) returns `choices[0].message.content` non-empty |
| 12 | `t_semantic_cache_hit` | After `t_chat_round_trip`, send the same prompt again; verify Redis `litellm_semantic_cache:*` key count grew OR second response latency is < first / 2 (fall back to key-count check if upstream hit-path behavior is unreliable per README) |
| 13 | `t_grafana_queries_prometheus` | Authenticate to Grafana as admin (password from `monitoring/secrets/grafana_admin_password`); `POST /api/ds/query` with simple PromQL `up` returns ≥1 frame |

### 5.4 Test implementation notes

- **Bearer token source.** Read `LITELLM_MASTER_KEY` from `.env` (grep + cut) at script start, pass to tests that need it.
- **Grafana password source.** Read from `monitoring/secrets/grafana_admin_password` (first line).
- **Container-to-container URLs.** Tests 5–10, 12, 13 run their HTTP probes via `docker compose exec <svc> wget -qO- ...` or curl, so they hit the internal `litellm-net` bridge. The `litellm-proxy` and `grafana` services are also reachable on loopback (`127.0.0.1:4000` / `127.0.0.1:3030`) per compose — pick whichever is cleaner per test.
- **Timeouts.** HTTP probes use `--max-time 10` for fast checks, `--max-time 30` for chat. TCP connects use `timeout 5`.
- **Hints on failure.** When `t_prometheus_targets_up` fails, the runner prints `hint: docker compose logs prometheus`. When `t_chat_round_trip` fails on the lemonade pre-check, hint is `hint: ping <lemonade_ip> or check LEMONADE_HOST_IP in .env`.

---

## 6. Error handling

| Failure                         | Behavior                                                                                       |
|---------------------------------|------------------------------------------------------------------------------------------------|
| Missing prereq tool             | Exit 1 with `missing: <tool>` line before any work.                                            |
| `.env` exists, no `--reset`     | Exit 1 with `refusing to overwrite .env (use --reset to wipe and re-bootstrap)`.               |
| Compose up fails                | Dump `docker compose ps` and the failing service's last 50 log lines. Exit 1.                  |
| Health-wait timeout (any svc)   | Dump `docker compose ps` + failing svc's logs. Exit 1.                                         |
| Any smoke test fails            | Print `[FAIL] <name>: <reason>` + final tally. Exit 1.                                          |
| Functional test's dep unreachable | Fail with clear `lemonade backend unreachable at <ip>:<port>` + `hint:` line. Exit 1.        |

No mid-script `exit 0` shortcuts. No swallowing errors via `|| true`. `set -euo pipefail` enforces fail-fast.

---

## 7. Output

- Plain ASCII. No ANSI color (CI logs, terminals with no color).
- `[PASS] <name>` and `[FAIL] <name>` per test.
- `[wait] <service> healthy (Ns)` per poll during health-wait.
- Final line: `Result: 13/13 passed` or `Result: 11/13 passed (2 failed)`.
- On bootstrap refusal: a single line `refusing to overwrite .env ...`.

No `--json` mode (YAGNI). No `--verbose` mode (each test prints enough on its own).

---

## 8. Testing the scripts

- **`shellcheck -s bash scripts/up.sh scripts/smoke.sh`** must be clean. Add to README as a pre-commit / pre-merge check (manual for now; CI when added).
- **Manual `up.sh --reset` round-trip:** from a known-good state, run `./scripts/up.sh --reset`. Should end with `Result: 13/13 passed`.
- **Manual `smoke.sh` idempotency:** run `./scripts/smoke.sh` twice in a row. Both should pass (state changes are limited to cache writes, which the tests handle).
- **Manual `up.sh --dry-run`:** should print plan, no Docker invocations, no `.env` writes. Verify with `ls .env` (should not exist if it didn't before).

No unit-test framework for the bash scripts. They're small enough that shellcheck + manual run is sufficient verification. Adding `bats` or similar is YAGNI at this size.

---

## 9. README update

Add a `## Scripts` section after `## Bring up`:

```bash
./scripts/up.sh             # first-time bootstrap (refuses if .env exists)
./scripts/up.sh --reset     # full wipe + re-bootstrap
./scripts/up.sh --dry-run   # print plan, don't execute
./scripts/smoke.sh          # re-run the smoke suite anytime
```

Trim `## Bring up` and `## Smoke tests` sections to a short "Manual fallback" subsection that keeps the raw `docker compose` commands for emergencies. The scripts are the happy path.

---

## 10. Out of scope

- CI / GitHub Actions workflow that runs `scripts/up.sh` + `scripts/smoke.sh` in a clean VM.
- `scripts/down.sh` — README keeps `docker compose down` documentation.
- Pre-flight OS package installs (installing `jq` / `openssl` if missing). Prereq check fails with a clear message; the user installs.
- Parallelizing smoke tests. They're sequential, total runtime well under 60s.
- Mocking curl/docker for unit tests of individual `t_*` functions.
- Adding or removing any service from `docker-compose.yml`.

---

## 11. Known limitations (after this spec)

- **Lemonade host dependency.** `t_chat_round_trip` and `t_semantic_cache_hit` will fail on any machine that cannot reach `${LEMONADE_HOST_IP:-192.168.31.246}:13305`. This is by design (per resolved decision #7: hard-fail). Run the suite only on a host with LAN access to lemonade. A `--skip-functional` flag for air-gapped runs is YAGNI for v1.
- **Read-side semantic cache for `/v1/embeddings` is broken upstream** (LiteLLM bug, per README 2026-06-30 note). `t_redis_cache_write` checks the write side; `t_semantic_cache_hit` uses `/v1/chat/completions` where the read side is unaffected.
- **`shellcheck` enforcement is manual.** Add a pre-commit hook or CI lint job as a follow-on if desired.