#!/usr/bin/env bash

set -Eeuo pipefail
umask 027

# ============================================================
# DEBIAN SERVER -> DOCKER -> KALI LAB
# Version corrigée
#
# Usage :
#   chmod +x debian-kali-server.sh
#   sudo ./debian-kali-server.sh
#
# Architecture :
#
#   Windows / Kali VM
#          |
#         SSH
#          |
#     Debian Server
#          |
#        Docker
#          |
#      kali-lab
#
# Usage prévu :
#   Lab personnel / CTF / pentest explicitement autorisé
# ============================================================


# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

KALI_DIR="/opt/redteam/kali"
KALI_CONTAINER="kali-lab"
KALI_IMAGE="kalilinux/kali-rolling:latest"

KALI_MEMORY="4g"
KALI_CPUS="2.0"
KALI_PIDS="512"

LOG_FILE="/var/log/debian-kali-bootstrap.log"

# Utilisateur ayant lancé sudo
ADMIN_USER="${SUDO_USER:-$USER}"


# ------------------------------------------------------------
# COULEURS
# ------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'


info() {
    echo -e "${BLUE}[+]${NC} $*"
}

ok() {
    echo -e "${GREEN}[✓]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $*"
}

error() {
    echo -e "${RED}[✗]${NC} $*" >&2
}


# ------------------------------------------------------------
# GESTION ERREURS
# ------------------------------------------------------------

trap 'error "Erreur ligne $LINENO : commande : $BASH_COMMAND"' ERR


# ------------------------------------------------------------
# ROOT
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    error "Ce script doit être lancé avec sudo/root."
    echo
    echo "Exemple :"
    echo "sudo $0"
    exit 1
fi


# ------------------------------------------------------------
# LOG
# ------------------------------------------------------------

touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1


echo
echo "============================================================"
echo "   Debian Server -> Docker -> Kali Lab"
echo "============================================================"
echo


# ------------------------------------------------------------
# DETECTION DEBIAN
# ------------------------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    error "/etc/os-release introuvable."
    exit 1
fi

source /etc/os-release

if [[ "${ID:-}" != "debian" ]]; then
    warn "Distribution détectée : ${PRETTY_NAME:-inconnue}"
    warn "Ce script est prévu principalement pour Debian."
fi

ok "Système détecté : ${PRETTY_NAME:-Debian}"


# ------------------------------------------------------------
# MISE A JOUR DEBIAN
# ------------------------------------------------------------

info "Mise à jour du système Debian..."

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

ok "Debian mis à jour."


# ------------------------------------------------------------
# PAQUETS DE BASE
# ------------------------------------------------------------

info "Installation des outils système..."

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    wget \
    gnupg \
    lsb-release \
    git \
    jq \
    vim \
    nano \
    tmux \
    htop \
    btop \
    tree \
    unzip \
    zip \
    rsync \
    openssh-server \
    ufw \
    fail2ban \
    iproute2 \
    iputils-ping \
    dnsutils \
    net-tools \
    procps

ok "Outils système installés."


# ------------------------------------------------------------
# SSH
# ------------------------------------------------------------

info "Activation du serveur SSH..."

systemctl enable --now ssh

ok "SSH actif."


# ------------------------------------------------------------
# UFW
# ------------------------------------------------------------

info "Configuration du pare-feu UFW..."

ufw allow OpenSSH >/dev/null 2>&1 || true

ufw --force enable >/dev/null 2>&1 || true

ok "Pare-feu UFW actif."


# ------------------------------------------------------------
# FAIL2BAN
# ------------------------------------------------------------

info "Activation de Fail2ban..."

systemctl enable --now fail2ban

ok "Fail2ban actif."


# ------------------------------------------------------------
# DOCKER - SUPPRESSION ANCIENS PAQUETS
# ------------------------------------------------------------

info "Préparation de Docker..."

apt-get remove -y \
    docker.io \
    docker-doc \
    docker-compose \
    podman-docker \
    containerd \
    runc 2>/dev/null || true


# ------------------------------------------------------------
# REPO OFFICIEL DOCKER
# ------------------------------------------------------------

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc

chmod a+r /etc/apt/keyrings/docker.asc

ARCH="$(dpkg --print-architecture)"
CODENAME="$VERSION_CODENAME"

cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable
EOF

apt-get update


# ------------------------------------------------------------
# INSTALLATION DOCKER
# ------------------------------------------------------------

info "Installation Docker..."

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

systemctl enable --now docker

ok "Docker installé."


# ------------------------------------------------------------
# CONFIGURATION DOCKER
# ------------------------------------------------------------

info "Configuration Docker..."

mkdir -p /etc/docker

cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  },
  "live-restore": true
}
EOF

systemctl restart docker

ok "Docker configuré."


# ------------------------------------------------------------
# GROUPE DOCKER
# ------------------------------------------------------------

if id "$ADMIN_USER" >/dev/null 2>&1; then

    info "Ajout de $ADMIN_USER au groupe docker..."

    usermod -aG docker "$ADMIN_USER"

    ok "$ADMIN_USER ajouté au groupe docker."

fi


# ------------------------------------------------------------
# REPERTOIRES KALI
# ------------------------------------------------------------

info "Création de l'environnement Kali..."

mkdir -p \
    "$KALI_DIR" \
    "$KALI_DIR/workspace" \
    "$KALI_DIR/logs" \
    "$KALI_DIR/shared"

chmod 750 "$KALI_DIR"
chmod 770 "$KALI_DIR/workspace"
chmod 770 "$KALI_DIR/logs"
chmod 770 "$KALI_DIR/shared"


# ------------------------------------------------------------
# DOCKER COMPOSE KALI
# ------------------------------------------------------------

cat >"$KALI_DIR/compose.yml" <<EOF
services:

  kali:

    image: ${KALI_IMAGE}

    container_name: ${KALI_CONTAINER}

    hostname: kali-lab

    restart: unless-stopped

    stdin_open: true
    tty: true

    privileged: false

    security_opt:
      - no-new-privileges:true

    # --------------------------------------------------------
    # SECURITE
    #
    # On retire toutes les capabilities Linux...
    # --------------------------------------------------------

    cap_drop:
      - ALL

    # --------------------------------------------------------
    # ... puis on ne réactive que celles nécessaires.
    #
    # CHOWN
    #   nécessaire notamment à apt / gestion fichiers
    #
    # DAC_OVERRIDE
    #   nécessaire à root pour certaines opérations fichiers
    #
    # FOWNER
    #   gestion permissions / ownership
    #
    # SETGID
    #   IMPORTANT : corrige "setgroups Operation not permitted"
    #
    # SETUID
    #   IMPORTANT : permet à apt de passer vers utilisateur _apt
    #
    # NET_RAW
    #   ping / nmap / raw sockets
    #
    # NET_ADMIN
    #   interfaces / routage / certains outils réseau
    # --------------------------------------------------------

    cap_add:
      - CHOWN
      - DAC_OVERRIDE
      - FOWNER
      - SETGID
      - SETUID
      - NET_RAW
      - NET_ADMIN

    pids_limit: ${KALI_PIDS}

    mem_limit: ${KALI_MEMORY}

    cpus: ${KALI_CPUS}

    volumes:

      - ./workspace:/workspace

      - ./logs:/logs

      - ./shared:/shared

    working_dir: /workspace

    command:
      - /bin/bash
      - -c
      - |
        trap : TERM INT
        sleep infinity &
        wait

    networks:
      - kali-net


networks:

  kali-net:

    driver: bridge
EOF


ok "compose.yml créé."


# ------------------------------------------------------------
# TELECHARGEMENT KALI
# ------------------------------------------------------------

info "Téléchargement de l'image Kali..."

docker pull "$KALI_IMAGE"

ok "Image Kali téléchargée."


# ------------------------------------------------------------
# SUPPRESSION ANCIEN CONTENEUR
# ------------------------------------------------------------

if docker ps -a --format '{{.Names}}' | grep -qx "$KALI_CONTAINER"; then

    warn "Ancien conteneur Kali détecté."

    info "Suppression de l'ancien conteneur..."

    docker rm -f "$KALI_CONTAINER" || true

fi


# ------------------------------------------------------------
# DEMARRAGE
# ------------------------------------------------------------

info "Démarrage du conteneur Kali..."

cd "$KALI_DIR"

docker compose up -d --force-recreate

ok "Conteneur Kali démarré."


# ------------------------------------------------------------
# ATTENTE
# ------------------------------------------------------------

info "Attente du démarrage du conteneur..."

sleep 5


# ------------------------------------------------------------
# TEST CAPABILITIES
# ------------------------------------------------------------

info "Capabilities Docker du conteneur :"

docker inspect "$KALI_CONTAINER" \
    --format 'CapDrop={{json .HostConfig.CapDrop}}'

docker inspect "$KALI_CONTAINER" \
    --format 'CapAdd={{json .HostConfig.CapAdd}}'


# ------------------------------------------------------------
# TEST KALI
# ------------------------------------------------------------

info "Test du conteneur Kali..."

docker exec "$KALI_CONTAINER" bash -c '
echo
echo "Kali :"
cat /etc/os-release | grep PRETTY_NAME
echo
id
echo
'

ok "Conteneur fonctionnel."


# ------------------------------------------------------------
# APT UPDATE KALI
# ------------------------------------------------------------

info "Mise à jour de Kali..."

docker exec "$KALI_CONTAINER" \
    bash -c 'apt-get update'

ok "apt update fonctionne correctement."


# ------------------------------------------------------------
# PAQUETS KALI
# ------------------------------------------------------------

info "Installation des outils Kali..."

docker exec "$KALI_CONTAINER" \
    env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y \
        kali-linux-headless \
        curl \
        wget \
        git \
        jq \
        vim \
        nano \
        tmux \
        python3 \
        python3-pip \
        python3-venv \
        pipx \
        iproute2 \
        iputils-ping \
        dnsutils \
        net-tools \
        traceroute \
        whois \
        nmap

ok "Outils Kali installés."


# ------------------------------------------------------------
# NETTOYAGE KALI
# ------------------------------------------------------------

info "Nettoyage du cache Kali..."

docker exec "$KALI_CONTAINER" bash -c '
apt-get clean
rm -rf /var/lib/apt/lists/*
'

ok "Nettoyage terminé."


# ------------------------------------------------------------
# HELPER KALI
# ------------------------------------------------------------

info "Création de la commande kali-shell..."

cat >/usr/local/bin/kali-shell <<'EOF'
#!/usr/bin/env bash

docker exec -it kali-lab bash
EOF

chmod 755 /usr/local/bin/kali-shell


# ------------------------------------------------------------
# HELPER KALI START
# ------------------------------------------------------------

cat >/usr/local/bin/kali-start <<EOF
#!/usr/bin/env bash

cd "${KALI_DIR}"

docker compose up -d
EOF

chmod 755 /usr/local/bin/kali-start


# ------------------------------------------------------------
# HELPER KALI STOP
# ------------------------------------------------------------

cat >/usr/local/bin/kali-stop <<EOF
#!/usr/bin/env bash

cd "${KALI_DIR}"

docker compose stop
EOF

chmod 755 /usr/local/bin/kali-stop


# ------------------------------------------------------------
# HELPER KALI RESTART
# ------------------------------------------------------------

cat >/usr/local/bin/kali-restart <<EOF
#!/usr/bin/env bash

cd "${KALI_DIR}"

docker compose restart
EOF

chmod 755 /usr/local/bin/kali-restart


# ------------------------------------------------------------
# HELPER KALI STATUS
# ------------------------------------------------------------

cat >/usr/local/bin/kali-status <<'EOF'
#!/usr/bin/env bash

echo
echo "=== Kali container ==="
docker ps -a --filter name=kali-lab

echo
echo "=== Capabilities ==="

docker inspect kali-lab \
    --format 'CapDrop={{json .HostConfig.CapDrop}}'

docker inspect kali-lab \
    --format 'CapAdd={{json .HostConfig.CapAdd}}'

echo
EOF

chmod 755 /usr/local/bin/kali-status


# ------------------------------------------------------------
# HELPER KALI UPDATE
# ------------------------------------------------------------

cat >/usr/local/bin/kali-update <<'EOF'
#!/usr/bin/env bash

set -e

echo "[+] apt update..."

docker exec kali-lab \
    apt-get update

echo "[+] apt upgrade..."

docker exec \
    -e DEBIAN_FRONTEND=noninteractive \
    kali-lab \
    apt-get dist-upgrade -y

echo "[+] Nettoyage..."

docker exec kali-lab \
    apt-get autoremove -y

docker exec kali-lab \
    apt-get clean

echo "[✓] Kali mis à jour."
EOF

chmod 755 /usr/local/bin/kali-update


# ------------------------------------------------------------
# TEST FINAL
# ------------------------------------------------------------

echo
echo "============================================================"
echo "   TEST FINAL"
echo "============================================================"
echo

docker ps --filter "name=$KALI_CONTAINER"

echo

docker exec "$KALI_CONTAINER" bash -c '
echo "Utilisateur :"
id
echo

echo "Réseau :"
ip addr
echo

echo "Nmap :"
nmap --version | head -n 1
echo
'


# ------------------------------------------------------------
# TERMINE
# ------------------------------------------------------------

echo
echo "============================================================"
echo -e "${GREEN}   INSTALLATION TERMINEE${NC}"
echo "============================================================"
echo

echo "Kali :"
echo
echo "  kali-shell"
echo

echo "ou :"
echo
echo "  docker exec -it kali-lab bash"
echo

echo "Commandes disponibles :"
echo
echo "  kali-start"
echo "  kali-stop"
echo "  kali-restart"
echo "  kali-status"
echo "  kali-update"
echo

echo "Dossier Kali :"
echo
echo "  $KALI_DIR"
echo

echo "Workspace :"
echo
echo "  $KALI_DIR/workspace"
echo

echo "Dossier partagé :"
echo
echo "  $KALI_DIR/shared"
echo

echo "Logs :"
echo
echo "  $KALI_DIR/logs"
echo

echo "Compose :"
echo
echo "  $KALI_DIR/compose.yml"
echo

echo "IMPORTANT :"
echo
echo "Ton utilisateur $ADMIN_USER vient éventuellement d'être"
echo "ajouté au groupe docker."
echo
echo "Déconnecte/reconnecte ta session SSH pour que le groupe"
echo "docker soit pris en compte."
echo

echo "Log bootstrap :"
echo
echo "  $LOG_FILE"
echo