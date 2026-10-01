# Kali Lab sur Debian avec Docker

Ce projet installe et configure automatiquement un environnement Kali Linux conteneurisé sur un serveur Debian headless.

L’objectif est de disposer d’un environnement Kali isolé, simple à administrer, sans interface graphique, destiné à un usage de laboratoire, d’administration, de diagnostic réseau ou de pentest explicitement autorisé.

---

## Architecture

L’environnement repose sur :

- Debian 12 ou Debian 13 comme système hôte ;
- Docker Engine installé depuis le dépôt officiel Docker ;
- Docker Compose ;
- Kali Linux Rolling dans un conteneur ;
- UFW pour le filtrage réseau ;
- Fail2ban pour la protection SSH ;
- WireGuard tools ;
- rotation des logs Docker ;
- répertoires persistants pour le workspace et les logs.

Le conteneur Kali est volontairement limité :

- pas de mode `--privileged` ;
- pas de montage du socket Docker ;
- pas de `network_mode: host` ;
- suppression des capacités Linux par défaut ;
- ajout uniquement de `NET_RAW` ;
- `no-new-privileges` activé ;
- limitation CPU, mémoire et nombre de processus.

---

## Compatibilité

Testé/conçu pour :

- Debian 12 Bookworm
- Debian 13 Trixie
- serveur sans interface graphique
- architecture amd64/arm64 compatible avec Docker et Kali

---

## Prérequis

Avant de lancer l’installation :

- disposer d’un accès SSH fonctionnel ;
- disposer d’un utilisateur avec droits `sudo` ;
- disposer d’une connexion Internet ;
- conserver une deuxième session SSH ouverte pendant l’installation.

Cette deuxième session est fortement recommandée au cas où une règle firewall empêcherait temporairement l’accès SSH.

---

## Installation

Créer le script :

```bash
nano install-kali-docker.sh
```

Y coller le script d’installation puis le rendre exécutable :

```bash
chmod +x install-kali-docker.sh
```

Lancer ensuite :

```bash
sudo ./install-kali-docker.sh
```

À la fin de l’installation, déconnectez puis reconnectez votre session SSH afin que l’appartenance au groupe `docker` soit prise en compte :

```bash
exit
```

Puis reconnectez-vous normalement.

---

## Arborescence

L’installation crée l’arborescence suivante :

```text
/opt/redteam/
├── kali/
│   ├── compose.yaml
│   ├── workspace/
│   └── logs/
├── engagements/
├── scripts/
└── backups/
```

### Workspace

Le répertoire :

```text
/opt/redteam/kali/workspace
```

est monté dans le conteneur sous :

```text
/workspace
```

Les fichiers créés dans `/workspace` sont donc persistants sur l’hôte.

### Logs

Le répertoire :

```text
/opt/redteam/kali/logs
```

est monté dans le conteneur sous :

```text
/logs
```

---

## Entrer dans Kali

La commande principale est :

```bash
kali-lab
```

Elle ouvre un shell interactif dans le conteneur Kali.

Commande équivalente :

```bash
docker exec -it kali-lab bash
```

Vous devriez obtenir un shell ressemblant à :

```text
root@kali-lab:/workspace#
```

---

## Vérifier l’état

Afficher l’état du conteneur Kali :

```bash
kali-status
```

Ou directement :

```bash
docker ps
```

Afficher les statistiques de ressources :

```bash
docker stats kali-lab
```

---

## Mettre Kali à jour

Utiliser :

```bash
kali-update
```

Cette commande effectue notamment :

```bash
apt-get update
apt-get full-upgrade
apt-get autoremove
apt-get clean
```

dans le conteneur.

---

## Démarrer / arrêter / redémarrer Kali

Démarrer :

```bash
docker start kali-lab
```

Arrêter :

```bash
docker stop kali-lab
```

Redémarrer :

```bash
docker restart kali-lab
```

Afficher les logs :

```bash
docker logs kali-lab
```

Suivre les logs en temps réel :

```bash
docker logs -f kali-lab
```

---

## Docker Compose

Le fichier Compose se trouve ici :

```text
/opt/redteam/kali/compose.yaml
```

Pour redémarrer l’environnement après modification :

```bash
cd /opt/redteam/kali
docker compose down
docker compose up -d
```

---

## Image Kali utilisée

Le conteneur utilise :

```text
kalilinux/kali-rolling:latest
```

Le script installe ensuite :

```text
kali-linux-headless
```

ainsi que plusieurs utilitaires courants.

---

## Outils installés dans Kali

Le conteneur inclut notamment :

- `kali-linux-headless`
- `curl`
- `wget`
- `git`
- `jq`
- `python3`
- `python3-pip`
- `python3-venv`
- `iproute2`
- `iputils-ping`
- `dnsutils`
- `net-tools`
- `procps`
- `vim`
- `nano`
- `tmux`
- `file`
- `zip`
- `unzip`

Le métapaquet `kali-linux-headless` installe également de nombreux outils Kali utilisables sans interface graphique.

---

## Sécurité du conteneur

Le conteneur n’est pas lancé avec :

```text
--privileged
```

Il ne monte pas :

```text
/var/run/docker.sock
```

Il n’utilise pas :

```text
network_mode: host
```

Toutes les capacités Linux sont retirées :

```yaml
cap_drop:
  - ALL
```

Seule la capacité suivante est ajoutée :

```yaml
cap_add:
  - NET_RAW
```

Cela permet notamment certaines opérations réseau comme `ping` et certains outils de diagnostic.

---

## Limitations réseau

Certaines fonctions avancées de Kali peuvent nécessiter des capacités supplémentaires comme :

```text
NET_ADMIN
```

Il est préférable de ne les ajouter que lorsqu’elles sont réellement nécessaires.

Exemple :

```yaml
cap_add:
  - NET_RAW
  - NET_ADMIN
```

Ne pas utiliser `privileged: true` par défaut.

---

## Firewall UFW

Afficher l’état :

```bash
sudo ufw status verbose
```

Le script :

- refuse les connexions entrantes par défaut ;
- autorise les connexions sortantes ;
- conserve l’accès SSH ;
- active UFW.

Exemple :

```text
Default: deny (incoming), allow (outgoing)
```

---

## Important : Docker et UFW

Docker manipule directement les règles Netfilter.

Cela signifie que des ports publiés via Docker peuvent ne pas se comporter exactement comme attendu avec UFW.

Exemple à éviter sans configuration supplémentaire :

```yaml
ports:
  - "8080:8080"
```

Dans la configuration actuelle, aucun port Kali n’est publié vers Internet.

Si vous ajoutez des ports plus tard, vérifiez également :

```bash
iptables -S DOCKER-USER
```

ou, selon la configuration système :

```bash
nft list ruleset
```

---

## Fail2ban

Afficher l’état général :

```bash
sudo fail2ban-client status
```

Afficher l’état de la jail SSH :

```bash
sudo fail2ban-client status sshd
```

Configuration créée :

```text
/etc/fail2ban/jail.d/sshd.local
```

Paramètres par défaut :

```text
maxretry = 5
findtime = 10m
bantime = 1h
```

---

## SSH

Le script essaie de détecter automatiquement le port SSH utilisé par le serveur.

Pour vérifier :

```bash
sudo sshd -T | grep '^port '
```

Exemple :

```text
port 22
```

---

## Groupe Docker

L’utilisateur ayant exécuté le script via `sudo` est ajouté au groupe :

```text
docker
```

Cela permet d’exécuter :

```bash
docker ps
```

sans `sudo`.

Attention :

> l’appartenance au groupe `docker` donne pratiquement des privilèges root sur le serveur.

Pour vérifier :

```bash
groups
```

---

## Logs Docker

Docker est configuré avec :

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  }
}
```

Cela évite que les logs Docker grossissent indéfiniment.

Configuration :

```text
/etc/docker/daemon.json
```

---

## Limites de ressources

Le conteneur est configuré avec des limites par défaut :

```yaml
mem_limit: 4g
cpus: 2.0
pids_limit: 512
```

Adaptez-les aux ressources de votre serveur.

Exemple pour un petit VPS :

```yaml
mem_limit: 2g
cpus: 1.0
```

---

## Sauvegarde du workspace

Sauvegarder :

```bash
sudo tar -czf kali-workspace-backup.tar.gz \
  /opt/redteam/kali/workspace
```

Restaurer :

```bash
sudo tar -xzf kali-workspace-backup.tar.gz -C /
```

---

## Sauvegarde de la configuration

Sauvegarder les fichiers importants :

```bash
sudo tar -czf redteam-config-backup.tar.gz \
  /opt/redteam \
  /etc/docker \
  /etc/fail2ban/jail.d/sshd.local
```

---

## Mise à jour de l’image Kali

Télécharger la dernière image :

```bash
docker pull kalilinux/kali-rolling:latest
```

Puis recréer le conteneur :

```bash
cd /opt/redteam/kali
docker compose down
docker compose up -d
```

Attention : les paquets installés manuellement dans le conteneur devront être réinstallés si l’image est recréée à partir de zéro.

Les données présentes dans les volumes :

```text
/workspace
/logs
```

restent persistantes.

---

## Vérifier les versions

Docker :

```bash
docker --version
```

Docker Compose :

```bash
docker compose version
```

Debian :

```bash
cat /etc/os-release
```

Kali :

```bash
docker exec kali-lab cat /etc/os-release
```

---

## Diagnostic

### Le conteneur ne démarre pas

Vérifier :

```bash
docker ps -a
```

Puis :

```bash
docker logs kali-lab
```

---

### Docker ne démarre pas

```bash
sudo systemctl status docker
```

Puis :

```bash
sudo journalctl -u docker -n 100 --no-pager
```

---

### Le helper `kali-lab` ne fonctionne pas

Vérifier :

```bash
which kali-lab
```

Puis :

```bash
ls -l /usr/local/bin/kali-lab
```

---

### Permission denied avec Docker

Vérifier :

```bash
groups
```

Si `docker` n’apparaît pas, reconnectez votre session SSH.

Vous pouvez aussi temporairement utiliser :

```bash
sudo docker ps
```

---

### Vérifier les capacités du conteneur

```bash
docker inspect kali-lab | jq '.[0].HostConfig.CapAdd'
```

---

## Désinstallation

Arrêter et supprimer le conteneur :

```bash
cd /opt/redteam/kali
docker compose down
```

Supprimer l’image Kali :

```bash
docker rmi kalilinux/kali-rolling:latest
```

Supprimer l’environnement :

```bash
sudo rm -rf /opt/redteam
```

Supprimer les helpers :

```bash
sudo rm -f \
  /usr/local/bin/kali-lab \
  /usr/local/bin/kali-status \
  /usr/local/bin/kali-update
```

Docker peut être conservé si d’autres conteneurs l’utilisent.

---

## Notes importantes

Un conteneur Kali Docker n’est pas identique à une machine virtuelle Kali complète.

En particulier :

- il partage le noyau Linux de l’hôte Debian ;
- il n’a généralement pas un `systemd` complet ;
- certaines opérations bas niveau nécessitent des capacités supplémentaires ;
- les périphériques USB/Wi-Fi ne sont pas automatiquement accessibles ;
- certaines fonctions de pentest réseau avancées sont mieux adaptées à une VM dédiée.

Pour les tâches classiques en CLI, automatisation, analyse, scripts et outils réseau, cette architecture reste légère et pratique.

---

## Usage responsable

Cet environnement est destiné à :

- vos propres systèmes ;
- vos laboratoires ;
- vos environnements de test ;
- des infrastructures pour lesquelles vous disposez d’une autorisation explicite.

Ne l’utilisez pas contre des systèmes tiers sans autorisation.

---

## Commandes utiles

```bash
# Entrer dans Kali
kali-lab

# État
kali-status

# Mise à jour Kali
kali-update

# Voir les conteneurs
docker ps

# Logs Kali
docker logs -f kali-lab

# Redémarrer Kali
docker restart kali-lab

# Firewall
sudo ufw status verbose

# Fail2ban
sudo fail2ban-client status sshd

# Docker
sudo systemctl status docker
```

---

## Résumé

Architecture finale :

```text
Internet
   |
   v
+---------------------------+
|        Debian Server      |
|                           |
| SSH + UFW + Fail2ban      |
|                           |
|  +---------------------+  |
|  |       Docker        |  |
|  |                     |  |
|  |  +---------------+  |  |
|  |  |   Kali Linux  |  |  |
|  |  |   Headless    |  |  |
|  |  +---------------+  |  |
|  +---------------------+  |
|                           |
| /opt/redteam              |
+---------------------------+
```

---

## Licence / responsabilité

Ce projet est fourni comme base d’administration et de laboratoire.

L’administrateur reste responsable :

- de la sécurité du serveur ;
- des règles firewall ;
- des identifiants SSH ;
- des services exposés ;
- des outils utilisés dans Kali ;
- du respect des lois et autorisations applicables.

Je vous conseille de le placer à côté de votre script :

```text
kali-debian-lab/
├── README.md
└── install-kali-docker.sh
```

Puis, si vous utilisez Git :

```bash
git init
git add README.md install-kali-docker.sh
git commit -m "Initial Debian Kali Docker lab"
```
