#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.2.0"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# Versiones verificadas al crear este instalador.
ZABBIX_IMAGE_TAG="ubuntu-7.0-latest"
POSTGRES_IMAGE="postgres:16-alpine"
GRAFANA_IMAGE="grafana/grafana:13.1.1"
GRAFANA_ZABBIX_PLUGIN_VERSION="6.6.0"
CADDY_IMAGE="caddy:2.10-alpine"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

info()  { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()   { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

on_error() {
  local ec=$?
  printf '\n%sFalló el instalador en la línea %s (código %s).%s\n' \
    "$RED" "${BASH_LINENO[0]:-desconocida}" "$ec" "$RESET" >&2
  printf 'Revise también: %s/install.log\n' "${INSTALL_DIR:-/opt/zabbix-monitoring}" >&2

  if [[ -n "${INSTALL_DIR:-}" && -f "${INSTALL_DIR}/compose.yml" ]] && command -v docker >/dev/null 2>&1; then
    printf '\n===== DIAGNÓSTICO AUTOMÁTICO =====\n' >&2
    (
      cd "$INSTALL_DIR"
      docker compose ps -a || true
      printf '\n--- zabbix-db-init ---\n'
      docker compose logs --no-color --tail=200 zabbix-db-init || true
      printf '\n--- postgres ---\n'
      docker compose logs --no-color --tail=100 postgres || true
    ) >&2
  fi
  exit "$ec"
}
trap on_error ERR
trap 'printf "\nInstalación cancelada.\n"; exit 130' INT TERM

if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "$@"
  fi
  die "Ejecute este script como root."
fi

banner() {
  clear 2>/dev/null || true
  cat <<'EOF'
================================================================
 Instalador interactivo Zabbix + PostgreSQL + Grafana + Caddy
================================================================
Este instalador:
  - genera Docker Compose y secretos;
  - despliega Zabbix 7.0 LTS, PostgreSQL y Grafana;
  - configura retención y contraseña de Admin por API;
  - crea autorregistro para Linux y Windows;
  - configura PSK opcional para agentes;
  - conecta Grafana con Zabbix;
  - prepara backup automático opcional.
EOF
  [[ $DRY_RUN -eq 1 ]] && warn "Modo --dry-run: genera archivos pero no ejecuta Docker."
  echo
}

ask() {
  local prompt="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "$prompt: " value
    printf '%s' "$value"
  fi
}

ask_yes_no() {
  local prompt="$1" default="${2:-s}" reply suffix
  [[ "$default" == "s" ]] && suffix="[S/n]" || suffix="[s/N]"
  while true; do
    read -r -p "$prompt $suffix: " reply
    reply="${reply:-$default}"
    case "${reply,,}" in
      s|si|sí|y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "Responda s o n." ;;
    esac
  done
}

ask_int() {
  local prompt="$1" default="$2" min="$3" max="$4" value
  while true; do
    value="$(ask "$prompt" "$default")"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min && value <= max )); then
      printf '%s' "$value"
      return
    fi
    warn "Ingrese un número entre $min y $max."
  done
}

ask_identifier() {
  local prompt="$1" default="$2" value
  while true; do
    value="$(ask "$prompt" "$default")"
    if [[ "$value" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,62}$ ]]; then
      printf '%s' "$value"
      return
    fi
    warn "Use letras, números, guion o guion bajo; debe comenzar con letra o _. "
  done
}

ask_project() {
  local prompt="$1" default="$2" value
  while true; do
    value="$(ask "$prompt" "$default")"
    if [[ "$value" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]; then
      printf '%s' "$value"
      return
    fi
    warn "Use minúsculas, números, guion o guion bajo."
  done
}

ask_port() {
  ask_int "$1" "$2" 1 65535
}

ask_fqdn() {
  local prompt="$1" default="${2:-}" value
  while true; do
    value="$(ask "$prompt" "$default")"
    if [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
      printf '%s' "${value,,}"
      return
    fi
    warn "Ingrese un FQDN válido, por ejemplo zabbix.empresa.com.ar."
  done
}

ask_email() {
  local prompt="$1" default="${2:-}" value
  while true; do
    value="$(ask "$prompt" "$default")"
    if [[ "$value" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
      printf '%s' "$value"
      return
    fi
    warn "Ingrese un correo válido."
  done
}

generate_secret() {
  local profile="$1"
  case "$profile" in
    postgres) openssl rand -hex 32 ;;
    grafana|zabbix)
      openssl rand -base64 48 | tr -dc 'A-Za-z0-9_@%+=:.,-' | head -c 40
      ;;
    psk) openssl rand -hex 32 ;;
    *) die "Perfil de secreto desconocido: $profile" ;;
  esac
}

validate_secret() {
  local profile="$1" value="$2"
  case "$profile" in
    postgres) [[ "$value" =~ ^[A-Fa-f0-9]{32,128}$ ]] ;;
    grafana|zabbix)
      (( ${#value} >= 16 && ${#value} <= 128 )) &&
        [[ "$value" =~ ^[A-Za-z0-9_@%+=:.,-]+$ ]]
      ;;
    psk)
      [[ "$value" =~ ^[A-Fa-f0-9]{32,512}$ ]] && (( ${#value} % 2 == 0 ))
      ;;
    *) return 1 ;;
  esac
}

prompt_secret() {
  local label="$1" profile="$2" first second generated choice
  while true; do
    echo >&2
    echo "$label" >&2
    echo "  1) Generar automáticamente una contraseña recomendada" >&2
    echo "  2) Ingresar una contraseña manualmente" >&2
    choice="$(ask_int "Seleccione una opción" "1" 1 2)"
    if [[ "$choice" == "1" ]]; then
      generated="$(generate_secret "$profile")"
      printf '%s' "$generated"
      return
    fi
    read -r -s -p "Ingrese la contraseña: " first
    echo >&2
    if ! validate_secret "$profile" "$first"; then
      case "$profile" in
        postgres) warn "Use 32-128 caracteres hexadecimales (0-9, a-f)." ;;
        grafana|zabbix) warn "Use 16-128 caracteres: letras, números y _ @ % + = : . , -" ;;
      esac
      continue
    fi
    read -r -s -p "Repita la contraseña: " second
    echo >&2
    [[ "$first" == "$second" ]] || { warn "Las contraseñas no coinciden."; continue; }
    printf '%s' "$first"
    return
  done
}

safe_name() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._[:space:]-]{0,100}$ ]]
}

port_in_use() {
  local bind="$1" port="$2"
  command -v ss >/dev/null 2>&1 || return 1
  if [[ "$bind" == "0.0.0.0" || "$bind" == "::" ]]; then
    ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"
  else
    ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|\[)$bind(\]|):$port$|(^|:)$port$"
  fi
}

ensure_dependencies() {
  local missing=()
  for cmd in curl openssl python3 tar gzip; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]} == 0)); then
    return
  fi

  warn "Faltan herramientas auxiliares: ${missing[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    info "Instalando curl, openssl y python3..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl python3 ca-certificates
  else
    die "Instale manualmente curl, openssl, python3, tar y gzip."
  fi
}

detect_timezone() {
  if [[ -r /etc/timezone ]]; then
    tr -d '\n' </etc/timezone
  elif command -v timedatectl >/dev/null 2>&1; then
    timedatectl show -p Timezone --value 2>/dev/null || echo "America/Argentina/Buenos_Aires"
  else
    echo "America/Argentina/Buenos_Aires"
  fi
}

detect_primary_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "${ip:-127.0.0.1}"
}

check_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker no está instalado."
  docker compose version >/dev/null 2>&1 || die "Se necesita Docker Compose v2."
  docker info >/dev/null 2>&1 || die "Docker Engine no está ejecutándose o no hay permisos."
}

calculate_caches() {
  local count="$1"
  if (( count <= 50 )); then
    ZBX_CACHESIZE="128M"
    ZBX_HISTORYCACHESIZE="32M"
    ZBX_HISTORYINDEXCACHESIZE="16M"
    ZBX_TRENDCACHESIZE="16M"
    ZBX_VALUECACHESIZE="64M"
    ZBX_STARTPOLLERS=10
    ZBX_STARTPINGERS=5
  elif (( count <= 200 )); then
    ZBX_CACHESIZE="256M"
    ZBX_HISTORYCACHESIZE="64M"
    ZBX_HISTORYINDEXCACHESIZE="32M"
    ZBX_TRENDCACHESIZE="32M"
    ZBX_VALUECACHESIZE="128M"
    ZBX_STARTPOLLERS=20
    ZBX_STARTPINGERS=10
  elif (( count <= 500 )); then
    ZBX_CACHESIZE="512M"
    ZBX_HISTORYCACHESIZE="128M"
    ZBX_HISTORYINDEXCACHESIZE="64M"
    ZBX_TRENDCACHESIZE="64M"
    ZBX_VALUECACHESIZE="256M"
    ZBX_STARTPOLLERS=40
    ZBX_STARTPINGERS=20
  else
    ZBX_CACHESIZE="1024M"
    ZBX_HISTORYCACHESIZE="256M"
    ZBX_HISTORYINDEXCACHESIZE="128M"
    ZBX_TRENDCACHESIZE="128M"
    ZBX_VALUECACHESIZE="512M"
    ZBX_STARTPOLLERS=80
    ZBX_STARTPINGERS=30
    warn "Para más de 500 VMs conviene revisar sizing, particionamiento y Zabbix Proxy."
  fi
}

prepare_install_dir() {
  if [[ -e "$INSTALL_DIR" && -n "$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    warn "El directorio $INSTALL_DIR no está vacío."
    if [[ -f "$INSTALL_DIR/compose.yml" ]]; then
      if ! ask_yes_no "¿Eliminar la instalación existente, incluidos sus volúmenes?" "n"; then
        die "No se modificó la instalación existente."
      fi
      if [[ $DRY_RUN -eq 0 ]]; then
        (cd "$INSTALL_DIR" && docker compose down -v --remove-orphans) || true
      fi
      local old="${INSTALL_DIR}.old.$(date +%Y%m%d-%H%M%S)"
      mv "$INSTALL_DIR" "$old"
      warn "La configuración anterior quedó en $old"
    else
      die "Use un directorio vacío o mueva su contenido."
    fi
  fi
  mkdir -p "$INSTALL_DIR"/{secrets,caddy,scripts,agents/linux,agents/windows,backups,zabbix/alertscripts,zabbix/externalscripts,zabbix/ssh_keys}
  chmod 700 "$INSTALL_DIR/secrets" "$INSTALL_DIR/backups" "$INSTALL_DIR/zabbix/ssh_keys"
}

write_secret() {
  local file="$1" value="$2"
  umask 022
  printf '%s' "$value" >"$INSTALL_DIR/secrets/$file"
  chmod 644 "$INSTALL_DIR/secrets/$file"
}

write_env() {
  cat >"$INSTALL_DIR/.env" <<EOF
COMPOSE_PROJECT_NAME=$PROJECT_NAME
TZ=$TIMEZONE
POSTGRES_DB=$POSTGRES_DB
POSTGRES_USER=$POSTGRES_USER
ZABBIX_WEB_PORT=$ZABBIX_WEB_PORT
GRAFANA_PORT=$GRAFANA_PORT
ZABBIX_TRAPPER_PORT=$ZABBIX_TRAPPER_PORT
EOF
  chmod 600 "$INSTALL_DIR/.env"
}

write_compose() {
  local caddy_service=""
  if [[ "$DEPLOY_MODE" == "public" ]]; then
    caddy_service=$(cat <<EOF

  caddy:
    image: $CADDY_IMAGE
    container_name: ${PROJECT_NAME}-caddy
    restart: unless-stopped
    environment:
      ZABBIX_FQDN: "$ZABBIX_FQDN"
      GRAFANA_FQDN: "$GRAFANA_FQDN"
      ACME_EMAIL: "$ACME_EMAIL"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    depends_on:
      - zabbix-web
      - grafana
    networks:
      - frontend
    logging: *default_logging
EOF
)
  fi

  cat >"$INSTALL_DIR/compose.yml" <<EOF
name: $PROJECT_NAME

services:
  postgres:
    image: $POSTGRES_IMAGE
    container_name: ${PROJECT_NAME}-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: "$POSTGRES_DB"
      POSTGRES_USER: "$POSTGRES_USER"
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
      TZ: "$TIMEZONE"
      PGTZ: "$TIMEZONE"
    secrets:
      - postgres_password
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
      interval: 10s
      timeout: 5s
      retries: 20
      start_period: 20s
    networks:
      - backend
    logging: &default_logging
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"

  zabbix-db-init:
    image: zabbix/zabbix-server-pgsql:$ZABBIX_IMAGE_TAG
    container_name: ${PROJECT_NAME}-db-init
    init: true
    attach: true
    read_only: true
    restart: "no"
    command: init_db_only
    tmpfs:
      - /tmp
    environment:
      DB_SERVER_HOST: postgres
      DB_SERVER_PORT: "5432"
      POSTGRES_DB: "$POSTGRES_DB"
      POSTGRES_USER: "$POSTGRES_USER"
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
      TZ: "$TIMEZONE"
    secrets:
      - postgres_password
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - backend
    logging: *default_logging

  zabbix-server:
    image: zabbix/zabbix-server-pgsql:$ZABBIX_IMAGE_TAG
    container_name: ${PROJECT_NAME}-server
    init: true
    restart: unless-stopped
    environment:
      DB_SERVER_HOST: postgres
      DB_SERVER_PORT: "5432"
      POSTGRES_DB: "$POSTGRES_DB"
      POSTGRES_USER: "$POSTGRES_USER"
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
      ZBX_CACHESIZE: "$ZBX_CACHESIZE"
      ZBX_HISTORYCACHESIZE: "$ZBX_HISTORYCACHESIZE"
      ZBX_HISTORYINDEXCACHESIZE: "$ZBX_HISTORYINDEXCACHESIZE"
      ZBX_TRENDCACHESIZE: "$ZBX_TRENDCACHESIZE"
      ZBX_VALUECACHESIZE: "$ZBX_VALUECACHESIZE"
      ZBX_STARTPOLLERS: "$ZBX_STARTPOLLERS"
      ZBX_STARTPINGERS: "$ZBX_STARTPINGERS"
      ZBX_TIMEOUT: "10"
      TZ: "$TIMEZONE"
    secrets:
      - postgres_password
    volumes:
      - ./zabbix/alertscripts:/usr/lib/zabbix/alertscripts:ro
      - ./zabbix/externalscripts:/usr/lib/zabbix/externalscripts:ro
      - ./zabbix/ssh_keys:/var/lib/zabbix/ssh_keys:ro
    cap_add:
      - NET_RAW
    ports:
      - "$ZABBIX_TRAPPER_BIND_IP:$ZABBIX_TRAPPER_PORT:10051"
    depends_on:
      postgres:
        condition: service_healthy
      zabbix-db-init:
        condition: service_completed_successfully
    stop_grace_period: 30s
    networks:
      - backend
      - frontend
    logging: *default_logging

  zabbix-web:
    image: zabbix/zabbix-web-nginx-pgsql:$ZABBIX_IMAGE_TAG
    container_name: ${PROJECT_NAME}-web
    restart: unless-stopped
    environment:
      DB_SERVER_HOST: postgres
      DB_SERVER_PORT: "5432"
      POSTGRES_DB: "$POSTGRES_DB"
      POSTGRES_USER: "$POSTGRES_USER"
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
      ZBX_SERVER_HOST: zabbix-server
      ZBX_SERVER_PORT: "10051"
      ZBX_SERVER_NAME: "$ZABBIX_SERVER_NAME"
      PHP_TZ: "$TIMEZONE"
    secrets:
      - postgres_password
    ports:
      - "$WEB_BIND_IP:$ZABBIX_WEB_PORT:8080"
    depends_on:
      postgres:
        condition: service_healthy
      zabbix-db-init:
        condition: service_completed_successfully
      zabbix-server:
        condition: service_started
    networks:
      - backend
      - frontend
    logging: *default_logging

  grafana:
    image: $GRAFANA_IMAGE
    container_name: ${PROJECT_NAME}-grafana
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_USER: "$GRAFANA_ADMIN_USER"
      GF_SECURITY_ADMIN_PASSWORD__FILE: /run/secrets/grafana_admin_password
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_AUTH_ANONYMOUS_ENABLED: "false"
      GF_SECURITY_COOKIE_SECURE: "$GRAFANA_COOKIE_SECURE"
      GF_SECURITY_COOKIE_SAMESITE: strict
      GF_SERVER_ROOT_URL: "$GRAFANA_ROOT_URL"
      GF_PLUGINS_PREINSTALL: "alexanderzobnin-zabbix-app@$GRAFANA_ZABBIX_PLUGIN_VERSION"
      GF_LOG_MODE: console
      TZ: "$TIMEZONE"
    secrets:
      - grafana_admin_password
    volumes:
      - grafana_data:/var/lib/grafana
    ports:
      - "$GRAFANA_BIND_IP:$GRAFANA_PORT:3000"
    depends_on:
      - zabbix-web
    networks:
      - backend
      - frontend
    logging: *default_logging
$caddy_service

networks:
  backend:
    internal: true
  frontend:

volumes:
  postgres_data:
    name: ${PROJECT_NAME}_postgres_data
  grafana_data:
    name: ${PROJECT_NAME}_grafana_data
  caddy_data:
    name: ${PROJECT_NAME}_caddy_data
  caddy_config:
    name: ${PROJECT_NAME}_caddy_config

secrets:
  postgres_password:
    file: ./secrets/postgres_password.txt
  grafana_admin_password:
    file: ./secrets/grafana_admin_password.txt
EOF
}

write_caddy() {
  [[ "$DEPLOY_MODE" == "public" ]] || return 0
  cat >"$INSTALL_DIR/caddy/Caddyfile" <<'EOF'
{
	email {$ACME_EMAIL}
	admin off
}

{$ZABBIX_FQDN} {
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
	}
	reverse_proxy zabbix-web:8080
}

{$GRAFANA_FQDN} {
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
	}
	reverse_proxy grafana:3000
}
EOF
}

write_agent_files() {
  local tls_linux tls_windows
  if [[ "$AGENT_TLS_MODE" == "psk" ]]; then
    tls_linux=$(cat <<EOF
TLSConnect=psk
TLSPSKIdentity=$AGENT_PSK_IDENTITY
TLSPSKFile=/etc/zabbix/zabbix_agent2.psk
EOF
)
    tls_windows=$(cat <<EOF
TLSConnect=psk
TLSPSKIdentity=$AGENT_PSK_IDENTITY
TLSPSKFile=C:\\Program Files\\Zabbix Agent 2\\zabbix_agent2.psk
EOF
)
    printf '%s' "$AGENT_PSK" >"$INSTALL_DIR/agents/linux/zabbix_agent2.psk"
    printf '%s' "$AGENT_PSK" >"$INSTALL_DIR/agents/windows/zabbix_agent2.psk"
    chmod 600 "$INSTALL_DIR/agents/linux/zabbix_agent2.psk" "$INSTALL_DIR/agents/windows/zabbix_agent2.psk"
  else
    tls_linux="TLSConnect=unencrypted"
    tls_windows="TLSConnect=unencrypted"
  fi

  cat >"$INSTALL_DIR/agents/linux/90-cloud-active.conf" <<EOF
# Zabbix Agent 2 - Linux - comprobaciones activas
ServerActive=$AGENT_SERVER_ADDRESS:$ZABBIX_TRAPPER_PORT
HostnameItem=system.hostname
HostMetadata=linux-cloud-active
RefreshActiveChecks=60
BufferSend=5
BufferSize=1000
Timeout=10
$tls_linux
EOF

  cat >"$INSTALL_DIR/agents/windows/90-cloud-active.conf" <<EOF
# Zabbix Agent 2 - Windows - comprobaciones activas
ServerActive=$AGENT_SERVER_ADDRESS:$ZABBIX_TRAPPER_PORT
HostnameItem=system.hostname
HostMetadata=windows-cloud-active
RefreshActiveChecks=60
BufferSend=5
BufferSize=1000
Timeout=10
$tls_windows
EOF

  cat >"$INSTALL_DIR/agents/linux/install-agent2-debian-ubuntu.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Ejecute con sudo."; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v zabbix_agent2 >/dev/null 2>&1; then
  echo "Zabbix Agent 2 no está instalado."
  echo "Instálelo desde el repositorio oficial correspondiente a su distribución y vuelva a ejecutar."
  exit 1
fi

install -d -m 0755 /etc/zabbix/zabbix_agent2.d
install -m 0644 "$SCRIPT_DIR/90-cloud-active.conf" \
  /etc/zabbix/zabbix_agent2.d/90-cloud-active.conf

if [[ -f "$SCRIPT_DIR/zabbix_agent2.psk" ]]; then
  install -o zabbix -g zabbix -m 0600 "$SCRIPT_DIR/zabbix_agent2.psk" \
    /etc/zabbix/zabbix_agent2.psk
fi

systemctl enable --now zabbix-agent2
systemctl restart zabbix-agent2
systemctl --no-pager --full status zabbix-agent2
EOF
  chmod +x "$INSTALL_DIR/agents/linux/install-agent2-debian-ubuntu.sh"
}

write_bootstrap_python() {
  cat >"$INSTALL_DIR/scripts/bootstrap_zabbix.py" <<'PYEOF'
#!/usr/bin/env python3
import argparse
import json
import os
import stat
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


class ApiError(RuntimeError):
    pass


class ZabbixAPI:
    def __init__(self, endpoint: str):
        self.endpoint = endpoint
        self.auth = None
        self.req_id = 0

    def call(self, method: str, params, authenticated: bool = True):
        self.req_id += 1
        body = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": self.req_id,
        }
        if authenticated and self.auth:
            body["auth"] = self.auth

        request = urllib.request.Request(
            self.endpoint,
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json-rpc"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise ApiError(f"{method}: {exc}") from exc

        if "error" in payload:
            err = payload["error"]
            raise ApiError(
                f"{method}: {err.get('message', 'error')} - {err.get('data', '')}"
            )
        return payload.get("result")

    def login(self, username: str, password: str):
        self.auth = self.call(
            "user.login",
            {"username": username, "password": password},
            authenticated=False,
        )
        return self.auth


def ensure_group(api: ZabbixAPI, name: str) -> str:
    result = api.call(
        "hostgroup.get",
        {"output": ["groupid", "name"], "filter": {"name": [name]}},
    )
    if result:
        return result[0]["groupid"]
    return api.call("hostgroup.create", {"name": name})["groupids"][0]


def find_template(api: ZabbixAPI, candidates: list[str]) -> tuple[str, str]:
    for name in candidates:
        result = api.call(
            "template.get",
            {"output": ["templateid", "host", "name"], "filter": {"host": [name]}},
        )
        if result:
            return result[0]["templateid"], name

        result = api.call(
            "template.get",
            {"output": ["templateid", "host", "name"], "filter": {"name": [name]}},
        )
        if result:
            return result[0]["templateid"], name
    raise ApiError(f"No se encontró ninguna plantilla: {', '.join(candidates)}")


def ensure_action(
    api: ZabbixAPI,
    name: str,
    metadata: str,
    group_id: str,
    template_id: str,
    os_name: str,
):
    current = api.call(
        "action.get",
        {
            "output": ["actionid", "name"],
            "filter": {"name": [name]},
        },
    )
    if current:
        print(f"[OK] Acción ya existente: {name}")
        return

    api.call(
        "action.create",
        {
            "name": name,
            "eventsource": "2",
            "status": "0",
            "filter": {
                "evaltype": "0",
                "conditions": [
                    {
                        "conditiontype": "24",
                        "operator": "2",
                        "value": metadata,
                    }
                ],
            },
            "operations": [
                {"operationtype": "2"},
                {
                    "operationtype": "4",
                    "opgroup": [{"groupid": group_id}],
                },
                {
                    "operationtype": "6",
                    "optemplate": [{"templateid": template_id}],
                },
                {"operationtype": "8"},
                {
                    "operationtype": "13",
                    "optag": [
                        {"tag": "environment", "value": "cloud"},
                        {"tag": "os", "value": os_name},
                        {"tag": "registration", "value": "automatic"},
                    ],
                },
            ],
        },
    )
    print(f"[OK] Acción creada: {name}")


def write_secret(path: Path, value: str):
    path.write_text(value, encoding="utf-8")
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--new-password-file", required=True)
    parser.add_argument("--history-days", type=int, required=True)
    parser.add_argument("--trends-days", type=int, required=True)
    parser.add_argument("--tls-mode", choices=["psk", "unencrypted"], required=True)
    parser.add_argument("--psk-identity")
    parser.add_argument("--psk-file")
    parser.add_argument("--token-output", required=True)
    args = parser.parse_args()

    new_password = Path(args.new_password_file).read_text(encoding="utf-8")
    api = ZabbixAPI(args.endpoint)

    logged_with_default = False
    try:
        api.login("Admin", "zabbix")
        logged_with_default = True
    except ApiError:
        api.login("Admin", new_password)

    users = api.call(
        "user.get",
        {"output": ["userid", "username"], "filter": {"username": ["Admin"]}},
    )
    if not users:
        raise ApiError("No se encontró el usuario Admin.")
    admin_id = users[0]["userid"]

    if logged_with_default and new_password != "zabbix":
        api.call(
            "user.update",
            {
                "userid": admin_id,
                "current_passwd": "zabbix",
                "passwd": new_password,
            },
        )
        print("[OK] Contraseña inicial de Zabbix cambiada.")

        # Zabbix invalida la sesión que realizó el cambio de contraseña.
        # Volvemos a iniciar sesión antes de continuar con housekeeping,
        # autorregistro, acciones y creación del token para Grafana.
        api.auth = None
        api.login("Admin", new_password)
        print("[OK] Nueva sesión API iniciada después del cambio de contraseña.")

    api.call(
        "housekeeping.update",
        {
            "hk_history_mode": "1",
            "hk_history_global": "1",
            "hk_history": f"{args.history_days}d",
            "hk_trends_mode": "1",
            "hk_trends_global": "1",
            "hk_trends": f"{args.trends_days}d",
        },
    )
    print(
        f"[OK] Retención configurada: history={args.history_days}d, "
        f"trends={args.trends_days}d."
    )

    if args.tls_mode == "psk":
        if not args.psk_identity or not args.psk_file:
            raise ApiError("Faltan PSK identity o PSK file.")
        psk = Path(args.psk_file).read_text(encoding="utf-8").strip()
        api.call(
            "autoregistration.update",
            {
                "tls_accept": "2",
                "tls_psk_identity": args.psk_identity,
                "tls_psk": psk,
            },
        )
        print("[OK] Autorregistro configurado con TLS-PSK.")
    else:
        api.call("autoregistration.update", {"tls_accept": "1"})
        print("[WARN] Autorregistro configurado sin cifrado.")

    linux_group = ensure_group(api, "Cloud/Linux")
    windows_group = ensure_group(api, "Cloud/Windows")

    linux_template, linux_name = find_template(
        api,
        ["Linux by Zabbix agent active", "Linux by Zabbix agent"],
    )
    windows_template, windows_name = find_template(
        api,
        ["Windows by Zabbix agent active", "Windows by Zabbix agent"],
    )
    print(f"[OK] Plantilla Linux: {linux_name}")
    print(f"[OK] Plantilla Windows: {windows_name}")

    ensure_action(
        api,
        "Autoregistro Cloud Linux",
        "linux-cloud-active",
        linux_group,
        linux_template,
        "linux",
    )
    ensure_action(
        api,
        "Autoregistro Cloud Windows",
        "windows-cloud-active",
        windows_group,
        windows_template,
        "windows",
    )

    token_name = "Grafana datasource"
    existing = api.call(
        "token.get",
        {
            "output": ["tokenid", "name", "userid", "status"],
            "filter": {"name": [token_name]},
        },
    )
    if existing:
        token_id = existing[0]["tokenid"]
    else:
        token_id = api.call(
            "token.create",
            {"name": token_name, "userid": admin_id, "status": "0"},
        )["tokenids"][0]

    generated = api.call("token.generate", [token_id])
    token = generated[0]["token"]
    write_secret(Path(args.token_output), token)
    print("[OK] API token para Grafana generado.")

    try:
        api.call("user.logout", [])
    except ApiError:
        pass


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        sys.exit(1)
PYEOF
  chmod 700 "$INSTALL_DIR/scripts/bootstrap_zabbix.py"

  cat >"$INSTALL_DIR/scripts/configure_grafana.py" <<'PYEOF'
#!/usr/bin/env python3
import argparse
import base64
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def request(url, method="GET", data=None, username=None, password=None):
    headers = {"Content-Type": "application/json"}
    if username is not None:
        raw = f"{username}:{password}".encode("utf-8")
        headers["Authorization"] = "Basic " + base64.b64encode(raw).decode("ascii")
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as response:
        content = response.read()
        return json.loads(content.decode("utf-8")) if content else {}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--grafana-url", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--zabbix-token-file", required=True)
    args = parser.parse_args()

    password = Path(args.password_file).read_text(encoding="utf-8")
    token = Path(args.zabbix_token_file).read_text(encoding="utf-8")
    base = args.grafana_url.rstrip("/")

    last_error = None
    for _ in range(60):
        try:
            request(f"{base}/api/health")
            break
        except Exception as exc:
            last_error = exc
            time.sleep(5)
    else:
        raise RuntimeError(f"Grafana no respondió: {last_error}")

    payload = {
        "name": "Zabbix",
        "type": "alexanderzobnin-zabbix-datasource",
        "access": "proxy",
        "url": "http://zabbix-web:8080/api_jsonrpc.php",
        "isDefault": True,
        "basicAuth": False,
        "jsonData": {
            "authType": "token",
            "trends": True,
            "trendsFrom": "7d",
            "trendsRange": "4d",
            "cacheTTL": "1h",
            "disableReadOnlyUsersAck": True,
        },
        "secureJsonData": {"apiToken": token},
    }

    for attempt in range(30):
        try:
            try:
                existing = request(
                    f"{base}/api/datasources/name/Zabbix",
                    username=args.username,
                    password=password,
                )
                uid = existing["uid"]
                request(
                    f"{base}/api/datasources/uid/{uid}",
                    method="PUT",
                    data=payload,
                    username=args.username,
                    password=password,
                )
                print("[OK] Datasource Zabbix actualizado en Grafana.")
            except urllib.error.HTTPError as exc:
                if exc.code != 404:
                    raise
                request(
                    f"{base}/api/datasources",
                    method="POST",
                    data=payload,
                    username=args.username,
                    password=password,
                )
                print("[OK] Datasource Zabbix creado en Grafana.")
            return
        except Exception as exc:
            last_error = exc
            time.sleep(5)

    raise RuntimeError(f"No se pudo configurar el datasource: {last_error}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        sys.exit(1)
PYEOF
  chmod 700 "$INSTALL_DIR/scripts/configure_grafana.py"
}

write_backup_scripts() {
  cat >"$INSTALL_DIR/scripts/backup.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

set -a
source .env
set +a

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="backups/$STAMP"
mkdir -p "$DEST"
chmod 700 "$DEST"

DB_PASSWORD="$(cat secrets/postgres_password.txt)"
docker compose exec -T -e PGPASSWORD="$DB_PASSWORD" postgres \
  pg_dump --clean --if-exists --no-owner --no-privileges \
  -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip -9 >"$DEST/zabbix-postgresql.sql.gz"

docker run --rm \
  -v "${COMPOSE_PROJECT_NAME}_grafana_data:/data:ro" \
  -v "$(pwd)/$DEST:/backup" \
  alpine:3.22 \
  tar -czf /backup/grafana-data.tar.gz -C /data .

tar -czf "$DEST/configuration.tar.gz" \
  --exclude='./secrets' \
  --exclude='./backups' \
  --exclude='./.git' \
  compose.yml .env caddy agents zabbix scripts README.md

sha256sum "$DEST"/* >"$DEST/SHA256SUMS"
chmod 600 "$DEST"/*
find backups -mindepth 1 -maxdepth 1 -type d -mtime +"${BACKUP_RETENTION_DAYS:-14}" -exec rm -rf {} +

echo "Backup terminado: $DEST"
EOF
  chmod 700 "$INSTALL_DIR/scripts/backup.sh"

  cat >"$INSTALL_DIR/scripts/restore-postgres.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

DUMP="${1:-}"
[[ -f "$DUMP" ]] || {
  echo "Uso: $0 backups/AAAAMMDD-HHMMSS/zabbix-postgresql.sql.gz"
  exit 1
}

set -a
source .env
set +a

read -r -p "Escriba RESTAURAR para reemplazar la base: " answer
[[ "$answer" == "RESTAURAR" ]] || exit 1

DB_PASSWORD="$(cat secrets/postgres_password.txt)"
docker compose stop zabbix-web zabbix-server grafana
gunzip -c "$DUMP" | docker compose exec -T -e PGPASSWORD="$DB_PASSWORD" postgres \
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" "$POSTGRES_DB"
docker compose start zabbix-server zabbix-web grafana
echo "Restauración terminada."
EOF
  chmod 700 "$INSTALL_DIR/scripts/restore-postgres.sh"
}

write_recovery_script() {
  cat >"$INSTALL_DIR/scripts/recover-db-init.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

echo "Estado actual:"
docker compose ps -a
echo
echo "Log de zabbix-db-init:"
docker compose logs --no-color --tail=250 zabbix-db-init || true
echo
echo "Log de PostgreSQL:"
docker compose logs --no-color --tail=150 postgres || true

if [[ "${1:-}" != "--reset-new-install" ]]; then
  cat <<'TXT'

No se realizaron cambios.

Si esta es una instalación NUEVA, sin datos que conservar, ejecute:
  sudo ./scripts/recover-db-init.sh --reset-new-install
TXT
  exit 0
fi

read -r -p "Esto eliminará la base nueva. Escriba REINICIAR: " answer
[[ "$answer" == "REINICIAR" ]] || exit 1

docker compose down -v --remove-orphans
docker compose up -d postgres zabbix-db-init
docker compose logs --no-color -f zabbix-db-init
EOF
  chmod 700 "$INSTALL_DIR/scripts/recover-db-init.sh"
}

write_readme() {
  cat >"$INSTALL_DIR/README.md" <<EOF
# Monitoreo cloud

Instalador versión: \`$SCRIPT_VERSION\`

Instalación generada por \`install-zabbix-monitoring.sh\`.

## Versiones

- Zabbix: \`$ZABBIX_IMAGE_TAG\`
- PostgreSQL: \`$POSTGRES_IMAGE\`
- Grafana: \`$GRAFANA_IMAGE\`
- Plugin Grafana-Zabbix: \`$GRAFANA_ZABBIX_PLUGIN_VERSION\`
- Caddy: \`$CADDY_IMAGE\`

## Operación

\`\`\`bash
cd $INSTALL_DIR
docker compose ps
docker compose logs -f --tail=100 zabbix-server
docker compose logs -f --tail=100 zabbix-web
docker compose logs -f --tail=100 grafana
\`\`\`

## URLs

- Zabbix: $ZABBIX_URL
- Grafana: $GRAFANA_URL

## Credenciales

Las contraseñas están en \`$INSTALL_DIR/secrets/\`, con permisos 600.

## Agentes

Copie el contenido de:

- \`agents/linux/\` a una VM Linux.
- \`agents/windows/\` a una VM Windows.

Los agentes usarán:

- ServerActive: \`$AGENT_SERVER_ADDRESS:$ZABBIX_TRAPPER_PORT\`
- Metadata Linux: \`linux-cloud-active\`
- Metadata Windows: \`windows-cloud-active\`
- Seguridad: \`$AGENT_TLS_MODE\`

## Backup

Manual:

\`\`\`bash
$INSTALL_DIR/scripts/backup.sh
\`\`\`

Restauración PostgreSQL:

\`\`\`bash
$INSTALL_DIR/scripts/restore-postgres.sh backups/FECHA/zabbix-postgresql.sql.gz
\`\`\`

## Actualización

\`\`\`bash
cd $INSTALL_DIR
./scripts/backup.sh
docker compose pull
docker compose up -d
docker compose ps
\`\`\`

Revise las notas de versión antes de cambiar las ramas mayores de Zabbix,
Grafana o PostgreSQL.
EOF
}

write_credentials_summary() {
  cat >"$INSTALL_DIR/secrets/ACCESS.txt" <<EOF
Zabbix URL: $ZABBIX_URL
Zabbix usuario: Admin
Zabbix contraseña: $(cat "$INSTALL_DIR/secrets/zabbix_admin_password.txt")

Grafana URL: $GRAFANA_URL
Grafana usuario: $GRAFANA_ADMIN_USER
Grafana contraseña: $(cat "$INSTALL_DIR/secrets/grafana_admin_password.txt")

PostgreSQL base: $POSTGRES_DB
PostgreSQL usuario: $POSTGRES_USER
PostgreSQL contraseña: $(cat "$INSTALL_DIR/secrets/postgres_password.txt")

Agentes ServerActive: $AGENT_SERVER_ADDRESS:$ZABBIX_TRAPPER_PORT
Seguridad de agentes: $AGENT_TLS_MODE
EOF
  if [[ "$AGENT_TLS_MODE" == "psk" ]]; then
    cat >>"$INSTALL_DIR/secrets/ACCESS.txt" <<EOF
PSK identity: $AGENT_PSK_IDENTITY
PSK: $AGENT_PSK
EOF
  fi
  chmod 600 "$INSTALL_DIR/secrets/ACCESS.txt"
}

wait_for_postgres() {
  info "Esperando PostgreSQL..."
  for _ in $(seq 1 60); do
    if [[ "$(docker inspect --format '{{.State.Health.Status}}' "${PROJECT_NAME}-postgres" 2>/dev/null || true)" == "healthy" ]]; then
      ok "PostgreSQL está saludable."
      return
    fi
    sleep 2
  done
  docker compose logs --no-color --tail=150 postgres >&2 || true
  die "PostgreSQL no quedó saludable."
}

test_postgres_auth() {
  info "Probando autenticación PostgreSQL por TCP..."
  docker run --rm \
    --network "${PROJECT_NAME}_backend" \
    -v "$INSTALL_DIR/secrets/postgres_password.txt:/run/db_password:ro" \
    -e PGUSER="$POSTGRES_USER" \
    -e PGDATABASE="$POSTGRES_DB" \
    "$POSTGRES_IMAGE" \
    sh -ec 'export PGPASSWORD="$(cat /run/db_password)"; psql -h postgres -p 5432 -v ON_ERROR_STOP=1 -c "select current_database(), current_user;" >/dev/null'
  ok "Autenticación PostgreSQL validada."
}

wait_for_db_init() {
  info "Esperando la importación inicial de Zabbix..."
  local status exit_code
  for _ in $(seq 1 180); do
    status="$(docker inspect --format '{{.State.Status}}' "${PROJECT_NAME}-db-init" 2>/dev/null || true)"
    exit_code="$(docker inspect --format '{{.State.ExitCode}}' "${PROJECT_NAME}-db-init" 2>/dev/null || true)"
    if [[ "$status" == "exited" && "$exit_code" == "0" ]]; then ok "Base de Zabbix inicializada."; return; fi
    if [[ "$status" == "exited" && "$exit_code" != "0" ]]; then
      docker compose logs --no-color --tail=250 zabbix-db-init >&2 || true
      die "zabbix-db-init terminó con código $exit_code."
    fi
    sleep 2
  done
  docker compose logs --no-color --tail=250 zabbix-db-init >&2 || true
  die "La inicialización de Zabbix excedió el tiempo esperado."
}

wait_for_zabbix_server_db() {
  info "Validando Zabbix Server..."
  for _ in $(seq 1 60); do
    if docker compose logs --no-color --since 20s zabbix-server 2>/dev/null | grep -q 'server #0 started'; then ok "Zabbix Server inició correctamente."; return; fi
    if docker compose logs --no-color --since 30s zabbix-server 2>/dev/null | grep -q 'password authentication failed'; then
      docker compose logs --no-color --tail=120 zabbix-server >&2 || true
      die "Zabbix Server no pudo autenticarse en PostgreSQL."
    fi
    sleep 2
  done
  docker compose logs --no-color --tail=150 zabbix-server >&2 || true
  die "Zabbix Server no terminó de iniciar."
}

wait_for_zabbix() {
  local endpoint="$1" response
  info "Esperando que la API de Zabbix esté disponible..."
  for _ in $(seq 1 90); do
    response="$(curl -fsS --max-time 5 \
      -H 'Content-Type: application/json-rpc' \
      -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' \
      "$endpoint" 2>/dev/null || true)"
    if grep -q '"result"' <<<"$response"; then
      ok "API de Zabbix disponible."
      return
    fi
    sleep 5
  done
  docker compose logs --tail=100 zabbix-web zabbix-server >&2 || true
  die "Zabbix no quedó disponible."
}

wait_for_grafana() {
  local url="$1"
  info "Esperando que Grafana esté disponible..."
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 5 "$url/api/health" >/dev/null 2>&1; then
      if docker compose exec -T grafana test -d /var/lib/grafana/plugins/alexanderzobnin-zabbix-app 2>/dev/null; then
        ok "Grafana y el plugin de Zabbix están disponibles."
        return
      fi
    fi
    sleep 5
  done
  docker compose logs --tail=100 grafana >&2 || true
  die "Grafana no quedó disponible."
}

configure_ufw() {
  [[ "$CONFIGURE_UFW" == "yes" ]] || return 0
  if ! command -v ufw >/dev/null 2>&1; then
    warn "UFW no está instalado; no se modificó el firewall."
    return
  fi
  if ! ufw status | grep -q '^Status: active'; then
    warn "UFW está inactivo. No se lo habilitó para evitar bloquear SSH."
    return
  fi

  ufw allow from "$AGENT_ALLOWED_CIDR" to any port "$ZABBIX_TRAPPER_PORT" proto tcp
  if [[ "$DEPLOY_MODE" == "public" ]]; then
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 443/udp
  else
    ufw allow from "$WEB_ALLOWED_CIDR" to any port "$ZABBIX_WEB_PORT" proto tcp
    ufw allow from "$WEB_ALLOWED_CIDR" to any port "$GRAFANA_PORT" proto tcp
  fi
  ok "Reglas UFW agregadas. Revise también el Security Group de la nube."
}

install_backup_timer() {
  [[ "$ENABLE_BACKUP" == "yes" ]] || return 0
  cat >"/etc/systemd/system/${PROJECT_NAME}-backup.service" <<EOF
[Unit]
Description=Backup de $PROJECT_NAME
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=$INSTALL_DIR
Environment=BACKUP_RETENTION_DAYS=$BACKUP_RETENTION_DAYS
ExecStart=$INSTALL_DIR/scripts/backup.sh
EOF

  cat >"/etc/systemd/system/${PROJECT_NAME}-backup.timer" <<EOF
[Unit]
Description=Backup diario de $PROJECT_NAME

[Timer]
OnCalendar=*-*-* $BACKUP_TIME:00
Persistent=true
RandomizedDelaySec=300
Unit=${PROJECT_NAME}-backup.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${PROJECT_NAME}-backup.timer"
  ok "Backup automático habilitado a las $BACKUP_TIME."
}

banner
[[ $DRY_RUN -eq 1 ]] || ensure_dependencies
[[ $DRY_RUN -eq 1 ]] || check_docker

DEFAULT_TZ="$(detect_timezone)"
DEFAULT_IP="$(detect_primary_ip)"

INSTALL_DIR="$(ask "Directorio de instalación" "/opt/zabbix-monitoring")"
[[ "$INSTALL_DIR" == /* ]] || die "El directorio debe ser una ruta absoluta."

PROJECT_NAME="$(ask_project "Nombre del proyecto Docker" "zabbix-monitoring")"
TIMEZONE="$(ask "Zona horaria" "${DEFAULT_TZ:-America/Argentina/Buenos_Aires}")"
ZABBIX_SERVER_NAME="$(ask "Nombre visible del servidor Zabbix" "Zabbix Cloud")"
safe_name "$ZABBIX_SERVER_NAME" || die "El nombre visible contiene caracteres no admitidos."

EXPECTED_VMS="$(ask_int "Cantidad estimada de VMs" "100" 1 100000)"
HISTORY_DAYS="$(ask_int "Días de métricas detalladas (history)" "30" 1 9125)"
TRENDS_DAYS="$(ask_int "Días de tendencias agregadas (trends)" "365" 1 9125)"
calculate_caches "$EXPECTED_VMS"

echo
echo "Modo de publicación:"
echo "  1) Interno: HTTP en IP/puertos elegidos"
echo "  2) Público: HTTPS automático con Caddy y DNS"
DEPLOY_CHOICE="$(ask_int "Seleccione el modo" "1" 1 2)"

if [[ "$DEPLOY_CHOICE" == "2" ]]; then
  DEPLOY_MODE="public"
  ZABBIX_FQDN="$(ask_fqdn "Dominio de Zabbix" "zabbix.example.com")"
  GRAFANA_FQDN="$(ask_fqdn "Dominio de Grafana" "grafana.example.com")"
  [[ "$ZABBIX_FQDN" != "$GRAFANA_FQDN" ]] || die "Los dominios deben ser distintos."
  ACME_EMAIL="$(ask_email "Correo para certificados TLS")"
  WEB_BIND_IP="127.0.0.1"
  GRAFANA_BIND_IP="127.0.0.1"
  ZABBIX_WEB_PORT="$(ask_port "Puerto local de mantenimiento para Zabbix" "8080")"
  GRAFANA_PORT="$(ask_port "Puerto local de mantenimiento para Grafana" "3000")"
  GRAFANA_ROOT_URL="https://$GRAFANA_FQDN"
  GRAFANA_COOKIE_SECURE="true"
  ZABBIX_URL="https://$ZABBIX_FQDN"
  GRAFANA_URL="https://$GRAFANA_FQDN"
  DEFAULT_AGENT_ADDR="$ZABBIX_FQDN"
else
  DEPLOY_MODE="internal"
  WEB_BIND_IP="$(ask "IP donde publicar Zabbix y Grafana" "$DEFAULT_IP")"
  GRAFANA_BIND_IP="$WEB_BIND_IP"
  ZABBIX_WEB_PORT="$(ask_port "Puerto web de Zabbix" "8080")"
  GRAFANA_PORT="$(ask_port "Puerto web de Grafana" "3000")"
  GRAFANA_ROOT_URL="http://$WEB_BIND_IP:$GRAFANA_PORT"
  GRAFANA_COOKIE_SECURE="false"
  ZABBIX_URL="http://$WEB_BIND_IP:$ZABBIX_WEB_PORT"
  GRAFANA_URL="http://$WEB_BIND_IP:$GRAFANA_PORT"
  DEFAULT_AGENT_ADDR="$WEB_BIND_IP"
  ZABBIX_FQDN=""
  GRAFANA_FQDN=""
  ACME_EMAIL=""
fi

[[ "$ZABBIX_WEB_PORT" != "$GRAFANA_PORT" ]] || die "Zabbix y Grafana no pueden usar el mismo puerto."
ZABBIX_TRAPPER_BIND_IP="$(ask "IP donde escuchar agentes" "0.0.0.0")"
ZABBIX_TRAPPER_PORT="$(ask_port "Puerto de agentes activos" "10051")"
AGENT_SERVER_ADDRESS="$(ask "DNS o IP que usarán las VMs en ServerActive" "$DEFAULT_AGENT_ADDR")"
[[ "$AGENT_SERVER_ADDRESS" != *" "* ]] || die "La dirección de agentes no puede contener espacios."

echo
echo "Seguridad entre agentes y Zabbix:"
echo "  1) TLS con PSK compartida para autorregistro (recomendado)"
echo "  2) Sin cifrado, solo para red privada/VPN controlada"
TLS_CHOICE="$(ask_int "Seleccione seguridad" "1" 1 2)"
if [[ "$TLS_CHOICE" == "1" ]]; then
  AGENT_TLS_MODE="psk"
  AGENT_PSK_IDENTITY="$(ask_identifier "Identidad PSK" "cloud-autoreg")"
  AGENT_PSK="$(generate_secret psk)"
else
  AGENT_TLS_MODE="unencrypted"
  AGENT_PSK_IDENTITY=""
  AGENT_PSK=""
  warn "El tráfico de Agent 2 no quedará cifrado."
fi

echo
POSTGRES_DB="$(ask_identifier "Nombre de la base PostgreSQL" "zabbix")"
POSTGRES_USER="$(ask_identifier "Usuario PostgreSQL" "zabbix")"
POSTGRES_PASSWORD="$(prompt_secret "Contraseña PostgreSQL" postgres)"

GRAFANA_ADMIN_USER="$(ask_identifier "Usuario administrador de Grafana" "admin")"
GRAFANA_ADMIN_PASSWORD="$(prompt_secret "Contraseña de Grafana" grafana)"
ZABBIX_ADMIN_PASSWORD="$(prompt_secret "Nueva contraseña del usuario Admin de Zabbix" zabbix)"
[[ "$ZABBIX_ADMIN_PASSWORD" != "zabbix" ]] || die "No use la contraseña inicial 'zabbix'."

if ask_yes_no "¿Configurar backup diario con systemd?" "s"; then
  ENABLE_BACKUP="yes"
  while true; do
    BACKUP_TIME="$(ask "Hora del backup, formato HH:MM" "03:15")"
    [[ "$BACKUP_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break
    warn "Formato inválido."
  done
  BACKUP_RETENTION_DAYS="$(ask_int "Días de backups locales a conservar" "14" 1 3650)"
else
  ENABLE_BACKUP="no"
  BACKUP_TIME=""
  BACKUP_RETENTION_DAYS="14"
fi

if ask_yes_no "¿Agregar reglas si UFW ya está activo?" "n"; then
  CONFIGURE_UFW="yes"
  AGENT_ALLOWED_CIDR="$(ask "CIDR autorizado para agentes" "10.0.0.0/8")"
  if [[ "$DEPLOY_MODE" == "internal" ]]; then
    WEB_ALLOWED_CIDR="$(ask "CIDR autorizado para las interfaces web" "10.0.0.0/8")"
  else
    WEB_ALLOWED_CIDR=""
  fi
else
  CONFIGURE_UFW="no"
  AGENT_ALLOWED_CIDR=""
  WEB_ALLOWED_CIDR=""
fi

echo
printf '%sResumen%s\n' "$BOLD" "$RESET"
printf '  Directorio:        %s\n' "$INSTALL_DIR"
printf '  Proyecto:           %s\n' "$PROJECT_NAME"
printf '  VMs estimadas:      %s\n' "$EXPECTED_VMS"
printf '  Zabbix:             %s\n' "$ZABBIX_URL"
printf '  Grafana:            %s\n' "$GRAFANA_URL"
printf '  Agentes:            %s:%s (%s)\n' "$AGENT_SERVER_ADDRESS" "$ZABBIX_TRAPPER_PORT" "$AGENT_TLS_MODE"
printf '  History/Trends:     %sd / %sd\n' "$HISTORY_DAYS" "$TRENDS_DAYS"
printf '  Backup automático:  %s\n' "$ENABLE_BACKUP"
printf '  Contraseñas:        definidas y ocultas\n'
echo

ask_yes_no "¿Generar y desplegar con esta configuración?" "s" || die "Instalación cancelada."

if [[ $DRY_RUN -eq 0 ]]; then
  if port_in_use "$WEB_BIND_IP" "$ZABBIX_WEB_PORT"; then
    die "El puerto $WEB_BIND_IP:$ZABBIX_WEB_PORT ya está en uso."
  fi
  if port_in_use "$GRAFANA_BIND_IP" "$GRAFANA_PORT"; then
    die "El puerto $GRAFANA_BIND_IP:$GRAFANA_PORT ya está en uso."
  fi
  if port_in_use "$ZABBIX_TRAPPER_BIND_IP" "$ZABBIX_TRAPPER_PORT"; then
    die "El puerto $ZABBIX_TRAPPER_BIND_IP:$ZABBIX_TRAPPER_PORT ya está en uso."
  fi
  if [[ "$DEPLOY_MODE" == "public" ]]; then
    port_in_use "0.0.0.0" 80 && die "TCP/80 ya está en uso."
    port_in_use "0.0.0.0" 443 && die "TCP/443 ya está en uso."
  fi
fi

prepare_install_dir
exec > >(tee -a "$INSTALL_DIR/install.log") 2>&1

info "Generando configuración..."
write_secret "postgres_password.txt" "$POSTGRES_PASSWORD"
write_secret "grafana_admin_password.txt" "$GRAFANA_ADMIN_PASSWORD"
write_secret "zabbix_admin_password.txt" "$ZABBIX_ADMIN_PASSWORD"
write_env
write_compose
write_caddy
write_agent_files
write_bootstrap_python
write_backup_scripts
write_recovery_script
write_readme
write_credentials_summary

touch "$INSTALL_DIR/zabbix/alertscripts/.gitkeep"
touch "$INSTALL_DIR/zabbix/externalscripts/.gitkeep"
touch "$INSTALL_DIR/zabbix/ssh_keys/.gitkeep"

chmod 600 "$INSTALL_DIR/.env" "$INSTALL_DIR/compose.yml"
chmod 600 "$INSTALL_DIR/install.log" || true

if [[ $DRY_RUN -eq 1 ]]; then
  ok "Archivos generados en $INSTALL_DIR."
  info "No se ejecutó Docker por estar en modo --dry-run."
  exit 0
fi

cd "$INSTALL_DIR"
docker compose config --quiet
ok "Docker Compose validado."

for secret_file in \
  secrets/postgres_password.txt \
  secrets/grafana_admin_password.txt \
  secrets/zabbix_admin_password.txt; do
  [[ -s "$secret_file" ]] || die "El secreto $secret_file está vacío o no existe."
  chmod 644 "$secret_file"
done
ok "Secretos validados."

info "Descargando imágenes..."
docker compose pull

info "Iniciando PostgreSQL..."
docker compose up -d postgres
wait_for_postgres
test_postgres_auth

info "Inicializando la base de Zabbix..."
docker compose up -d zabbix-db-init
wait_for_db_init

info "Iniciando Zabbix Server y la interfaz web..."
docker compose up -d zabbix-server zabbix-web
wait_for_zabbix_server_db

BOOTSTRAP_HOST="$WEB_BIND_IP"
[[ "$BOOTSTRAP_HOST" == "0.0.0.0" || "$BOOTSTRAP_HOST" == "::" ]] && BOOTSTRAP_HOST="127.0.0.1"
ZABBIX_API_ENDPOINT="http://$BOOTSTRAP_HOST:$ZABBIX_WEB_PORT/api_jsonrpc.php"
wait_for_zabbix "$ZABBIX_API_ENDPOINT"

BOOTSTRAP_ARGS=(
  --endpoint "$ZABBIX_API_ENDPOINT"
  --new-password-file "$INSTALL_DIR/secrets/zabbix_admin_password.txt"
  --history-days "$HISTORY_DAYS"
  --trends-days "$TRENDS_DAYS"
  --tls-mode "$AGENT_TLS_MODE"
  --token-output "$INSTALL_DIR/secrets/zabbix_grafana_api_token.txt"
)
if [[ "$AGENT_TLS_MODE" == "psk" ]]; then
  BOOTSTRAP_ARGS+=(
    --psk-identity "$AGENT_PSK_IDENTITY"
    --psk-file "$INSTALL_DIR/agents/linux/zabbix_agent2.psk"
  )
fi
info "Aplicando configuración automática de Zabbix..."
python3 -u "$INSTALL_DIR/scripts/bootstrap_zabbix.py" "${BOOTSTRAP_ARGS[@]}"
ok "Configuración automática de Zabbix terminada."

[[ -s "$INSTALL_DIR/secrets/zabbix_grafana_api_token.txt" ]] ||
  die "Zabbix no generó el API token requerido por Grafana."
chmod 600 "$INSTALL_DIR/secrets/zabbix_grafana_api_token.txt"

info "Iniciando Grafana..."
docker compose up -d grafana

GRAFANA_BOOTSTRAP_HOST="$GRAFANA_BIND_IP"
[[ "$GRAFANA_BOOTSTRAP_HOST" == "0.0.0.0" || "$GRAFANA_BOOTSTRAP_HOST" == "::" ]] && GRAFANA_BOOTSTRAP_HOST="127.0.0.1"
GRAFANA_BOOTSTRAP_URL="http://$GRAFANA_BOOTSTRAP_HOST:$GRAFANA_PORT"
wait_for_grafana "$GRAFANA_BOOTSTRAP_URL"

info "Configurando el datasource Zabbix en Grafana..."
python3 -u "$INSTALL_DIR/scripts/configure_grafana.py" \
  --grafana-url "$GRAFANA_BOOTSTRAP_URL" \
  --username "$GRAFANA_ADMIN_USER" \
  --password-file "$INSTALL_DIR/secrets/grafana_admin_password.txt" \
  --zabbix-token-file "$INSTALL_DIR/secrets/zabbix_grafana_api_token.txt"
ok "Datasource Zabbix configurado en Grafana."

if [[ "$DEPLOY_MODE" == "public" ]]; then
  info "Iniciando Caddy y solicitando certificados..."
  docker compose up -d caddy
fi

configure_ufw
install_backup_timer

info "Validando el despliegue final..."
docker compose ps -a

[[ "$(docker inspect --format '{{.State.Health.Status}}' "${PROJECT_NAME}-postgres" 2>/dev/null)" == "healthy" ]] ||
  die "PostgreSQL no está healthy al finalizar."

[[ "$(docker inspect --format '{{.State.Status}}' "${PROJECT_NAME}-server" 2>/dev/null)" == "running" ]] ||
  die "Zabbix Server no está ejecutándose al finalizar."

[[ "$(docker inspect --format '{{.State.Status}}' "${PROJECT_NAME}-web" 2>/dev/null)" == "running" ]] ||
  die "Zabbix Web no está ejecutándose al finalizar."

[[ "$(docker inspect --format '{{.State.Status}}' "${PROJECT_NAME}-grafana" 2>/dev/null)" == "running" ]] ||
  die "Grafana no está ejecutándose al finalizar."

curl -fsS --max-time 10 "$ZABBIX_API_ENDPOINT"   -H 'Content-Type: application/json-rpc'   -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}'   | grep -q '"result"' ||
  die "La API de Zabbix no respondió correctamente al finalizar."

curl -fsS --max-time 10 "$GRAFANA_BOOTSTRAP_URL/api/health" >/dev/null ||
  die "La API de salud de Grafana no respondió correctamente al finalizar."

ok "Despliegue terminado y validado."

cat <<EOF

================================================================
 ACCESO
================================================================
Zabbix:  $ZABBIX_URL
Usuario: Admin

Grafana: $GRAFANA_URL
Usuario: $GRAFANA_ADMIN_USER

Credenciales completas:
  $INSTALL_DIR/secrets/ACCESS.txt

Agentes:
  $INSTALL_DIR/agents/

Comandos útiles:
  cd $INSTALL_DIR
  docker compose ps
  docker compose logs -f --tail=100 zabbix-server
  docker compose logs -f --tail=100 grafana

IMPORTANTE:
  - Permita TCP/$ZABBIX_TRAPPER_PORT desde las redes de las VMs.
  - En modo público, permita TCP/80, TCP/443 y opcionalmente UDP/443.
  - Configure también el Security Group o firewall de la nube.
  - Copie los backups fuera de esta misma VM.
================================================================
EOF
