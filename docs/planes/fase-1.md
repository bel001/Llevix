# Plan — Fase 1: primera imagen que arranca

## Objetivo
`out/llevix-ubuntu-24.04.img` arranca en QEMU con UEFI + Secure Boot, UEFI sin
Secure Boot y BIOS antiguo, y llega al escritorio (graphical.target con el gestor
de sesión activo). Todo se construye y prueba en GitHub Actions.

## Archivos
- `image/build.sh <variante>`: construye la imagen.
- `image/distros/ubuntu-24.04.conf`: qué escritorio y qué base usa la variante.
- `image/overlay/`: archivos que se copian tal cual al sistema (servicio de estado).
- `tests/qemu-boot-test.sh <imagen> [modos]`: prueba de arranque.
- `.github/workflows/build.yml`: construye, prueba y guarda la imagen como artefacto.

## Pasos de build.sh
1. Comprobar root, variante válida y herramientas. Solo se trabaja con un archivo
   `.img` y un loop device (nunca discos reales; se verifica que el dispositivo sea
   `/dev/loopN`).
2. `truncate` del archivo y particiones GPT con `sgdisk`:
   - p2 BIOS boot 1 MiB (al inicio), p3 ESP FAT32 512 MiB, p4 sistema btrfs 24 GiB,
   - p1 LLEVIX-DATOS exFAT con el resto, físicamente al final (número 1 en la tabla).
3. btrfs con subvolúmenes `@` y `@home`, montados con `compress=zstd:3,noatime`.
4. `debootstrap noble`, luego en chroot: kernel `linux-generic`, `linux-firmware`,
   shim y GRUB firmados (UEFI) y `grub-pc-bin` (BIOS), y el escritorio de la variante.
5. GRUB UEFI en modo "removable" (`EFI/BOOT/BOOTX64.EFI` = shim), sin tocar la NVRAM
   de nadie; GRUB BIOS en la partición BIOS boot. `os-prober` desactivado.
6. `fstab` por UUID; hostname `llevix`; `machine-id` vacío (se genera al arrancar).
7. Usuario temporal `llevix` sin contraseña con inicio automático (solo fase 1).
8. Marca: GRUB y `PRETTY_NAME` dicen "Llevix (basado en Ubuntu 24.04 LTS)"; se quita
   el logo de Ubuntu de la pantalla de arranque (plymouth).
9. `fstrim` para que el archivo quede disperso (solo ocupa lo que tiene datos).

## Cómo sabe la prueba que arrancó
Un servicio pequeño (`llevix-estado-arranque`) se ejecuta después de
`graphical.target` y escribe en el puerto serie: el modo de arranque (bios, uefi,
uefi-sb), si el gestor de sesión está activo y las unidades que fallaron.
La prueba lee el puerto serie, comprueba que el modo coincide con el esperado
(así se confirma que Secure Boot estaba de verdad activo) y guarda una captura de
pantalla. El disco se conecta a QEMU como memoria USB (xHCI + usb-storage) y se usa
una capa qcow2 encima para no modificar la imagen.

## Decisiones
- Tamaño de imagen: 28 GiB y no 32 GB. Una memoria de "32 GB" tiene en la práctica
  entre 28,6 y 29,8 GiB; una imagen de 32 GiB no cabría. El primer arranque (fase 2)
  amplía la partición de datos al tamaño real del disco.
- Etiqueta del sistema de archivos de datos: `LLEVIX` (exFAT admite 11 caracteres;
  `LLEVIX-DATOS` tiene 12). El nombre de la partición GPT sí es `LLEVIX-DATOS`.
- Firefox y Thunderbird de Ubuntu 24.04 son snaps; instalarlos dentro de un chroot no
  funciona. En esta fase se excluyen; en la fase 3 se agregan como snaps "sembrados"
  (seed) que se instalan solos en el primer arranque.
