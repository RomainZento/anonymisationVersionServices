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

# Contrôle du masquage et des régressions
sudo ./anonymisation.sh verifier

# Si tout est OK : suppression des anciennes sauvegardes (la dernière est gardée)
sudo ./anonymisation.sh nettoyer
```

**Revenir en arrière avec la dernière sauvegarde :** `sudo ./anonymisation.sh annuler`

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

Avant toute modification, `appliquer` enregistre l'état des services dans
`/var/backups/masquage-versions/etat-avant.txt` (services actifs, code HTTP de
chaque port web). Cet état est remplacé à chaque lancement.

## Ce que contrôle `verifier`

1. **Configurations** : `nginx -t`, `apache2ctl configtest` ou `httpd -t`,
   `sshd -t`, présence de `server_tokens off` dans `nginx -T`,
   `expose_php = Off` dans chaque `php.ini`.
2. **Ce que voit un client** : pour chaque port où nginx ou Apache écoute,
   en-têtes `Server` et `X-Powered-By` sans version, page d'erreur sans version ;
   bannière SSH sans suffixe de distribution.
3. **Régressions** : comparaison avec l'état enregistré par `appliquer` :
   un service qui ne tourne plus ou un port dont le code HTTP a changé est signalé.

Chaque ligne commence par `OK`, `ECHEC` ou `INFO`. La commande renvoie un code
de sortie non nul s'il y a au moins un `ECHEC`, ce qui permet de l'utiliser
dans une boucle SSH ou dans Ansible.

## Sauvegardes, retour arrière et nettoyage

Chaque lancement de `appliquer` qui modifie quelque chose crée une sauvegarde
dans `/var/backups/masquage-versions/<date>/` (accès root uniquement) :

- une copie de chaque fichier modifié, à son chemin d'origine ;
- un `manifeste.txt` qui liste les fichiers modifiés et les fichiers créés.

### Revenir en arrière

```bash
# Annule la dernière sauvegarde (celle conservée par nettoyer)
sudo ./anonymisation.sh annuler

# Lister les sauvegardes disponibles
sudo ls /var/backups/masquage-versions/

# Annuler une sauvegarde précise
sudo ./anonymisation.sh annuler 20261127-153000
```

`annuler` remet les fichiers modifiés, supprime les fichiers créés, teste chaque
configuration et ne recharge un service que si sa configuration est acceptée.
La sauvegarde est ensuite marquée comme annulée : relancer `annuler` remonte à
la sauvegarde précédente.

### Nettoyer

```bash
sudo ./anonymisation.sh nettoyer
```

`nettoyer` lance d'abord `verifier`. S'il y a un `ECHEC`, rien n'est supprimé.
Sinon, toutes les sauvegardes sont supprimées sauf la dernière, qui reste
utilisable avec `sudo ./anonymisation.sh annuler`.

## Tests

```bash
./tests/test_anonymisation.sh
```

Les tests travaillent dans un dossier temporaire et ne modifient pas le système.

## Systèmes pris en charge

Debian, Ubuntu, RHEL, Rocky, Alma (bash, systemd).
