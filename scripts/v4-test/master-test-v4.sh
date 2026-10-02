#!/usr/bin/env bash

set -Eeuo pipefail
umask 027

# ============================================================
# Debian Server -> Docker -> Kali Lab
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
# ERREURS
# ------------------------------------------------------------

trap 'error "Erreur ligne $LINENO : $BASH_COMMAND"' ERR


# ------------------------------------------------------------
# ROOT
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    error "Lance ce script avec sudo."
    echo
    echo "sudo $0"
    exit 1
fi


# ------------------------------------------------------------
# LOGS
# ------------------------------------------------------------

touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1


echo
echo "============================================================"
echo "        DEBIAN -> DOCKER -> KALI LAB"
echo "============================================================"
echo


# ------------------------------------------------------------
# DETECTION SYSTEME
# ------------------------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    error "/etc/os-release introuvable."
    exit 1
fi

source /etc/os-release

ok "Système détecté : ${PRETTY_NAME:-Linux}"

if [[ "${ID:-}" != "debian" ]]; then
    warn "Ce script a été prévu principalement pour Debian."
fi


# ------------------------------------------------------------
# MISE A JOUR DEBIAN
# ------------------------------------------------------------

info "Mise à jour Debian..."

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

ok "Debian mis à jour."


# ------------------------------------------------------------
# PAQUETS DE BASE
# ------------------------------------------------------------

info "Installation des paquets système..."

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
    procps \
    sudo

ok "Paquets système installés."


# ------------------------------------------------------------
# SSH
# ------------------------------------------------------------

info "Activation SSH..."

systemctl enable --now ssh

ok "SSH actif."


# ------------------------------------------------------------
# PARE-FEU
# ------------------------------------------------------------

info "Configuration UFW..."

ufw allow OpenSSH >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true

ok "UFW actif."


# ------------------------------------------------------------
# FAIL2BAN
# ------------------------------------------------------------

info "Activation Fail2ban..."

systemctl enable --now fail2ban

ok "Fail2ban actif."


# ------------------------------------------------------------
# SUPPRESSION ANCIENS PAQUETS DOCKER
# ------------------------------------------------------------

info "Préparation Docker..."

apt-get remove -y \
    docker.io \
    docker-doc \
    docker-compose \
    podman-docker \
    containerd \
    runc 2>/dev/null || true


# ------------------------------------------------------------
# CLE DOCKER
# ------------------------------------------------------------

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc

chmod a+r /etc/apt/keyrings/docker.asc


# ------------------------------------------------------------
# DEPOT DOCKER
# ------------------------------------------------------------

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
# CONFIG DOCKER
# ------------------------------------------------------------

info "Configuration du daemon Docker..."

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
# AJOUT GROUPE DOCKER
# ------------------------------------------------------------

if id "$ADMIN_USER" >/dev/null 2>&1; then

    info "Ajout de $ADMIN_USER au groupe docker..."

    usermod -aG docker "$ADMIN_USER"

    ok "$ADMIN_USER ajouté au groupe docker."

fi


# ------------------------------------------------------------
# TEST DOCKER
# ------------------------------------------------------------

info "Test Docker..."

docker version >/dev/null

ok "Docker fonctionnel."


# ------------------------------------------------------------
# DOSSIERS KALI
# ------------------------------------------------------------

info "Création de l'environnement Kali..."

mkdir -p \
    "$KALI_DIR" \
    "$KALI_DIR/workspace" \
    "$KALI_DIR/shared" \
    "$KALI_DIR/logs"

chmod 750 "$KALI_DIR"
chmod 770 "$KALI_DIR/workspace"
chmod 770 "$KALI_DIR/shared"
chmod 770 "$KALI_DIR/logs"

ok "Répertoires Kali créés."


# ------------------------------------------------------------
# COMPOSE KALI
# ------------------------------------------------------------

info "Création du compose.yml..."

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

    # --------------------------------------------------------
    # IMPORTANT
    #
    # Ne PAS utiliser :
    #
    # cap_drop:
    #   - ALL
    #
    # car apt utilise notamment :
    #
    # SETUID
    # SETGID
    # CHOWN
    #
    # Docker garde ici ses capabilities par défaut.
    # On ajoute uniquement NET_ADMIN.
    # --------------------------------------------------------

    cap_add:
      - NET_ADMIN

    pids_limit: ${KALI_PIDS}

    mem_limit: ${KALI_MEMORY}

    cpus: ${KALI_CPUS}

    volumes:

      - ./workspace:/workspace

      - ./shared:/shared

      - ./logs:/logs

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
# SUPPRESSION ANCIEN CONTENEUR
# ------------------------------------------------------------

if docker ps -a \
    --format '{{.Names}}' \
    | grep -qx "$KALI_CONTAINER"; then

    warn "Ancien conteneur Kali détecté."

    docker rm -f "$KALI_CONTAINER"

    ok "Ancien conteneur supprimé."

fi


# ------------------------------------------------------------
# PULL KALI
# ------------------------------------------------------------

info "Téléchargement de Kali..."

docker pull "$KALI_IMAGE"

ok "Image Kali disponible."


# ------------------------------------------------------------
# DEMARRAGE KALI
# ------------------------------------------------------------

info "Démarrage Kali..."

cd "$KALI_DIR"

docker compose down \
    --remove-orphans \
    2>/dev/null || true

docker compose up -d \
    --force-recreate

ok "Kali démarré."


# ------------------------------------------------------------
# ATTENTE
# ------------------------------------------------------------

info "Attente du conteneur..."

sleep 5


# ------------------------------------------------------------
# VERIFICATION ETAT
# ------------------------------------------------------------

if ! docker ps \
    --format '{{.Names}}' \
    | grep -qx "$KALI_CONTAINER"; then

    error "Le conteneur Kali n'est pas actif."

    docker logs "$KALI_CONTAINER" || true

    exit 1

fi

ok "Conteneur actif."


# ------------------------------------------------------------
# CONFIGURATION EFFECTIVE
# ------------------------------------------------------------

echo
info "Configuration des capabilities :"

docker inspect "$KALI_CONTAINER" \
    --format 'CapDrop={{json .HostConfig.CapDrop}}'

docker inspect "$KALI_CONTAINER" \
    --format 'CapAdd={{json .HostConfig.CapAdd}}'

docker inspect "$KALI_CONTAINER" \
    --format 'Privileged={{.HostConfig.Privileged}}'

docker inspect "$KALI_CONTAINER" \
    --format 'SecurityOpt={{json .HostConfig.SecurityOpt}}'

echo


# ------------------------------------------------------------
# TEST IDENTITE
# ------------------------------------------------------------

info "Test utilisateur dans Kali..."

docker exec "$KALI_CONTAINER" \
    bash -c '
        echo "OS :"
        grep PRETTY_NAME /etc/os-release
        echo
        echo "Utilisateur :"
        id
    '

ok "Conteneur fonctionnel."


# ------------------------------------------------------------
# TEST CHOWN
# ------------------------------------------------------------

info "Test CHOWN / UID / GID..."

docker exec "$KALI_CONTAINER" \
    bash -c '
        set -e

        touch /tmp/kali-cap-test

        chown 42:65534 /tmp/kali-cap-test

        ls -ln /tmp/kali-cap-test

        rm -f /tmp/kali-cap-test
    '

ok "CHOWN / UID / GID fonctionnels."


# ------------------------------------------------------------
# APT UPDATE
# ------------------------------------------------------------

info "Mise à jour de Kali..."

if ! docker exec "$KALI_CONTAINER" \
    bash -c 'apt-get update'; then

    echo
    error "apt-get update a échoué."
    echo
    warn "Diagnostic Docker :"
    echo

    docker info \
        | grep -Ei \
        'rootless|security|userns|seccomp|apparmor' \
        || true

    echo
    warn "Configuration du conteneur :"
    echo

    docker inspect "$KALI_CONTAINER" \
        --format 'CapDrop={{json .HostConfig.CapDrop}}'

    docker inspect "$KALI_CONTAINER" \
        --format 'CapAdd={{json .HostConfig.CapAdd}}'

    docker inspect "$KALI_CONTAINER" \
        --format 'SecurityOpt={{json .HostConfig.SecurityOpt}}'

    docker inspect "$KALI_CONTAINER" \
        --format 'Privileged={{.HostConfig.Privileged}}'

    echo
    warn "Le script s'arrête ici pour éviter une installation partielle."

    exit 112
fi

ok "apt update fonctionne."


# ------------------------------------------------------------
# INSTALLATION OUTILS KALI
# ------------------------------------------------------------

info "Installation des outils Kali..."

docker exec \
    -e DEBIAN_FRONTEND=noninteractive \
    "$KALI_CONTAINER" \
    apt-get install -y \
        kali-linux-headless \
        curl \
        wget \
        git \
        jq \
        vim \
        nano \
        tmux \
        less \
        file \
        tree \
        unzip \
        zip \
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
        nmap \
        netcat-openbsd \
        socat

ok "Outils Kali installés."


# ------------------------------------------------------------
# NETTOYAGE
# ------------------------------------------------------------

info "Nettoyage Kali..."

docker exec "$KALI_CONTAINER" \
    bash -c '
        apt-get autoremove -y
        apt-get clean
        rm -rf /var/lib/apt/lists/*
    '

ok "Kali nettoyé."


# ------------------------------------------------------------
# COMMANDES HELPER
# ------------------------------------------------------------

info "Création des commandes Kali..."


# kali-shell

cat >/usr/local/bin/kali-shell <<'EOF'
#!/usr/bin/env bash

docker exec -it kali-lab bash
EOF

chmod 755 /usr/local/bin/kali-shell


# kali-start

cat >/usr/local/bin/kali-start <<EOF
#!/usr/bin/env bash

cd "${KALI_DIR}"

docker compose up -d
EOF

chmod 755 /usr/local/bin/kali-start


# kali-stop

cat >/usr/local/bin/kali-stop <<EOF
#!/usr/bin/env bash

cd "${KALI_DIR}"

docker compose stop
EOF

chmod 755 /usr/local/bin/kali-stop


# kali-restart

cat >/usr/local/bin/kali-restart <<EOF
#!/usr/bin/env bash

cd "${KALI_DIR}"

docker compose restart
EOF

chmod 755 /usr/local/bin/kali-restart


# kali-status

cat >/usr/local/bin/kali-status <<'EOF'
#!/usr/bin/env bash

echo
echo "========================================"
echo " KALI STATUS"
echo "========================================"
echo

docker ps -a \
    --filter name=kali-lab

echo
echo "--- Capabilities ---"

docker inspect kali-lab \
    --format 'CapDrop={{json .HostConfig.CapDrop}}'

docker inspect kali-lab \
    --format 'CapAdd={{json .HostConfig.CapAdd}}'

docker inspect kali-lab \
    --format 'Privileged={{.HostConfig.Privileged}}'

docker inspect kali-lab \
    --format 'SecurityOpt={{json .HostConfig.SecurityOpt}}'

echo
EOF

chmod 755 /usr/local/bin/kali-status


# kali-update

cat >/usr/local/bin/kali-update <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

echo
echo "[+] apt update"

docker exec kali-lab \
    apt-get update

echo
echo "[+] dist-upgrade"

docker exec \
    -e DEBIAN_FRONTEND=noninteractive \
    kali-lab \
    apt-get dist-upgrade -y

echo
echo "[+] autoremove"

docker exec kali-lab \
    apt-get autoremove -y

echo
echo "[+] clean"

docker exec kali-lab \
    apt-get clean

echo
echo "[✓] Kali mis à jour."
echo
EOF

chmod 755 /usr/local/bin/kali-update


# kali-logs

cat >/usr/local/bin/kali-logs <<'EOF'
#!/usr/bin/env bash

docker logs \
    --tail 200 \
    -f \
    kali-lab
EOF

chmod 755 /usr/local/bin/kali-logs


# kali-inspect

cat >/usr/local/bin/kali-inspect <<'EOF'
#!/usr/bin/env bash

echo
echo "=== Docker ==="
echo

docker info \
    | grep -Ei \
    'rootless|security|userns|seccomp|apparmor' \
    || true

echo
echo "=== Kali ==="
echo

docker inspect kali-lab \
    --format 'CapDrop={{json .HostConfig.CapDrop}}'

docker inspect kali-lab \
    --format 'CapAdd={{json .HostConfig.CapAdd}}'

docker inspect kali-lab \
    --format 'Privileged={{.HostConfig.Privileged}}'

docker inspect kali-lab \
    --format 'SecurityOpt={{json .HostConfig.SecurityOpt}}'

echo
EOF

chmod 755 /usr/local/bin/kali-inspect


ok "Commandes Kali créées."


# ------------------------------------------------------------
# TEST NMAP
# ------------------------------------------------------------

info "Test Nmap..."

docker exec "$KALI_CONTAINER" \
    nmap --version \
    | head -n 2

ok "Nmap disponible."


# ------------------------------------------------------------
# TEST RESEAU
# ------------------------------------------------------------

info "Test réseau Kali..."

docker exec "$KALI_CONTAINER" \
    bash -c '
        ip addr
        echo
        ip route
    '

ok "Réseau disponible."


# ------------------------------------------------------------
# INFOS FINALES
# ------------------------------------------------------------

echo
echo "============================================================"
echo -e "${GREEN}        INSTALLATION TERMINEE${NC}"
echo "============================================================"
echo

echo "Connexion au Kali :"
echo
echo "    kali-shell"
echo

echo "ou :"
echo
echo "    docker exec -it kali-lab bash"
echo

echo
echo "Commandes :"
echo

echo "    kali-shell"
echo "    kali-start"
echo "    kali-stop"
echo "    kali-restart"
echo "    kali-status"
echo "    kali-update"
echo "    kali-logs"
echo "    kali-inspect"

echo
echo "Dossier Kali :"
echo
echo "    $KALI_DIR"

echo
echo "Workspace :"
echo
echo "    $KALI_DIR/workspace"

echo
echo "Partage :"
echo
echo "    $KALI_DIR/shared"

echo
echo "Logs :"
echo
echo "    $KALI_DIR/logs"

echo
echo "Compose :"
echo
echo "    $KALI_DIR/compose.yml"

echo
echo "Log bootstrap :"
echo
echo "    $LOG_FILE"

echo
echo "IMPORTANT :"
echo
echo "Si $ADMIN_USER vient d'être ajouté au groupe docker,"
echo "déconnecte puis reconnecte ta session SSH."
echo

echo "Configuration Kali attendue :"
echo
echo "    CapDrop=null"
echo "    CapAdd=[\"CAP_NET_ADMIN\"]"
echo "    Privileged=false"
echo

echo "Le conteneur conserve donc les capabilities Docker"
echo "par défaut nécessaires à apt, SETUID, SETGID, CHOWN, etc."
echo