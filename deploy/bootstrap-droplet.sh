#!/usr/bin/env bash
# One-time droplet provisioning. Run as root (or via sudo) on a fresh
# Ubuntu 22.04/24.04 DigitalOcean droplet:
#
#   ssh root@<droplet-ip> 'bash -s' < deploy/bootstrap-droplet.sh
#
# Installs Docker + Compose, creates the non-root deploy user, opens the firewall,
# and prepares /opt/aisat-intel. Idempotent — safe to re-run.
set -euo pipefail

APP_DIR="/opt/aisat-intel"
DEPLOY_USER="${DEPLOY_USER:-deploy}"

log() { printf '\n\033[1;32m== %s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root (or sudo)"; exit 1; }

log "Installing Docker Engine + Compose plugin"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

log "Creating deploy user '${DEPLOY_USER}'"
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"

log "Preparing ${APP_DIR}"
mkdir -p "${APP_DIR}/deploy"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$APP_DIR"

log "Configuring firewall (SSH + HTTP + HTTPS)"
if command -v ufw >/dev/null 2>&1; then
  ufw allow OpenSSH || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  yes | ufw enable || true
fi

log "Enabling swap (2G) if none present (small droplets)"
if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

cat <<EOF

============================================================================
 Droplet bootstrap complete. Finish setup as the deploy user:

 1) Provide the SSH key the CD pipeline will use:
      - add the PUBLIC key to  /home/${DEPLOY_USER}/.ssh/authorized_keys
      - add the PRIVATE key to GitHub secret  DROPLET_SSH_KEY
      - set GitHub secrets DROPLET_HOST / DROPLET_USER (=${DEPLOY_USER})

 2) Create the production env file (NOT committed):
      cd ${APP_DIR}/deploy
      cp .env.production.example .env.production   # (copied here on first deploy)
      \$EDITOR .env.production && chmod 600 .env.production

 3) Log Docker into Docker Hub so private images can be pulled:
      su - ${DEPLOY_USER} -c 'docker login -u <DOCKERHUB_USERNAME>'

 Then push to main and approve the 'production' deployment in GitHub.
============================================================================
EOF
