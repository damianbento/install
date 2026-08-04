#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.1.0"
DEFAULT_ZABBIX_DIR="/opt/zabbix-monitoring"
DEFAULT_SSH_USER="dami"
DEFAULT_SSH_PORT="22"
DEFAULT_PARALLEL="1"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; RESET=$'\033[0m'
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Uso:
  $0 [opciones]

Opciones:
  --hosts FILE            Archivo con una IP/DNS por línea.
  --user USER             Usuario SSH.
  --port PORT             Puerto SSH.
  --identity FILE         Clave privada SSH.
  --zabbix-dir DIR        Directorio del stack Zabbix.
  --host IP_O_DNS         Agregar un único host. Puede repetirse.
  --parallel N            Cantidad de instalaciones simultáneas.
  --no-copy-id            No instalar la clave pública automáticamente.
  --dry-run               Preparar SSH y probar requisitos sin instalar Agent 2.
  --help                  Mostrar esta ayuda.

Comportamiento SSH:
  1. Si no existe una clave local, crea ~/.ssh/id_ed25519.
  2. Prueba autenticación sin contraseña.
  3. Si falla, ejecuta ssh-copy-id y solicita una vez la contraseña SSH.
  4. Las instalaciones posteriores usan exclusivamente la clave.
USAGE
}

SSH_USER="$DEFAULT_SSH_USER"; SSH_PORT="$DEFAULT_SSH_PORT"; IDENTITY_FILE=""; ZABBIX_DIR="$DEFAULT_ZABBIX_DIR"; HOSTS_FILE=""; PARALLEL="$DEFAULT_PARALLEL"; DRY_RUN=0; COPY_ID=1
declare -a CLI_HOSTS=()

while (($#)); do
  case "$1" in
    --hosts) HOSTS_FILE="${2:?Falta archivo para --hosts}"; shift 2 ;;
    --user) SSH_USER="${2:?Falta usuario para --user}"; shift 2 ;;
    --port) SSH_PORT="${2:?Falta puerto para --port}"; shift 2 ;;
    --identity) IDENTITY_FILE="${2:?Falta clave para --identity}"; shift 2 ;;
    --zabbix-dir) ZABBIX_DIR="${2:?Falta directorio para --zabbix-dir}"; shift 2 ;;
    --host) CLI_HOSTS+=("${2:?Falta IP o DNS para --host}"); shift 2 ;;
    --parallel) PARALLEL="${2:?Falta cantidad para --parallel}"; shift 2 ;;
    --no-copy-id) COPY_ID=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "Puerto SSH inválido."
((SSH_PORT >= 1 && SSH_PORT <= 65535)) || die "Puerto SSH fuera de rango."
[[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] || die "--parallel debe ser mayor que cero."

install_local_ssh_tools() {
  local missing=()
  command -v ssh >/dev/null 2>&1 || missing+=(ssh)
  command -v scp >/dev/null 2>&1 || missing+=(scp)
  command -v ssh-keygen >/dev/null 2>&1 || missing+=(ssh-keygen)
  if [[ $COPY_ID -eq 1 ]] && ! command -v ssh-copy-id >/dev/null 2>&1; then missing+=(ssh-copy-id); fi
  ((${#missing[@]} == 0)) && return 0
  warn "Faltan herramientas SSH: ${missing[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    info "Instalando openssh-client..."
    if [[ $EUID -eq 0 ]]; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-client
    elif command -v sudo >/dev/null 2>&1; then
      sudo apt-get update
      sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-client
    else
      die "Se necesita root o sudo para instalar openssh-client."
    fi
  else
    die "Instale openssh-client manualmente."
  fi
}
install_local_ssh_tools

AGENT_DIR="$ZABBIX_DIR/agents/linux"
AGENT_CONF="$AGENT_DIR/90-cloud-active.conf"
AGENT_PSK="$AGENT_DIR/zabbix_agent2.psk"
[[ -r "$AGENT_CONF" ]] || die "No existe o no se puede leer: $AGENT_CONF"

USE_PSK=0
if grep -Eq '^[[:space:]]*TLSConnect=psk[[:space:]]*$' "$AGENT_CONF"; then
  [[ -r "$AGENT_PSK" ]] || die "La configuración usa PSK pero falta: $AGENT_PSK"
  USE_PSK=1
fi

SERVER_ACTIVE="$(awk -F= '/^[[:space:]]*ServerActive[[:space:]]*=/{v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; exit}' "$AGENT_CONF")"
[[ -n "$SERVER_ACTIVE" ]] || die "No se encontró ServerActive en $AGENT_CONF"
if [[ "$SERVER_ACTIVE" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
  SERVER_HOST="${BASH_REMATCH[1]}"; SERVER_PORT="${BASH_REMATCH[2]}"
elif [[ "$SERVER_ACTIVE" =~ ^([^:]+):([0-9]+)$ ]]; then
  SERVER_HOST="${BASH_REMATCH[1]}"; SERVER_PORT="${BASH_REMATCH[2]}"
else
  die "Formato ServerActive no soportado: $SERVER_ACTIVE"
fi

declare -a HOSTS=()
if [[ -n "$HOSTS_FILE" ]]; then
  [[ -r "$HOSTS_FILE" ]] || die "No se puede leer $HOSTS_FILE"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"; line="$(printf '%s' "$line" | xargs)"; [[ -n "$line" ]] && HOSTS+=("$line")
  done < "$HOSTS_FILE"
fi
((${#CLI_HOSTS[@]})) && HOSTS+=("${CLI_HOSTS[@]}")
if ((${#HOSTS[@]} == 0)); then
  read -r -p "IPs o DNS separados por espacios: " host_line
  read -r -a HOSTS <<< "$host_line"
fi
((${#HOSTS[@]})) || die "No se indicó ningún host."

declare -A SEEN_HOSTS=(); declare -a UNIQUE_HOSTS=()
for host in "${HOSTS[@]}"; do [[ -n "${SEEN_HOSTS[$host]:-}" ]] && continue; SEEN_HOSTS["$host"]=1; UNIQUE_HOSTS+=("$host"); done
HOSTS=("${UNIQUE_HOSTS[@]}")

prepare_identity() {
  if [[ -n "$IDENTITY_FILE" ]]; then
    IDENTITY_FILE="${IDENTITY_FILE/#\~/$HOME}"
    if [[ ! -r "$IDENTITY_FILE" ]]; then
      [[ -e "$IDENTITY_FILE" ]] && die "La clave existe pero no se puede leer: $IDENTITY_FILE"
      info "Creando clave Ed25519 en $IDENTITY_FILE"
      mkdir -p "$(dirname "$IDENTITY_FILE")"; chmod 700 "$(dirname "$IDENTITY_FILE")"
      ssh-keygen -t ed25519 -a 100 -N "" -C "zabbix-agent-deployer@$(hostname)-$(date +%Y%m%d)" -f "$IDENTITY_FILE"
    fi
  else
    for candidate in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "/root/.ssh/id_ed25519" "/root/.ssh/id_rsa"; do
      [[ -r "$candidate" ]] && IDENTITY_FILE="$candidate" && break
    done
    if [[ -z "$IDENTITY_FILE" ]]; then
      IDENTITY_FILE="$HOME/.ssh/id_ed25519"
      info "No existe una clave SSH local. Creando $IDENTITY_FILE"
      mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
      ssh-keygen -t ed25519 -a 100 -N "" -C "zabbix-agent-deployer@$(hostname)-$(date +%Y%m%d)" -f "$IDENTITY_FILE"
    fi
  fi
  [[ -r "$IDENTITY_FILE" ]] || die "No se puede leer la clave privada: $IDENTITY_FILE"
  PUBLIC_KEY="${IDENTITY_FILE}.pub"
  if [[ ! -r "$PUBLIC_KEY" ]]; then ssh-keygen -y -f "$IDENTITY_FILE" > "$PUBLIC_KEY"; chmod 644 "$PUBLIC_KEY"; fi
  ok "Clave SSH seleccionada: $IDENTITY_FILE"
}
prepare_identity

SSH_OPTIONS=(-p "$SSH_PORT" -i "$IDENTITY_FILE" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new)
SCP_OPTIONS=(-P "$SSH_PORT" -i "$IDENTITY_FILE" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

test_key_auth() { local host="$1"; ssh "${SSH_OPTIONS[@]}" "${SSH_USER}@${host}" 'printf SSH_KEY_OK' 2>/dev/null | grep -q '^SSH_KEY_OK$'; }
copy_key_to_host() {
  local host="$1"
  [[ $COPY_ID -eq 1 ]] || { warn "$host: autenticación por clave no disponible y --no-copy-id fue indicado."; return 1; }
  info "$host: ssh-copy-id solicitará la contraseña SSH una sola vez."
  ssh-copy-id -f -i "$PUBLIC_KEY" -p "$SSH_PORT" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "${SSH_USER}@${host}"
  test_key_auth "$host"
}
prepare_host_ssh() {
  local host="$1"; printf '\n===== Preparando SSH: %s =====\n' "$host"
  if test_key_auth "$host"; then ok "$host: autenticación por clave ya operativa"; return 0; fi
  copy_key_to_host "$host" || { warn "$host: no se pudo instalar o validar la clave SSH."; return 1; }
  ok "$host: clave pública instalada correctamente"
}

declare -a READY_HOSTS=(); declare -a SSH_FAILED_HOSTS=()
for host in "${HOSTS[@]}"; do if prepare_host_ssh "$host"; then READY_HOSTS+=("$host"); else SSH_FAILED_HOSTS+=("$host"); fi; done
((${#READY_HOSTS[@]})) || die "No quedó ningún host accesible mediante clave SSH."

TMP_ROOT="$(mktemp -d)"; trap 'rm -rf "$TMP_ROOT"' EXIT
PACKAGE_DIR="$TMP_ROOT/zabbix-agent-deploy"; mkdir -p "$PACKAGE_DIR"
install -m 0644 "$AGENT_CONF" "$PACKAGE_DIR/90-cloud-active.conf"
[[ $USE_PSK -eq 1 ]] && install -m 0600 "$AGENT_PSK" "$PACKAGE_DIR/zabbix_agent2.psk"

cat > "$PACKAGE_DIR/remote-install.sh" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
PACKAGE_DIR="${1:-/tmp/zabbix-agent-deploy}"
ZABBIX_MAJOR="7.0"
log() { printf '[REMOTE] %s\n' "$*"; }
warn() { printf '[REMOTE WARN] %s\n' "$*" >&2; }
fail() { printf '[REMOTE ERROR] %s\n' "$*" >&2; exit 1; }
[[ -r /etc/os-release ]] || fail "No existe /etc/os-release."
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail "Sistema no compatible: ${PRETTY_NAME:-desconocido}"
case "${VERSION_ID:-}" in 20.04|22.04|24.04|26.04) ;; *) fail "Ubuntu ${VERSION_ID:-desconocido} no contemplado." ;; esac
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in amd64) REPO_FLAVOR="ubuntu" ;; arm64) REPO_FLAVOR="ubuntu-arm64" ;; *) fail "Arquitectura no compatible: $ARCH" ;; esac
if [[ "$(id -u)" -eq 0 ]]; then SUDO=(); else command -v sudo >/dev/null 2>&1 || fail "sudo no instalado"; sudo -n true 2>/dev/null || fail "Se necesita sudo sin contraseña"; SUDO=(sudo -n); fi
log "Sistema: $PRETTY_NAME ($ARCH)"
"${SUDO[@]}" apt-get update
"${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
RELEASE_DEB="/tmp/zabbix-release.deb"
BASE_URL="https://repo.zabbix.com/zabbix/${ZABBIX_MAJOR}/${REPO_FLAVOR}/pool/main/z/zabbix-release"
LATEST_URL="${BASE_URL}/zabbix-release_latest_${ZABBIX_MAJOR}+ubuntu${VERSION_ID}_all.deb"
if ! curl -fL --retry 3 --connect-timeout 15 "$LATEST_URL" -o "$RELEASE_DEB"; then
  PACKAGE_NAME="$(curl -fsSL "$BASE_URL/" | grep -oE "zabbix-release_[0-9][^\"']*ubuntu${VERSION_ID}_all\.deb" | sort -V | tail -n 1)"
  [[ -n "$PACKAGE_NAME" ]] || fail "No se encontró zabbix-release para Ubuntu $VERSION_ID"
  curl -fL --retry 3 "${BASE_URL}/${PACKAGE_NAME}" -o "$RELEASE_DEB"
fi
"${SUDO[@]}" dpkg -i "$RELEASE_DEB"
"${SUDO[@]}" apt-get update
"${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y zabbix-agent2

MAIN_CONF="/etc/zabbix/zabbix_agent2.conf"
DROPIN_DIR="/etc/zabbix/zabbix_agent2.d"
DROPIN_CONF="$DROPIN_DIR/90-cloud-active.conf"
[[ -f "$MAIN_CONF" ]] || fail "No existe $MAIN_CONF"
BACKUP="${MAIN_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
"${SUDO[@]}" cp -a "$MAIN_CONF" "$BACKUP"
log "Backup creado: $BACKUP"

# Evita que todas las VMs se identifiquen como 'Zabbix server'.
"${SUDO[@]}" sed -ri \
  -e 's|^([[:space:]]*)ServerActive[[:space:]]*=|# Deshabilitado por despliegue cloud: ServerActive=|' \
  -e 's|^([[:space:]]*)Hostname[[:space:]]*=|# Deshabilitado por despliegue cloud: Hostname=|' \
  -e 's|^([[:space:]]*)HostnameItem[[:space:]]*=|# Deshabilitado por despliegue cloud: HostnameItem=|' \
  -e 's|^([[:space:]]*)HostMetadata[[:space:]]*=|# Deshabilitado por despliegue cloud: HostMetadata=|' \
  "$MAIN_CONF"

if ! grep -Eq '^[[:space:]]*Include[[:space:]]*=[[:space:]]*/etc/zabbix/zabbix_agent2\.d/.*\.conf' "$MAIN_CONF"; then
  printf '\nInclude=/etc/zabbix/zabbix_agent2.d/*.conf\n' | "${SUDO[@]}" tee -a "$MAIN_CONF" >/dev/null
fi

"${SUDO[@]}" install -d -m 0755 "$DROPIN_DIR"
"${SUDO[@]}" install -m 0644 "$PACKAGE_DIR/90-cloud-active.conf" "$DROPIN_CONF"
if [[ -f "$PACKAGE_DIR/zabbix_agent2.psk" ]]; then
  "${SUDO[@]}" install -o zabbix -g zabbix -m 0600 "$PACKAGE_DIR/zabbix_agent2.psk" /etc/zabbix/zabbix_agent2.psk
fi

EXPECTED_HOSTNAME="$(hostname)"
[[ -n "$EXPECTED_HOSTNAME" ]] || fail "El hostname está vacío."
[[ "$EXPECTED_HOSTNAME" != "Zabbix server" ]] || fail "El hostname real no puede ser 'Zabbix server'."

"${SUDO[@]}" zabbix_agent2 -c "$MAIN_CONF" -T
"${SUDO[@]}" systemctl enable zabbix-agent2
"${SUDO[@]}" systemctl restart zabbix-agent2
sleep 3
"${SUDO[@]}" systemctl is-active --quiet zabbix-agent2 || fail "zabbix-agent2 no quedó activo"
AGENT_LOG="$("${SUDO[@]}" journalctl -u zabbix-agent2 -n 50 --no-pager 2>/dev/null || true)"
printf '%s\n' "$AGENT_LOG" | tail -n 20
if grep -Fq "Zabbix Agent2 hostname: [$EXPECTED_HOSTNAME]" <<< "$AGENT_LOG"; then
  log "Hostname efectivo confirmado: $EXPECTED_HOSTNAME"
else
  warn "No se pudo confirmar el hostname en journalctl; esperado: $EXPECTED_HOSTNAME"
fi
if grep -Fq 'Zabbix Agent2 hostname: [Zabbix server]' <<< "$AGENT_LOG"; then
  fail "El agente todavía se identifica como 'Zabbix server'."
fi
log "Agent 2 instalado, corregido y activo."
REMOTE
chmod 0755 "$PACKAGE_DIR/remote-install.sh"

run_host() {
  local host="$1" remote="${SSH_USER}@${host}" remote_tmp="/tmp/zabbix-agent-deploy"
  printf '\n===== Instalando en %s =====\n' "$host"
  ssh "${SSH_OPTIONS[@]}" "$remote" 'printf SSH_OK' | grep -q '^SSH_OK$' || { warn "$host: SSH por clave falló"; return 1; }
  ssh "${SSH_OPTIONS[@]}" "$remote" 'if [ "$(id -u)" -eq 0 ]; then exit 0; else sudo -n true; fi' || { warn "$host: requiere sudo sin contraseña"; return 1; }
  [[ $DRY_RUN -eq 1 ]] && { info "$host: dry-run"; return 0; }
  ssh "${SSH_OPTIONS[@]}" "$remote" "rm -rf '$remote_tmp' && mkdir -p '$remote_tmp'"
  scp -q -r "${SCP_OPTIONS[@]}" "$PACKAGE_DIR/." "$remote:$remote_tmp/"
  ssh "${SSH_OPTIONS[@]}" "$remote" "bash '$remote_tmp/remote-install.sh' '$remote_tmp'" || { warn "$host: instalación fallida"; return 1; }
  ssh "${SSH_OPTIONS[@]}" "$remote" "timeout 5 bash -c '</dev/tcp/$SERVER_HOST/$SERVER_PORT'" >/dev/null 2>&1 || { warn "$host: no alcanza $SERVER_ACTIVE"; return 1; }
  REMOTE_HOSTNAME="$(ssh "${SSH_OPTIONS[@]}" "$remote" hostname 2>/dev/null || true)"
  [[ -n "$REMOTE_HOSTNAME" ]] && ok "$host: se registrará como '$REMOTE_HOSTNAME'"
  ssh "${SSH_OPTIONS[@]}" "$remote" "rm -rf '$remote_tmp'" || true
  ok "$host: incorporación finalizada"
}

RESULT_DIR="$TMP_ROOT/results"; mkdir -p "$RESULT_DIR"
run_and_record() { local host="$1" safe; safe="$(printf '%s' "$host" | tr '/: ' '___')"; if run_host "$host"; then echo OK > "$RESULT_DIR/$safe"; else echo FAIL > "$RESULT_DIR/$safe"; fi; }

declare -a PIDS=()
for host in "${READY_HOSTS[@]}"; do
  run_and_record "$host" & PIDS+=("$!")
  while ((${#PIDS[@]} >= PARALLEL)); do wait "${PIDS[0]}" || true; PIDS=("${PIDS[@]:1}"); done
done
for pid in "${PIDS[@]}"; do wait "$pid" || true; done

SUCCESS=0; FAILED=${#SSH_FAILED_HOSTS[@]}
for result_file in "$RESULT_DIR"/*; do [[ -e "$result_file" ]] || continue; if grep -q '^OK$' "$result_file"; then ((SUCCESS+=1)); else ((FAILED+=1)); fi; done

echo
echo "Correctos: $SUCCESS"
echo "Fallidos:  $FAILED"
echo "Revise en Zabbix: Data collection -> Hosts y Monitoring -> Latest data"
echo "Cada VM debe aparecer con el valor real devuelto por hostname."
((FAILED == 0))
