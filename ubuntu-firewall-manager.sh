#!/usr/bin/env bash
# ubuntu-firewall-manager.sh
# Gestor simple de firewall UFW para usuarios finales.
#
# La primera vez que se ejecuta, se puede auto-instalar en:
# /usr/local/sbin/ubuntu-firewall-manager
#
# USO:
#   sudo bash ubuntu-firewall-manager.sh
#   sudo ubuntu-firewall-manager

set -Eeuo pipefail

INSTALL_PATH="/usr/local/sbin/ubuntu-firewall-manager"

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

self_install_if_needed() {
  local current_path

  current_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

  if [[ "$current_path" == "$INSTALL_PATH" ]]; then
    return 0
  fi

  echo
  info "Este script no está instalado globalmente."
  echo "Ruta actual:      $current_path"
  echo "Ruta recomendada: $INSTALL_PATH"
  echo

  if ask_yes_no "¿Querés instalarlo en /usr/local/sbin para que cualquier usuario con sudo pueda ejecutarlo?" "S"; then
    install -o root -g root -m 755 "$current_path" "$INSTALL_PATH"
    ok "Instalado en $INSTALL_PATH"
    echo
    echo "Desde ahora podés ejecutarlo con:"
    echo "  sudo ubuntu-firewall-manager"
    echo

    if ask_yes_no "¿Querés continuar ejecutando la versión instalada ahora?" "S"; then
      exec "$INSTALL_PATH"
    fi
  fi
}

ensure_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    info "UFW no está instalado. Instalando..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
  fi
}

ask_port() {
  local port
  while true; do
    read -r -p "Puerto: " port
    if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
      echo "$port"
      return 0
    fi
    echo "Puerto inválido. Usá 1-65535."
  done
}

ask_proto() {
  local proto
  while true; do
    read -r -p "Protocolo [tcp/udp] [tcp]: " proto
    proto="${proto:-tcp}"
    case "$proto" in
      tcp|udp) echo "$proto"; return 0 ;;
      *) echo "Protocolo inválido. Usá tcp o udp." ;;
    esac
  done
}

pause() {
  echo
  read -r -p "Enter para continuar..."
}

show_status() {
  echo
  ufw status verbose
  echo
}

show_rules() {
  echo
  ufw status numbered
  echo
}

allow_port_any() {
  local port proto comment
  port="$(ask_port)"
  proto="$(ask_proto)"
  read -r -p "Comentario opcional: " comment

  if [[ -n "$comment" ]]; then
    ufw allow "$port/$proto" comment "$comment"
  else
    ufw allow "$port/$proto"
  fi

  ok "Permitido $port/$proto desde cualquier origen."
}

allow_port_source() {
  local port proto source comment
  port="$(ask_port)"
  proto="$(ask_proto)"
  read -r -p "IP o red origen permitida. Ej: 181.10.20.30 o 192.168.1.0/24: " source

  if [[ -z "$source" ]]; then
    err "Origen vacío. No se aplicó ningún cambio."
    return 1
  fi

  read -r -p "Comentario opcional: " comment

  if [[ -n "$comment" ]]; then
    ufw allow from "$source" to any port "$port" proto "$proto" comment "$comment"
  else
    ufw allow from "$source" to any port "$port" proto "$proto"
  fi

  ok "Permitido $port/$proto desde $source."
}

deny_port() {
  local port proto source
  port="$(ask_port)"
  proto="$(ask_proto)"

  read -r -p "¿Bloquear solo desde un origen específico? Dejar vacío para cualquier origen: " source

  if [[ -n "$source" ]]; then
    ufw deny from "$source" to any port "$port" proto "$proto"
    ok "Bloqueado $port/$proto desde $source."
  else
    ufw deny "$port/$proto"
    ok "Bloqueado $port/$proto desde cualquier origen."
  fi
}

delete_rule() {
  show_rules
  local num
  read -r -p "Número de regla a eliminar: " num

  if [[ ! "$num" =~ ^[0-9]+$ ]]; then
    err "Número inválido."
    return 1
  fi

  warn "Vas a eliminar la regla número $num."
  read -r -p "Confirmar [s/N]: " confirm
  case "$confirm" in
    s|S|si|SI|sí|SÍ|y|Y)
      ufw --force delete "$num"
      ok "Regla eliminada."
      ;;
    *)
      warn "Cancelado."
      ;;
  esac
}

enable_firewall() {
  warn "Antes de activar UFW, asegurate de tener permitido tu puerto SSH actual."
  read -r -p "¿Activar UFW? [s/N]: " confirm
  case "$confirm" in
    s|S|si|SI|sí|SÍ|y|Y)
      ufw --force enable
      ok "UFW activado."
      ;;
    *)
      warn "Cancelado."
      ;;
  esac
}

disable_firewall() {
  warn "Esto desactiva el firewall."
  read -r -p "¿Desactivar UFW? [s/N]: " confirm
  case "$confirm" in
    s|S|si|SI|sí|SÍ|y|Y)
      ufw disable
      ok "UFW desactivado."
      ;;
    *)
      warn "Cancelado."
      ;;
  esac
}

set_defaults() {
  warn "Esto define política por defecto: denegar entrante, permitir saliente."
  read -r -p "¿Aplicar defaults seguros? [s/N]: " confirm
  case "$confirm" in
    s|S|si|SI|sí|SÍ|y|Y)
      ufw default deny incoming
      ufw default allow outgoing
      ok "Defaults aplicados."
      ;;
    *)
      warn "Cancelado."
      ;;
  esac
}

show_install_info() {
  echo
  echo "Ruta instalada:"
  if [[ -f "$INSTALL_PATH" ]]; then
    ls -l "$INSTALL_PATH"
  else
    echo "No instalado en $INSTALL_PATH"
  fi
  echo
}

menu() {
  while true; do
    clear
    echo "=== Ubuntu Firewall Manager - UFW ==="
    echo
    echo "1) Ver estado del firewall"
    echo "2) Ver reglas permitidas/bloqueadas numeradas"
    echo "3) Permitir puerto desde cualquier origen"
    echo "4) Permitir puerto desde IP/red específica"
    echo "5) Bloquear puerto"
    echo "6) Eliminar regla por número"
    echo "7) Activar firewall"
    echo "8) Desactivar firewall"
    echo "9) Aplicar defaults seguros"
    echo "10) Ver ruta de instalación del script"
    echo "0) Salir"
    echo
    read -r -p "Opción: " option

    case "$option" in
      1) show_status; pause ;;
      2) show_rules; pause ;;
      3) allow_port_any; pause ;;
      4) allow_port_source; pause ;;
      5) deny_port; pause ;;
      6) delete_rule; pause ;;
      7) enable_firewall; pause ;;
      8) disable_firewall; pause ;;
      9) set_defaults; pause ;;
      10) show_install_info; pause ;;
      0) exit 0 ;;
      *) echo "Opción inválida."; sleep 1 ;;
    esac
  done
}

main() {
  require_root
  self_install_if_needed
  ensure_ufw
  menu
}

main "$@"
