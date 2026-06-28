#!/usr/bin/env bash
# Workaround persistente para pantalla negra en i915 (Intel Ice Lake, GPU 8086:8a51)
# en mini-PCs clonados que exponen HDMI vía PHY Type-C (DDI C/D) con HPD roto.
# Ver README.md en este mismo directorio para el diagnóstico completo.
#
# Uso:
#   sudo ./apply.sh                          # usa eDP-1:d + HDMI-A-1:e (default)
#   sudo ./apply.sh --connector HDMI-A-2     # si tu HDMI real está en DDI D/PHY TC2
#   sudo ./apply.sh --force                  # saltea la detección de hardware
#   sudo ./apply.sh --dry-run                # muestra los cambios sin aplicarlos
#
# Requiere un sistema basado en Fedora/RHEL con grubby + BLS
# (usa /etc/kernel/cmdline y /etc/default/grub como fuentes de verdad).

set -euo pipefail

EDP_CONN="eDP-1"
HDMI_CONN="HDMI-A-1"
FORCE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --connector) HDMI_CONN="$2"; shift 2 ;;
    --edp) EDP_CONN="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "Argumento desconocido: $1" >&2; exit 1 ;;
  esac
done

if [[ "$DRY_RUN" -eq 0 && "$EUID" -ne 0 ]]; then
  echo "Este script necesita root (sudo) para tocar /etc/kernel/cmdline, /etc/default/grub y grubby." >&2
  exit 1
fi

EDP_ARG="video=${EDP_CONN}:d"
HDMI_ARG="video=${HDMI_CONN}:e"
VIDEO_ARGS="${EDP_ARG} ${HDMI_ARG}"

# Quita 'nomodeset' (si está) y agrega EDP_ARG/HDMI_ARG (si faltan) a una
# cadena de argumentos de kernel. Idempotente: correrlo dos veces no duplica
# nada ni depende de que 'nomodeset' esté presente.
normalize_args() {
  local args="$1"
  args=$(echo "$args" | sed -E 's/(^|[[:space:]])nomodeset([[:space:]]|$)/ /g')
  echo "$args" | grep -qw -- "$EDP_ARG" || args="$args $EDP_ARG"
  echo "$args" | grep -qw -- "$HDMI_ARG" || args="$args $HDMI_ARG"
  echo "$args" | tr -s '[:space:]' ' ' | sed -E 's/^ +//; s/ +$//'
}

echo "== Verificando que el hardware coincide con el patrón conocido =="
GPU_ID=$(lspci -nn 2>/dev/null | grep -i 'vga.*8086:8a51' || true)
if [[ -z "$GPU_ID" && "$FORCE" -eq 0 ]]; then
  echo "No se encontró GPU Intel 8086:8a51 (Iris Plus G7 / Ice Lake)." >&2
  echo "Este fix es específico para ese hardware. Si estás seguro de que aplica" >&2
  echo "a tu caso de todas formas, volvé a correr con --force." >&2
  exit 1
fi
[[ -n "$GPU_ID" ]] && echo "OK: $GPU_ID"

echo "== Buscando patrón de HPD roto en el kernel log actual (informativo) =="
if command -v journalctl >/dev/null 2>&1; then
  journalctl -k -b 2>/dev/null | grep -i "HPD: disconnected" | head -3 || \
    echo "(no se encontró la línea de HPD disconnected en el boot actual — puede ser normal si ya tenés el fix aplicado, o si no usaste drm.debug)"
fi

CMDLINE_FILE="/etc/kernel/cmdline"
GRUB_FILE="/etc/default/grub"

if [[ ! -f "$GRUB_FILE" ]]; then
  echo "No se encontró $GRUB_FILE. Este script asume Fedora/RHEL con grubby+BLS;" >&2
  echo "en otras distros vas a tener que aplicar los parámetros a mano (ver README.md)." >&2
  exit 1
fi

CMDLINE_OLD=""
CMDLINE_NEW=""
if [[ -f "$CMDLINE_FILE" ]]; then
  CMDLINE_OLD=$(cat "$CMDLINE_FILE")
  CMDLINE_NEW=$(normalize_args "$CMDLINE_OLD")
else
  echo "(no existe $CMDLINE_FILE, se omite — no es estándar en todas las distros)"
fi

GRUB_LINE_OLD=$(grep -oP '(?<=^GRUB_CMDLINE_LINUX=")[^"]*' "$GRUB_FILE" || true)
if [[ -z "$GRUB_LINE_OLD" ]]; then
  echo "No se encontró una línea GRUB_CMDLINE_LINUX=\"...\" en $GRUB_FILE." >&2
  exit 1
fi
GRUB_LINE_NEW=$(normalize_args "$GRUB_LINE_OLD")

if [[ "$CMDLINE_OLD" == "$CMDLINE_NEW" && "$GRUB_LINE_OLD" == "$GRUB_LINE_NEW" ]]; then
  echo "== Ya aplicado, no hay nada que hacer =="
  exit 0
fi

echo "== Cambios a aplicar =="
if [[ -f "$CMDLINE_FILE" && "$CMDLINE_OLD" != "$CMDLINE_NEW" ]]; then
  echo "  $CMDLINE_FILE:"
  echo "    antes: $CMDLINE_OLD"
  echo "    luego: $CMDLINE_NEW"
fi
if [[ "$GRUB_LINE_OLD" != "$GRUB_LINE_NEW" ]]; then
  echo "  $GRUB_FILE (GRUB_CMDLINE_LINUX):"
  echo "    antes: $GRUB_LINE_OLD"
  echo "    luego: $GRUB_LINE_NEW"
fi
echo "  grubby --update-kernel=ALL --remove-args=nomodeset --args=\"$VIDEO_ARGS\""

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "(dry-run, no se modificó nada)"
  exit 0
fi

TS=$(date +%Y%m%d%H%M%S)
cp "$GRUB_FILE" "${GRUB_FILE}.bak.${TS}"
if [[ -f "$CMDLINE_FILE" ]]; then
  cp "$CMDLINE_FILE" "${CMDLINE_FILE}.bak.${TS}"
  printf '%s\n' "$CMDLINE_NEW" > "$CMDLINE_FILE"
fi

GRUB_LINE_NEW_ESCAPED=$(printf '%s' "$GRUB_LINE_NEW" | sed -e 's/[\/&]/\\&/g')
sed -i -E "s|^GRUB_CMDLINE_LINUX=\".*\"|GRUB_CMDLINE_LINUX=\"${GRUB_LINE_NEW_ESCAPED}\"|" "$GRUB_FILE"

grubby --update-kernel=ALL --remove-args="nomodeset" --args="${VIDEO_ARGS}"

echo "== Listo. Backups en ${GRUB_FILE}.bak.${TS}$( [[ -f "$CMDLINE_FILE" ]] && echo " y ${CMDLINE_FILE}.bak.${TS}" ) =="
echo "Reiniciá y confirmá con: cat /proc/cmdline ; glxinfo | grep renderer"
