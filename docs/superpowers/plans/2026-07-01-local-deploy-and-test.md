# Local Deploy & Test Scripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the existing manual `cp .env.example .env` + `docker compose up -d` + ad-hoc `curl` smoke workflow with two bash scripts: `scripts/up.sh` for one-command bootstrap and `scripts/smoke.sh` for a programmatic 13-test end-to-end suite. Strict clean-slate re-run policy.

**Architecture:** Pure bash + `docker compose` + `curl` + `jq` + `openssl`. `up.sh` is a fail-fast bootstrap (prereq → clean-slate → env → secrets → compose up → health-wait → exec smoke). `smoke.sh` is a standalone test runner (independent of bootstrap, re-runnable). Both `set -euo pipefail`. No shared library file; cross-call is `up.sh → smoke.sh` only.

**Tech Stack:** Bash 4+, Docker Compose v2, `curl`, `jq`, `openssl`, `shellcheck -s bash` for lint.

**Spec:** `docs/superpowers/specs/2026-07-01-local-deploy-and-test-design.md`

---

## Global Constraints

- Working directory: `/home/john/Projects/litellm-stack/`
- All paths in this plan are **relative to the working directory** unless prefixed with `/`.
- Bash is the host shell (Fedora 45, bash 5.x). POSIX sh NOT sufficient (uses arrays, `[[ ]]`, `pipefail`).
- Every task ends with a commit. Use `git add` for the specific files created/changed in that task.
- Commit message format: `type: short description` — `chore:`, `feat:`, `docs:`, `test:`, `fix:`.
- Both scripts MUST pass `shellcheck -s bash` clean before final commit.
- `set -euo pipefail` is mandatory in both scripts.
- Both scripts MUST be `chmod +x`.
- No new dependencies. Tools required on host: `docker`, `docker compose`, `curl`, `jq`, `openssl`. `up.sh` prereq check fails with clear `missing: <tool>` line if any absent.
- Loopback bind only (`127.0.0.1:4000` for litellm, `127.0.0.1:3030` for grafana) is the host exposure — preserved.
- Re-run policy: `up.sh` refuses to overwrite `.env` unless `--reset` is passed. No idempotency for the env file; only the smoke suite is idempotent (cumulative key writes are expected).
- Lemonade backend is on `${LEMONADE_HOST_IP:-192.168.31.246}:13305` per existing `.env.example` and `docker-compose.yml` `extra_hosts`. Suite hard-fails if unreachable.
- Functional tests are required (no `--skip-functional` flag — YAGNI per spec).
- LLM-generated suite output: plain ASCII, no ANSI color. CI logs may strip color.

---

## File Structure

| Path | Purpose |
|---|---|
| `scripts/up.sh` (create) | Bootstrap: prereq → clean-slate → env → secrets → compose up → health-wait → exec smoke.sh |
| `scripts/smoke.sh` (create) | Standalone test runner with 13 required tests, plain ASCII pass/fail output, exit code propagation |
| `README.md` (modify) | Add `## Scripts` section after `## Bring up`; trim `## Bring up` and `## Smoke tests` into a `## Manual fallback` subsection |

`scripts/` is a new directory. The two scripts do not share a library file. Cross-call is `up.sh` shelling out to `smoke.sh` (a sibling in the same directory).

---

## Task 1: Scaffold `scripts/up.sh` — flag parser, `--help`, prereq check, working dir

**Files:**
- Create: `scripts/up.sh`

**Interfaces:**
- Consumes: `--reset`, `--dry-run`, `--help` flags; no environment variables.
- Produces: a `up.sh` that exits cleanly on `--help`, fails with `missing: <tool>` on missing prereqs, and is callable from any working directory.

- [ ] **Step 1: Create `scripts/` directory and the `up.sh` skeleton**

```bash
mkdir -p scripts
chmod 755 scripts
```

Create `scripts/up.sh` with this content (full file):

```bash
#!/usr/bin/env bash
# scripts/up.sh — bootstrap the litellm-stack Docker Compose stack.
# See docs/superpowers/specs/2026-07-01-local-deploy-and-test-design.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Flags ───────────────────────────────────────────────────────────
RESET=0
DRY_RUN=0
print_help() {
  cat <<EOF
Usage: up.sh [flag]

  (no flag)    Strict clean-slate bootstrap. Refuses if .env exists.
  --reset      Full wipe (docker compose down -v) then re-bootstrap.
  --dry-run    Print the plan, do not write any files or run docker compose.
  --help       Show this help.
EOF
}

case "${1:-}" in
  --reset)  RESET=1 ;;
  --dry-run) DRY_RUN=1 ;;
  --help|-h) print_help; exit 0 ;;
  "")       ;;
  *)        echo "unknown flag: $1" >&2; print_help >&2; exit 1 ;;
esac

# ── Working dir ──────────────────────────────────────────────────────
cd "$REPO_ROOT"
[[ -f docker-compose.yml ]] || { echo "not in repo root (no docker-compose.yml at $REPO_ROOT)" >&2; exit 1; }

# ── Prereq check ─────────────────────────────────────────────────────
check_prereqs() {
  local missing=()
  command -v docker   >/dev/null 2>&1 || missing+=(docker)
  command -v curl     >/dev/null 2>&1 || missing+=(curl)
  command -v jq       >/dev/null 2>&1 || missing+=(jq)
  command -v openssl  >/dev/null 2>&1 || missing+=(openssl)
  if ! docker compose version >/dev/null 2>&1; then
    missing+=("docker compose plugin")
  fi
  if (( ${#missing[@]} > 0 )); then
    echo "missing: ${missing[*]}" >&2
    exit 1
  fi
}
check_prereqs

# ── Placeholder for the rest (filled by later tasks) ─────────────────
echo "[ok] prereqs + flags parsed; next tasks add env, secrets, compose up."
```

- [ ] **Step 2: Make the script executable and lint it**

```bash
chmod +x scripts/up.sh
shellcheck -s bash scripts/up.sh
```

Expected: shellcheck exits 0. If it reports any finding, fix and re-run until clean.

- [ ] **Step 3: Verify `--help` works**

```bash
./scripts/up.sh --help
```

Expected: prints the usage block, exits 0.

- [ ] **Step 4: Verify missing-tool failure mode**

Temporarily mask a tool to confirm the prereq check fires:

```bash
PATH="/usr/local/bin:/usr/bin" ./scripts/up.sh 2>&1 | head -5
```

If `jq` is at `/usr/bin/jq` (it is on Fedora), this won't trigger the missing case. Instead, run:

```bash
( PATH="/nonexistent" ./scripts/up.sh; echo "exit=$?" ) 2>&1 | head -5
```

Expected: `missing:` line + non-zero exit. (If shellcheck complains about the `PATH="/nonexistent"` form, just confirm the original `check_prereqs` function fires by removing the `command -v docker` check temporarily and re-running — but a cleaner test: `docker compose version` is the easiest to test. Skip this step if you've already verified prereqs pass on the dev box.)

Acceptance: `check_prereqs` exists and would fail with `missing: <tool>` on a stripped PATH. Don't actually break PATH; just review the function.

- [ ] **Step 5: Verify script runs from any working directory**

```bash
cd /tmp && /home/john/Projects/litellm-stack/scripts/up.sh --help
```

Expected: prints usage, exits 0. (Confirms `cd "$REPO_ROOT"` works via `BASH_SOURCE`.)

- [ ] **Step 6: Commit**

```bash
git add scripts/up.sh
git commit -m "feat(scripts): scaffold up.sh with flag parser, prereq check, --help"
```

---

## Task 2: `up.sh` — clean-slate enforcement + `--reset`

**Files:**
- Modify: `scripts/up.sh`

**Interfaces:**
- Consumes: `$RESET` from Task 1's flag parser; `.env` file presence in `$REPO_ROOT`.
- Produces: refuses to run if `.env` exists and `$RESET=0`; runs `docker compose down -v` if `$RESET=1`. Honors `$DRY_RUN`.

- [ ] **Step 1: Add the clean-slate block after the prereq check**

Replace the placeholder line at the end of `scripts/up.sh`:

```bash
# ── Placeholder for the rest (filled by later tasks) ─────────────────
echo "[ok] prereqs + flags parsed; next tasks add env, secrets, compose up."
```

with:

```bash
# ── Clean-slate enforcement ─────────────────────────────────────────
if [[ -f .env && $RESET -ne 1 ]]; then
  mtime=$(stat -c '%y' .env 2>/dev/null || stat -f '%Sm' .env 2>/dev/null || echo "unknown")
  size=$(wc -c < .env 2>/dev/null || echo "?")
  echo "refusing to overwrite .env (mtime=$mtime, size=$size bytes)" >&2
  echo "use --reset to wipe and re-bootstrap" >&2
  exit 1
fi

# ── --reset: full wipe ──────────────────────────────────────────────
if [[ $RESET -eq 1 ]]; then
  echo "[reset] docker compose down -v"
  if [[ $DRY_RUN -ne 1 ]]; then
    docker compose down -v
  fi
fi

# ── Placeholder for env generation (filled by Task 3) ───────────────
echo "[ok] clean-slate enforced; next task adds env generation."
```

- [ ] **Step 2: Lint and verify refusal**

```bash
shellcheck -s bash scripts/up.sh
```

Expected: clean.

If `.env` exists, verify the refusal:

```bash
[[ -f .env ]] && ./scripts/up.sh 2>&1 | head -3
```

Expected: `refusing to overwrite .env` + hint. Exit non-zero. If `.env` does NOT exist, skip this verification (Task 3's env generation will create it).

- [ ] **Step 3: Verify `--dry-run` does NOT invoke docker compose**

```bash
( cd /tmp && /home/john/Projects/litellm-stack/scripts/up.sh --dry-run --reset 2>&1 ) | head -10
```

Expected: prints `[reset] docker compose down -v` then `clean-slate enforced` placeholder, no actual docker invocation. If you want to be paranoid, `strace -e trace=execve ./scripts/up.sh --dry-run --reset 2>&1 | grep docker` should show no `docker` exec.

- [ ] **Step 4: Commit**

```bash
git add scripts/up.sh
git commit -m "feat(scripts): add clean-slate enforcement and --reset to up.sh"
```

---

## Task 3: `up.sh` — env file generation + secret file mirroring

**Files:**
- Modify: `scripts/up.sh`

**Interfaces:**
- Consumes: `.env.example` (must exist in `$REPO_ROOT`); secret file target paths in `monitoring/secrets/`.
- Produces: `.env` with `LITELLM_MASTER_KEY` and `GRAFANA_ADMIN_PASSWORD` regenerated; mirrored secret files in `monitoring/secrets/{litellm_master_key,grafana_admin_password,minio_metrics_user,minio_metrics_pass}` mode 644.

- [ ] **Step 1: Replace the placeholder with the env + secret generation block**

Replace this line in `scripts/up.sh`:

```bash
# ── Placeholder for env generation (filled by Task 3) ───────────────
echo "[ok] clean-slate enforced; next task adds env generation."
```

with:

```bash
# ── Env file generation ─────────────────────────────────────────────
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] would copy .env.example -> .env"
  echo "[dry-run] would regenerate LITELLM_MASTER_KEY (openssl rand -hex 32)"
  echo "[dry-run] would regenerate GRAFANA_ADMIN_PASSWORD (openssl rand -hex 16)"
  echo "[dry-run] would write secret files: monitoring/secrets/{litellm_master_key,grafana_admin_password,minio_metrics_user,minio_metrics_pass}"
  echo "[dry-run] would chmod 644 all 4 secret files"
else
  cp .env.example .env

  new_key=$(openssl rand -hex 32)
  sed -i "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=${new_key}|" .env

  new_gf=$(openssl rand -hex 16)
  sed -i "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=${new_gf}|" .env

  # Pull final values (in case the user customized them) and mirror to secret files.
  final_key=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d= -f2-)
  final_gf=$(grep '^GRAFANA_ADMIN_PASSWORD=' .env | cut -d= -f2-)
  final_minio_user=$(grep '^MINIO_METRICS_USER=' .env | cut -d= -f2-)
  final_minio_pass=$(grep '^MINIO_METRICS_PASS=' .env | cut -d= -f2-)

  mkdir -p monitoring/secrets
  printf '%s' "$final_key"       > monitoring/secrets/litellm_master_key
  printf '%s' "$final_gf"        > monitoring/secrets/grafana_admin_password
  printf '%s' "$final_minio_user" > monitoring/secrets/minio_metrics_user
  printf '%s' "$final_minio_pass" > monitoring/secrets/minio_metrics_pass
  chmod 644 monitoring/secrets/litellm_master_key \
           monitoring/secrets/grafana_admin_password \
           monitoring/secrets/minio_metrics_user \
           monitoring/secrets/minio_metrics_pass

  echo "[ok] .env generated; 4 secret files written mode 644."
fi
```

- [ ] **Step 2: Lint**

```bash
shellcheck -s bash scripts/up.sh
```

Expected: clean. If shellcheck warns about `printf '%s'`, switch to `printf '%s\n'` only if the existing perms in `monitoring/secrets/` had trailing newlines. (Trailing newlines are fine — they don't break Prometheus's `credentials_file` reader, which trims whitespace. Keep `printf '%s'` for byte-exact mirror of the env value.)

- [ ] **Step 3: Manual verification of dry-run output**

```bash
( cd /tmp && /home/john/Projects/litellm-stack/scripts/up.sh --dry-run ) 2>&1 | head -10
```

Expected: prints the `[dry-run] would ...` lines, no actual file creation. Verify no `.env` was touched:

```bash
ls -la .env 2>&1 | head -1
```

Expected: `.env` unchanged from its prior state (or `No such file` if it didn't exist before).

- [ ] **Step 4: Manual verification of a real `--reset` run (without compose up)**

The next task adds compose up + health wait. To verify JUST env+secret generation works end-to-end without the rest, temporarily make a one-off script that sources the env + secret block. OR run the full `up.sh --reset` and inspect artifacts after it fails at the compose-up step (Task 4).

Easier: run the full bootstrap end-to-end in Task 4. For Task 3, just verify the dry-run. Skip the live end-to-end here.

- [ ] **Step 5: Commit**

```bash
git add scripts/up.sh
git commit -m "feat(scripts): add env file generation and secret file mirroring to up.sh"
```

---

## Task 4: `up.sh` — compose up + health-wait loop + exec smoke

**Files:**
- Modify: `scripts/up.sh`

**Interfaces:**
- Consumes: `.env` and `monitoring/secrets/*` from Task 3; running Docker daemon; existing `docker-compose.yml`.
- Produces: stack brought up; waits for `litellm-proxy`, `prometheus`, `grafana`, `alertmanager`, `milvus`, `redis` to be `healthy`; shells out to `scripts/smoke.sh` (which doesn't exist yet — Task 6 onward).

- [ ] **Step 1: Add `wait_healthy` and the compose-up block**

Add at the END of `scripts/up.sh` (after the env generation block, before any final echoes):

```bash
# ── Compose up ──────────────────────────────────────────────────────
wait_healthy() {
  local svc="$1" timeout="$2"
  local start=$SECONDS
  while (( SECONDS - start < timeout )); do
    if docker compose ps "$svc" 2>/dev/null | grep -q "(healthy)"; then
      printf '[wait] %s healthy (%ds)\n' "$svc" "$((SECONDS - start))"
      return 0
    fi
    sleep 2
  done
  printf '[fail] %s not healthy in %ds\n' "$svc" "$timeout" >&2
  docker compose ps >&2 || true
  docker compose logs --tail 50 "$svc" >&2 || true
  return 1
}

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] would run: docker compose up -d"
  echo "[dry-run] would wait for healthy: litellm-proxy, redis, milvus, prometheus, grafana, alertmanager"
  echo "[dry-run] would exec: scripts/smoke.sh"
else
  echo "[up] docker compose up -d"
  docker compose up -d

  for svc in litellm-proxy redis milvus prometheus grafana alertmanager; do
    wait_healthy "$svc" 120
  done

  echo "[ok] all services healthy; running smoke."
  exec "$SCRIPT_DIR/smoke.sh"
fi
```

- [ ] **Step 2: Lint**

```bash
shellcheck -s bash scripts/up.sh
```

Expected: clean.

- [ ] **Step 3: Dry-run the full bootstrap to confirm plan output**

```bash
./scripts/up.sh --dry-run --reset 2>&1 | head -30
```

Expected (no `.env` present, so this is a clean dry-run):
```
[reset] docker compose down -v
[dry-run] would copy .env.example -> .env
[dry-run] would regenerate LITELLM_MASTER_KEY (openssl rand -hex 32)
[dry-run] would regenerate GRAFANA_ADMIN_PASSWORD (openssl rand -hex 16)
[dry-run] would write secret files: ...
[dry-run] would chmod 644 all 4 secret files
[dry-run] would run: docker compose up -d
[dry-run] would wait for healthy: litellm-proxy, redis, milvus, prometheus, grafana, alertmanager
[dry-run] would exec: scripts/smoke.sh
```

- [ ] **Step 4: Live `up.sh --reset` end-to-end (full bootstrap)**

This is the first live run. It will fail at `exec scripts/smoke.sh` because smoke.sh doesn't exist yet — that's expected for this task.

```bash
./scripts/up.sh --reset
```

Expected: all 6 services report `[wait] <svc> healthy`. Final failure on `exec scripts/smoke.sh` with "No such file or directory". Stack is up and healthy — that's the deliverable for this task. Smoke is the next batch of tasks.

- [ ] **Step 5: Verify the stack is actually up**

```bash
docker compose ps
```

Expected: all 11 services show `Up` (most with `healthy`, some without healthcheck).

- [ ] **Step 6: Commit**

```bash
git add scripts/up.sh
git commit -m "feat(scripts): add compose up, health-wait, and smoke exec to up.sh"
```

---

## Task 5: `up.sh --dry-run` — confirmed no writes, no docker invocations

**Files:**
- Modify: `scripts/up.sh` (only if dry-run coverage is incomplete)

**Interfaces:**
- Consumes: any flag combination.
- Produces: `--dry-run` outputs the full plan and mutates no state.

The previous tasks already added `--dry-run` branches in steps 1, 3, and 4. This task is a verification pass.

- [ ] **Step 1: Confirm `--dry-run` covers every state-mutating branch**

Audit `scripts/up.sh` for any branch that mutates state without checking `$DRY_RUN`:

- `[ -f .env ] && RESET=0` refusal — pure read, no mutation. OK.
- `docker compose down -v` (in `--reset` block) — wrapped in `if [[ $DRY_RUN -ne 1 ]]`. OK.
- Env generation block — wrapped in `if/else` on `$DRY_RUN`. OK.
- `wait_healthy` and `docker compose up -d` — wrapped. OK.
- `exec smoke.sh` — wrapped. OK.

If any branch is missing the dry-run guard, add it now.

- [ ] **Step 2: Verify dry-run leaves the filesystem untouched**

```bash
ls -la .env monitoring/secrets/ 2>&1 | head -10
./scripts/up.sh --dry-run --reset 2>&1 | tail -20
ls -la .env monitoring/secrets/ 2>&1 | head -10
```

Expected: file mtimes/sizes identical before and after the dry-run.

- [ ] **Step 3: Verify dry-run does not exec docker**

```bash
strace -f -e trace=execve -o /tmp/up.strace ./scripts/up.sh --dry-run --reset 2>&1 | head -5
grep -c '"/usr/bin/docker"' /tmp/up.strace || true
```

Expected: 0 docker invocations. (If strace isn't available on the dev box, skip this step — the code review in step 1 is the real verification.)

- [ ] **Step 4: Commit (only if step 1 required a fix)**

```bash
git add scripts/up.sh
git commit -m "fix(scripts): confirm --dry-run covers all state-mutating branches"
```

If no fix was needed, skip this commit. (Check `git status` — if clean, no commit.)

---

## Task 6: `smoke.sh` — runner loop + tests 1–5 (proxy health, embed, cache write, UI login, milvus)

**Files:**
- Create: `scripts/smoke.sh`

**Interfaces:**
- Consumes: `.env` (for `LITELLM_MASTER_KEY`); `monitoring/secrets/grafana_admin_password` (later tests).
- Produces: a test runner that prints `[PASS] <name>` / `[FAIL] <name>` lines and a final `Result: N/13 passed` tally, exiting 1 on any failure.

- [ ] **Step 1: Create `scripts/smoke.sh` with the runner and tests 1–5**

Create `scripts/smoke.sh` with this content (full file):

```bash
#!/usr/bin/env bash
# scripts/smoke.sh — end-to-end smoke test for the litellm-stack.
# See docs/superpowers/specs/2026-07-01-local-deploy-and-test-design.md
# Run standalone: ./scripts/smoke.sh
# Called by up.sh at the end of bootstrap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

KEY=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d= -f2-)
LEMONADE_HOST_IP=$(grep '^LEMONADE_HOST_IP=' .env | cut -d= -f2-)

# ── Test functions ──────────────────────────────────────────────────
# Each function returns 0 on pass, non-zero on fail. Print to stderr
# for diagnostic context on failure.

t_proxy_ready() {
  curl -sf --max-time 10 http://127.0.0.1:4000/health/readiness \
    | jq -e '.status == "healthy"' >/dev/null
}

t_embed() {
  curl -sf --max-time 30 -X POST http://127.0.0.1:4000/v1/embeddings \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"harrier-oss-v1-0.6b","input":"hello world"}' \
    | jq -e '(.data | length) > 0 and (.data[0].embedding | length) > 0' >/dev/null
}

t_redis_cache_write() {
  docker compose exec -T redis redis-cli KEYS 'litellm_semantic_cache:*' \
    | grep -q 'litellm_semantic_cache:'
}

t_ui_login() {
  # POST /ui/login with master_key as password (form-encoded).
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -X POST http://127.0.0.1:4000/ui/login \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=admin" \
    --data-urlencode "password=$KEY")
  [[ $code == 200 || $code == 302 ]]
}

t_milvus_reachable() {
  docker compose exec -T litellm python3 -c \
    "import socket; s=socket.create_connection(('milvus',19530),timeout=5); s.close()" >/dev/null
}

# ── Runner ──────────────────────────────────────────────────────────
REQUIRED_TESTS=(
  t_proxy_ready t_embed t_redis_cache_write t_ui_login t_milvus_reachable
  t_prometheus_targets_up t_alertmanager_health t_grafana_health
  t_redis_exporter t_postgres_exporter
  t_chat_round_trip t_semantic_cache_hit t_grafana_queries_prometheus
)

fails=0
for t in "${REQUIRED_TESTS[@]}"; do
  if "$t" 2>/dev/null; then
    printf '[PASS] %s\n' "${t#t_}"
  else
    printf '[FAIL] %s\n' "${t#t_}"
    fails=$((fails+1))
  fi
done

echo '───'
total=${#REQUIRED_TESTS[@]}
printf 'Result: %d/%d passed\n' "$((total - fails))" "$total"
exit $(( fails > 0 ? 1 : 0 ))
```

- [ ] **Step 2: chmod + lint**

```bash
chmod +x scripts/smoke.sh
shellcheck -s bash scripts/smoke.sh
```

Expected: shellcheck may flag `$LEMONADE_HOST_IP` as unused (it IS used in Task 8's chat test). Suppress with `# shellcheck disable=SC2034` if it complains, or ignore the warning for now and add the disable in Task 8.

If shellcheck flags unused `LEMONADE_HOST_IP`: add `# shellcheck disable=SC2034` above the line and re-run.

- [ ] **Step 3: Run smoke.sh — expect tests 1–5 to pass, 6–13 to fail (functions not yet defined)**

```bash
./scripts/smoke.sh
```

Expected: 5 PASS lines + 8 FAIL lines (one per undefined function). Result: `5/13 passed`. Exit 1. (This is the red-phase for the TDD pattern adapted to bash — we scaffold the runner, watch it fail on the missing tests, then add the tests.)

- [ ] **Step 4: Commit**

```bash
git add scripts/smoke.sh
git commit -m "feat(smoke): scaffold runner + 5 core tests (proxy, embed, cache, ui, milvus)"
```

---

## Task 7: `smoke.sh` — tests 6–10 (observability: prometheus targets, alertmanager, grafana, exporters)

**Files:**
- Modify: `scripts/smoke.sh`

**Interfaces:**
- Consumes: prometheus / alertmanager / grafana / exporter endpoints reachable via `docker compose exec` on the `litellm-net` bridge.
- Produces: 5 more passing tests, bringing total to 10.

- [ ] **Step 1: Add the observability test functions**

Insert these functions in `scripts/smoke.sh` after `t_milvus_reachable` and before the `# ── Runner` divider:

```bash
t_prometheus_targets_up() {
  # All 7 scrape jobs must report health="up".
  local down
  down=$(docker compose exec -T prometheus wget -qO- http://localhost:9090/api/v1/targets \
    | jq -r '[.data.activeTargets[] | select(.health != "up") | .labels.job] | join(",")')
  [[ -z $down ]]
}

t_alertmanager_health() {
  docker compose exec -T alertmanager wget -qO- http://localhost:9093/api/v2/status \
    | jq -e '.success' >/dev/null
}

t_grafana_health() {
  docker compose exec -T grafana wget -qO- http://localhost:3030/api/health \
    | jq -e '.database == "ok"' >/dev/null
}

t_redis_exporter() {
  docker compose exec -T redis-exporter wget -qO- http://localhost:9121/metrics \
    | grep -q '^redis_up'
}

t_postgres_exporter() {
  docker compose exec -T postgres-exporter wget -qO- http://localhost:9187/metrics \
    | grep -q '^pg_up 1'
}
```

- [ ] **Step 2: Lint**

```bash
shellcheck -s bash scripts/smoke.sh
```

Expected: clean. (`wget` may not be in every exporter image — if it isn't, the exec will fail. Fallback: use `curl` if wget fails. The exporter images used in compose all have `wget` via the base image, but verify with a one-off `docker compose exec redis-exporter which wget` if unsure.)

- [ ] **Step 3: Run smoke.sh — expect 10 pass, 3 fail**

```bash
./scripts/smoke.sh
```

Expected: 10 PASS + 3 FAIL (chat/semantic_cache/grafana_query still missing). Result: `10/13 passed`.

- [ ] **Step 4: If `t_prometheus_targets_up` reports DOWN on minio, investigate**

The latest commit (`d9341f0`) made minio metrics public, so it should be UP. If it's DOWN, the scrape job config may be off. Check:

```bash
docker compose exec prometheus wget -qO- http://localhost:9090/api/v1/targets \
  | jq -r '.data.activeTargets[] | "\(.labels.job) \(.health) \(.lastError // "ok")"'
```

If `minio` shows DOWN, the most likely cause is `minio` container restarted after the env-var change and is still booting. Wait 30s and re-run smoke. If it persists, run `docker compose logs minio --tail 30` and check for `MINIO_PROMETHEUS_AUTH_TYPE` errors.

- [ ] **Step 5: Commit**

```bash
git add scripts/smoke.sh
git commit -m "feat(smoke): add 5 observability tests (prometheus, alertmanager, grafana, exporters)"
```

---

## Task 8: `smoke.sh` — tests 11–13 (functional: chat round-trip, semantic cache hit, grafana→prometheus query)

**Files:**
- Modify: `scripts/smoke.sh`

**Interfaces:**
- Consumes: `${LEMONADE_HOST_IP:-192.168.31.246}:13305` reachable from the `litellm` container; grafana admin password from `monitoring/secrets/grafana_admin_password`.
- Produces: 3 more passing tests, bringing total to 13/13.

- [ ] **Step 1: Add the functional test functions**

Insert these functions in `scripts/smoke.sh` after `t_postgres_exporter` and before the `# ── Runner` divider:

```bash
t_chat_round_trip() {
  # Pre-check: lemonade backend reachable from inside the litellm container.
  if ! docker compose exec -T litellm python3 -c \
      "import socket; s=socket.create_connection(('host.docker.internal',13305),timeout=5); s.close()" >/dev/null 2>&1; then
    echo "lemonade backend unreachable at ${LEMONADE_HOST_IP:-192.168.31.246}:13305" >&2
    echo "hint: ping ${LEMONADE_HOST_IP:-192.168.31.246} or check LEMONADE_HOST_IP in .env" >&2
    return 1
  fi

  curl -sf --max-time 30 -X POST http://127.0.0.1:4000/v1/chat/completions \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"harrier-oss-v1-0.6b","messages":[{"role":"user","content":"Reply with the single word OK"}],"max_tokens":16}' \
    | jq -e '(.choices | length) > 0 and (.choices[0].message.content | length) > 0' >/dev/null
}

t_semantic_cache_hit() {
  # Send the same chat prompt twice; verify Redis cache key count grew.
  # Per README, read-side cache hit for chat is not guaranteed upstream;
  # the write side IS — so we verify the write happened.
  local before after
  before=$(docker compose exec -T redis redis-cli KEYS 'litellm_semantic_cache:*' | wc -l)
  curl -sf --max-time 30 -X POST http://127.0.0.1:4000/v1/chat/completions \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"harrier-oss-v1-0.6b","messages":[{"role":"user","content":"smoke cache probe"}],"max_tokens":8}' >/dev/null
  after=$(docker compose exec -T redis redis-cli KEYS 'litellm_semantic_cache:*' | wc -l)
  (( after > before ))
}

t_grafana_queries_prometheus() {
  # Authenticate to Grafana as admin and run a simple PromQL query through the datasource.
  local gf_pass prometheus_datasource_id
  gf_pass=$(cat monitoring/secrets/grafana_admin_password)

  # Find the Prometheus datasource UID via the Grafana API.
  prometheus_datasource_id=$(curl -sf --max-time 10 -u "admin:${gf_pass}" \
    http://127.0.0.1:3030/api/datasources \
    | jq -r '.[] | select(.type == "prometheus") | .uid' \
    | head -1)
  [[ -n $prometheus_datasource_id ]] || return 1

  # Run `up` query.
  local frames
  frames=$(curl -sf --max-time 10 -u "admin:${gf_pass}" \
    -X POST http://127.0.0.1:3030/api/ds/query \
    -H "Content-Type: application/json" \
    -d "{\"queries\":[{\"refId\":\"A\",\"datasource\":{\"type\":\"prometheus\",\"uid\":\"${prometheus_datasource_id}\"},\"expr\":\"up\"}],\"from\":\"now-5m\",\"to\":\"now\"}" \
    | jq -r '.results.A.frames | length')
  (( frames > 0 ))
}
```

- [ ] **Step 2: Remove the shellcheck disable on `LEMONADE_HOST_IP` (if you added one in Task 6)**

`LEMONADE_HOST_IP` is now used in `t_chat_round_trip`. Remove any `# shellcheck disable=SC2034` line that was added in Task 6.

- [ ] **Step 3: Lint**

```bash
shellcheck -s bash scripts/smoke.sh
```

Expected: clean. If shellcheck flags the complex JSON in `t_grafana_queries_prometheus`, suppress with `# shellcheck disable=SC2155` (assign-and-exit) if needed.

- [ ] **Step 4: Run smoke.sh — expect 13/13**

```bash
./scripts/smoke.sh
```

Expected: 13 PASS lines, `Result: 13/13 passed`, exit 0.

If `t_chat_round_trip` fails on the lemonade pre-check: confirm `${LEMONADE_HOST_IP:-192.168.31.246}` is reachable. The dev box should have it on `192.168.31.246:13305`.

If `t_semantic_cache_hit` fails: confirm the chat round-trip produced output. The cache key write is downstream of a successful chat completion.

If `t_grafana_queries_prometheus` fails: check `curl -u admin:$GF_PASS http://127.0.0.1:3030/api/datasources` returns at least one Prometheus datasource. If empty, the Grafana provisioning is broken — investigate `monitoring/grafana/provisioning/datasources/`.

- [ ] **Step 5: Re-run smoke.sh — confirm idempotency**

```bash
./scripts/smoke.sh && ./scripts/smoke.sh
```

Expected: both runs show `13/13 passed`. (The semantic cache test will see the cache key already exists from the first run — that's why the test reads `before`, sends one chat, and checks `after > before`.)

- [ ] **Step 6: Commit**

```bash
git add scripts/smoke.sh
git commit -m "feat(smoke): add 3 functional tests (chat, cache hit, grafana->prometheus query)"
```

---

## Task 9: README update — add `## Scripts` section, trim manual fallback

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: existing `## Bring up` and `## Smoke tests` sections.
- Produces: a new top-level `## Scripts` section; existing `## Bring up` and `## Smoke tests` content moved into a `## Manual fallback` subsection for emergencies.

- [ ] **Step 1: Read current README to find section boundaries**

```bash
grep -n '^## ' README.md
```

Expected output:
```
3:## Layout
7:## Bring up
24:## Monitoring
30:## Known limitations
36:## Smoke tests
67:## Tearing down
73:## Adding chat completions
```

- [ ] **Step 2: Add `## Scripts` section right after `## Bring up`**

Insert this block between line 23 (end of `## Bring up`) and line 24 (`## Monitoring`):

```markdown
## Scripts

```bash
./scripts/up.sh             # first-time bootstrap (refuses if .env exists)
./scripts/up.sh --reset     # full wipe + re-bootstrap
./scripts/up.sh --dry-run   # print plan, don't execute
./scripts/smoke.sh          # re-run the smoke suite anytime
```

`up.sh` is the happy path for bringing the stack up. It enforces strict clean-slate (refuses to overwrite `.env` unless `--reset` is passed), generates secrets, brings the compose stack up, waits for services to be healthy, and runs the smoke suite at the end. `smoke.sh` is callable independently to re-verify an already-up stack.

See `docs/superpowers/specs/2026-07-01-local-deploy-and-test-design.md` for the full design.
```

- [ ] **Step 3: Wrap the existing `## Bring up` and `## Smoke tests` content into `## Manual fallback`**

Replace the `## Bring up` heading with `## Manual fallback` and prepend a sentence:

```markdown
## Manual fallback

The scripts above handle the happy path. If `scripts/up.sh` is unavailable (e.g. partial clone), the raw `docker compose` commands still work:
```

Then keep the original `cp .env.example .env` / `docker compose up -d` block, the `## Smoke tests` heading + 5 numbered steps, all under this single `## Manual fallback` section.

The resulting `## Manual fallback` should be roughly the concatenation of the old `## Bring up` and `## Smoke tests` content, indented as one section.

- [ ] **Step 4: Verify the new section structure**

```bash
grep -n '^## ' README.md
```

Expected output:
```
3:## Layout
7:## Manual fallback
30:## Scripts
45:## Monitoring
51:## Known limitations
57:## Tearing down
63:## Adding chat completions
```

(The line numbers will vary. The 4 sections in the expected order are: Layout, Manual fallback, Scripts, Monitoring, Known limitations, Tearing down, Adding chat completions.)

- [ ] **Step 5: Render-test the README**

```bash
command -v grip >/dev/null 2>&1 && grip -b README.md || echo "skip render test (grip not installed)"
```

If `grip` (GitHub README Instant Preview) is installed, it serves the README at `http://localhost:6419` so you can verify the formatting. Skip if not installed.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: add Scripts section, consolidate Bring up + Smoke tests into Manual fallback"
```

---

## Task 10: Final verification — shellcheck clean + full `up.sh --reset` round-trip

**Files:** (none modified — verification only)

- [ ] **Step 1: shellcheck clean across both scripts**

```bash
shellcheck -s bash scripts/up.sh scripts/smoke.sh && echo "shellcheck: clean"
```

Expected: `shellcheck: clean`. If anything is flagged, fix it inline (most common: unused variable, unquoted glob) and re-run.

- [ ] **Step 2: Run the full bootstrap end-to-end via `up.sh --reset`**

```bash
./scripts/up.sh --reset
```

Expected:
- `[reset] docker compose down -v`
- `.env` + secret files generated.
- `docker compose up -d` brings all 11 services up.
- 6 `[wait] <svc> healthy (Ns)` lines (litellm-proxy, redis, milvus, prometheus, grafana, alertmanager).
- `[ok] all services healthy; running smoke.`
- 13 PASS lines.
- `Result: 13/13 passed`
- exit 0.

Total wall time: ~60–90s for first bring-up (Milvus init is the slow part), ~30s for the smoke suite.

- [ ] **Step 3: Re-run smoke.sh standalone**

```bash
./scripts/smoke.sh
```

Expected: `13/13 passed`, exit 0.

- [ ] **Step 4: Confirm `up.sh` (no flag) refuses on a populated stack**

```bash
./scripts/up.sh
```

Expected: `refusing to overwrite .env ...` + `use --reset to wipe and re-bootstrap`, exit 1.

- [ ] **Step 5: Update the progress ledger**

```bash
cat >> .superpowers/sdd/progress.md <<EOF

### Local deploy & test scripts (10-task plan)

- scripts/up.sh: strict clean-slate bootstrap; --reset/--dry-run/--help flags; shellcheck clean.
- scripts/smoke.sh: 13 required tests (5 core + 5 observability + 3 functional); exit 0/1.
- README: \`## Scripts\` section added; \`## Bring up\` + \`## Smoke tests\` collapsed into \`## Manual fallback\`.
- Spec: docs/superpowers/specs/2026-07-01-local-deploy-and-test-design.md (approved).
- Verified: full \`up.sh --reset\` round-trip -> 13/13 passed.
- 9 commits total.
EOF
```

- [ ] **Step 6: Push to GitHub**

```bash
git push origin master
```

Expected: `master -> master` (or similar). 9 commits ahead of origin (Task 1 through Task 9, plus progress.md update).

---

## Self-Review (post-write)

1. **Spec coverage:**
   - §3 File layout (scripts/up.sh + scripts/smoke.sh) — Tasks 1, 4, 6.
   - §4.1 Prereq check — Task 1.
   - §4.2 Working dir — Task 1.
   - §4.3 Clean-slate + --reset — Task 2.
   - §4.4 Env file generation — Task 3.
   - §4.5 Secret file mirroring — Task 3.
   - §4.6 Compose up — Task 4.
   - §4.7 Health-wait loop — Task 4.
   - §4.8 Invoke smoke — Task 4.
   - §4.9 Flags (--reset, --dry-run, --help) — Tasks 1, 2, 5.
   - §5.1 Runner shape — Task 6.
   - §5.2 Core tests 1–5 — Task 6.
   - §5.2 Core tests 6–10 — Task 7.
   - §5.3 Functional tests 11–13 — Task 8.
   - §5.4 Implementation notes (bearer source, GF pass source, timeouts, hints) — Tasks 6, 7, 8.
   - §6 Error handling — Tasks 1, 2, 4, 8 (clean-slate refusal, health-wait timeout, chat pre-check).
   - §7 Output format (plain ASCII, [PASS]/[FAIL], tally) — Tasks 6, 7, 8.
   - §8 Testing the scripts (shellcheck, manual round-trip, dry-run, idempotency) — Tasks 5, 8, 10.
   - §9 README update — Task 9.
   - §10 Out of scope — excluded.

2. **Placeholders:** none. Every flag, command, env var, function name, and assertion is explicit.

3. **Type / key consistency:** `LITELLM_MASTER_KEY`, `GRAFANA_ADMIN_PASSWORD`, `LEMONADE_HOST_IP`, `MINIO_METRICS_USER`, `MINIO_METRICS_PASS` env var names are consistent across `.env.example`, `up.sh` sed patterns, and `smoke.sh` greps. Service names (`litellm-proxy`, `prometheus`, `grafana`, `alertmanager`, `milvus`, `redis`, `redis-exporter`, `postgres-exporter`) match the `container_name:` values in `docker-compose.yml`. Test function names (`t_proxy_ready`, `t_embed`, etc.) are consistent in the runner array and function definitions.

4. **Task right-sizing:** Tasks 1–4 build `up.sh` incrementally with each step independently verifiable. Tasks 6–8 build `smoke.sh` in 3 batches (5 + 5 + 3 tests), each ending in a runnable smoke that shows N/13 progress. Task 9 is the README. Task 10 is verification. Each task ends in a commit.