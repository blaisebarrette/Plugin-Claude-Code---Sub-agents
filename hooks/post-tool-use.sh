#!/usr/bin/env sh
# PostToolUse (Edit|Write|MultiEdit|NotebookEdit) — enregistre le fichier de code
# modifie dans la file d'attente de revue, et rappelle a Claude d'invoquer les
# sous-agents reellement presents dans CE projet (lus a chaud, jamais codes en dur).
#
# Trois garde-fous contre le bruit et les boucles :
#   - is_reviewable ecarte artefacts, dependances et fichiers de doc ecrits par
#     les sous-agents eux-memes ;
#   - le rappel est emis au plus une fois par tour utilisateur (prompt_id) ;
#   - le stdout d'un PostToolUse n'etant pas vu par Claude, le rappel sort en
#     JSON hookSpecificOutput.additionalContext.
set -u

DIR="$( CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd )" || exit 0
# shellcheck source=lib.sh
. "$DIR/lib.sh" 2>/dev/null || exit 0

read_payload
ROOT="$(project_root)"

FILE="$(json_str file_path)"
[ -n "$FILE" ] || FILE="$(json_str filePath)"
[ -n "$FILE" ] || FILE="$(json_str notebook_path)"
[ -n "$FILE" ] || exit 0

is_reviewable "$FILE" || exit 0

AGENTS="$(project_agents "$ROOT")"
[ -n "$AGENTS" ] || exit 0

STATE="$(state_dir "$ROOT")"
[ -n "$STATE" ] || exit 0

SID="$(json_str session_id)"
[ -n "$SID" ] || SID="inconnue"
PID="$(json_str prompt_id)"
[ -n "$PID" ] || PID="$SID"

# File d'attente : sert au hook Stop et a la commande /revue.
printf '%s\n' "$FILE" >> "$STATE/$SID.pending" 2>/dev/null || exit 0

# Un seul rappel par tour utilisateur : sans ce verrou, une serie de dix editions
# injecte dix fois le meme paragraphe.
MARK="$STATE/$SID.$PID.rappel"
[ -f "$MARK" ] && exit 0
: > "$MARK" 2>/dev/null || exit 0

LISTE="$(printf '%s' "$AGENTS" | sed 's/^/  - /')"
NB="$(sort -u "$STATE/$SID.pending" 2>/dev/null | wc -l | tr -d ' ')"

emit_context PostToolUse <<EOF
[plugin sous-agents] Du code vient d'etre modifie ($NB fichier(s) ce tour-ci, dont \`$FILE\`).

Sous-agents disponibles dans ce projet :
$LISTE

Avant de conclure ce tour, fais la passe de revue sur les fichiers modifies — soit en lancant \`/revue\`, soit en invoquant toi-meme les sous-agents concernes. Chaque sous-agent ignore la conversation : donne-lui un resume factuel des changements (fichiers touches, ce qui a ete ajoute/modifie/supprime, et pourquoi).

Ordre impose quand plusieurs s'appliquent : \`error-handling\`, puis \`qualite-code\`, puis \`securite\` — l'un apres l'autre, jamais en parallele, car ils editent les memes fichiers ; \`securite\` passe en dernier pour auditer le code final. Ensuite seulement, \`memoire-projet\`, \`guide-utilisateur\` et \`reference-api\` peuvent tourner en parallele : ils ecrivent dans des fichiers distincts.

N'invoque que ceux dont le perimetre correspond vraiment a ce qui a change, en te fiant a leur description. Si aucun ne s'applique (changement purement cosmetique), dis-le en une phrase et continue.
EOF
exit 0
