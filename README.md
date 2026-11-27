# Anonymisation des versions de services

Script bash qui :

1. liste les services installés sur la VM et leurs versions (en clair, en local) ;
2. masque les numéros de version visibles depuis l'extérieur (scans réseau).

## Utilisation

Copier `anonymisation.sh` sur la VM, puis :

```bash
# Liste des services et versions (pas besoin d'être root)
./anonymisation.sh inventaire

# Masquage des versions exposées
sudo ./anonymisation.sh appliquer
```

Pour garder l'inventaire dans un fichier lisible uniquement par root :

```bash
sudo sh -c './anonymisation.sh inventaire > /root/inventaire.txt && chmod 600 /root/inventaire.txt'
```

## Services détectés par l'inventaire

python, node, npm, php, composer, nginx, apache, mysql, mariadb, postgresql,
redis, mongodb, haproxy, varnish, openssh, openssl, curl, git, docker,
docker compose, java, ruby, perl, go, ainsi que les conteneurs Docker en cours
d'exécution.

## Ce que fait `appliquer`

| Service | Avant | Après | Modification |
|---|---|---|---|
| PHP | `X-Powered-By: PHP/8.2.12` | en-tête supprimé | `expose_php = Off` dans chaque `php.ini` |
| nginx | `Server: nginx/1.24.0` | `Server: nginx` | `server_tokens off;` (bloc `http` + sites qui l'activaient) |
| Apache | `Server: Apache/2.4.58 (Ubuntu)` | `Server: Apache` | `ServerTokens Prod` et `ServerSignature Off` |
| SSH (Debian/Ubuntu) | `OpenSSH_9.6p1 Ubuntu-3` | `OpenSSH_9.6p1` | `DebianBanner no` |

Pour chaque service :

- les fichiers sont sauvegardés avant modification dans
  `/var/backups/masquage-versions/<date>/` ;
- la configuration est testée (`nginx -t`, `apache2ctl configtest`, `sshd -t`)
  avant rechargement ;
- si le test échoue, les fichiers d'origine sont remis en place.

Le script peut être relancé sans risque : ce qui est déjà masqué n'est pas modifié.

## Tests

```bash
./tests/test_anonymisation.sh
```

Les tests travaillent dans un dossier temporaire et ne modifient pas le système.

## Systèmes pris en charge

Debian, Ubuntu, RHEL, Rocky, Alma (bash, systemd).
