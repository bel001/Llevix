# Plan — Fase 8: "Trae tu ISO"

Base: docs/planes/catalogo-e-iso-propia.md (sección B). Cambio respecto a ese plan:
la ISO no se copia a LLEVIX-DATOS sino a una zona reservada de la partición del sistema,
porque en un disco de 32 GB no entraría junto al sistema instalado.

## Esquema del disco al salir del creador
- Igual que siempre (GPT: datos, BIOS boot, ESP, sistema de 24 GiB).
- Partición 4: btrfs de solo **16 GiB** con el "Llevix instalador" (Ubuntu 24.04 mínimo).
- Partición 4, desde 16 GiB: encabezado de 1 MiB (`LLEVIX-ISO 1`, tamaño, sha256,
  nombre) y la ISO tal cual (máximo 8 GiB − 1 MiB).

## Instalador (`image/instalador/instalar-iso.sh`, servicio en el primer arranque)
1. Lee el encabezado y verifica la SHA256 de la ISO (loop devices de solo lectura).
2. Detecta el sistema de la ISO: capas de Ubuntu 24.04+ (`install-sources.yaml`) o
   `casper/filesystem.squashfs` (Mint, sabores, Zorin, elementary…). Otra cosa → mensaje claro.
3. Secure Boot: el disco arranca con shim/GRUB de Ubuntu, así que el kernel de la ISO
   debe estar firmado por Canonical; si no y Secure Boot está activo, se detiene y explica.
4. Copia el sistema (overlay de capas → rsync) a `@nuevo`, quita los paquetes del modo
   en vivo, pone el kernel de la ISO, genera el initramfs y agrega la capa de Llevix
   (servicios, primer arranque, `jq` estático, reporte).
5. `@` → `@llevix-instalador`, `@nuevo` → `@`; menú de GRUB del sistema nuevo; btrfs
   crece sobre la zona de la ISO; LLEVIX-DATOS se amplía; reinicia.
6. Si algo falla, deshace el cambio de subvolúmenes, explica el motivo en pantalla y en
   `LLEVIX-ERROR.txt`.
7. El primer arranque del sistema nuevo crea la cuenta (llevix-config.json) y borra
   `@llevix-instalador`.

## Creador (segunda parte de la fase)
Opción "Usar mi propia ISO": elegir archivo, comprobarlo (ISO 9660 con `casper/`),
tamaño máximo, escribir la imagen del instalador, el encabezado y la ISO en la zona
reservada, y el config en la ESP.

## Pruebas
`tests/iso-propia-test.sh` + workflow `iso-propia`: con Mint 22.3 Xfce, Kubuntu 24.04.5 y
Ubuntu 24.04.5 reales, instalar con UEFI + Secure Boot, comprobar escritorio, cuenta, red,
sonido, navegador y Datos, y volver a arrancar en BIOS.
