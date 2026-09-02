#!/usr/bin/env sh
# SessionStart — trois roles, evalues dans cet ordre, un seul a la fois :
#
#   1. Projet sans sous-agents : demander a Claude de poser la question de la
#      selection, puis d'installer les agents choisis.
#   2. Agents installes dont le contexte n'a jamais ete rempli (projet vide au
#      moment de l'installation) : demander de finaliser l'adaptation maintenant
#      que le depot a du code a observer.
#   3. Agents de documentation jamais amorces : proposer une fois la passe
#      /amorcer-docs, qui construit ou audite leurs fichiers depuis le depot
#      entier — un travail que leur mode incremental ne sait pas faire.
#
# Silencieux dans tous les autres cas. Le stdout d'un hook SessionStart est
# ajoute tel quel au contexte de Claude : pas besoin de JSON.
set -u

DIR="$( CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd )" || exit 0
# shellcheck source=lib.sh
. "$DIR/lib.sh" 2>/dev/null || exit 0

read_payload
ROOT="$(project_root)"
PLUGIN="$(plugin_root)"
TPL="$PLUGIN/templates/agents"
STATE_DIR="$ROOT/.claude/.state"

[ -d "$TPL" ] || exit 0

# ---------------------------------------------------------------------------
# Cas 1 : aucun sous-agent installe.
# ---------------------------------------------------------------------------
if [ -z "$(project_agents "$ROOT")" ]; then
  # Selection deja declinee : on ne redemande plus (l'utilisateur a /agents-setup).
  [ -f "$STATE_DIR/agents-setup-skipped" ] && exit 0

  CATALOGUE=""
  for f in "$TPL"/*.md; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    CATALOGUE="$CATALOGUE
- ${b%.md} — $(agent_description "$f")"
  done
  [ -n "$CATALOGUE" ] || exit 0

  # L'instruction d'adaptation depend de ce qu'il y a a observer dans le depot.
  if has_code "$ROOT"; then
    ADAPTATION="2. Pour chaque fichier copie, remplace le bloc delimite par \`<!-- CONTEXTE-PROJET:DEBUT -->\` et \`<!-- CONTEXTE-PROJET:FIN -->\` par le contexte reel de CE projet, apres l'avoir constate dans le depot (jamais suppose) : langages et frameworks, gestionnaire de paquets, commandes de build/lint/test, dossiers generes et dependances a ne jamais toucher, conventions de gestion d'erreurs, emplacement des routes API et de l'interface. Retire ensuite les deux marqueurs. Si un point ne peut pas etre verifie, ecris moins plutot que d'inventer."
  else
    ADAPTATION="2. Ce projet ne contient pas encore de code a observer : **laisse le bloc \`<!-- CONTEXTE-PROJET:DEBUT -->\` et ses marqueurs en place**, tels quels. Ne remplis rien et n'invente aucune pile technique — les agents savent travailler sans ce bloc, ils lisent alors les fichiers avant d'agir. Si l'utilisateur mentionne de lui-meme la pile prevue, ajoute-la dans le bloc en la marquant clairement \`(declaree par l'utilisateur, non verifiee dans le code)\`, sans retirer les marqueurs. Des que le projet aura du code, une prochaine session proposera de finaliser l'adaptation."
  fi

  cat <<EOF
[plugin sous-agents] Ce projet n'a pas encore de sous-agents : \`$ROOT/.claude/agents/\` est absent ou vide.

Au debut de ta prochaine reponse, avant de traiter la demande de l'utilisateur, pose-lui la question de la selection avec l'outil AskUserQuestion, en \`multiSelect: true\`. **Cet outil n'accepte que quatre options par question** : repartis donc les agents ci-dessous sur deux questions — les correcteurs de code d'abord, les tenues de documentation ensuite — et dis dans chacune qu'il peut n'en prendre aucun. Reprends la description de chaque agent comme explication de son option.
$CATALOGUE

Une fois la reponse obtenue :

1. \`mkdir -p "$ROOT/.claude/agents"\` puis copie **uniquement** les agents choisis depuis \`$TPL/\` vers \`$ROOT/.claude/agents/\`.
$ADAPTATION
3. Ajoute la ligne \`.claude/.state/\` au \`.gitignore\` du projet si elle n'y est pas deja (ce dossier ne contient que de l'etat de session). Cree le fichier s'il n'existe pas ; si le projet n'est pas un depot git, passe cette etape.
4. Si l'utilisateur n'en veut aucun : cree le fichier vide \`$STATE_DIR/agents-setup-skipped\` pour que la question ne revienne plus, et signale-lui qu'il peut lancer \`/sous-agents:agents-setup\` plus tard.
5. Dis en une ligne ce qui a ete installe, **puis previens l'utilisateur que ces sous-agents ne seront invocables qu'au prochain demarrage de session** : la liste des agents est lue au lancement, un agent copie en cours de session est introuvable jusque-la. N'essaie pas de les invoquer avant, et ne te rabats surtout pas sur un agent generique en leur place — leurs instructions detaillees seraient perdues. Enchaine ensuite normalement sur la demande de l'utilisateur.

Ne copie aucun agent que l'utilisateur n'a pas choisi, et ne modifie aucun fichier du plugin lui-meme.
EOF
  exit 0
fi

# Le projet est equipe : on pose le repere de detection des modifications, pour
# que le hook Stop rattrape aussi les editions faites autrement que par
# Edit/Write (mode automatique : ecriture par Bash).
SID="$(json_str session_id)"
[ -n "$SID" ] || SID="inconnue"
_st="$(state_dir "$ROOT")"
[ -n "$_st" ] && : > "$_st/$SID.epoch" 2>/dev/null

# ---------------------------------------------------------------------------
# Cas 2 : des agents installes attendent encore leur contexte.
# ---------------------------------------------------------------------------
ATTENTE="$(agents_awaiting_context "$ROOT")"
if [ -n "$ATTENTE" ]; then
  [ -f "$STATE_DIR/agents-context-skipped" ] && exit 0   # refus memorise
  has_code "$ROOT" || exit 0                             # rien a observer

  LISTE="$(printf '%s' "$ATTENTE" | sed 's/^/  - /')"
  cat <<EOF
[plugin sous-agents] Des sous-agents de ce projet n'ont jamais recu leur contexte : ils ont ete installes alors que le depot etait encore vide, et leur bloc \`<!-- CONTEXTE-PROJET:DEBUT -->\` est toujours en place. Le projet contient maintenant du code : c'est le moment de les finaliser.

Agents concernes :
$LISTE

Au debut de ta prochaine reponse, avant de traiter la demande de l'utilisateur :

1. Dis-lui en une phrase que ces agents peuvent maintenant etre adaptes au projet, et demande-lui si tu le fais tout de suite.
2. S'il accepte : pour chacun, remplace le bloc delimite par \`<!-- CONTEXTE-PROJET:DEBUT -->\` et \`<!-- CONTEXTE-PROJET:FIN -->\` par le contexte reel du projet, constate dans le depot (jamais suppose) — chaque agent precise dans son bloc ce dont il a besoin. Retire ensuite les deux marqueurs. Ne modifie rien d'autre dans ces fichiers.
3. S'il refuse : cree le fichier vide \`$STATE_DIR/agents-context-skipped\` pour ne plus le relancer, et dis-lui que \`/sous-agents:agents-setup\` le fera quand il voudra.
4. Enchaine ensuite normalement sur sa demande.
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
# Cas 3 : agents de documentation jamais amorces.
# ---------------------------------------------------------------------------
DOCS="$(doc_status "$ROOT")"
[ -n "$DOCS" ] || exit 0
[ -f "$STATE_DIR/docs-amorcage" ] && exit 0            # passe deja faite
[ -f "$STATE_DIR/docs-amorcage-skipped" ] && exit 0    # refus memorise
has_code "$ROOT" || exit 0

ETAT="$(printf '%s\n' "$DOCS" | awk '{
  if ($3 == "absent") print "  - " $2 " — absent, a construire depuis le depot (" $1 ")"
  else print "  - " $2 " — present, a auditer et corriger (" $1 ")"
}')"

cat <<EOF
[plugin sous-agents] Les agents de documentation de ce projet n'ont jamais fait de passe d'amorcage. Ils sont concus pour du travail incremental sur un diff : ils tiennent un fichier a jour, mais ne savent ni le construire depuis rien, ni redresser un fichier ecrit avant eux.

Etat des fichiers :
$ETAT

Au debut de ta prochaine reponse, avant de traiter la demande de l'utilisateur, propose la passe \`/sous-agents:amorcer-docs\` en une phrase, en disant qu'elle lit le depot entier — donc nettement plus couteuse qu'une mise a jour ordinaire — et qu'elle ne se fait qu'une fois.

- S'il accepte : lance \`/sous-agents:amorcer-docs\`.
- S'il prefere plus tard : cree le fichier vide \`$STATE_DIR/docs-amorcage-skipped\` pour ne plus le relancer, et dis-lui que \`/sous-agents:amorcer-docs\` reste disponible a tout moment.
- Puis enchaine normalement sur sa demande.
EOF
exit 0
