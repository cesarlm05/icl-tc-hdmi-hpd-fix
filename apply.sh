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

VIDEO_ARGS="video=${EDP_CONN}:d video=${HDMI_CONN}:e"

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

if grep -q "video=${HDMI_CONN}:e" "$CMDLINE_FILE" 2>/dev/null; then
  echo "== Ya aplicado en $CMDLINE_FILE, no hay nada que hacer =="
  exit 0
fi

echo "== Cambios a aplicar =="
echo "  $CMDLINE_FILE : quitar 'nomodeset', agregar '$VIDEO_ARGS'"
echo "  $GRUB_FILE     : quitar 'nomodeset', agregar '$VIDEO_ARGS'"
echo "  grubby --update-kernel=ALL --remove-args=nomodeset --args=\"$VIDEO_ARGS\""

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "(dry-run, no se modificó nada)"
  exit 0
fi

TS=$(date +%Y%m%d%H%M%S)
cp "$CMDLINE_FILE" "${CMDLINE_FILE}.bak.${TS}"
cp "$GRUB_FILE" "${GRUB_FILE}.bak.${TS}"

sed -i "s/nomodeset/${VIDEO_ARGS}/" "$CMDLINE_FILE"
sed -i "s/nomodeset/${VIDEO_ARGS}/" "$GRUB_FILE"
grubby --update-kernel=ALL --remove-args="nomodeset" --args="${VIDEO_ARGS}"

echo "== Listo. Backups en ${CMDLINE_FILE}.bak.${TS} y ${GRUB_FILE}.bak.${TS} =="
echo "Reiniciá y confirmá con: cat /proc/cmdline ; glxinfo | grep renderer"
