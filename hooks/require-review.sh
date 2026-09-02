#!/usr/bin/env sh
# Stop — filet de securite : si du code a ete modifie pendant ce tour sans passe
# de revue, bloque une seule fois et demande /revue.
#
# Le garde stop_hook_active rend toute boucle impossible : au second passage
# l'etat est purge et le tour se termine, quoi qu'il arrive.
set -u

DIR="$( CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd )" || exit 0
# « . » est un utilitaire special : si la bibliotheque manque, ni « 2>/dev/null »
# ni « || exit 0 » n'ont d'effet et dash termine le hook en code 2 — soit, ici, un
# blocage. La lisibilite se verifie donc avant de sourcer.
[ -n "${DIR:-}" ] && [ -r "$DIR/lib.sh" ] || exit 0
# shellcheck source=lib.sh
. "$DIR/lib.sh"

read_payload
ROOT="$(project_root)"

SID="$(session_key)"

STATE="$(state_path "$ROOT")"
PENDING="$STATE/$SID.pending"
REVIEW="$STATE/$SID.review"
EPOCH="$STATE/$SID.epoch"

# Passe de revue en cours : les editions du tour sont celles des sous-agents.
# Exiger une revue de la revue est la boucle que ce marqueur existe pour couper.
if revue_en_cours "$ROOT"; then
  exit 0
fi

# Deuxieme passage : la revue a eu lieu ou a ete refusee. On purge et on sort.
if json_true stop_hook_active; then
  rm -f "$PENDING" "$REVIEW" 2>/dev/null || true
  touch_marker "$EPOCH"
  exit 0
fi

# File d'attente vide : cela ne veut pas dire que rien n'a change. En mode
# automatique, Claude ecrit par Bash et PostToolUse ne voit rien passer. On
# compare alors les dates de modification au repere pose au tour precedent.
if [ ! -s "$PENDING" ]; then
  if [ -f "$EPOCH" ]; then
    # Groupe redirige : un .claude/.state devenu non inscriptible fait echouer la
    # redirection, et le message du shell ne doit pas remonter au journal du hook.
    { changed_since "$ROOT" "$EPOCH" >> "$PENDING"; } 2>/dev/null || true
  else
    # Premier tour : on pose le repere, rien a exiger encore.
    mkdir -p "$STATE" 2>/dev/null && touch_marker "$EPOCH"
    exit 0
  fi
fi

[ -s "$PENDING" ] || exit 0

# Aucun sous-agent installe : rien a exiger.
AGENTS="$(project_agents "$ROOT")"
if [ -z "$AGENTS" ]; then
  rm -f "$PENDING" 2>/dev/null || true
  exit 0
fi

# La file passe en .review : /revue sait alors quoi relire, meme apres purge.
{ sort -u "$PENDING" > "$REVIEW"; } 2>/dev/null || exit 0
[ -s "$REVIEW" ] || exit 0
rm -f "$PENDING" 2>/dev/null || true
touch_marker "$EPOCH"

FICHIERS="$(sed 's|^|  - |' "$REVIEW" 2>/dev/null)"
# Bloquer le tour sans pouvoir nommer un seul fichier ne dirait rien d'utile a
# Claude : dans ce cas on laisse simplement le tour se terminer.
[ -n "$FICHIERS" ] || exit 0
# .review contient au moins une ligne : un compte illisible vaut 1 (safe_count).
NB="$(safe_count "$(wc -l < "$REVIEW" 2>/dev/null | tr -d ' ')")"
LISTE="$(printf '%s' "$AGENTS" | sed 's/^/  - /')"

RAISON="$(cat <<EOF | json_escape
Passe de revue non effectuee. $NB fichier(s) de code modifie(s) pendant ce tour :

$FICHIERS

Sous-agents installes dans ce projet :
$LISTE

Lance maintenant la passe de revue : \`/revue\` si le projet a sa propre commande, sinon \`/sous-agents:revue\`. Elle lit la liste dans \`.claude/.state/$SID.review\` et enchaine les sous-agents dans le bon ordre.

Si ces changements sont purement cosmetiques (reformatage, renommage local, typo, commentaires), ou si l'utilisateur t'a explicitement demande de sauter la revue, dis-le en une phrase et termine sans lancer /revue.
EOF
)"

printf '{"decision":"block","reason":"%s"}\n' "$RAISON"
exit 0
