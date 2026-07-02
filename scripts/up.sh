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

# ── Placeholder for env generation (filled by Task 3) ───────────────
echo "[ok] clean-slate enforced; next task adds env generation."
