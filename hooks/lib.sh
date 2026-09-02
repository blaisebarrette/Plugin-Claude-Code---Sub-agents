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
#
# Le premier « tr » retire tous les caracteres de controle sauf la tabulation
# (\011) et le retour a la ligne (\012), traites juste apres. JSON interdit un
# octet inferieur a 0x20 laisse tel quel dans une chaine : un seul suffisait a
# rendre la sortie du hook illisible, et Claude Code jette alors le message en
# silence. Un depot clone peut contenir un fichier dont le nom porte un octet
# d'echappement — changed_since le remonte, il finit dans la raison du hook Stop,
# et c'est tout le filet de revue qui disparait sans rien dire. Cela neutralise
# du meme coup les sequences d'echappement terminal recopiees dans un message.
json_escape() {
  tr -d '\000-\010\013-\037' | tr '\t' ' ' \
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
    *.php|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.vue|*.svelte|*.astro) return 0 ;;
    *.html|*.htm|*.twig|*.blade.php|*.erb) return 0 ;;
    *.py|*.rb|*.go|*.rs|*.java|*.kt|*.swift|*.cs|*.c|*.h|*.cpp|*.hpp|*.m|*.mm) return 0 ;;
    *.sql|*.sh|*.bash|*.zsh|*.css|*.scss|*.json|*.yml|*.yaml|*.toml) return 0 ;;
    *) return 1 ;;
  esac
}

# touch_marker <chemin> : cree ou reactualise un fichier repere vide, sans jamais
# faire echouer le hook.
#
# Ne pas revenir a « : > fichier » : « : » est un utilitaire special, et une
# redirection qui echoue sur un utilitaire special termine immediatement un shell
# non interactif (dash sous Debian/Ubuntu/WSL, zsh en mode sh) — ni « 2>/dev/null »
# ni « || true » n'y changent quoi que ce soit. Un dossier .claude/.state non
# inscriptible suffisait alors a faire sortir le hook Stop en code 2, c'est-a-dire
# a bloquer le tour avec le message d'erreur du shell en guise de raison.
touch_marker() {
  touch "$1" 2>/dev/null || return 0
}

# safe_key <valeur> : reduit une valeur du payload a un nom de fichier sur.
#
# Ces champs sont des donnees externes et servent a nommer des fichiers d'etat :
# une valeur absente, ou portant un separateur de chemin, un espace ou un retour a
# la ligne, donne « inconnue » plutot qu'une ecriture hors de .claude/.state.
safe_key() {
  case "${1:-}" in
    .|..) printf 'inconnue' ;;
    ''|*[!A-Za-z0-9._-]*) printf 'inconnue' ;;
    *) printf '%s' "$1" ;;
  esac
}

# safe_path <chemin> : chemin du payload ramene a une seule ligne affichable.
#
# safe_key ne convient pas ici : ce chemin n'est pas un nom de fichier a fabriquer
# mais un chemin reel a montrer, avec ses separateurs et ses accents. Ce qu'il faut
# lui retirer est autre chose.
#
# Ce chemin est ecrit dans la file d'attente, ou une ligne vaut un fichier, puis
# recopie dans le texte injecte dans le contexte de Claude. Un nom de fichier
# portant un retour a la ligne y ajoutait donc des lignes entieres, choisies par
# qui a cree le fichier, au milieu d'un message que Claude lit comme venant du
# plugin : de quoi faire passer une consigne quelconque pour une instruction du
# plugin, et de quoi ajouter de fausses entrees dans la file de revue. Les
# caracteres de controle deviennent des espaces ou disparaissent — le chemin reste
# lisible, et une ligne reste une ligne.
#
# Deux « tr » plutot qu'un seul avec un intervalle : « tr » dont la seconde chaine
# est plus courte que la premiere n'a pas le meme comportement partout, alors que
# trois caracteres remplaces par trois espaces ne se discute nulle part.
safe_path() {
  printf '%s' "${1:-}" | tr '\n\r\t' '   ' | tr -d '\000-\037'
}

# safe_count <valeur> : compte de fichiers destine a une phrase, ramene a 1 quand
# il est illisible ou nul.
#
# wc, sort ou une lecture de fichier peuvent n'avoir rien rendu : la liste de
# fichiers affichee juste a cote fait alors foi, et on n'ecrit pas un trou dans la
# phrase. Regle tenue ici seule, les hooks Stop et PostToolUse en dependent tous
# les deux.
safe_count() {
  case "${1:-}" in
    ''|*[!0-9]*|0) printf '1' ;;
    *) printf '%s' "$1" ;;
  esac
}

# session_key : identifiant de session du payload, assaini pour nommer un fichier.
session_key() {
  safe_key "$(json_str session_id)"
}

# state_path <racine> : chemin du dossier d'etat de session, sans rien creer ni
# purger. Seul endroit qui connaisse cet emplacement : les hooks qui ne font que
# lire des fichiers repere passent par ici plutot que de reecrire le chemin.
state_path() {
  printf '%s' "$1/.claude/.state"
}

# state_dir <racine> : dossier d'etat de session, cree si besoin. Vide si la
# creation echoue (projet en lecture seule) — les appelants sortent alors sans
# rien casser.
state_dir() {
  _s="$(state_path "$1")"
  mkdir -p "$_s" 2>/dev/null || return 0
  # Purge des restes de sessions anciennes : sans filet, ce dossier grossit sans fin.
  #
  # La purge ne vise QUE les fichiers d'etat de session, jamais les marqueurs de
  # decision (agents-setup-skipped, agents-context-skipped, docs-amorcage,
  # docs-amorcage-skipped) : ceux-la portent un choix de l'utilisateur et doivent
  # survivre indefiniment. Les effacer faisait reproposer, passe deux jours, une
  # adaptation refusee ou un amorcage deja fait.
  find "$_s" -type f \
    \( -name '*.pending' -o -name '*.review' -o -name '*.epoch' -o -name '*.rappel' \) \
    -mtime +2 -delete 2>/dev/null || true
  printf '%s' "$_s"
}

# _find_code_files <racine> [predicats find...] : chemins des fichiers du projet,
# un par ligne, sans jamais faire echouer l'appelant.
#
# Les predicats supplementaires s'inserent apres « -type f », seule position qui
# les ajoute au filtre sans casser l'elagage : places avant le groupe « -prune »,
# ils se colleraient a la branche d'elagage et la branche « -print » perdrait le
# filtre. Un « -maxdepth » y reste global sous BSD comme sous GNU (GNU avertit sur
# stderr, deja jete).
#
# La liste elaguee reprend celle de is_reviewable : elle evite de parcourir des
# dossiers dont chaque fichier serait de toute facon ecarte ensuite. is_reviewable
# reste le seul juge de ce qui compte comme du code — un dossier ajoute ici n'est
# qu'une acceleration, l'oublier ne change aucun resultat.
_find_code_files() {
  _fr="$1"
  shift
  find "$_fr" \
    \( -name .git -o -name .claude -o -name .cursor -o -name node_modules \
       -o -name vendor -o -name dist -o -name build -o -name .next \
       -o -name target -o -name .venv -o -name venv -o -name __pycache__ \) \
    -prune -o -type f ${1+"$@"} -print 2>/dev/null
}

# _is_config <chemin> : 0 pour un fichier de configuration ou de donnees.
# Defini hors de has_code a dessein : le /bin/sh de macOS (bash 3.2) echoue a
# analyser un « case » place dans une substitution de commande $( ... ).
_is_config() {
  case "$1" in
    *.json|*.yml|*.yaml|*.toml) return 0 ;;
  esac
  return 1
}

# _has_two_code_files <racine> [predicats find...] : 0 si au moins deux fichiers
# de code sont trouves sous cette racine.
#
# La boucle s'arrete au deuxieme fichier : le pipe se ferme, find prend un EPIPE
# et cesse de parcourir au lieu d'enumerer le depot entier. Les filtres de chaine
# passent avant le test d'existence : sur un depot volumineux la quasi-totalite
# des lignes est alors ecartee sans le moindre appel systeme. Les deux conditions
# restent exigees, leur ordre ne change aucun verdict. C'est ce qui tient l'appel
# dans les dix secondes du hook.
#
# Aucun commentaire portant une apostrophe dans la substitution ci-dessous : le
# /bin/sh de macOS (bash 3.2) analyse mal les quotes des commentaires places dans
# un $( ... ) et refuse tout le fichier — meme raison que pour _is_config.
_has_two_code_files() {
  _hr="$1"
  shift
  _n="$(_find_code_files "$_hr" ${1+"$@"} | { _c=0
      while IFS= read -r _f; do
        is_reviewable "$_f" || continue
        _is_config "$_f" && continue
        # « read » coupe aux retours a la ligne : un nom de fichier qui en
        # contient arrive en morceaux, qui ne designent aucun fichier.
        [ -f "$_f" ] || continue
        _c=$((_c + 1))
        [ "$_c" -ge 2 ] && break
      done
      printf '%s' "$_c"; })"
  # find, le pipeline ou le sous-shell peuvent n'avoir rien rendu : un compte non
  # numerique se lit « pas de code », il ne part pas dans « [ -ge ] » qui protesterait.
  case "${_n:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$_n" -ge 2 ]
}

# has_code <racine> : 0 si le projet contient de quoi observer une pile technique.
#
# Le critere est celui de is_reviewable, moins les fichiers de configuration et
# de donnees (json, yaml, toml) : deux manifestes ne disent pas comment le projet
# est ecrit. Seuil a deux fichiers — un projet d'un seul fichier squelette
# n'apprend pas assez pour adapter un agent honnetement.
#
# Ne jamais restreindre ce compte a une liste d'extensions propre : is_reviewable
# fait autorite, une extension s'ajoute la et nulle part ailleurs. Une liste plus
# etroite ici, plus un seuil trop haut, faisaient echouer la proposition
# d'adaptation en silence sur un jeu en HTML/CSS/JS — le defaut exact qui a fait
# passer le plugin pour inerte lors du premier essai en conditions reelles.
has_code() {
  # Racine absente ou illisible : rien a observer, jamais une erreur.
  [ -d "$1" ] || return 1
  # Les fichiers de la racine seule d'abord : c'est une lecture de repertoire,
  # et cela suffit a repondre sur la plupart des projets (un jeu HTML/CSS/JS,
  # un paquet a plat) sans parcourir le depot. Le verdict est le meme — deux
  # fichiers de code a la racine sont deux fichiers de code du depot.
  #
  # Le cout n'est pas dans find (0,03 s pour 20 000 fichiers) mais dans le
  # « while read » qui relit ses lignes une a une (1,2 s pour les memes 20 000) :
  # ne pas lui donner a lire ce dont on n'a pas besoin est le seul levier reel,
  # et le hook n'a que dix secondes. Une deuxieme passe bornee plus profond a ete
  # essayee puis retiree : sur un depot dont les fichiers sont tous a la meme
  # profondeur, elle refaisait presque tout le parcours et doublait le pire cas.
  _has_two_code_files "$1" -maxdepth 1 && return 0
  _has_two_code_files "$1"
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

# doc_status <racine> : pour chaque agent de documentation installe, une ligne
# « agent fichier etat » (etat = absent | present). Rien si aucun n'est installe.
#
# La correspondance agent -> fichier est volontairement explicite ici : c'est le
# seul endroit a changer si un modele d'agent adopte un autre nom de fichier.
# Chaque fichier accepte plusieurs noms d'agent, separes par « | » : un projet
# equipe avant le plugin nomme souvent ces agents en anglais, et renommer ses
# agents rodes juste pour satisfaire le plugin serait le mauvais sens.
doc_status() {
  _root="$1"
  for _pair in "memoire-projet|project-memory PROJECT_MEMORY.md" \
               "guide-utilisateur|user-guide USER_GUIDE.md" \
               "reference-api|api-reference API_REFERENCE.md"; do
    _noms="${_pair%% *}"
    _file="${_pair##* }"
    _agent=""
    _reste="$_noms"
    while [ -n "$_reste" ]; do
      _n="${_reste%%|*}"
      if [ -f "$_root/.claude/agents/$_n.md" ]; then
        _agent="$_n"
        break
      fi
      [ "$_reste" = "$_n" ] && break
      _reste="${_reste#*|}"
    done
    [ -n "$_agent" ] || continue
    if [ -f "$_root/$_file" ]; then
      printf '%s %s present\n' "$_agent" "$_file"
    else
      printf '%s %s absent\n' "$_agent" "$_file"
    fi
  done
}

# changed_since <racine> <fichier_repere> : fichiers de code modifies depuis le
# repere, un par ligne.
#
# Raison d'etre : le hook PostToolUse ne voit que Edit/Write/MultiEdit. En mode
# automatique, Claude ecrit les fichiers par Bash (heredoc, sed, script) — la
# file d'attente reste alors vide et le filet de securite ne se declenche jamais.
# Comparer les dates de modification a un repere pose en debut de tour rattrape
# toutes les voies d'ecriture, quel que soit l'outil employe.
changed_since() {
  _root="$1"
  _ref="$2"
  # Repere absent ou racine illisible : aucune liste, et surtout aucune erreur.
  [ -d "$_root" ] || return 0
  [ -f "$_ref" ] || return 0
  _find_code_files "$_root" -newer "$_ref" | while IFS= read -r _f; do
    # Filtre de chaine d'abord : les lignes ecartees ne coutent aucun appel
    # systeme. Les deux conditions restent exigees, l'ordre ne change rien.
    is_reviewable "$_f" || continue
    # « read » coupe aux retours a la ligne : un nom de fichier qui en contient
    # arrive en morceaux, qui ne designent aucun fichier. Le test d'existence
    # les ecarte, et couvre aussi un fichier supprime depuis le passage de find.
    [ -f "$_f" ] || continue
    printf '%s\n' "$_f"
  done
  # Statut fixe : sans cela le code de retour est celui du dernier is_reviewable,
  # et un appelant qui ecrirait « if changed_since ... » lirait « rien n'a change »
  # simplement parce que le dernier fichier trouve n'etait pas du code.
  return 0
}

# revue_en_cours <racine> : 0 si une passe de revue est en cours dans ce projet.
#
# Les sous-agents de revue editent le code qu'ils corrigent. Sans ce marqueur,
# leurs propres editions comptaient comme « du code non revise » : le hook Stop
# redemandait une revue a la fin de chaque tour de la passe, et le rappel
# PostToolUse arrivait dans le contexte des sous-agents eux-memes. Observe
# quatre fois de suite lors de la premiere passe reelle.
#
# Le marqueur est pose par la commande de revue et retire par elle. Un marqueur
# de plus de 30 minutes est considere comme abandonne (passe interrompue) et
# efface : sans cette peremption, une revue avortee desarmerait le filet de
# securite pour toujours.
revue_en_cours() {
  _m="$(state_path "$1")/revue-en-cours"
  [ -f "$_m" ] || return 1
  if [ -n "$(find "$_m" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    rm -f "$_m" 2>/dev/null || true
    return 1
  fi
  return 0
}
