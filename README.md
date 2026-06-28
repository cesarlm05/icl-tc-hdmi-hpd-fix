# Fix: pantalla negra (i915) en mini-PCs Ice Lake clonados con HDMI vía Type-C

## ¿Este es tu hardware?

No vas a poder confirmarlo por DMI: estas placas ODM sin marca reportan campos
genéricos (`sys_vendor=AMI`, `board_name=Intel`, `product_name="To be filled
by O.E.M."`). Confirmá por estos otros datos en su lugar:

- CPU: Intel Ice Lake-U de bajo consumo (ej. `Core i7-1060NG7`, 9W).
- GPU: Intel Iris Plus Graphics G7, PCI ID `8086:8a51`. Confirmar con:
  `lspci -nn | grep -i vga`
- Chasis de escritorio/mini-PC, no laptop (`cat /sys/class/dmi/id/chassis_type` → `3`).
- Sin controlador Thunderbolt/USB4 dedicado en `lspci` — el HDMI físico está
  cableado a través de un PHY Type-C (probablemente con un redriver),
  no de un puerto Type-C real.
- Sin `nomodeset` y con el módulo `i915` cargado, la pantalla queda negra y en
  `journalctl -b -k` aparece este patrón:
  ```
  i915 ...: [drm] [ENCODER:267:DDI A/PHY A] failed to retrieve link info, disabling eDP
  i915 ...: [drm] Cannot find any crtc or sizes
  ```
  y con `drm.debug=0x1e` se ve además:
  ```
  Port C/TC#1: PHY mode: legacy (ready: yes, owned: yes, HPD: disconnected)
  ...
  Disabling [CONNECTOR:268:HDMI-A-1]
  ```

## Causa raíz

El VBT (firmware de configuración de video) de la placa declara:
1. Un conector `eDP-1` fantasma en `DDI A/PHY A` que no existe físicamente
   (es de escritorio, no tiene panel interno). `i915` intenta leer su DPCD,
   falla, y eso bloquea la inicialización de CRTCs.
2. Los conectores HDMI reales en `DDI C (TC)/PHY TC1` y `DDI D (TC)/PHY TC2`
   (Type-C en modo legacy/alt-mode). El firmware/GOP los deja activos antes
   de que `i915` tome control (por eso `simple-framebuffer` sí mostraba algo).
   Pero la detección de Hot-Plug (`HPD`) de `i915` los reporta
   "disconnected" — probablemente porque el mux/redriver Type-C de esta
   placa no expone el HPD por ACPI de forma que Linux lo entienda (Windows
   lo resuelve con drivers propietarios de Intel). `i915` entonces apaga el
   conector que sí estaba funcionando.

Resultado: pantalla negra total con `i915` cargado, aunque el resto del
sistema arranca normal en background.

## Fix

No es un parche al driver, es decirle a `i915`/DRM que ignore el HPD roto
y fuerce los conectores correctos vía parámetros de kernel:

```
video=eDP-1:d video=HDMI-A-1:e
```

- `eDP-1:d` → deshabilita explícitamente el conector eDP fantasma.
- `HDMI-A-1:e` → fuerza el conector HDMI real a "conectado"
  (`DRM_FORCE_ON`), sin esperar al HPD.

Si tu placa expone el HDMI físico en el otro puerto (`DDI D (TC)/PHY TC2`),
usá `HDMI-A-2:e` en su lugar — revisá con `drm.debug=0x1e` cuál conector
es el que tiene tu monitor.

## Uso

1. Probá primero **temporalmente** en el menú de GRUB (tecla `e` sobre la
   entrada de arranque, editar la línea `linux`, arrancar con Ctrl+X) antes
   de aplicar nada permanente.
2. Si funciona, corré `apply.sh` (ver script en este mismo directorio) para
   dejarlo permanente, o aplicá los mismos cambios a mano.

`apply.sh` asume un sistema basado en Fedora/RHEL con `grubby` y BLS (usa
`/etc/kernel/cmdline` y `GRUB_CMDLINE_LINUX` en `/etc/default/grub` como
fuentes de verdad). En otras distros (Debian/Ubuntu, etc.) aplicá los mismos
parámetros a mano según el mecanismo de tu bootloader.

## Limitaciones

Esto es un workaround, no una solución del driver. Si en algún momento
Intel/el kernel agregan soporte correcto de mux Type-C/HPD para este tipo de
placas, este parámetro de boot deja de ser necesario (y de hecho podría
quedar obsoleto si el connector real cambia de nombre entre boots/kernels —
poco común pero posible). Revisar `dmesg | grep -i hdmi` después de cada
actualización mayor de kernel para confirmar que el nombre del conector
(`HDMI-A-1`) sigue siendo el mismo.
