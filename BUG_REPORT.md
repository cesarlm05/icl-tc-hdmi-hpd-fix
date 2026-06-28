# Reporte de fallo, fix y conclusiones

Este documento es el reporte que se envía/envió upstream, en inglés (idioma
de ambos trackers), conservado aquí como registro del diagnóstico. Los logs
completos que respaldan cada afirmación están en [logs/](logs/).

- GitLab (drm/i915): _pendiente — completar con el link una vez creado el issue_
- Fedora Bugzilla: _pendiente — completar con el link una vez creado el bug_

---

# i915: black screen on Ice Lake mini-PC, HDMI exposed via Type-C PHY reports HPD: disconnected

## Summary

On an unbranded Ice Lake-U mini-PC (ODM/whitebox board, desktop chassis, no
internal panel), loading `i915` without `nomodeset` produces a fully black
screen. Two independent problems combine to cause this:

1. The board's VBT declares a phantom `eDP-1` connector on `DDI A/PHY A` that
   does not physically exist (desktop board, no internal eDP panel). i915
   tries to read its DPCD, fails, and this contributes to the modeset
   failing to find any usable CRTC/sizes.
2. The real HDMI output is wired through a Type-C PHY (`DDI C/PHY TC1`) in
   legacy/alt-mode, presumably through a redriver/mux. Firmware/GOP drives
   this output fine before i915 takes over (the `simple-framebuffer` console
   shows video), but i915's hotplug detection reports `HPD: disconnected` for
   that port, so i915 explicitly disables the connector that was already
   working (`Disabling [CONNECTOR:268:HDMI-A-1]`), leaving the screen black.

A boot-time workaround (`video=eDP-1:d video=HDMI-A-1:e`) confirms the
diagnosis: forcing the phantom eDP connector off and forcing the real HDMI
connector "on" regardless of HPD restores video output completely.

## Hardware

This board reports generic/whitebox DMI strings, so identify by these
instead:

- CPU: Intel Ice Lake-U, low power (e.g. `Core i7-1060NG7`, 9W)
- GPU: Intel Iris Plus Graphics G7, PCI ID `8086:8a51`
- Desktop/mini-PC chassis (`chassis_type` = 3), not a laptop
- No dedicated Thunderbolt/USB4 controller in `lspci` — physical HDMI is
  wired through a Type-C PHY (likely with a redriver), not a real USB-C port
- DMI: `sys_vendor=AMI`, `board_name=Intel`, `product_name=Intel`,
  `bios_vendor=American Megatrends Inc.`, `bios_version=V1.3_226`

```
$ lspci -nn | grep -i vga
00:02.0 VGA compatible controller [0300]: Intel Corporation Iris Plus Graphics G7 (Ice Lake) [8086:8a51] (rev 07)
```

## Software environment

- Distro: Fedora 44
- Kernel: 7.0.12-201.fc44.x86_64 (issue reproduces on 7.0.13-200.fc44.x86_64 as well)
- `i915` is the active driver (`Kernel driver in use: i915`)

## Steps to reproduce

1. Boot the affected hardware with `i915` loaded and no `nomodeset`/`video=`
   overrides (plain `rhgb quiet`).
2. Screen stays black for the entire boot; the rest of the system comes up
   normally in the background (sshable, services running).

## Expected vs. actual

- Expected: HDMI output active, since firmware/GOP already shows video on
  this same physical connector before i915 takes over.
- Actual: i915 disables the connector after probing it as "HPD: disconnected".

## Relevant kernel log (boot without any workaround)

Full log attached as `dmesg-failure-no-workaround.log`. Key lines:

```
i915 0000:00:02.0: [drm] [ENCODER:267:DDI A/PHY A] failed to retrieve link info, disabling eDP
i915 0000:00:02.0: [drm] Cannot find any crtc or sizes
```

## Relevant kernel log (boot with `drm.debug=0x1e`)

Full log attached as `dmesg-drm-debug-0x1e.log`. Key lines, in order:

```
[drm:intel_dp_aux_ch [i915]] [ENCODER:267:DDI A/PHY A] Using AUX CH A (VBT)
[drm:intel_dp_init_connector [i915]] Adding eDP connector on [ENCODER:267:DDI A/PHY A]
[drm] [ENCODER:267:DDI A/PHY A] failed to retrieve link info, disabling eDP
[drm:intel_dp_aux_ch [i915]] [ENCODER:267:DDI C (TC)/PHY TC1] Using AUX CH C (platform default)
[drm:tc_phy_get_current_mode [i915]] Port C/TC#1: PHY mode: legacy (ready: yes, owned: yes, HPD: disconnected)
[drm:intel_hdmi_init_connector [i915]] Adding HDMI connector on [ENCODER:267:DDI C (TC)/PHY TC1]
[drm:tc_phy_get_current_mode [i915]] Port D/TC#2: PHY mode: disconnected (ready: yes, owned: no, HPD: disconnected)
[drm:intel_tc_port_sanitize_mode [i915]] Port C/TC#1: PHY connected: yes (ready: yes, owned: yes, pll_type: non-tbt)
[drm:intel_modeset_readout_hw_state [i915]] [ENCODER:267:DDI C (TC)/PHY TC1] hw state readout: enabled, pipe B
[drm:update_connector_routing] [CONNECTOR:268:HDMI-A-1] keeps [ENCODER:267:DDI C (TC)/PHY TC1], now on [CRTC:187:pipe B]
[drm] Cannot find any crtc or sizes
[drm:update_connector_routing] Disabling [CONNECTOR:268:HDMI-A-1]
```

Note `Port C/TC#1` is reported `owned: yes` (i915 has PHY ownership) and was
already driving the display (firmware left it `PHY connected: yes`,
`hw state readout: enabled, pipe B`) — yet HPD reads `disconnected`, and i915
disables the connector on that basis alone.

`Port D/TC#2` (the second Type-C-routed DDI on this board) is `owned: no`,
confirming nothing is physically wired there; only `DDI C/PHY TC1` carries
the real HDMI signal.

## Workaround (confirms diagnosis)

Kernel command line addition:

```
video=eDP-1:d video=HDMI-A-1:e
```

- `eDP-1:d` disables the phantom eDP connector outright.
- `HDMI-A-1:e` force-enables the real HDMI connector
  (`drm_connector_force` = `DRM_FORCE_ON`), bypassing the broken HPD check.

With this, the kernel log shows `[drm] forcing HDMI-A-1 connector on` and
video output works normally for every subsequent boot/kernel update tested
(7.0.12-201.fc44 through 7.0.13-200.fc44).

A small reference script (`apply.sh`) that applies/reverts this boot
parameter is here, in case it's useful for anyone else hitting the same
signature: <https://github.com/cesarlm05/icl-tc-hdmi-hpd-fix>

## Suspected root cause

The Type-C mux/redriver on this board does not expose hotplug state over
ACPI/PHY ownership signaling in a way `i915`'s TC PHY HPD logic
(`tc_phy_get_current_mode`) can read correctly — likely an OEM-specific
quirk only handled by Intel's proprietary Windows drivers, with no
equivalent path in `i915`.

## Not an isolated case

This same symptom and log signature
(`[ENCODER:...:DDI A/PHY A] failed to retrieve link info, disabling eDP` +
repeated `Cannot find any crtc or sizes`) has been independently reported on
a different SKU of what appears to be the same reference design: a "Bmax B6
Power" mini-PC, also Intel Iris Plus G7 (Ice Lake), also fixed by forcing
the real HDMI connector via a `video=` kernel parameter (in that case
`HDMI-A-2` instead of `HDMI-A-1`, and `[ENCODER:242:...]` instead of
`[ENCODER:267:...]` — consistent with a slightly different board revision of
the same whitebox design):
<https://bbs.archlinux.org/viewtopic.php?id=305056>

That report has no connection to this one and was found independently while
preparing this issue; neither one mentions VBT/TC-PHY-level detail, but the
matching signature suggests this is a recurring problem across several
rebranded SKUs of the same ODM board rather than a one-off. I could not find
an existing report with this exact signature already filed on
gitlab.freedesktop.org/drm/i915, so this does not appear to be a duplicate.

## Attachments

- [`logs/dmesg-failure-no-workaround.log`](logs/dmesg-failure-no-workaround.log) —
  full kernel log, boot without any workaround, screen black.
- [`logs/dmesg-drm-debug-0x1e.log`](logs/dmesg-drm-debug-0x1e.log) — full
  kernel log, same failure with `drm.debug=0x1e` for the TC PHY/connector
  trace above.
- [`logs/hardware-info.txt`](logs/hardware-info.txt) — DMI fields,
  `lspci -vvnn` for the GPU, kernel/distro version, DRM connector list.

Nota: las direcciones MAC y los UUID de filesystem/disco en los logs
adjuntos fueron reemplazados por valores ficticios (`00:00:00:00:00:00` y
`00000000-0000-0000-0000-00000000000N`) antes de publicarlos; no son
relevantes para el diagnóstico de i915.

---

## Conclusiones

- El fallo es del driver `i915` (confirmado con `drm.debug=0x1e`), no algo
  específico de Fedora ni de este equipo en particular: el mismo patrón de
  log apareció de forma independiente en otra placa de la misma familia de
  diseño ("Bmax B6 Power"), reportado en un foro sin que esa persona llegara
  a identificar la causa raíz (VBT + HPD roto en el PHY Type-C).
- El workaround de `video=eDP-1:d video=HDMI-A-1:e` es estable entre
  actualizaciones de kernel (probado de 7.0.12-201.fc44 a 7.0.13-200.fc44),
  pero sigue siendo un parche de arranque, no una corrección del driver — si
  alguna vez `i915` agrega soporte correcto para este tipo de mux Type-C, el
  parámetro deja de ser necesario.
- Vale la pena reportarlo upstream: no hay un issue duplicado ya abierto en
  gitlab.freedesktop.org/drm/i915 con esta firma, y al menos un usuario más
  ya se topó con el mismo síntoma sin resolver la causa raíz.
- Reportar en dos lugares tiene sentido: GitLab freedesktop (donde vive el
  desarrollo real de `i915`) para que alguien con acceso al código evalúe un
  fix de driver, y Fedora Bugzilla para que quede registrado en la distro
  (que probablemente lo reenvíe upstream si lo confirma como bug del kernel,
  no de empaquetado).
