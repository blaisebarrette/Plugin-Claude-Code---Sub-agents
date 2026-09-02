#!/usr/bin/env sh
# SessionStart — au premier lancement dans un projet sans sous-agents, demande a
# Claude de poser la question de la selection puis d'installer les agents choisis.
#
# Ne fait strictement rien si .claude/agents/ contient deja au moins un agent, ou
# si l'utilisateur a decline la selection une fois (marqueur .state). La question
# n'est donc jamais reposee de session en session.
#
# Le stdout d'un hook SessionStart est ajoute tel quel au contexte de Claude :
# pas besoin d'envelopper ce texte dans du JSON.
set -u

DIR="$( CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd )" || exit 0
# shellcheck source=lib.sh
. "$DIR/lib.sh" 2>/dev/null || exit 0

read_payload
ROOT="$(project_root)"
PLUGIN="$(plugin_root)"
TPL="$PLUGIN/templates/agents"

[ -d "$TPL" ] || exit 0

# Deja configure : on sort sans bruit.
if [ -n "$(project_agents "$ROOT")" ]; then
  exit 0
fi

# Selection deja declinee : on ne redemande plus (l'utilisateur a /agents-setup).
[ -f "$ROOT/.claude/.state/agents-setup-skipped" ] && exit 0

# Catalogue lisible, construit depuis les modeles reellement presents.
CATALOGUE=""
for f in "$TPL"/*.md; do
  [ -f "$f" ] || continue
  b="${f##*/}"
  CATALOGUE="$CATALOGUE
- ${b%.md} — $(agent_description "$f")"
done
[ -n "$CATALOGUE" ] || exit 0

cat <<EOF
[plugin sous-agents] Ce projet n'a pas encore de sous-agents : \`$ROOT/.claude/agents/\` est absent ou vide.

Au debut de ta prochaine reponse, avant de traiter la demande de l'utilisateur, pose-lui la question de la selection avec l'outil AskUserQuestion (une seule question, \`multiSelect: true\`, une option par agent ci-dessous, plus la possibilite de n'en prendre aucun) :
$CATALOGUE

Une fois la reponse obtenue :

1. \`mkdir -p "$ROOT/.claude/agents"\` puis copie **uniquement** les agents choisis depuis \`$TPL/\` vers \`$ROOT/.claude/agents/\`.
2. Pour chaque fichier copie, remplace le bloc delimite par \`<!-- CONTEXTE-PROJET:DEBUT -->\` et \`<!-- CONTEXTE-PROJET:FIN -->\` par le contexte reel de CE projet, apres l'avoir constate dans le depot (jamais suppose) : langages et frameworks, gestionnaire de paquets, commandes de build/lint/test, dossiers generes et dependances a ne jamais toucher, conventions de gestion d'erreurs, emplacement des routes API et de l'interface. Retire les deux marqueurs. Si tu ne peux pas verifier un point, ecris moins plutot que d'inventer.
3. Si l'utilisateur n'en veut aucun : cree le fichier vide \`$ROOT/.claude/.state/agents-setup-skipped\` pour que la question ne revienne plus, et signale-lui qu'il peut lancer \`/agents-setup\` plus tard.
4. Dis en une ligne ce qui a ete installe, puis enchaine normalement sur la demande de l'utilisateur.

Ne copie aucun agent que l'utilisateur n'a pas choisi, et ne modifie aucun fichier du plugin lui-meme.
EOF
exit 0
