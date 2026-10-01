#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# ============================================================
# Bootstrap Debian Server -> Docker -> Kali Linux container
# Usage prévu : administration / lab / pentest autorisé
#
# Compatible :
#   - Debian 12 Bookworm
#   - Debian 13 Trixie
#
# IMPORTANT :
# - Garder une seconde session SSH ouverte pendant l'installation.
# - Vérifier le port SSH configuré avant d'activer UFW.
# - Le groupe "docker" équivaut pratiquement à un accès root.
# ============================================================


# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

BASE_DIR="/opt/redteam"

KALI_NAME="kali-lab"
KALI_IMAGE="kalilinux/kali-rolling:latest"

# Par défaut, récupération automatique du port SSH.
# Vous pouvez remplacer manuellement par :
# SSH_PORT="22"
SSH_PORT=""

DOCKER_LOG_SIZE="20m"
DOCKER_LOG_FILES="5"


# ------------------------------------------------------------
# FONCTIONS
# ------------------------------------------------------------

log() {
    printf '\033[1;34m[+]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[!]\033[0m %s\n' "$*"
}

die() {
    printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
    exit 1
}

cleanup_on_error() {
    local exit_code=$?

    printf '\n'
    warn "Le script s'est arrêté avec le code : $exit_code"
    warn "Vérifiez les messages précédents avant de relancer."

    exit "$exit_code"
}

trap cleanup_on_error ERR


# ------------------------------------------------------------
# VÉRIFICATIONS INITIALES
# ------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "Exécutez ce script avec sudo."

[[ -f /etc/os-release ]] || die "/etc/os-release introuvable."

. /etc/os-release

case "${ID:-}" in
    debian)
        ;;
    *)
        die "Ce script est prévu pour Debian. OS détecté : ${ID:-inconnu}"
        ;;
esac

case "${VERSION_ID:-}" in
    12|13)
        ;;
    *)
        warn "Version Debian non explicitement testée : ${VERSION_ID:-inconnue}"
        ;;
esac

log "Système détecté : ${PRETTY_NAME:-Debian}"


# ------------------------------------------------------------
# DÉTERMINATION UTILISATEUR ADMIN
# ------------------------------------------------------------

if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
    ADMIN_USER="$SUDO_USER"
else
    ADMIN_USER="${USER:-root}"
fi

if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    die "Utilisateur administrateur introuvable : $ADMIN_USER"
fi

ADMIN_GROUP="$(id -gn "$ADMIN_USER")"

log "Utilisateur administrateur : $ADMIN_USER"
log "Groupe principal : $ADMIN_GROUP"


# ------------------------------------------------------------
# DÉTECTION PORT SSH
# ------------------------------------------------------------

if [[ -z "$SSH_PORT" ]]; then

    if command -v sshd >/dev/null 2>&1; then

        SSH_PORT="$(
            sshd -T 2>/dev/null \
            | awk '$1 == "port" {print $2; exit}' \
            || true
        )"

    fi

fi

SSH_PORT="${SSH_PORT:-22}"

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
    die "Port SSH invalide détecté : $SSH_PORT"
fi

log "Port SSH utilisé pour le firewall : $SSH_PORT/tcp"


# ============================================================
# 1. MISE À JOUR SYSTÈME
# ============================================================

log "Mise à jour des index APT..."

apt-get update


log "Mise à niveau du système..."

DEBIAN_FRONTEND=noninteractive \
apt-get upgrade -y


# ============================================================
# 2. PAQUETS DE BASE
# ============================================================

log "Installation des dépendances..."

DEBIAN_FRONTEND=noninteractive \
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    git \
    jq \
    tmux \
    vim \
    nano \
    htop \
    ufw \
    fail2ban \
    wireguard-tools \
    openssh-server \
    apt-transport-https \
    lsb-release


# ============================================================
# 3. SSH
# ============================================================

log "Vérification du service SSH..."

systemctl enable ssh >/dev/null 2>&1 || true
systemctl start ssh >/dev/null 2>&1 || true


# ============================================================
# 4. FIREWALL UFW
# ============================================================

log "Configuration UFW..."

ufw default deny incoming
ufw default allow outgoing

# Autorise le port SSH réel AVANT l'activation du firewall.
ufw allow "${SSH_PORT}/tcp"

ufw --force enable


log "État UFW :"

ufw status verbose || true


# ============================================================
# 5. FAIL2BAN
# ============================================================

log "Configuration Fail2ban..."

mkdir -p /etc/fail2ban/jail.d

cat >/etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]

enabled = true

maxretry = 5
findtime = 10m
bantime = 1h

backend = systemd
EOF


systemctl enable fail2ban
systemctl restart fail2ban


# ============================================================
# 6. SUPPRESSION DES PAQUETS DOCKER CONFLICTUELS
# ============================================================

log "Suppression éventuelle des paquets Docker conflictuels..."

for pkg in \
    docker.io \
    docker-compose \
    docker-doc \
    docker-buildx \
    podman-docker \
    containerd \
    runc
do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        apt-get remove -y "$pkg"
    fi
done


# ============================================================
# 7. DÉPÔT DOCKER OFFICIEL DEBIAN
# ============================================================

log "Ajout du dépôt Docker officiel..."

install -m 0755 -d /etc/apt/keyrings


curl -fsSL \
    https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc


chmod a+r /etc/apt/keyrings/docker.asc


cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF


apt-get update


# ============================================================
# 8. INSTALLATION DOCKER
# ============================================================

log "Installation Docker Engine..."

DEBIAN_FRONTEND=noninteractive \
apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin


systemctl enable docker
systemctl enable containerd

systemctl start containerd
systemctl start docker


# ============================================================
# 9. CONFIGURATION DOCKER
# ============================================================

log "Configuration du daemon Docker..."

mkdir -p /etc/docker


if [[ -f /etc/docker/daemon.json ]]; then

    cp \
        /etc/docker/daemon.json \
        "/etc/docker/daemon.json.backup.$(date +%Y%m%d-%H%M%S)"

fi


cat >/etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DOCKER_LOG_SIZE}",
    "max-file": "${DOCKER_LOG_FILES}"
  },
  "live-restore": true,
  "no-new-privileges": true
}
EOF


systemctl restart docker


# ============================================================
# 10. GROUPE DOCKER
# ============================================================

if [[ "$ADMIN_USER" != "root" ]]; then

    log "Ajout de $ADMIN_USER au groupe docker..."

    usermod -aG docker "$ADMIN_USER"

else

    warn "Le script est exécuté directement comme root."
    warn "Aucun utilisateur non-root n'a été ajouté au groupe docker."

fi


# ============================================================
# 11. TEST DOCKER
# ============================================================

log "Test Docker..."

docker version

docker compose version

docker run --rm hello-world


# ============================================================
# 12. ARBORESCENCE REDTEAM
# ============================================================

log "Création de l'arborescence $BASE_DIR..."

mkdir -p \
    "$BASE_DIR/kali/workspace" \
    "$BASE_DIR/kali/logs" \
    "$BASE_DIR/engagements" \
    "$BASE_DIR/scripts" \
    "$BASE_DIR/backups"


chown -R \
    "$ADMIN_USER:$ADMIN_GROUP" \
    "$BASE_DIR"


chmod 750 "$BASE_DIR"

chmod 750 "$BASE_DIR/kali"
chmod 750 "$BASE_DIR/kali/workspace"
chmod 750 "$BASE_DIR/kali/logs"
chmod 750 "$BASE_DIR/engagements"
chmod 750 "$BASE_DIR/scripts"
chmod 750 "$BASE_DIR/backups"


# ============================================================
# 13. DOCKER COMPOSE : KALI
# ============================================================

log "Création du fichier Docker Compose Kali..."

cat >"$BASE_DIR/kali/compose.yaml" <<EOF
services:

  kali:

    image: ${KALI_IMAGE}

    container_name: ${KALI_NAME}

    hostname: kali-lab

    stdin_open: true
    tty: true

    restart: unless-stopped

    working_dir: /workspace

    volumes:
      - ./workspace:/workspace
      - ./logs:/logs

    # Pas de mode privilégié.
    privileged: false

    # Évite l'élévation de privilèges via execve.
    security_opt:
      - no-new-privileges:true

    # On retire toutes les capacités Linux,
    # puis on ajoute uniquement NET_RAW.
    cap_drop:
      - ALL

    cap_add:
      - NET_RAW

    # Empêche un fork-bomb simple.
    pids_limit: 512

    # Limites raisonnables ; ajustez selon votre VPS.
    mem_limit: 4g
    cpus: 2.0

    command:
      - sleep
      - infinity
EOF


chown \
    "$ADMIN_USER:$ADMIN_GROUP" \
    "$BASE_DIR/kali/compose.yaml"


chmod 640 \
    "$BASE_DIR/kali/compose.yaml"


# ============================================================
# 14. TÉLÉCHARGEMENT KALI
# ============================================================

log "Téléchargement de Kali Linux..."

docker pull "$KALI_IMAGE"


# ============================================================
# 15. DÉMARRAGE KALI
# ============================================================

log "Démarrage du conteneur Kali..."

cd "$BASE_DIR/kali"

docker compose up -d


# ============================================================
# 16. ATTENTE DISPONIBILITÉ CONTENEUR
# ============================================================

log "Attente du démarrage du conteneur..."

for i in $(seq 1 30); do

    if docker inspect \
        -f '{{.State.Running}}' \
        "$KALI_NAME" \
        2>/dev/null \
        | grep -q true
    then
        break
    fi

    sleep 1

done


docker inspect \
    -f '{{.State.Running}}' \
    "$KALI_NAME" \
    | grep -q true \
    || die "Le conteneur Kali n'est pas démarré."


# ============================================================
# 17. INSTALLATION KALI HEADLESS
# ============================================================

log "Mise à jour de Kali..."

docker exec "$KALI_NAME" \
    bash -lc '
        set -Eeuo pipefail

        apt-get update

        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    '


log "Installation des outils Kali headless..."

docker exec "$KALI_NAME" \
    bash -lc '
        set -Eeuo pipefail

        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            kali-linux-headless \
            curl \
            wget \
            git \
            jq \
            python3 \
            python3-pip \
            python3-venv \
            iproute2 \
            iputils-ping \
            dnsutils \
            net-tools \
            procps \
            vim \
            nano \
            tmux \
            less \
            file \
            unzip \
            zip \
            ca-certificates

        apt-get clean

        rm -rf /var/lib/apt/lists/*
    '


# ============================================================
# 18. HELPER KALI-LAB
# ============================================================

log "Création du helper /usr/local/bin/kali-lab..."

cat >/usr/local/bin/kali-lab <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

KALI_NAME="${KALI_NAME}"

if ! docker inspect "\$KALI_NAME" >/dev/null 2>&1; then
    echo "Conteneur \$KALI_NAME introuvable."
    exit 1
fi

if [[ "\$(docker inspect -f '{{.State.Running}}' "\$KALI_NAME")" != "true" ]]; then
    echo "Démarrage de \$KALI_NAME..."
    docker start "\$KALI_NAME" >/dev/null
fi

exec docker exec -it "\$KALI_NAME" bash
EOF


chmod 755 /usr/local/bin/kali-lab


# ============================================================
# 19. HELPER KALI-STATUS
# ============================================================

cat >/usr/local/bin/kali-status <<EOF
#!/usr/bin/env bash

echo
echo "=== Docker ==="
docker --version
docker compose version

echo
echo "=== Kali ==="
docker ps \
    --filter "name=${KALI_NAME}" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'

echo
echo "=== Ressources ==="
docker stats \
    --no-stream \
    ${KALI_NAME} \
    2>/dev/null \
    || true
EOF


chmod 755 /usr/local/bin/kali-status


# ============================================================
# 20. HELPER KALI-UPDATE
# ============================================================

cat >/usr/local/bin/kali-update <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

docker exec ${KALI_NAME} \
    bash -lc '
        apt-get update &&
        DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y &&
        apt-get autoremove -y &&
        apt-get clean &&
        rm -rf /var/lib/apt/lists/*
    '
EOF


chmod 755 /usr/local/bin/kali-update


# ============================================================
# 21. TESTS FINAUX
# ============================================================

log "Vérification Docker..."

docker ps


log "Vérification Kali..."

docker exec \
    "$KALI_NAME" \
    bash -lc '
        cat /etc/os-release | grep PRETTY_NAME
    '


# ============================================================
# 22. RAPPORT FINAL
# ============================================================

echo
echo "============================================================"
echo "              INSTALLATION TERMINÉE"
echo "============================================================"
echo
echo "Hôte       : ${PRETTY_NAME:-Debian}"
echo "Admin      : $ADMIN_USER"
echo "SSH        : port $SSH_PORT/tcp"
echo
echo "Docker     : $(docker --version)"
echo "Compose    : $(docker compose version)"
echo
echo "Kali       : $KALI_NAME"
echo
echo "Workspace  : $BASE_DIR/kali/workspace"
echo "Logs       : $BASE_DIR/kali/logs"
echo
echo "Compose    : $BASE_DIR/kali/compose.yaml"
echo
echo "------------------------------------------------------------"
echo
echo "Entrer dans Kali :"
echo
echo "    kali-lab"
echo
echo "ou :"
echo
echo "    docker exec -it $KALI_NAME bash"
echo
echo "État Kali :"
echo
echo "    kali-status"
echo
echo "Mise à jour Kali :"
echo
echo "    kali-update"
echo
echo "État Docker :"
echo
echo "    docker ps"
echo
echo "État firewall :"
echo
echo "    ufw status verbose"
echo
echo "État Fail2ban :"
echo
echo "    fail2ban-client status sshd"
echo
echo "Logs Docker/Kali :"
echo
echo "    docker logs $KALI_NAME"
echo
echo "Arrêter Kali :"
echo
echo "    docker stop $KALI_NAME"
echo
echo "Redémarrer Kali :"
echo
echo "    docker restart $KALI_NAME"
echo
echo "============================================================"
echo

if [[ "$ADMIN_USER" != "root" ]]; then

    warn "Déconnectez puis reconnectez votre session SSH"
    warn "pour que l'appartenance au groupe docker soit prise en compte."

fi

warn "Docker et UFW ont des interactions particulières."
warn "N'exposez pas de ports Docker publiquement sans vérifier"
warn "vos règles firewall et la chaîne DOCKER-USER."

echo