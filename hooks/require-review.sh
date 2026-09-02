#!/usr/bin/env sh
# Stop — filet de securite : si du code a ete modifie pendant ce tour sans passe
# de revue, bloque une seule fois et demande /revue.
#
# Le garde stop_hook_active rend toute boucle impossible : au second passage
# l'etat est purge et le tour se termine, quoi qu'il arrive.
set -u

DIR="$( CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd )" || exit 0
# shellcheck source=lib.sh
. "$DIR/lib.sh" 2>/dev/null || exit 0

read_payload
ROOT="$(project_root)"

SID="$(json_str session_id)"
[ -n "$SID" ] || SID="inconnue"

STATE="$ROOT/.claude/.state"
PENDING="$STATE/$SID.pending"
REVIEW="$STATE/$SID.review"

# Deuxieme passage : la revue a eu lieu ou a ete refusee. On purge et on sort.
if json_true stop_hook_active; then
  rm -f "$PENDING" "$REVIEW" 2>/dev/null || true
  exit 0
fi

[ -s "$PENDING" ] || exit 0

# Aucun sous-agent installe : rien a exiger.
AGENTS="$(project_agents "$ROOT")"
if [ -z "$AGENTS" ]; then
  rm -f "$PENDING" 2>/dev/null || true
  exit 0
fi

# La file passe en .review : /revue sait alors quoi relire, meme apres purge.
sort -u "$PENDING" > "$REVIEW" 2>/dev/null || exit 0
rm -f "$PENDING" 2>/dev/null || true

FICHIERS="$(sed 's|^|  - |' "$REVIEW")"
NB="$(wc -l < "$REVIEW" | tr -d ' ')"
LISTE="$(printf '%s' "$AGENTS" | sed 's/^/  - /')"

RAISON="$(cat <<EOF | json_escape
Passe de revue non effectuee. $NB fichier(s) de code modifie(s) pendant ce tour :

$FICHIERS

Sous-agents installes dans ce projet :
$LISTE

Lance maintenant \`/revue\` : la commande lit la liste dans \`.claude/.state/$SID.review\` et enchaine les sous-agents dans le bon ordre.

Si ces changements sont purement cosmetiques (reformatage, renommage local, typo, commentaires), ou si l'utilisateur t'a explicitement demande de sauter la revue, dis-le en une phrase et termine sans lancer /revue.
EOF
)"

printf '{"decision":"block","reason":"%s"}\n' "$RAISON"
exit 0
