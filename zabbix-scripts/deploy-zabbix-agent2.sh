#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.0.0"
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
  --dry-run               Solo probar SSH y mostrar lo que haría.
  --help                  Mostrar esta ayuda.
USAGE
}

SSH_USER="$DEFAULT_SSH_USER"; SSH_PORT="$DEFAULT_SSH_PORT"; IDENTITY_FILE=""; ZABBIX_DIR="$DEFAULT_ZABBIX_DIR"; HOSTS_FILE=""; PARALLEL="$DEFAULT_PARALLEL"; DRY_RUN=0
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
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "Puerto SSH inválido."
[[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] || die "--parallel debe ser mayor que cero."
command -v ssh >/dev/null 2>&1 || die "No se encontró ssh."
command -v scp >/dev/null 2>&1 || die "No se encontró scp."

AGENT_DIR="$ZABBIX_DIR/agents/linux"
AGENT_CONF="$AGENT_DIR/90-cloud-active.conf"
AGENT_PSK="$AGENT_DIR/zabbix_agent2.psk"
[[ -r "$AGENT_CONF" ]] || die "No existe o no se puede leer: $AGENT_CONF"

USE_PSK=0
if grep -q '^TLSConnect=psk' "$AGENT_CONF"; then
  [[ -r "$AGENT_PSK" ]] || die "La configuración usa PSK pero falta: $AGENT_PSK"
  USE_PSK=1
fi

SERVER_ACTIVE="$(awk -F= '/^ServerActive=/{print $2; exit}' "$AGENT_CONF")"
[[ -n "$SERVER_ACTIVE" ]] || die "No se encontró ServerActive en $AGENT_CONF"
SERVER_HOST="${SERVER_ACTIVE%:*}"
SERVER_PORT="${SERVER_ACTIVE##*:}"

declare -a HOSTS=()
if [[ -n "$HOSTS_FILE" ]]; then
  [[ -r "$HOSTS_FILE" ]] || die "No se puede leer $HOSTS_FILE"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | xargs)"
    [[ -n "$line" ]] && HOSTS+=("$line")
  done < "$HOSTS_FILE"
fi
((${#CLI_HOSTS[@]})) && HOSTS+=("${CLI_HOSTS[@]}")
if ((${#HOSTS[@]} == 0)); then
  read -r -p "IPs o DNS separados por espacios: " host_line
  read -r -a HOSTS <<< "$host_line"
fi
((${#HOSTS[@]})) || die "No se indicó ningún host."

if [[ -z "$IDENTITY_FILE" ]]; then
  for candidate in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "/root/.ssh/id_ed25519" "/root/.ssh/id_rsa"; do
    [[ -r "$candidate" ]] && IDENTITY_FILE="$candidate" && break
  done
fi
[[ -n "$IDENTITY_FILE" && -r "$IDENTITY_FILE" ]] || die "Indique una clave privada válida con --identity."

SSH_OPTIONS=(-p "$SSH_PORT" -i "$IDENTITY_FILE" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new)
SCP_OPTIONS=(-P "$SSH_PORT" -i "$IDENTITY_FILE" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

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
"${SUDO[@]}" install -d -m 0755 /etc/zabbix/zabbix_agent2.d
"${SUDO[@]}" install -m 0644 "$PACKAGE_DIR/90-cloud-active.conf" /etc/zabbix/zabbix_agent2.d/90-cloud-active.conf
if [[ -f "$PACKAGE_DIR/zabbix_agent2.psk" ]]; then
  "${SUDO[@]}" install -o zabbix -g zabbix -m 0600 "$PACKAGE_DIR/zabbix_agent2.psk" /etc/zabbix/zabbix_agent2.psk
fi
"${SUDO[@]}" zabbix_agent2 -c /etc/zabbix/zabbix_agent2.conf -T
"${SUDO[@]}" systemctl enable zabbix-agent2
"${SUDO[@]}" systemctl restart zabbix-agent2
sleep 2
"${SUDO[@]}" systemctl is-active --quiet zabbix-agent2 || fail "zabbix-agent2 no quedó activo"
log "Agent 2 instalado y activo"
"${SUDO[@]}" systemctl --no-pager --full status zabbix-agent2 | sed -n '1,12p'
REMOTE
chmod 0755 "$PACKAGE_DIR/remote-install.sh"

run_host() {
  local host="$1" remote="${SSH_USER}@${host}" remote_tmp="/tmp/zabbix-agent-deploy"
  printf '\n===== %s =====\n' "$host"
  ssh "${SSH_OPTIONS[@]}" "$remote" 'echo SSH_OK' | grep -q SSH_OK || { warn "$host: SSH falló"; return 1; }
  ok "$host: SSH correcto"
  ssh "${SSH_OPTIONS[@]}" "$remote" 'if [ "$(id -u)" -eq 0 ]; then exit 0; else sudo -n true; fi' || { warn "$host: requiere sudo sin contraseña"; return 1; }
  ok "$host: privilegios correctos"
  [[ $DRY_RUN -eq 1 ]] && { info "$host: dry-run"; return 0; }
  ssh "${SSH_OPTIONS[@]}" "$remote" "rm -rf '$remote_tmp' && mkdir -p '$remote_tmp'"
  scp -q -r "${SCP_OPTIONS[@]}" "$PACKAGE_DIR/." "$remote:$remote_tmp/"
  ssh -tt "${SSH_OPTIONS[@]}" "$remote" "bash '$remote_tmp/remote-install.sh' '$remote_tmp'" || { warn "$host: instalación fallida"; return 1; }
  ssh "${SSH_OPTIONS[@]}" "$remote" "timeout 5 bash -c '</dev/tcp/$SERVER_HOST/$SERVER_PORT'" >/dev/null 2>&1 || { warn "$host: no alcanza $SERVER_ACTIVE"; return 1; }
  ssh "${SSH_OPTIONS[@]}" "$remote" "rm -rf '$remote_tmp'" || true
  ok "$host: incorporación finalizada"
}

SUCCESS=0; FAILED=0
for host in "${HOSTS[@]}"; do
  if run_host "$host"; then ((SUCCESS+=1)); else ((FAILED+=1)); fi
done

echo
echo "Correctos: $SUCCESS"
echo "Fallidos:  $FAILED"
echo "Revise en Zabbix: Data collection -> Hosts y Monitoring -> Latest data"
((FAILED == 0))
