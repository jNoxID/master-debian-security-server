#!/usr/bin/env bash

set -Eeuo pipefail
umask 027

# ============================================================
# Debian Server -> Docker -> Kali Linux Headless
# ============================================================
#
# Usage :
#
#   chmod +x ~/Scripts/install-kali-docker.sh
#   sudo ~/Scripts/install-kali-docker.sh
#
# Conteneur :
#   kali-lab
#
# Répertoire :
#   /opt/kali-lab
#
# Usage prévu :
#   CTF / Lab / pentest autorisé
#
# ============================================================


# ============================================================
# CONFIGURATION
# ============================================================

KALI_CONTAINER="kali-lab"
KALI_IMAGE="kalilinux/kali-rolling:latest"

KALI_DIR="/opt/kali-lab"

KALI_MEMORY="6g"
KALI_CPUS="4.0"
KALI_PIDS="1024"

LOG_FILE="/var/log/kali-docker-install.log"

ADMIN_USER="${SUDO_USER:-$USER}"


# ============================================================
# COULEURS
# ============================================================

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

fail() {
    echo -e "${RED}[✗]${NC} $*" >&2
}


# ============================================================
# GESTION DES ERREURS
# ============================================================

trap 'fail "Erreur ligne $LINENO : $BASH_COMMAND"' ERR


# ============================================================
# ROOT
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    fail "Ce script doit être exécuté avec sudo."
    echo
    echo "sudo $0"
    exit 1
fi


# ============================================================
# LOG
# ============================================================

touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1


clear || true

echo
echo "============================================================"
echo "         DEBIAN -> DOCKER -> KALI LINUX"
echo "============================================================"
echo


# ============================================================
# VERIFICATION DEBIAN
# ============================================================

if [[ ! -f /etc/os-release ]]; then
    fail "/etc/os-release introuvable."
    exit 1
fi

source /etc/os-release

info "Système détecté : ${PRETTY_NAME:-Linux}"

if [[ "${ID:-}" != "debian" ]]; then
    warn "Ce script est conçu pour Debian."
fi


# ============================================================
# MISE A JOUR DEBIAN
# ============================================================

info "Mise à jour des dépôts Debian..."

apt-get update

ok "Dépôts Debian à jour."


# ============================================================
# OUTILS DE BASE
# ============================================================

info "Installation des outils système..."

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    wget \
    gnupg \
    git \
    jq \
    nano \
    vim \
    tmux \
    htop \
    btop \
    tree \
    unzip \
    zip \
    openssh-server \
    ufw \
    fail2ban \
    iproute2 \
    iputils-ping \
    dnsutils \
    net-tools \
    procps \
    sudo

ok "Outils système installés."


# ============================================================
# SSH
# ============================================================

info "Activation de SSH..."

systemctl enable --now ssh

ok "SSH actif."


# ============================================================
# FIREWALL
# ============================================================

info "Configuration UFW..."

ufw allow OpenSSH >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true

ok "UFW actif."


# ============================================================
# FAIL2BAN
# ============================================================

info "Activation Fail2ban..."

systemctl enable --now fail2ban || true

ok "Fail2ban configuré."


# ============================================================
# INSTALLATION DOCKER SI ABSENT
# ============================================================

if ! command -v docker >/dev/null 2>&1; then

    info "Docker absent : installation..."

    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc

    chmod a+r /etc/apt/keyrings/docker.asc

    ARCH="$(dpkg --print-architecture)"
    CODENAME="${VERSION_CODENAME}"

    cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable
EOF

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

else

    ok "Docker est déjà installé."

fi


# ============================================================
# DOCKER SERVICE
# ============================================================

info "Activation Docker..."

systemctl enable --now docker

docker version >/dev/null

ok "Docker opérationnel."


# ============================================================
# UTILISATEUR -> GROUPE DOCKER
# ============================================================

if id "$ADMIN_USER" >/dev/null 2>&1; then

    if ! id -nG "$ADMIN_USER" | grep -qw docker; then

        info "Ajout de $ADMIN_USER au groupe docker..."

        usermod -aG docker "$ADMIN_USER"

        warn "Une reconnexion SSH sera nécessaire pour utiliser Docker sans sudo."

    fi

fi


# ============================================================
# DOSSIERS
# ============================================================

info "Préparation de $KALI_DIR..."

mkdir -p \
    "$KALI_DIR/workspace" \
    "$KALI_DIR/shared" \
    "$KALI_DIR/logs"

chmod 755 "$KALI_DIR"

chmod 775 \
    "$KALI_DIR/workspace" \
    "$KALI_DIR/shared" \
    "$KALI_DIR/logs"

ok "Répertoires créés."


# ============================================================
# SUPPRESSION D'UNE EVENTUELLE ANCIENNE CONFIG COMPOSE
# ============================================================

info "Nettoyage d'une éventuelle ancienne configuration..."

rm -f \
    "$KALI_DIR/docker-compose.yml" \
    "$KALI_DIR/compose.yaml" \
    "$KALI_DIR/docker-compose.yaml"

ok "Anciennes configurations supprimées."


# ============================================================
# CREATION COMPOSE
# ============================================================

info "Création du nouveau compose.yml..."

cat >"$KALI_DIR/compose.yml" <<EOF
services:

  kali:

    image: ${KALI_IMAGE}

    container_name: ${KALI_CONTAINER}

    hostname: kali-lab

    restart: unless-stopped

    stdin_open: true
    tty: true

    # --------------------------------------------------------
    # IMPORTANT
    #
    # PAS de :
    #
    #   cap_drop:
    #     - ALL
    #
    # PAS de :
    #
    #   security_opt:
    #     - no-new-privileges:true
    #
    # PAS de :
    #
    #   privileged: true
    #
    # Docker conserve donc son jeu normal de capabilities :
    # CHOWN, SETUID, SETGID, NET_RAW, etc.
    #
    # NET_ADMIN est ajouté pour certains usages réseau.
    # --------------------------------------------------------

    cap_add:
      - NET_ADMIN

    mem_limit: ${KALI_MEMORY}

    cpus: ${KALI_CPUS}

    pids_limit: ${KALI_PIDS}

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


# ============================================================
# AFFICHAGE CONFIG
# ============================================================

echo
info "Configuration Docker Compose utilisée :"
echo

cat "$KALI_DIR/compose.yml"

echo


# ============================================================
# SECURITE : SUPPRESSION CONTENEUR EXISTANT
# ============================================================

if docker ps -a \
    --format '{{.Names}}' \
    | grep -qx "$KALI_CONTAINER"; then

    warn "Un conteneur $KALI_CONTAINER existe encore."

    docker rm -f "$KALI_CONTAINER"

fi


# ============================================================
# IMAGE KALI
# ============================================================

info "Téléchargement de Kali Rolling..."

docker pull "$KALI_IMAGE"

ok "Image Kali disponible."


# ============================================================
# DEMARRAGE
# ============================================================

info "Démarrage de Kali..."

cd "$KALI_DIR"

docker compose \
    -f "$KALI_DIR/compose.yml" \
    up -d \
    --force-recreate

ok "Kali démarré."


# ============================================================
# ATTENTE
# ============================================================

info "Attente du démarrage..."

sleep 5


# ============================================================
# VERIFICATION CONTAINER
# ============================================================

if ! docker ps \
    --format '{{.Names}}' \
    | grep -qx "$KALI_CONTAINER"; then

    fail "Le conteneur Kali ne fonctionne pas."

    docker logs "$KALI_CONTAINER" || true

    exit 1

fi

ok "Conteneur actif."


# ============================================================
# VERIFICATION DES CAPABILITIES
# ============================================================

echo
echo "============================================================"
echo "        CONFIGURATION EFFECTIVE DU CONTENEUR"
echo "============================================================"
echo

docker inspect "$KALI_CONTAINER" \
    --format 'CapDrop={{json .HostConfig.CapDrop}}'

docker inspect "$KALI_CONTAINER" \
    --format 'CapAdd={{json .HostConfig.CapAdd}}'

docker inspect "$KALI_CONTAINER" \
    --format 'Privileged={{.HostConfig.Privileged}}'

docker inspect "$KALI_CONTAINER" \
    --format 'SecurityOpt={{json .HostConfig.SecurityOpt}}'

echo


# ============================================================
# CONTROLE ANTI-ANCIENNE-CONFIG
# ============================================================

CAP_DROP="$(
    docker inspect "$KALI_CONTAINER" \
    --format '{{json .HostConfig.CapDrop}}'
)"

SECURITY_OPT="$(
    docker inspect "$KALI_CONTAINER" \
    --format '{{json .HostConfig.SecurityOpt}}'
)"


if [[ "$CAP_DROP" == *'"ALL"'* ]]; then

    fail "CapDrop=ALL détecté alors qu'il ne devrait plus être présent."
    exit 1

fi


if [[ "$SECURITY_OPT" == *'no-new-privileges'* ]]; then

    fail "no-new-privileges détecté alors qu'il ne devrait plus être présent."
    exit 1

fi


ok "Aucune ancienne restriction Docker détectée."


# ============================================================
# TEST ROOT
# ============================================================

info "Test utilisateur Kali..."

docker exec "$KALI_CONTAINER" bash -c '

    echo
    cat /etc/os-release | grep PRETTY_NAME
    echo

    id

'

ok "Root Kali fonctionnel."


# ============================================================
# TEST CHOWN
# ============================================================

info "Test CHOWN / SETUID / SETGID..."

docker exec "$KALI_CONTAINER" bash -c '

    set -e

    TEST_FILE="/tmp/kali-permission-test"

    touch "$TEST_FILE"

    chown 42:65534 "$TEST_FILE"

    ls -ln "$TEST_FILE"

    rm -f "$TEST_FILE"

'

ok "CHOWN fonctionnel."


# ============================================================
# TEST SETUID / SETGID
# ============================================================

info "Test changement UID/GID..."

docker exec "$KALI_CONTAINER" bash -c '

    set -e

    if command -v setpriv >/dev/null 2>&1; then

        setpriv \
            --reuid=65534 \
            --regid=65534 \
            --clear-groups \
            id

    else

        echo "setpriv absent : test ignoré."

    fi

'

ok "Permissions utilisateur fonctionnelles."


# ============================================================
# APT UPDATE KALI
# ============================================================

echo
echo "============================================================"
echo "                  TEST APT KALI"
echo "============================================================"
echo

info "apt-get update..."

docker exec "$KALI_CONTAINER" \
    apt-get update

ok "APT fonctionne correctement."


# ============================================================
# INSTALLATION PAQUETS DE BASE
# ============================================================

info "Installation des outils essentiels Kali..."

docker exec \
    -e DEBIAN_FRONTEND=noninteractive \
    "$KALI_CONTAINER" \
    apt-get install -y \
        kali-linux-headless \
        bash-completion \
        curl \
        wget \
        git \
        jq \
        nano \
        vim \
        tmux \
        tree \
        less \
        file \
        unzip \
        zip \
        python3 \
        python3-pip \
        python3-venv \
        pipx \
        iproute2 \
        iputils-ping \
        net-tools \
        dnsutils \
        whois \
        traceroute \
        netcat-openbsd \
        socat \
        nmap

ok "Kali Linux Headless installé."


# ============================================================
# TEST NMAP
# ============================================================

info "Test Nmap..."

docker exec "$KALI_CONTAINER" \
    nmap --version \
    | head -n 2

ok "Nmap opérationnel."


# ============================================================
# TEST PYTHON
# ============================================================

info "Test Python..."

docker exec "$KALI_CONTAINER" \
    python3 --version

ok "Python opérationnel."


# ============================================================
# TEST RESEAU
# ============================================================

info "Configuration réseau Kali :"

docker exec "$KALI_CONTAINER" bash -c '

    echo
    ip addr
    echo
    ip route
    echo

'

ok "Interface réseau opérationnelle."


# ============================================================
# COMMANDES HELPER
# ============================================================

info "Création des commandes pratiques..."


# ------------------------------------------------------------
# kali-shell
# ------------------------------------------------------------

cat >/usr/local/bin/kali-shell <<'EOF'
#!/usr/bin/env bash

docker exec -it kali-lab bash
EOF

chmod 755 /usr/local/bin/kali-shell


# ------------------------------------------------------------
# kali-start
# ------------------------------------------------------------

cat >/usr/local/bin/kali-start <<EOF
#!/usr/bin/env bash

cd "${KALI_DIR}"

docker compose \
    -f "${KALI_DIR}/compose.yml" \
    up -d
EOF

chmod 755 /usr/local/bin/kali-start


# ------------------------------------------------------------
# kali-stop
# ------------------------------------------------------------

cat >/usr/local/bin/kali-stop <<EOF
#!/usr/bin/env bash

cd "${KALI_DIR}"

docker compose \
    -f "${KALI_DIR}/compose.yml" \
    stop
EOF

chmod 755 /usr/local/bin/kali-stop


# ------------------------------------------------------------
# kali-restart
# ------------------------------------------------------------

cat >/usr/local/bin/kali-restart <<EOF
#!/usr/bin/env bash

cd "${KALI_DIR}"

docker compose \
    -f "${KALI_DIR}/compose.yml" \
    restart
EOF

chmod 755 /usr/local/bin/kali-restart


# ------------------------------------------------------------
# kali-status
# ------------------------------------------------------------

cat >/usr/local/bin/kali-status <<'EOF'
#!/usr/bin/env bash

echo
echo "============================================================"
echo "                     KALI STATUS"
echo "============================================================"
echo

docker ps -a \
    --filter name=kali-lab

echo
echo "Capabilities :"
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

chmod 755 /usr/local/bin/kali-status


# ------------------------------------------------------------
# kali-update
# ------------------------------------------------------------

cat >/usr/local/bin/kali-update <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

echo
echo "[+] Mise à jour Kali..."
echo

docker exec kali-lab \
    apt-get update

docker exec \
    -e DEBIAN_FRONTEND=noninteractive \
    kali-lab \
    apt-get dist-upgrade -y

docker exec kali-lab \
    apt-get autoremove -y

docker exec kali-lab \
    apt-get clean

echo
echo "[✓] Kali à jour."
echo
EOF

chmod 755 /usr/local/bin/kali-update


# ------------------------------------------------------------
# kali-logs
# ------------------------------------------------------------

cat >/usr/local/bin/kali-logs <<'EOF'
#!/usr/bin/env bash

docker logs \
    --tail 250 \
    -f \
    kali-lab
EOF

chmod 755 /usr/local/bin/kali-logs


# ------------------------------------------------------------
# kali-info
# ------------------------------------------------------------

cat >/usr/local/bin/kali-info <<'EOF'
#!/usr/bin/env bash

echo
echo "=== KALI ==="
echo

docker exec kali-lab \
    bash -c '
        grep PRETTY_NAME /etc/os-release
        echo
        uname -a
        echo
        python3 --version
        echo
        nmap --version | head -n 1
        echo
        ip route
    '

echo
echo "=== DOCKER SECURITY ==="
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

chmod 755 /usr/local/bin/kali-info


ok "Commandes helper installées."


# ============================================================
# PERMISSIONS DES DOSSIERS
# ============================================================

if id "$ADMIN_USER" >/dev/null 2>&1; then

    chown -R \
        "$ADMIN_USER":"$ADMIN_USER" \
        "$KALI_DIR/workspace" \
        "$KALI_DIR/shared" \
        "$KALI_DIR/logs" \
        || true

fi


# ============================================================
# TEST FINAL APT
# ============================================================

echo
echo "============================================================"
echo "                    TEST FINAL"
echo "============================================================"
echo

docker exec "$KALI_CONTAINER" bash -c '

    echo "Kali :"
    grep PRETTY_NAME /etc/os-release

    echo
    echo "Utilisateur :"
    id

    echo
    echo "APT :"

    apt-get update >/dev/null

    echo "OK"

    echo
    echo "Python :"
    python3 --version

    echo
    echo "Nmap :"
    nmap --version | head -n 1

'

echo
echo "============================================================"
echo -e "${GREEN}         INSTALLATION REUSSIE${NC}"
echo "============================================================"
echo

echo "Entrer dans Kali :"
echo
echo "    kali-shell"
echo

echo "Ou :"
echo
echo "    docker exec -it kali-lab bash"
echo

echo
echo "Commandes disponibles :"
echo

echo "    kali-shell"
echo "    kali-start"
echo "    kali-stop"
echo "    kali-restart"
echo "    kali-status"
echo "    kali-update"
echo "    kali-logs"
echo "    kali-info"

echo
echo "Répertoire principal :"
echo
echo "    $KALI_DIR"

echo
echo "Workspace partagé :"
echo
echo "    $KALI_DIR/workspace"

echo
echo "Fichiers partagés :"
echo
echo "    $KALI_DIR/shared"

echo
echo "Compose :"
echo
echo "    $KALI_DIR/compose.yml"

echo
echo "Log installation :"
echo
echo "    $LOG_FILE"

echo
echo "Configuration attendue :"
echo
echo '    CapDrop=null'
echo '    CapAdd=["CAP_NET_ADMIN"]'
echo '    Privileged=false'
echo '    SecurityOpt=null'
echo

if id "$ADMIN_USER" >/dev/null 2>&1; then

    if id -nG "$ADMIN_USER" | grep -qw docker; then

        echo "Utilisateur Docker : $ADMIN_USER"
        echo

    else

        echo "Reconnecte ta session SSH pour appliquer le groupe docker."
        echo

    fi

fi