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

dossier_sauvegarde() {
    printf '%s\n' "$RACINE/var/backups/masquage-versions/$HORODATAGE"
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

valider_php() {
    local unite
    [ "$RECHARGER" = 1 ] || return 0
    for unite in $(systemctl list-units --type=service --state=active \
        --no-legend --plain 'php*fpm*' 2>/dev/null | awk '{print $1}'); do
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
            printf '%-8s version masquée\n' "$service"
        else
            restaurer
            printf '%-8s configuration refusée par le service, restaurée\n' "$service"
        fi
    done

    if [ "$modifie" = 1 ] && [ -d "$(dossier_sauvegarde)" ]; then
        printf '\nSauvegardes des fichiers modifiés : %s\n' "$(dossier_sauvegarde)"
    fi
}

usage() {
    cat <<EOF
Usage : $0 <commande>

  inventaire   Liste les services installés et leurs versions (en clair, en local)
  appliquer    Masque les versions vues depuis l'extérieur (root requis)
EOF
}

main() {
    case "${1:-}" in
        inventaire) inventaire ;;
        appliquer) appliquer ;;
        *) usage; return 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
