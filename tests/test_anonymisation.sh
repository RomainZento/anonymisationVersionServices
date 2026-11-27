#!/usr/bin/env bash
#
# Tests de anonymisation.sh
# Chaque test travaille dans un dossier temporaire (RACINE), sans toucher
# au système ni recharger de service.
#
# Usage : ./tests/test_anonymisation.sh

set -u
cd "$(dirname "$0")/.." || exit 1

RECHARGER=0
# shellcheck source=../anonymisation.sh
. ./anonymisation.sh

REUSSIS=0
ECHECS=0

verifier() {
    local description="$1"
    shift
    if "$@"; then
        REUSSIS=$((REUSSIS + 1))
    else
        ECHECS=$((ECHECS + 1))
        echo "ECHEC : $description"
    fi
}

preparer() {
    RACINE="$(mktemp -d)"
    reinitialiser_suivi
}

nettoyer() {
    rm -rf "$RACINE"
}

compter() {
    grep -cE "$1" "$2"
}

# Inverse le résultat de la commande donnée.
non() {
    ! "$@"
}

# Vrai si le motif est absent du fichier.
absent() {
    ! grep -q "$@"
}

# --- extraction de version --------------------------------------------------

test_extraire_version() {
    verifier "nginx" [ "$(extraire_version 'nginx version: nginx/1.24.0')" = "1.24.0" ]
    verifier "apache" [ "$(extraire_version 'Server version: Apache/2.4.58 (Ubuntu)')" = "2.4.58" ]
    verifier "java" [ "$(extraire_version 'openjdk version "17.0.9" 2023-10-17')" = "17.0.9" ]
    verifier "go" [ "$(extraire_version 'go version go1.21.5 linux/amd64')" = "1.21.5" ]
    verifier "node" [ "$(extraire_version 'v20.10.0')" = "20.10.0" ]
    verifier "mariadb" [ "$(extraire_version 'mariadbd  Ver 10.11.6-MariaDB-0+deb12u1 for debian-linux-gnu')" = "10.11.6" ]
    verifier "ssh" [ "$(extraire_version 'OpenSSH_9.6p1 Ubuntu-3ubuntu13, OpenSSL 3.0.13 30 Jan 2024')" = "9.6" ]
    verifier "sans version" [ -z "$(extraire_version 'commande introuvable')" ]
}

# --- nginx ------------------------------------------------------------------

ecrire_nginx_conf() {
    mkdir -p "$RACINE/etc/nginx"
    cat >"$RACINE/etc/nginx/nginx.conf" <<'EOF'
user www-data;
events {
    worker_connections 768;
}
http {
    # server_tokens off;
    include /etc/nginx/conf.d/*.conf;
}
EOF
}

test_nginx_ajout_dans_bloc_http() {
    preparer
    ecrire_nginx_conf
    masquer_nginx
    local conf="$RACINE/etc/nginx/nginx.conf"
    verifier "nginx : directive ajoutée une fois" [ "$(compter '^[[:space:]]+server_tokens off;' "$conf")" = 1 ]
    verifier "nginx : directive placée juste après http {" \
        [ "$(grep -A1 '^http {' "$conf" | tail -n 1 | sed 's/^ *//')" = "server_tokens off;" ]
    nettoyer
}

test_nginx_directive_on_dans_un_site() {
    preparer
    ecrire_nginx_conf
    mkdir -p "$RACINE/etc/nginx/sites-available"
    printf 'server {\n    listen 80;\n    server_tokens on;\n}\n' >"$RACINE/etc/nginx/sites-available/app"
    masquer_nginx
    verifier "nginx : server_tokens on remplacé" absent 'server_tokens on' "$RACINE/etc/nginx/sites-available/app"
    verifier "nginx : sauvegarde hors de /etc/nginx" \
        grep -q 'server_tokens on' "$(dossier_sauvegarde)/etc/nginx/sites-available/app"
    nettoyer
}

test_nginx_idempotent() {
    preparer
    ecrire_nginx_conf
    masquer_nginx
    reinitialiser_suivi
    masquer_nginx
    verifier "nginx : rien à modifier au second passage" [ -z "$FICHIERS_MODIFIES$FICHIERS_CREES" ]
    verifier "nginx : pas de doublon" \
        [ "$(compter '^[[:space:]]+server_tokens off;' "$RACINE/etc/nginx/nginx.conf")" = 1 ]
    nettoyer
}

test_nginx_absent() {
    preparer
    masquer_nginx
    verifier "nginx : absent renvoie 2" [ $? = 2 ]
    nettoyer
}

test_restauration() {
    preparer
    ecrire_nginx_conf
    cp "$RACINE/etc/nginx/nginx.conf" "$RACINE/original"
    masquer_nginx
    restaurer
    verifier "restauration : fichier identique à l'original" cmp -s "$RACINE/original" "$RACINE/etc/nginx/nginx.conf"
    nettoyer
}

# --- apache -----------------------------------------------------------------

test_apache_debian() {
    preparer
    mkdir -p "$RACINE/etc/apache2"
    masquer_apache
    verifier "apache debian : fichier créé" grep -q 'ServerTokens Prod' "$RACINE/etc/apache2/conf-available/zz-masquage-version.conf"
    verifier "apache debian : configuration activée" [ -L "$RACINE/etc/apache2/conf-enabled/zz-masquage-version.conf" ]
    restaurer
    verifier "apache debian : restauration supprime les fichiers" [ ! -e "$RACINE/etc/apache2/conf-available/zz-masquage-version.conf" ]
    nettoyer
}

test_apache_rhel() {
    preparer
    mkdir -p "$RACINE/etc/httpd"
    masquer_apache
    verifier "apache rhel : fichier créé" grep -q 'ServerSignature Off' "$RACINE/etc/httpd/conf.d/zz-masquage-version.conf"
    nettoyer
}

# --- php --------------------------------------------------------------------

test_php() {
    preparer
    mkdir -p "$RACINE/etc/php/8.2/fpm" "$RACINE/etc/php/8.2/cli"
    printf '[PHP]\nexpose_php = On\n' >"$RACINE/etc/php/8.2/fpm/php.ini"
    printf '[PHP]\nmemory_limit = 128M\n' >"$RACINE/etc/php/8.2/cli/php.ini"
    masquer_php
    verifier "php : On remplacé par Off" grep -qx 'expose_php = Off' "$RACINE/etc/php/8.2/fpm/php.ini"
    verifier "php : plus de On" absent 'expose_php = On' "$RACINE/etc/php/8.2/fpm/php.ini"
    verifier "php : directive ajoutée si absente" grep -qx 'expose_php = Off' "$RACINE/etc/php/8.2/cli/php.ini"
    nettoyer
}

# --- ssh --------------------------------------------------------------------

test_ssh_avec_include() {
    preparer
    mkdir -p "$RACINE/etc/ssh"
    printf 'Include /etc/ssh/sshd_config.d/*.conf\nPort 22\n' >"$RACINE/etc/ssh/sshd_config"
    masquer_ssh
    verifier "ssh : fichier 00 créé" grep -qx 'DebianBanner no' "$RACINE/etc/ssh/sshd_config.d/00-masquage-version.conf"
    nettoyer
}

test_ssh_sans_include() {
    preparer
    mkdir -p "$RACINE/etc/ssh"
    printf 'Port 22\n' >"$RACINE/etc/ssh/sshd_config"
    masquer_ssh
    verifier "ssh : directive en première ligne" [ "$(head -n 1 "$RACINE/etc/ssh/sshd_config")" = "DebianBanner no" ]
    nettoyer
}

test_ssh_directive_existante() {
    preparer
    mkdir -p "$RACINE/etc/ssh"
    printf 'Port 22\nDebianBanner yes\n' >"$RACINE/etc/ssh/sshd_config"
    masquer_ssh
    verifier "ssh : yes remplacé par no" grep -qx 'DebianBanner no' "$RACINE/etc/ssh/sshd_config"
    verifier "ssh : une seule directive" [ "$(compter 'DebianBanner' "$RACINE/etc/ssh/sshd_config")" = 1 ]
    nettoyer
}

# --- verifier ---------------------------------------------------------------

test_fuites_entetes() {
    local masques='HTTP/1.1 200 OK
Server: nginx
Content-Type: text/html
X-Powered-By: Express'
    verifier "en-têtes masqués : aucune fuite" [ -z "$(fuites_entetes "$masques")" ]
    verifier "en-têtes : version nginx détectée" [ -n "$(fuites_entetes 'Server: nginx/1.24.0')" ]
    verifier "en-têtes : système Apache détecté" [ -n "$(fuites_entetes 'Server: Apache (Ubuntu)')" ]
    verifier "en-têtes : version PHP détectée" [ -n "$(fuites_entetes 'x-powered-by: PHP/8.2.12')" ]
    verifier "en-têtes : retour chariot HTTP ignoré" [ -z "$(fuites_entetes "$(printf 'Server: nginx\r')")" ]
}

test_fuites_page() {
    verifier "page : version nginx détectée" \
        [ "$(fuites_page '<hr><center>nginx/1.24.0</center>')" = "nginx/1.24.0" ]
    verifier "page : signature Apache détectée" \
        [ -n "$(fuites_page '<address>Apache/2.4.58 (Ubuntu) Server at localhost Port 80</address>')" ]
    verifier "page masquée : aucune fuite" [ -z "$(fuites_page '<hr><center>nginx</center>')" ]
}

test_banniere_ssh() {
    verifier "ssh : suffixe détecté" banniere_ssh_avec_suffixe 'SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13'
    verifier "ssh : bannière masquée acceptée" non banniere_ssh_avec_suffixe 'SSH-2.0-OpenSSH_9.6p1'
}

test_fuites_php_ini() {
    preparer
    mkdir -p "$RACINE/etc/php/8.2/fpm" "$RACINE/etc/php/8.2/cli"
    printf '[PHP]\nexpose_php = Off\n' >"$RACINE/etc/php/8.2/fpm/php.ini"
    printf '[PHP]\nexpose_php = On\n' >"$RACINE/etc/php/8.2/cli/php.ini"
    verifier "php.ini : seul le fichier à On est signalé" \
        [ "$(fuites_php_ini)" = "$RACINE/etc/php/8.2/cli/php.ini" ]
    masquer_php
    verifier "php.ini : plus de fuite après masquage" [ -z "$(fuites_php_ini)" ]
    nettoyer
}

test_comparer_etats() {
    preparer
    printf 'service nginx actif\nservice php8.2-fpm.service actif\nhttp 80 200\nhttp 443 301\n' >"$RACINE/avant"
    cp "$RACINE/avant" "$RACINE/identique"
    printf 'service nginx actif\nhttp 80 502\n' >"$RACINE/apres"
    verifier "états identiques : aucune régression" [ -z "$(comparer_etats "$RACINE/avant" "$RACINE/identique")" ]
    local regressions
    regressions="$(comparer_etats "$RACINE/avant" "$RACINE/apres")"
    verifier "régression : service arrêté détecté" grep -q 'php8.2-fpm.service' <<<"$regressions"
    verifier "régression : code HTTP changé détecté" grep -q 'port 80 : code HTTP 200 avant, 502' <<<"$regressions"
    verifier "régression : port disparu détecté" grep -q 'port 443 : code HTTP 301 avant, absent' <<<"$regressions"
    verifier "régression : service toujours actif non signalé" non grep -q 'service nginx' <<<"$regressions"
    nettoyer
}

# --- sauvegardes, annuler, nettoyer -----------------------------------------

# Machine fictive avec nginx, Apache (Debian) et SSH à masquer.
preparer_machine() {
    ecrire_nginx_conf
    mkdir -p "$RACINE/etc/apache2" "$RACINE/etc/ssh"
    printf 'Include /etc/ssh/sshd_config.d/*.conf\nPort 22\n' >"$RACINE/etc/ssh/sshd_config"
    cp "$RACINE/etc/nginx/nginx.conf" "$RACINE/nginx.original"
}

test_manifeste() {
    preparer
    preparer_machine
    HORODATAGE="20260101-000000"
    appliquer >/dev/null
    local manifeste="$RACINE/var/backups/masquage-versions/20260101-000000/manifeste.txt"
    verifier "manifeste : créé" [ -f "$manifeste" ]
    verifier "manifeste : fichier modifié listé" grep -qx 'nginx modifie /etc/nginx/nginx.conf' "$manifeste"
    verifier "manifeste : fichier créé listé" grep -qx 'ssh cree /etc/ssh/sshd_config.d/00-masquage-version.conf' "$manifeste"
    verifier "manifeste : lien Apache listé" grep -qx 'apache cree /etc/apache2/conf-enabled/zz-masquage-version.conf' "$manifeste"
    verifier "sauvegardes : accès root uniquement" \
        [ "$(ls -ld "$RACINE/var/backups/masquage-versions" | cut -c1-10)" = "drwx------" ]
    nettoyer
}

test_annuler() {
    preparer
    preparer_machine
    HORODATAGE="20260101-000000"
    appliquer >/dev/null
    annuler >/dev/null
    verifier "annuler : nginx.conf d'origine" cmp -s "$RACINE/nginx.original" "$RACINE/etc/nginx/nginx.conf"
    verifier "annuler : fichier Apache supprimé" [ ! -e "$RACINE/etc/apache2/conf-available/zz-masquage-version.conf" ]
    verifier "annuler : lien Apache supprimé" [ ! -L "$RACINE/etc/apache2/conf-enabled/zz-masquage-version.conf" ]
    verifier "annuler : fichier SSH supprimé" [ ! -e "$RACINE/etc/ssh/sshd_config.d/00-masquage-version.conf" ]
    verifier "annuler : manifeste marqué annulé" \
        [ -f "$RACINE/var/backups/masquage-versions/20260101-000000/manifeste.annule.txt" ]
    annuler >/dev/null 2>&1
    verifier "annuler : rien à annuler une seconde fois" [ $? = 1 ]
    nettoyer
}

test_annuler_deux_passages() {
    preparer
    preparer_machine
    HORODATAGE="20260101-000000"
    appliquer >/dev/null
    mkdir -p "$RACINE/etc/nginx/sites-available"
    printf 'server {\n    server_tokens on;\n}\n' >"$RACINE/etc/nginx/sites-available/nouveau"
    HORODATAGE="20260102-000000"
    appliquer >/dev/null
    annuler >/dev/null
    verifier "deux passages : le dernier est annulé en premier" \
        grep -q 'server_tokens on' "$RACINE/etc/nginx/sites-available/nouveau"
    verifier "deux passages : le premier est encore en place" \
        grep -q 'server_tokens off' "$RACINE/etc/nginx/nginx.conf"
    annuler >/dev/null
    verifier "deux passages : retour complet à l'origine" cmp -s "$RACINE/nginx.original" "$RACINE/etc/nginx/nginx.conf"
    nettoyer
}

test_annuler_date_invalide() {
    preparer
    annuler '../../etc' >/dev/null 2>&1
    verifier "annuler : date invalide refusée" [ $? = 1 ]
    nettoyer
}

test_nettoyer_garde_la_derniere() {
    preparer
    preparer_machine
    HORODATAGE="20260101-000000"
    appliquer >/dev/null
    mkdir -p "$RACINE/etc/nginx/sites-available"
    printf 'server {\n    server_tokens on;\n}\n' >"$RACINE/etc/nginx/sites-available/nouveau"
    HORODATAGE="20260102-000000"
    appliquer >/dev/null
    nettoyer_sauvegardes >/dev/null
    local racine="$RACINE/var/backups/masquage-versions"
    verifier "nettoyer : ancienne sauvegarde supprimée" [ ! -d "$racine/20260101-000000" ]
    verifier "nettoyer : dernière sauvegarde conservée" [ -f "$racine/20260102-000000/manifeste.txt" ]
    annuler >/dev/null
    verifier "nettoyer : la sauvegarde conservée reste annulable" \
        grep -q 'server_tokens on' "$RACINE/etc/nginx/sites-available/nouveau"
    nettoyer
}

# --- lancement --------------------------------------------------------------

test_extraire_version
test_nginx_ajout_dans_bloc_http
test_nginx_directive_on_dans_un_site
test_nginx_idempotent
test_nginx_absent
test_restauration
test_apache_debian
test_apache_rhel
test_php
test_ssh_avec_include
test_ssh_sans_include
test_ssh_directive_existante
test_fuites_entetes
test_fuites_page
test_banniere_ssh
test_fuites_php_ini
test_comparer_etats
test_manifeste
test_annuler
test_annuler_deux_passages
test_annuler_date_invalide
test_nettoyer_garde_la_derniere

echo "Réussis : $REUSSIS  Echecs : $ECHECS"
[ "$ECHECS" = 0 ]
