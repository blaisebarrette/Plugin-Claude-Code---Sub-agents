#!/usr/bin/env sh
# Fonctions communes aux hooks du plugin « sous-agents ».
#
# POSIX sh volontairement (pas de bashisme) : les scripts tournent identiquement
# sous bash (macOS), dash (Debian/Ubuntu/WSL) et zsh. Aucune dependance externe
# obligatoire : jq est utilise s'il est present, sinon repli sur sed/awk.
#
# Contrat : chaque fonction est non bloquante et ne fait jamais echouer le hook.
# Un payload stdin absent, tronque ou malforme donne des valeurs vides, jamais
# une erreur.

# Detection de jq une seule fois.
if command -v jq >/dev/null 2>&1; then
  _HAS_JQ=1
else
  _HAS_JQ=0
fi

# read_payload : lit stdin en entier dans PAYLOAD, sans jamais bloquer le hook.
# Un stdin vide ou ferme donne PAYLOAD="".
read_payload() {
  PAYLOAD="$(cat 2>/dev/null || printf '')"
  export PAYLOAD
}

# json_str <cle> : premiere valeur chaine portant cette cle, a n'importe quelle
# profondeur du payload. Vide si absente ou si le JSON est illisible.
json_str() {
  [ -n "${PAYLOAD:-}" ] || return 0
  if [ "$_HAS_JQ" -eq 1 ]; then
    printf '%s' "$PAYLOAD" | jq -r --arg k "$1" \
      '[.. | objects | .[$k]? | select(type == "string")] | first // empty' 2>/dev/null
  else
    # Repli sans jq : premiere occurrence de "cle": "valeur" sur le payload aplati.
    printf '%s' "$PAYLOAD" | tr '\n' ' ' \
      | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n 1
  fi
}

# json_true <cle> : 0 si la cle vaut booleen true, 1 sinon.
json_true() {
  [ -n "${PAYLOAD:-}" ] || return 1
  if [ "$_HAS_JQ" -eq 1 ]; then
    [ "$(printf '%s' "$PAYLOAD" | jq -r --arg k "$1" \
      '[.. | objects | .[$k]? | select(type == "boolean")] | first // false' 2>/dev/null)" = "true" ]
  else
    printf '%s' "$PAYLOAD" | tr '\n' ' ' \
      | grep -q '"'"$1"'"[[:space:]]*:[[:space:]]*true'
  fi
}

# json_escape : lit du texte sur stdin, ecrit une chaine JSON echappee (sans les
# guillemets englobants). Les retours a la ligne deviennent \n, les tabulations
# des espaces, les CR sont supprimes (fichiers CRLF sous WSL).
json_escape() {
  tr -d '\r' | tr '\t' ' ' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | awk 'BEGIN { ORS = "" } { print $0 "\\n" }'
}

# emit_context <nom_evenement> : lit le texte sur stdin et l'injecte dans le
# contexte de Claude. Indispensable pour PostToolUse, dont le stdout brut part
# au journal de debogage et n'est jamais vu par Claude.
emit_context() {
  _txt="$(json_escape)"
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$1" "$_txt"
}

# project_root : racine du projet courant. CLAUDE_PROJECT_DIR fait autorite ;
# sinon le cwd du payload ; sinon le repertoire courant.
project_root() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s' "$CLAUDE_PROJECT_DIR"
    return 0
  fi
  _cwd="$(json_str cwd)"
  if [ -n "$_cwd" ]; then
    printf '%s' "$_cwd"
    return 0
  fi
  pwd
}

# plugin_root : racine du plugin. CLAUDE_PLUGIN_ROOT est fourni par Claude Code ;
# le repli permet d'executer les scripts a la main pour les tester.
plugin_root() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '%s' "$CLAUDE_PLUGIN_ROOT"
    return 0
  fi
  ( CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd )
}

# project_agents <racine> : noms (sans .md) des sous-agents presents dans le
# projet, un par ligne. Rien si le dossier est absent ou vide.
project_agents() {
  _dir="$1/.claude/agents"
  [ -d "$_dir" ] || return 0
  for _f in "$_dir"/*.md; do
    [ -f "$_f" ] || continue
    _b="${_f##*/}"
    printf '%s\n' "${_b%.md}"
  done
}

# agent_description <fichier.md> : description du frontmatter, aplatie sur une
# ligne et tronquee. Vide si le fichier n'en a pas.
agent_description() {
  [ -f "$1" ] || return 0
  awk '
    /^description:[[:space:]]*/ {
      inblock = 1
      line = $0
      sub(/^description:[[:space:]]*>?-?[[:space:]]*/, "", line)
      if (length(line) > 0) print line
      next
    }
    inblock && /^[A-Za-z_-]+:/ { exit }
    inblock && /^---[[:space:]]*$/ { exit }
    inblock {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      print line
    }
  ' "$1" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g' \
    | awk '{
        n = index($0, ". ")
        if (n > 0 && n < 260) print substr($0, 1, n)
        else print substr($0, 1, 200)
      }'
}

# is_reviewable <chemin> : 0 si le fichier merite une passe de sous-agents.
# Ecarte les artefacts generes, les dependances, la config de l'outillage et les
# fichiers de documentation ecrits par les sous-agents eux-memes (sinon leurs
# propres ecritures relancent un rappel en boucle).
is_reviewable() {
  case "$1" in
    */node_modules/*|*/vendor/*|*/dist/*|*/build/*|*/.next/*|*/target/*|*/__pycache__/*) return 1 ;;
    */.git/*|*/.claude/*|*/.cursor/*|*/.venv/*|*/venv/*) return 1 ;;
    *PROJECT_MEMORY.md|*USER_GUIDE.md|*API_REFERENCE.md) return 1 ;;
    *.lock|*-lock.json|*.tsbuildinfo|*.min.js|*.map) return 1 ;;
  esac
  case "$1" in
    *.php|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.vue|*.svelte) return 0 ;;
    *.py|*.rb|*.go|*.rs|*.java|*.kt|*.swift|*.cs|*.c|*.h|*.cpp|*.hpp|*.m|*.mm) return 0 ;;
    *.sql|*.sh|*.bash|*.zsh|*.css|*.scss|*.json|*.yml|*.yaml|*.toml) return 0 ;;
    *) return 1 ;;
  esac
}

# state_dir <racine> : dossier d'etat de session, cree si besoin. Vide si la
# creation echoue (projet en lecture seule) — les appelants sortent alors sans
# rien casser.
state_dir() {
  _s="$1/.claude/.state"
  mkdir -p "$_s" 2>/dev/null || return 0
  # Purge des restes de sessions anciennes : sans filet, ce dossier grossit sans fin.
  find "$_s" -type f -mtime +2 -delete 2>/dev/null || true
  printf '%s' "$_s"
}

# has_code <racine> : 0 si le projet contient de quoi observer une pile technique.
# Seuil a 3 fichiers de code hors dependances : un depot qui n'a qu'un README et
# un fichier de config ne permet pas encore d'adapter un agent honnetement.
has_code() {
  _n="$(find "$1" \
    \( -name .git -o -name .claude -o -name node_modules -o -name vendor \
       -o -name dist -o -name build -o -name target -o -name .venv -o -name venv \) -prune -o \
    -type f \( -name '*.php' -o -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \
       -o -name '*.mjs' -o -name '*.vue' -o -name '*.svelte' -o -name '*.py' -o -name '*.rb' \
       -o -name '*.go' -o -name '*.rs' -o -name '*.java' -o -name '*.kt' -o -name '*.swift' \
       -o -name '*.cs' -o -name '*.c' -o -name '*.h' -o -name '*.cpp' -o -name '*.m' \) \
    -print 2>/dev/null | head -n 3 | wc -l | tr -d ' ')"
  [ "${_n:-0}" -ge 3 ]
}

# agents_awaiting_context <racine> : noms des agents installes dont le bloc
# « Contexte du projet » n'a jamais ete rempli (marqueurs encore presents), un par
# ligne. C'est le cas d'un projet installe alors qu'il etait encore vide.
agents_awaiting_context() {
  _dir="$1/.claude/agents"
  [ -d "$_dir" ] || return 0
  grep -l 'CONTEXTE-PROJET' "$_dir"/*.md 2>/dev/null | while IFS= read -r _f; do
    _b="${_f##*/}"
    printf '%s\n' "${_b%.md}"
  done
}
