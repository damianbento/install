#!/usr/bin/env bash
# ubuntu-ssh-hardening.sh
# Hardening inicial de SSH para Ubuntu Server.
# Recomendado para Ubuntu 22.04 / 24.04.
#
# Qué hace:
# - Instala openssh-server, ufw, fail2ban y logrotate si faltan.
# - Pide usuario administrativo.
# - Pide clave pública SSH y la instala en authorized_keys.
# - Cambia puerto SSH.
# - Deshabilita login root por SSH.
# - Deshabilita autenticación por password.
# - Activa autenticación por clave pública.
# - Configura fail2ban para SSH.
# - Configura rotación de logs de autenticación.
# - Activa UFW permitiendo el nuevo puerto SSH antes de habilitar el firewall.
#
# USO:
#   sudo bash ubuntu-ssh-hardening.sh
#
# IMPORTANTE:
#   Mantené una sesión/consola abierta mientras probás el nuevo acceso SSH.

set -Eeuo pipefail

BACKUP_DIR="/root/ssh-hardening-backups-$(date +%Y%m%d-%H%M%S)"
SSH_DROPIN="/etc/ssh/sshd_config.d/99-hardening.conf"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/sshd-hardening.local"
LOGROTATE_AUTH="/etc/logrotate.d/auth-hardening"

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok() { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Ejecutá este script como root o con sudo."
    exit 1
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer

  while true; do
    if [[ "$default" =~ ^[YySs]$ ]]; then
      read -r -p "$prompt [S/n]: " answer
      answer="${answer:-S}"
    else
      read -r -p "$prompt [s/N]: " answer
      answer="${answer:-N}"
    fi

    case "$answer" in
      s|S|si|SI|sí|SÍ|y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) echo "Respondé s o n." ;;
    esac
  done
}

ask_port() {
  local port
  while true; do
    read -r -p "Puerto SSH nuevo [2222]: " port
    port="${port:-2222}"

    if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 )); then
      echo "$port"
      return 0
    fi
    echo "Usá un puerto TCP entre 1024 y 65535."
  done
}

ask_user() {
  local user
  while true; do
    read -r -p "Usuario administrativo remoto [sshadmin]: " user
    user="${user:-sshadmin}"

    if [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
      echo "$user"
      return 0
    fi
    echo "Nombre de usuario inválido. Ejemplo: damian, sshadmin, soporte."
  done
}

ask_public_key() {
  local key
  echo
  echo "Pegá la clave pública SSH que va a poder conectarse."
  echo "Debe empezar con ssh-ed25519, ssh-rsa o ecdsa-sha2-nistp..."
  echo "Ejemplo: ssh-ed25519 AAAAC3... damian@mi-pc"
  echo
  while true; do
    read -r -p "Clave pública SSH: " key

    if [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
      echo "$key"
      return 0
    fi
    echo "La clave no parece válida. Copiá el contenido completo de tu archivo .pub."
  done
}

validate_cidr_or_ip_basic() {
  local value="$1"

  # Validación básica. No intenta reemplazar validadores completos de IPv4/IPv6/CIDR.
  if [[ "$value" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]]; then
    return 0
  fi

  return 1
}

install_packages() {
  info "Actualizando índice de paquetes e instalando dependencias..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server ufw fail2ban logrotate
  ok "Paquetes necesarios instalados."
}

create_backup() {
  mkdir -p "$BACKUP_DIR"

  [[ -f /etc/ssh/sshd_config ]] && cp -a /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.bak"
  [[ -f "$SSH_DROPIN" ]] && cp -a "$SSH_DROPIN" "$BACKUP_DIR/99-hardening.conf.bak"
  [[ -f "$FAIL2BAN_JAIL" ]] && cp -a "$FAIL2BAN_JAIL" "$BACKUP_DIR/sshd-hardening.local.bak"
  [[ -f "$LOGROTATE_AUTH" ]] && cp -a "$LOGROTATE_AUTH" "$BACKUP_DIR/auth-hardening.bak"

  ok "Backup guardado en $BACKUP_DIR"
}

ensure_user() {
  local user="$1"

  if id "$user" >/dev/null 2>&1; then
    info "El usuario $user ya existe."
  else
    info "Creando usuario $user..."

    # adduser falla si existe un grupo con el mismo nombre, aunque el usuario no exista.
    # Por eso, si el grupo ya existe, usamos useradd -g.
    if getent group "$user" >/dev/null 2>&1; then
      warn "Existe el grupo $user pero no el usuario. Creando usuario usando ese grupo existente."
      useradd -m -s /bin/bash -g "$user" "$user"
      passwd "$user"
    else
      adduser --gecos "" "$user"
    fi
  fi

  usermod -aG sudo "$user"
  ok "Usuario $user agregado al grupo sudo."
}

install_public_key() {
  local user="$1"
  local key="$2"
  local home_dir

  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  if [[ -z "$home_dir" || ! -d "$home_dir" ]]; then
    err "No pude detectar el home de $user."
    exit 1
  fi

  install -d -m 700 -o "$user" -g "$user" "$home_dir/.ssh"
  touch "$home_dir/.ssh/authorized_keys"
  chown "$user:$user" "$home_dir/.ssh/authorized_keys"
  chmod 600 "$home_dir/.ssh/authorized_keys"

  if grep -qxF "$key" "$home_dir/.ssh/authorized_keys"; then
    info "La clave pública ya estaba instalada para $user."
  else
    echo "$key" >> "$home_dir/.ssh/authorized_keys"
    ok "Clave pública instalada en $home_dir/.ssh/authorized_keys"
  fi
}

configure_sshd() {
  local user="$1"
  local port="$2"

  info "Configurando hardening SSH en $SSH_DROPIN..."

  mkdir -p /etc/ssh/sshd_config.d

  cat > "$SSH_DROPIN" <<EOF
# Gestionado por ubuntu-ssh-hardening.sh
Port $port
Protocol 2

PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no

PermitRootLogin no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2

AllowUsers $user
EOF

  chmod 644 "$SSH_DROPIN"

  if sshd -t; then
    ok "La configuración de sshd es válida."
  else
    err "sshd -t detectó errores. Restaurá desde $BACKUP_DIR si hace falta."
    exit 1
  fi
}

configure_ssh_socket_if_needed() {
  local port="$1"

  if systemctl list-unit-files ssh.socket >/dev/null 2>&1; then
    if systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1; then
      info "Detecté ssh.socket. Configurando ListenStream para el puerto $port..."

      mkdir -p /etc/systemd/system/ssh.socket.d
      cat > /etc/systemd/system/ssh.socket.d/override.conf <<EOF
# Gestionado por ubuntu-ssh-hardening.sh
[Socket]
ListenStream=
ListenStream=0.0.0.0:$port
ListenStream=[::]:$port
EOF

      systemctl daemon-reload
      systemctl restart ssh.socket
      systemctl restart ssh || true
      ok "ssh.socket configurado en el puerto $port."
      return 0
    fi
  fi

  info "No se detectó ssh.socket activo. Se usará el servicio ssh tradicional."
  systemctl restart ssh
}

configure_ufw() {
  local port="$1"
  local restrict_source="$2"
  local source_cidr="$3"

  info "Configurando UFW..."

  # No reseteamos UFW por defecto para no borrar reglas existentes.
  # Solo aplicamos defaults y agregamos el puerto SSH.
  ufw default deny incoming
  ufw default allow outgoing

  if [[ "$restrict_source" == "yes" ]]; then
    ufw allow from "$source_cidr" to any port "$port" proto tcp comment "SSH hardened restricted"
    ok "Permitido SSH puerto $port/tcp desde $source_cidr."
  else
    ufw allow "$port/tcp" comment "SSH hardened"
    ok "Permitido SSH puerto $port/tcp desde cualquier origen."
  fi

  ufw --force enable
  ufw reload
  ok "UFW activado."
}

configure_fail2ban() {
  local port="$1"

  info "Configurando Fail2Ban para SSH..."

  mkdir -p /etc/fail2ban/jail.d

  cat > "$FAIL2BAN_JAIL" <<EOF
# Gestionado por ubuntu-ssh-hardening.sh
[sshd]
enabled = true
port = $port
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

  systemctl enable fail2ban
  systemctl restart fail2ban
  ok "Fail2Ban activado para SSH."
}

configure_logrotate() {
  info "Configurando logrotate para logs de autenticación..."

  cat > "$LOGROTATE_AUTH" <<'EOF'
# Gestionado por ubuntu-ssh-hardening.sh
# Objetivo: evitar crecimiento excesivo de logs de autenticación.
# Rota si supera 100M, conserva 50 rotaciones comprimidas.
# Límite aproximado sin compresión: 5G.
/var/log/auth.log /var/log/fail2ban.log {
    daily
    rotate 50
    size 100M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0640 syslog adm
}
EOF

  logrotate -d "$LOGROTATE_AUTH" >/dev/null
  ok "Logrotate configurado."
}

show_summary() {
  local user="$1"
  local port="$2"

  echo
  ok "Hardening aplicado."
  echo
  echo "Probá desde tu PC:"
  echo "  ssh -p $port $user@IP_DEL_SERVIDOR"
  echo
  echo "Ver puerto escuchando:"
  echo "  sudo ss -tlnp | grep ssh"
  echo
  echo "Ver estado de UFW:"
  echo "  sudo ufw status numbered"
  echo
  echo "Ver Fail2Ban:"
  echo "  sudo fail2ban-client status sshd"
  echo
  echo "Backups:"
  echo "  $BACKUP_DIR"
  echo
  warn "No cierres la consola actual hasta probar una nueva conexión SSH."
}

main() {
  require_root

  echo "=== Ubuntu SSH Hardening ==="
  echo

  local admin_user ssh_port public_key restrict_source source_cidr

  admin_user="$(ask_user)"
  ssh_port="$(ask_port)"
  public_key="$(ask_public_key)"

  restrict_source="no"
  source_cidr=""
  if ask_yes_no "¿Querés limitar SSH a una IP o red de origen? Ej: 181.10.20.30 o 192.168.1.0/24" "N"; then
    restrict_source="yes"

    while true; do
      read -r -p "Origen permitido para SSH: " source_cidr
      if [[ -n "$source_cidr" ]] && validate_cidr_or_ip_basic "$source_cidr"; then
        break
      fi
      echo "Origen inválido o vacío. Ejemplos: 181.10.20.30 o 192.168.1.0/24"
    done
  fi

  echo
  warn "Resumen:"
  echo "  Usuario: $admin_user"
  echo "  Puerto SSH: $ssh_port"
  if [[ "$restrict_source" == "yes" ]]; then
    echo "  SSH permitido desde: $source_cidr"
  else
    echo "  SSH permitido desde: cualquier origen"
  fi
  echo "  PasswordAuthentication: no"
  echo "  PermitRootLogin: no"
  echo

  if ! ask_yes_no "¿Aplicar esta configuración?" "N"; then
    warn "Cancelado por el usuario."
    exit 0
  fi

  install_packages
  create_backup
  ensure_user "$admin_user"
  install_public_key "$admin_user" "$public_key"
  configure_sshd "$admin_user" "$ssh_port"
  configure_ufw "$ssh_port" "$restrict_source" "$source_cidr"
  configure_fail2ban "$ssh_port"
  configure_logrotate
  configure_ssh_socket_if_needed "$ssh_port"

  show_summary "$admin_user" "$ssh_port"
}

main "$@"
