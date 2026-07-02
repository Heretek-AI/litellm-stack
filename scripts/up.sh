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