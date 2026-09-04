#!/usr/bin/env bash
# =============================================================================
# setup-test-env.sh — Environnement de test isolé pour les expériences de cache
# =============================================================================
#
# Crée un bac à sable pi COMPLÈTEMENT séparé du harness de l'utilisateur :
#   .pi-test/
#   ├── config/     → PI_CODING_AGENT_DIR       (config + auth.json partagé)
#   ├── sessions/   → PI_CODING_AGENT_SESSION_DIR (sessions de test isolées)
#   ├── work/       → repo de travail pour les tests
#   └── results/    → résultats expérimentaux
#
# PRINCIPE DE SÉCURITÉ :
#   - auth.json est COPIÉ depuis ~/.pi/agent (seul partage de creds) ;
#   - son CONTENU n'est JAMAIS lu ni affiché (existence + permissions seulement) ;
#   - aucune autre ressource du harness (extensions, skills, themes, settings)
#     n'est copiée : l'env de test démarre avec une config pi VIERGE.
#
# USAGE :
#   ./setup-test-env.sh            # crée/rafraîchit le bac à sable
#   ./setup-test-env.sh check      # vérifie que pi démarre + creds accessibles
#   source ./setup-test-env.sh env # exporte les variables PI_* isolées (bash)
# =============================================================================

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$PROJECT_DIR/.pi-test"
CONFIG_DIR="$TEST_ROOT/config"
SESSION_DIR="$TEST_ROOT/sessions"
WORK_DIR="$TEST_ROOT/work"
RESULTS_DIR="$TEST_ROOT/results"
SOURCE_AUTH="$HOME/.pi/agent/auth.json"
TARGET_AUTH="$CONFIG_DIR/auth.json"

# Variables d'isolation exportables (bash tool / sous-shell)
export PI_CODING_AGENT_DIR="$CONFIG_DIR"
export PI_CODING_AGENT_SESSION_DIR="$SESSION_DIR"
export PI_OFFLINE=1
export PI_TELEMETRY=0

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$SESSION_DIR" "$WORK_DIR" "$RESULTS_DIR"
}

sync_auth() {
  if [ -f "$SOURCE_AUTH" ]; then
    cp -f "$SOURCE_AUTH" "$TARGET_AUTH"
    chmod 600 "$TARGET_AUTH"
    printf 'auth.json synchronisé depuis %s (mode %s)\n' \
      "$SOURCE_AUTH" "$(stat -c '%a' "$TARGET_AUTH")"
  else
    printf 'ATTENTION : %s absent — les tests API échoueront (aucun credential).\n' "$SOURCE_AUTH" >&2
  fi
}

check_auth() {
  # Check binaire : jamais d'affichage du contenu de auth.json
  $1 auth check --json --no-refresh 2>&1 | head -2
}

cmd_check() {
  ensure_dirs
  sync_auth
  echo "=== pi démarre-t-il en env isolé ? ==="
  echo "config dir: $CONFIG_DIR"
  echo "session dir: $SESSION_DIR"
  # Vérification silencieuse
  PI_CODING_AGENT_DIR="$CONFIG_DIR" \
  PI_CODING_AGENT_SESSION_DIR="$SESSION_DIR" \
  PI_OFFLINE=1 PI_TELEMETRY=0 \
  pi --version >/dev/null 2>&1 \
    && echo "OK: pi --version fonctionne" \
    || { echo "ÉCHEC: pi --version"; exit 1; }
  echo
  echo "=== Credentials accessibles (binaire, sans afficher le secret) ==="
  for prov in opencode-go minimax; do
    printf '%-12s: ' "$prov"
    PI_CODING_AGENT_DIR="$CONFIG_DIR" \
    PI_CODING_AGENT_SESSION_DIR="$SESSION_DIR" \
    PI_OFFLINE=1 PI_TELEMETRY=0 \
    pi auth check --provider "$prov" --json --no-refresh 2>/dev/null \
      | head -1 | sed -n 's/.*"status":"\([^"]*\)".*/status=\1/p'
  done
  echo
  echo "=== Liste des modèles (confirmation catalogues) ==="
  PI_CODING_AGENT_DIR="$CONFIG_DIR" \
  PI_CODING_AGENT_SESSION_DIR="$SESSION_DIR" \
  PI_OFFLINE=1 PI_TELEMETRY=0 \
  pi --list-models 2>&1 | head -12
  echo
  echo "Bac à sable opérationnel : $TEST_ROOT"
}

case "${1:-}" in
  check) cmd_check ;;
  env)   ensure_dirs; sync_auth; \
         echo "export PI_CODING_AGENT_DIR=$CONFIG_DIR"; \
         echo "export PI_CODING_AGENT_SESSION_DIR=$SESSION_DIR"; \
         echo "export PI_OFFLINE=1"; echo "export PI_TELEMETRY=0" ;;
  *)     ensure_dirs; sync_auth; echo "Bac à sable prêt : $TEST_ROOT" ;;
esac