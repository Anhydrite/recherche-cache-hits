#!/usr/bin/env bash
# =============================================================================
# exp-runner.sh — Harness générique d'expérimentation cache
# =============================================================================
# Usage :
#   EXP_NAME=... EXP_TRACE=... \
#   exp-runner.sh <label> <session_id> [tools_flag] [--print <prompt>] [extra pi args...]
#
# Exécute UN tour pi avec l'extension cache-trace, même session (clé de cache
# stable), dans le bac à sable isolé. Écrit la trace dans $EXP_TRACE.
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CFG_DIR="$ROOT/.pi-test/config"
SESS_DIR="$ROOT/.pi-test/sessions"
EXT="${EXP_EXT:-$ROOT/.pi-test/extensions/cache-trace.ts}"
PROVIDER="${EXP_PROVIDER:-opencode-go}"
MODEL="${EXP_MODEL:-deepseek-v4-flash}"
TRACE_PATH="${EXP_TRACE:-$ROOT/.pi-test/results/cache/trace.jsonl}"

export PI_CODING_AGENT_DIR="$CFG_DIR"
export PI_CODING_AGENT_SESSION_DIR="$SESS_DIR"
export PI_OFFLINE=1
export PI_TELEMETRY=0
export TRACE_PATH

LABEL="${1:?label requis}"
SID="${2:?session_id requis}"
TOOLS="${3:-}"
TRACE_ARG="${4:-}"
[ -n "$TRACE_ARG" ] && TRACE_PATH="$TRACE_ARG"
shift 4 2>/dev/null || true

ARGS=(--print "${LABEL}: réponds uniquement OK."
       --session-id "$SID" --provider "$PROVIDER" --model "$MODEL")
[ -n "$TOOLS" ] && ARGS+=( $TOOLS )
# Arguments supplémentaires (--print custom, --no-context-files, etc.)
ARGS+=( "$@" )

mkdir -p "$(dirname "$TRACE_PATH")"
T1_TRACE_PATH="$TRACE_PATH" timeout 120 pi --extension "$EXT" "${ARGS[@]}" >/dev/null 2>&1
echo "[$LABEL] exit=$?"