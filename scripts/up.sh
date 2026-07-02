#!/usr/bin/env bash
# scripts/up.sh — bootstrap the litellm-stack Docker Compose stack.
# See docs/superpowers/specs/2026-07-01-local-deploy-and-test-design.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Flags ───────────────────────────────────────────────────────────
RESET=0
DRY_RUN=0
export RESET DRY_RUN  # consumed by later tasks; silence shellcheck SC2034
print_help() {
  cat <<EOF
Usage: up.sh [flag]

  (no flag)    Strict clean-slate bootstrap. Refuses if .env exists.
  --reset      Full wipe (docker compose down -v) then re-bootstrap.
  --dry-run    Print the plan, do not write any files or run docker compose.
  --help       Show this help.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --reset)  RESET=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --help|-h) print_help; exit 0 ;;
    "")       ;;
    *)        echo "unknown flag: $arg" >&2; print_help >&2; exit 1 ;;
  esac
done

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
