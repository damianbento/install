#!/usr/bin/env bash
#
# sshmenu - Menú para conectarse por SSH desde el jumphost
#
# Usa whiptail (viene con Raspberry Pi OS) para mostrar el menú.
# Si no está instalado, usa un menú de texto simple.

# ─── Lista de equipos ────────────────────────────────────────────
# Formato:  "Nombre amigable|usuario|ip[|puerto]"
# El puerto es opcional; si no se pone, usa el 22.
HOSTS=(
  "Proxmox nodo 1|root|pve1"
  "Proxmox nodo 2|root|pve2"
  "Proxmox nodo 3|root|pve3"
  "Vision01|user|vision01"
  "ubuntu1|user|192.168.1.100"
)
# ─────────────────────────────────────────────────────────────────

TITULO="Jumphost - Conexiones SSH"
SSH_OPTS=(-o ConnectTimeout=10)

# Arma "usuario@ip" (agrega :puerto si no es el 22)
destino() {
  local usuario=$1 ip=$2 puerto=$3
  if [[ -n $puerto && $puerto != 22 ]]; then
    printf '%s@%s:%s' "$usuario" "$ip" "$puerto"
  else
    printf '%s@%s' "$usuario" "$ip"
  fi
}

menu_whiptail() {
  local opciones=() i nombre usuario ip puerto
  for i in "${!HOSTS[@]}"; do
    IFS='|' read -r nombre usuario ip puerto <<< "${HOSTS[$i]}"
    opciones+=("$((i + 1))" "$(printf '%-24s %s' "$nombre" "$(destino "$usuario" "$ip" "$puerto")")")
  done

  local filas=${#HOSTS[@]}
  (( filas > 15 )) && filas=15

  whiptail --title "$TITULO" --ok-button "Conectar" --cancel-button "Salir" \
    --menu "Elegí a dónde conectarte:" $((filas + 8)) 72 "$filas" \
    "${opciones[@]}" 3>&1 1>&2 2>&3
}

menu_texto() {
  local i nombre usuario ip puerto opcion
  clear >&2
  echo "== $TITULO ==" >&2
  echo >&2
  for i in "${!HOSTS[@]}"; do
    IFS='|' read -r nombre usuario ip puerto <<< "${HOSTS[$i]}"
    printf ' %2d) %-24s %s\n' "$((i + 1))" "$nombre" "$(destino "$usuario" "$ip" "$puerto")" >&2
  done
  echo >&2
  read -rp "Número (q para salir): " opcion
  [[ -z $opcion || $opcion == q ]] && return 1
  echo "$opcion"
}

conectar() {
  local nombre usuario ip puerto rc
  IFS='|' read -r nombre usuario ip puerto <<< "$1"
  puerto=${puerto:-22}
  clear
  echo "Conectando a $nombre ($(destino "$usuario" "$ip" "$puerto"))..."
  ssh "${SSH_OPTS[@]}" -p "$puerto" "$usuario@$ip"
  rc=$?
  # 255 = falló la conexión SSH en sí (no responde, clave rechazada, etc.)
  if (( rc == 255 )); then
    echo
    read -rp "No se pudo conectar. Enter para volver al menú..." _
  fi
}

if command -v whiptail >/dev/null 2>&1; then
  mostrar_menu=menu_whiptail
else
  mostrar_menu=menu_texto
fi

while true; do
  eleccion=$($mostrar_menu) || break
  if [[ $eleccion =~ ^[0-9]+$ ]] && (( eleccion >= 1 && eleccion <= ${#HOSTS[@]} )); then
    conectar "${HOSTS[$((eleccion - 1))]}"
  fi
done
clear
