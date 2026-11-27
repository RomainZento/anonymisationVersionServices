#!/usr/bin/env bash
#
# anonymisation.sh
#
# 1. Inventaire des services installés sur la machine et de leurs versions
#    (affiché en clair, en local uniquement).
# 2. Masquage des numéros de version vus depuis l'extérieur
#    (en-têtes HTTP, pages d'erreur, bannière SSH).
#
# Usage :
#   ./anonymisation.sh inventaire   Liste les services et leurs versions
#   ./anonymisation.sh appliquer    Masque les versions exposées (root requis)

set -u

# Préfixe ajouté à tous les chemins système. Vide en usage normal,
# pointe vers un dossier temporaire dans les tests.
RACINE="${RACINE:-}"

# 1 = tester la configuration et recharger les services après modification.
# 0 = ne rien tester ni recharger (utilisé par les tests).
RECHARGER="${RECHARGER:-1}"

HORODATAGE="$(date +%Y%m%d-%H%M%S)"

PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

# Fichiers touchés pour le service en cours de traitement, un chemin par
# ligne. Servent à restaurer la configuration si la vérification échoue.
FICHIERS_MODIFIES=""
FICHIERS_CREES=""

# ---------------------------------------------------------------------------
# Inventaire
# ---------------------------------------------------------------------------

# nom|commande qui affiche la version.
# Pour un même nom, seule la première commande qui répond est retenue.
LISTE_SERVICES='python3|python3 --version
python2|python2 --version
node|node --version
npm|npm --version
php|php -v
composer|composer --version --no-ansi --no-interaction
nginx|nginx -v
apache|apache2ctl -v
apache|httpd -v
mariadb|mariadbd --version
mysql|mysqld --version
postgresql|psql --version
redis|redis-server --version
mongodb|mongod --version
haproxy|haproxy -v
varnish|varnishd -V
openssh|ssh -V
openssl|openssl version
curl|curl --version
git|git --version
docker|docker --version
docker-compose|docker compose version
docker-compose|docker-compose --version
java|java -version
ruby|ruby --version
perl|perl --version
go|go version'

# Renvoie le premier numéro de version (ex: 1.24.0) trouvé dans le texte.
extraire_version() {
    printf '%s\n' "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1
}

# Lance une commande de version avec une limite de temps si possible.
lancer_commande() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 10 $1 </dev/null 2>&1
    else
        $1 </dev/null 2>&1
    fi
}

inventaire() {
    local deja=" " nom commande chemin sortie version

    printf '%-16s %-16s %s\n' "SERVICE" "VERSION" "EMPLACEMENT"
    while IFS='|' read -r nom commande; do
        [ -n "$nom" ] || continue
        case "$deja" in *" $nom "*) continue ;; esac

        chemin="$(command -v "${commande%% *}" 2>/dev/null)" || continue
        sortie="$(lancer_commande "$commande")" || continue

        # Sur certaines distributions, mysqld est en réalité MariaDB.
        if [ "$nom" = "mysql" ] && printf '%s' "$sortie" | grep -qi mariadb; then
            nom="mariadb"
            case "$deja" in *" $nom "*) continue ;; esac
        fi

        version="$(extraire_version "$sortie")"
        [ -n "$version" ] || continue

        printf '%-16s %-16s %s\n' "$nom" "$version" "$chemin"
        deja="$deja$nom "
    done <<EOF
$LISTE_SERVICES
EOF

    inventaire_conteneurs
}

inventaire_conteneurs() {
    local liste nom image
    command -v docker >/dev/null 2>&1 || return 0
    liste="$(docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null)" || return 0
    [ -n "$liste" ] || return 0

    printf '\nCONTENEURS DOCKER\n'
    printf '%-30s %s\n' "NOM" "IMAGE"
    while IFS='|' read -r nom image; do
        printf '%-30s %s\n' "$nom" "$image"
    done <<EOF
$liste
EOF
}

# ---------------------------------------------------------------------------
# Outils pour modifier les fichiers de configuration
# ---------------------------------------------------------------------------

racine_sauvegardes() {
    printf '%s\n' "$RACINE/var/backups/masquage-versions"
}

# Dossier de sauvegarde du lancement en cours.
dossier_sauvegarde() {
    printf '%s\n' "$(racine_sauvegardes)/$HORODATAGE"
}

# Dernière sauvegarde qui peut encore être annulée (avec un manifeste).
derniere_sauvegarde() {
    local d dernier=""
    for d in "$(racine_sauvegardes)"/*/; do
        [ -f "${d}manifeste.txt" ] && dernier="${d%/}"
    done
    printf '%s\n' "$dernier"
}

lister_sauvegardes() {
    local d
    for d in "$(racine_sauvegardes)"/*/; do
        [ -f "${d}manifeste.txt" ] && printf '  %s\n' "$(basename "$d")"
    done
    return 0
}

# Ajoute au manifeste de la sauvegarde les fichiers touchés pour un service.
# Format d'une ligne : <service> <modifie|cree> <chemin>
ecrire_manifeste() {
    local service="$1" manifeste f
    manifeste="$(dossier_sauvegarde)/manifeste.txt"
    mkdir -p "$(dossier_sauvegarde)"
    printf '%s' "$FICHIERS_MODIFIES" | sort -u | while IFS= read -r f; do
        [ -n "$f" ] && printf '%s modifie %s\n' "$service" "${f#"$RACINE"}"
    done >>"$manifeste"
    printf '%s' "$FICHIERS_CREES" | sort -u | while IFS= read -r f; do
        [ -n "$f" ] && printf '%s cree %s\n' "$service" "${f#"$RACINE"}"
    done >>"$manifeste"
    return 0
}

reinitialiser_suivi() {
    FICHIERS_MODIFIES=""
    FICHIERS_CREES=""
}

# Copie le fichier dans le dossier de sauvegarde avant sa première
# modification. La sauvegarde est rangée hors de /etc pour ne jamais être
# chargée par un service (ex: sites-enabled/*).
sauvegarder() {
    local fichier="$1" copie
    copie="$(dossier_sauvegarde)${fichier#"$RACINE"}"
    if [ ! -e "$copie" ]; then
        mkdir -p "$(dirname "$copie")"
        cp -p "$fichier" "$copie"
    fi
    FICHIERS_MODIFIES="$FICHIERS_MODIFIES$fichier
"
}

# Applique une expression sed -E au fichier, en conservant ses droits.
remplacer_dans_fichier() {
    local fichier="$1" expression="$2" tmp
    tmp="$(mktemp)"
    sed -E "$expression" "$fichier" >"$tmp" && cat "$tmp" >"$fichier"
    rm -f "$tmp"
}

# Crée (ou remplace) un fichier avec le contenu donné, s'il diffère.
creer_fichier() {
    local fichier="$1" contenu="$2"
    if [ -f "$fichier" ]; then
        [ "$(cat "$fichier")" = "$contenu" ] && return 0
        sauvegarder "$fichier"
    else
        mkdir -p "$(dirname "$fichier")"
        FICHIERS_CREES="$FICHIERS_CREES$fichier
"
    fi
    printf '%s\n' "$contenu" >"$fichier"
}

# Remet les fichiers dans leur état d'avant modification.
restaurer() {
    local f
    while IFS= read -r f; do
        [ -n "$f" ] && rm -f "$f"
    done <<EOF
$FICHIERS_CREES
EOF
    while IFS= read -r f; do
        [ -n "$f" ] && cp -p "$(dossier_sauvegarde)${f#"$RACINE"}" "$f"
    done <<EOF
$FICHIERS_MODIFIES
EOF
}

# Vrai si le programme est installé. Toujours vrai pendant les tests.
binaire_present() {
    [ "$RECHARGER" = 0 ] || command -v "$1" >/dev/null 2>&1
}

recharger_service() {
    systemctl reload "$1" >/dev/null 2>&1 || service "$1" reload >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Masquage par service
# Codes retour : 0 = fait, 1 = échec, 2 = non installé, 3 = non applicable
# ---------------------------------------------------------------------------

# PHP : supprime l'en-tête X-Powered-By: PHP/x.y.z
masquer_php() {
    local f trouve=0
    for f in "$RACINE"/etc/php/*/*/php.ini "$RACINE"/etc/php.ini; do
        [ -f "$f" ] || continue
        trouve=1
        if grep -qE '^[[:space:]]*expose_php[[:space:]]*=' "$f"; then
            if grep -E '^[[:space:]]*expose_php[[:space:]]*=' "$f" |
                grep -qviE '=[[:space:]]*"?off"?[[:space:]]*$'; then
                sauvegarder "$f"
                remplacer_dans_fichier "$f" 's/^[[:space:]]*expose_php[[:space:]]*=.*/expose_php = Off/'
            fi
        else
            sauvegarder "$f"
            printf '\nexpose_php = Off\n' >>"$f"
        fi
    done
    [ "$trouve" = 1 ] || return 2
    return 0
}

unites_php_fpm() {
    systemctl list-units --type=service --state=active \
        --no-legend --plain 'php*fpm*' 2>/dev/null | awk '{print $1}'
}

valider_php() {
    local unite
    [ "$RECHARGER" = 1 ] || return 0
    for unite in $(unites_php_fpm); do
        recharger_service "$unite" || return 1
    done
    return 0
}

# nginx : Server: nginx/1.24.0 devient Server: nginx
masquer_nginx() {
    local dossier="$RACINE/etc/nginx" conf="$RACINE/etc/nginx/nginx.conf" f tmp
    [ -f "$conf" ] && binaire_present nginx || return 2

    # Toute directive server_tokens active différente de off passe à off
    # (nginx.conf, sites, conf.d, snippets).
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if grep -E '^[[:space:]]*server_tokens[[:space:]]' "$f" |
            grep -qvE 'server_tokens[[:space:]]+off[[:space:]]*;'; then
            sauvegarder "$f"
            remplacer_dans_fichier "$f" 's/^([[:space:]]*)server_tokens[[:space:]]+[^;]*;/\1server_tokens off;/'
        fi
    done <<EOF
$(grep -RlE '^[[:space:]]*server_tokens[[:space:]]' "$dossier" 2>/dev/null)
EOF

    # Aucune directive dans nginx.conf : on l'ajoute dans le bloc http.
    if ! grep -qE '^[[:space:]]*server_tokens[[:space:]]' "$conf"; then
        if grep -qE '^[[:space:]]*http[[:space:]]*\{' "$conf"; then
            sauvegarder "$conf"
            tmp="$(mktemp)"
            awk '{ print }
                 !fait && /^[[:space:]]*http[[:space:]]*\{/ { print "    server_tokens off;"; fait = 1 }' \
                "$conf" >"$tmp" && cat "$tmp" >"$conf"
            rm -f "$tmp"
        else
            creer_fichier "$dossier/conf.d/zz-masquage-version.conf" "server_tokens off;"
        fi
    fi
    return 0
}

valider_nginx() {
    [ "$RECHARGER" = 1 ] || return 0
    nginx -t >/dev/null 2>&1 && recharger_service nginx
}

# Apache : Server: Apache/2.4.58 (Ubuntu) devient Server: Apache
APACHE_CONF='# Ajouté par anonymisation.sh : masque la version d Apache
ServerTokens Prod
ServerSignature Off'

masquer_apache() {
    local lien
    if [ -d "$RACINE/etc/apache2" ] && binaire_present apache2ctl; then
        # Le préfixe zz garantit un chargement après security.conf.
        creer_fichier "$RACINE/etc/apache2/conf-available/zz-masquage-version.conf" "$APACHE_CONF"
        lien="$RACINE/etc/apache2/conf-enabled/zz-masquage-version.conf"
        if [ ! -e "$lien" ] && [ ! -L "$lien" ]; then
            mkdir -p "$(dirname "$lien")"
            ln -s ../conf-available/zz-masquage-version.conf "$lien"
            FICHIERS_CREES="$FICHIERS_CREES$lien
"
        fi
    elif [ -d "$RACINE/etc/httpd" ] && binaire_present httpd; then
        creer_fichier "$RACINE/etc/httpd/conf.d/zz-masquage-version.conf" "$APACHE_CONF"
    else
        return 2
    fi
    return 0
}

valider_apache() {
    [ "$RECHARGER" = 1 ] || return 0
    if [ -d /etc/apache2 ]; then
        apache2ctl configtest >/dev/null 2>&1 && recharger_service apache2
    else
        httpd -t >/dev/null 2>&1 && recharger_service httpd
    fi
}

# SSH : retire le suffixe de distribution de la bannière
# (SSH-2.0-OpenSSH_9.6p1 Ubuntu-3 devient SSH-2.0-OpenSSH_9.6p1).
# Seule l'option DebianBanner (Debian/Ubuntu) le permet sans recompiler.
ssh_accepte_debianbanner() {
    [ "$RECHARGER" = 0 ] && return 0
    sshd -T 2>/dev/null | grep -qi '^debianbanner'
}

masquer_ssh() {
    local conf="$RACINE/etc/ssh/sshd_config" tmp
    [ -f "$conf" ] && binaire_present sshd || return 2
    ssh_accepte_debianbanner || return 3

    if grep -qE '^[[:space:]]*[Dd]ebian[Bb]anner[[:space:]]' "$conf"; then
        if grep -E '^[[:space:]]*[Dd]ebian[Bb]anner[[:space:]]' "$conf" |
            grep -qviE 'debianbanner[[:space:]]+no[[:space:]]*$'; then
            sauvegarder "$conf"
            remplacer_dans_fichier "$conf" 's/^[[:space:]]*[Dd]ebian[Bb]anner[[:space:]].*/DebianBanner no/'
        fi
    elif grep -qiE '^[[:space:]]*Include[[:space:]].*sshd_config\.d' "$conf"; then
        # sshd garde la première valeur lue : préfixe 00 pour passer en premier.
        creer_fichier "$RACINE/etc/ssh/sshd_config.d/00-masquage-version.conf" "DebianBanner no"
    else
        sauvegarder "$conf"
        tmp="$(mktemp)"
        { printf 'DebianBanner no\n'; cat "$conf"; } >"$tmp" && cat "$tmp" >"$conf"
        rm -f "$tmp"
    fi
    return 0
}

valider_ssh() {
    [ "$RECHARGER" = 1 ] || return 0
    sshd -t >/dev/null 2>&1 || return 1
    recharger_service ssh || recharger_service sshd
}

# ---------------------------------------------------------------------------
# Commande appliquer
# ---------------------------------------------------------------------------

appliquer() {
    local service code modifie=0

    if [ -z "$RACINE" ] && [ "$(id -u)" -ne 0 ]; then
        echo "Cette commande doit être lancée en root." >&2
        return 1
    fi

    # Sauvegardes accessibles à root uniquement.
    mkdir -p "$(racine_sauvegardes)"
    chmod 700 "$(racine_sauvegardes)"

    # Etat de référence utilisé par la commande verifier pour détecter
    # les régressions.
    if [ "$RECHARGER" = 1 ]; then
        capturer_etat >"$(fichier_etat_avant)"
    fi

    # PHP en premier pour qu'Apache (mod_php) recharge le php.ini modifié.
    for service in php nginx apache ssh; do
        reinitialiser_suivi
        "masquer_$service"
        code=$?
        case "$code" in
            2) printf '%-8s non installé\n' "$service"; continue ;;
            3) printf '%-8s version non masquable sur ce système\n' "$service"; continue ;;
            1) restaurer; printf '%-8s échec, configuration restaurée\n' "$service"; continue ;;
        esac

        if [ -z "$FICHIERS_MODIFIES$FICHIERS_CREES" ]; then
            printf '%-8s déjà masqué\n' "$service"
        elif "valider_$service"; then
            modifie=1
            ecrire_manifeste "$service"
            printf '%-8s version masquée\n' "$service"
        else
            restaurer
            printf '%-8s configuration refusée par le service, restaurée\n' "$service"
        fi
    done

    if [ "$modifie" = 1 ]; then
        printf '\nSauvegarde : %s\n' "$(dossier_sauvegarde)"
        printf 'Pour revenir en arrière : sudo %s annuler\n' "$0"
    fi
}

# ---------------------------------------------------------------------------
# Commande verifier : contrôle du masquage et absence de régression
# ---------------------------------------------------------------------------

fichier_etat_avant() {
    printf '%s\n' "$RACINE/var/backups/masquage-versions/etat-avant.txt"
}

NB_OK=0
NB_ECHECS=0

# $1 = OK, ECHEC ou INFO ; $2 = message
resultat() {
    printf '%-6s %s\n' "$1" "$2"
    case "$1" in
        OK) NB_OK=$((NB_OK + 1)) ;;
        ECHEC) NB_ECHECS=$((NB_ECHECS + 1)) ;;
    esac
}

# Affiche les en-têtes HTTP qui révèlent une version ou un système.
# Ex : "Server: nginx/1.24.0", "Server: Apache (Ubuntu)", "X-Powered-By: PHP/8.2.12"
fuites_entetes() {
    printf '%s\n' "$1" | tr -d '\r' |
        grep -iE '^(server|x-powered-by|x-aspnet-version|x-aspnetmvc-version):' |
        grep -E '[0-9]|\('
}

# Affiche les signatures de version présentes dans une page (pages d'erreur).
fuites_page() {
    printf '%s\n' "$1" | grep -oiE '(nginx|apache|php|openresty)/[0-9][0-9.]*' | sort -u
}

# Vrai si la bannière SSH contient un suffixe de distribution
# (ex : "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13").
banniere_ssh_avec_suffixe() {
    printf '%s\n' "$1" | tr -d '\r' | grep -qE '^SSH-[0-9.]+-[^ ]+ .+'
}

# Affiche les php.ini où expose_php n'est pas à Off.
fuites_php_ini() {
    local f
    for f in "$RACINE"/etc/php/*/*/php.ini "$RACINE"/etc/php.ini; do
        [ -f "$f" ] || continue
        if ! grep -qE '^[[:space:]]*expose_php[[:space:]]*=' "$f" ||
            grep -E '^[[:space:]]*expose_php[[:space:]]*=' "$f" |
            grep -qviE '=[[:space:]]*"?off"?[[:space:]]*$'; then
            printf '%s\n' "$f"
        fi
    done
}

# Ports TCP sur lesquels nginx ou Apache écoutent.
ports_web() {
    ss -ltnp 2>/dev/null | grep -E '"(nginx|apache2|httpd)"' |
        awk '{print $4}' | sed 's/.*://' | sort -un
}

# URL locale d'un port web : HTTPS si le port y répond, HTTP sinon.
url_locale() {
    local port="$1" proto
    for proto in https http; do
        if [ "$(curl -sk -o /dev/null -w '%{http_code}' -m 5 "$proto://127.0.0.1:$port/")" != "000" ]; then
            printf '%s://127.0.0.1:%s\n' "$proto" "$port"
            return 0
        fi
    done
    printf 'http://127.0.0.1:%s\n' "$port"
}

code_http() {
    curl -sk -o /dev/null -w '%{http_code}' -m 5 "$(url_locale "$1")/"
}

lire_banniere_ssh() {
    timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1 && head -n 1 <&3" 2>/dev/null | tr -d '\r'
}

# Etat des services, une ligne par élément :
#   service <unité> actif
#   http <port> <code HTTP>
capturer_etat() {
    local unite port
    for unite in nginx apache2 httpd ssh sshd $(unites_php_fpm); do
        if systemctl is-active --quiet "$unite" 2>/dev/null; then
            printf 'service %s actif\n' "$unite"
        fi
    done
    for port in $(ports_web); do
        printf 'http %s %s\n' "$port" "$(code_http "$port")"
    done
}

# Compare deux fichiers d'état et affiche les régressions.
# $1 = état avant, $2 = état actuel
comparer_etats() {
    local type nom valeur actuel
    while read -r type nom valeur; do
        case "$type" in
            service)
                grep -qx "service $nom actif" "$2" ||
                    printf "service %s : n'est plus actif\n" "$nom"
                ;;
            http)
                actuel="$(awk -v p="$nom" '$1 == "http" && $2 == p { print $3 }' "$2")"
                [ "$actuel" = "$valeur" ] ||
                    printf 'port %s : code HTTP %s avant, %s maintenant\n' "$nom" "$valeur" "${actuel:-absent}"
                ;;
        esac
    done <"$1"
}

verification() {
    local port url fuites f banniere port_ssh avant actuel regressions ligne

    if [ "$(id -u)" -ne 0 ]; then
        echo "Cette commande doit être lancée en root." >&2
        return 1
    fi
    NB_OK=0
    NB_ECHECS=0

    echo "-- Configurations"
    if command -v nginx >/dev/null 2>&1; then
        if nginx -t >/dev/null 2>&1; then
            resultat OK "nginx : configuration valide"
        else
            resultat ECHEC "nginx : configuration invalide (voir nginx -t)"
        fi
        if nginx -T 2>/dev/null | grep -qE '^[[:space:]]*server_tokens[[:space:]]+(on|build)'; then
            resultat ECHEC "nginx : server_tokens encore actif quelque part (voir nginx -T)"
        elif nginx -T 2>/dev/null | grep -qE '^[[:space:]]*server_tokens[[:space:]]+off'; then
            resultat OK "nginx : server_tokens off"
        else
            resultat ECHEC "nginx : server_tokens off absent"
        fi
    fi
    if command -v apache2ctl >/dev/null 2>&1; then
        if apache2ctl configtest >/dev/null 2>&1; then
            resultat OK "apache : configuration valide"
        else
            resultat ECHEC "apache : configuration invalide (voir apache2ctl configtest)"
        fi
    elif command -v httpd >/dev/null 2>&1; then
        if httpd -t >/dev/null 2>&1; then
            resultat OK "apache : configuration valide"
        else
            resultat ECHEC "apache : configuration invalide (voir httpd -t)"
        fi
    fi
    if command -v sshd >/dev/null 2>&1; then
        if sshd -t >/dev/null 2>&1; then
            resultat OK "ssh : configuration valide"
        else
            resultat ECHEC "ssh : configuration invalide (voir sshd -t)"
        fi
    fi
    fuites="$(fuites_php_ini)"
    if [ -n "$fuites" ]; then
        while IFS= read -r f; do
            resultat ECHEC "php : expose_php n'est pas à Off dans $f"
        done <<EOF
$fuites
EOF
    elif command -v php >/dev/null 2>&1; then
        resultat OK "php : expose_php = Off"
    fi

    echo
    echo "-- Ce que voit un client"
    for port in $(ports_web); do
        url="$(url_locale "$port")"
        fuites="$(fuites_entetes "$(curl -sk -m 5 -D - -o /dev/null "$url/")")"
        if [ -n "$fuites" ]; then
            resultat ECHEC "$url : $(printf '%s' "$fuites" | tr '\n' ' ')"
        else
            resultat OK "$url : en-têtes sans version"
        fi
        fuites="$(fuites_page "$(curl -sk -m 5 "$url/verification-masquage-$$")")"
        if [ -n "$fuites" ]; then
            resultat ECHEC "$url : page d'erreur affiche $(printf '%s' "$fuites" | tr '\n' ' ')"
        else
            resultat OK "$url : page d'erreur sans version"
        fi
    done
    [ -n "$(ports_web)" ] || resultat INFO "aucun port web nginx ou Apache en écoute"

    if command -v sshd >/dev/null 2>&1; then
        port_ssh="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
        banniere="$(lire_banniere_ssh "${port_ssh:-22}")"
        if [ -z "$banniere" ]; then
            resultat INFO "ssh : bannière non lue sur 127.0.0.1:${port_ssh:-22}"
        elif ! ssh_accepte_debianbanner; then
            resultat INFO "ssh : version OpenSSH non masquable sur ce système ($banniere)"
        elif banniere_ssh_avec_suffixe "$banniere"; then
            resultat ECHEC "ssh : bannière avec suffixe de distribution ($banniere)"
        else
            resultat OK "ssh : bannière sans suffixe de distribution ($banniere)"
        fi
    fi

    echo
    echo "-- Régressions"
    avant="$(fichier_etat_avant)"
    if [ -f "$avant" ]; then
        actuel="$(mktemp)"
        capturer_etat >"$actuel"
        regressions="$(comparer_etats "$avant" "$actuel")"
        rm -f "$actuel"
        if [ -z "$regressions" ]; then
            resultat OK "services actifs et codes HTTP identiques à avant appliquer"
        else
            while IFS= read -r ligne; do
                resultat ECHEC "$ligne"
            done <<EOF
$regressions
EOF
        fi
    else
        resultat INFO "pas d'état de référence : lancer appliquer d'abord"
    fi

    printf '\nOK : %s  Echecs : %s\n' "$NB_OK" "$NB_ECHECS"
    [ "$NB_ECHECS" = 0 ]
}

# ---------------------------------------------------------------------------
# Commandes annuler et nettoyer
# ---------------------------------------------------------------------------

# Remet les fichiers listés dans le manifeste d'une sauvegarde (la dernière
# par défaut), puis teste et recharge les services concernés.
annuler() {
    local dossier service action chemin services="" code=0

    if [ -z "$RACINE" ] && [ "$(id -u)" -ne 0 ]; then
        echo "Cette commande doit être lancée en root." >&2
        return 1
    fi

    if [ -n "${1:-}" ]; then
        case "$1" in
            *[!0-9-]*) echo "Date de sauvegarde invalide : $1" >&2; return 1 ;;
        esac
        dossier="$(racine_sauvegardes)/$1"
    else
        dossier="$(derniere_sauvegarde)"
    fi

    if [ -z "$dossier" ] || [ ! -f "$dossier/manifeste.txt" ]; then
        echo "Aucune sauvegarde à annuler. Sauvegardes disponibles :" >&2
        lister_sauvegardes >&2
        return 1
    fi

    while read -r service action chemin; do
        case "$action" in
            modifie) cp -p "$dossier$chemin" "$RACINE$chemin" ;;
            cree) rm -f "$RACINE$chemin" ;;
            *) continue ;;
        esac
        case " $services " in
            *" $service "*) ;;
            *) services="$services $service" ;;
        esac
    done <"$dossier/manifeste.txt"

    # Le service n'est rechargé que si sa configuration est acceptée.
    for service in $services; do
        if "valider_$service"; then
            printf "%-8s configuration d'origine remise\n" "$service"
        else
            printf '%-8s fichiers remis mais configuration refusée, service non rechargé\n' "$service"
            code=1
        fi
    done

    mv "$dossier/manifeste.txt" "$dossier/manifeste.annule.txt"
    printf '\nSauvegarde annulée : %s\n' "$(basename "$dossier")"
    return "$code"
}

# Supprime les sauvegardes si la vérification est entièrement OK,
# en gardant la dernière pour pouvoir encore revenir en arrière.
nettoyer_sauvegardes() {
    local garder d

    if [ -z "$RACINE" ] && [ "$(id -u)" -ne 0 ]; then
        echo "Cette commande doit être lancée en root." >&2
        return 1
    fi

    if [ "$RECHARGER" = 1 ]; then
        if ! verification; then
            printf '\nVérification en échec : aucune sauvegarde supprimée.\n'
            return 1
        fi
        echo
    fi

    garder="$(derniere_sauvegarde)"
    for d in "$(racine_sauvegardes)"/*/; do
        d="${d%/}"
        [ -d "$d" ] || continue
        [ "$d" = "$garder" ] && continue
        rm -rf "$d"
        printf 'Sauvegarde supprimée : %s\n' "$(basename "$d")"
    done

    if [ -n "$garder" ]; then
        printf 'Sauvegarde conservée : %s\n' "$(basename "$garder")"
        printf 'Pour revenir en arrière : sudo %s annuler\n' "$0"
    fi
}

usage() {
    cat <<EOF
Usage : $0 <commande>

  inventaire       Liste les services installés et leurs versions (en clair, en local)
  appliquer        Masque les versions vues depuis l'extérieur (root requis)
  verifier         Contrôle le masquage et l'absence de régression (root requis)
  annuler [date]   Revient à l'état d'avant une sauvegarde, la dernière par défaut (root requis)
  nettoyer         Si verifier est OK, supprime les sauvegardes sauf la dernière (root requis)
EOF
}

main() {
    case "${1:-}" in
        inventaire) inventaire ;;
        appliquer) appliquer ;;
        verifier) verification ;;
        annuler) annuler "${2:-}" ;;
        nettoyer) nettoyer_sauvegardes ;;
        *) usage; return 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
