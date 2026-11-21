# Bitácora de Llevix

Lo más reciente arriba. Cada fase anota qué se hizo, qué se decidió y qué quedó pendiente.

## Fase 1 — Primera imagen que arranca (2026-11-21)

**Qué se hizo**
- `image/build.sh <variante>`: imagen GPT de 28 GiB (dispersa) con BIOS boot, ESP,
  sistema btrfs (`@`, `@home`, zstd) y LLEVIX-DATOS (exFAT, número 1, al final).
  debootstrap de noble, `linux-generic`, `linux-firmware`, shim + GRUB firmados
  (modo removable, sin tocar NVRAM) y GRUB BIOS. Escritorio `ubuntu-desktop-minimal`.
- `image/overlay/`: servicio `llevix-estado-arranque` que informa por puerto serie el
  modo de arranque (bios/uefi/uefi-sb) y si el gestor de sesión está activo.
- `tests/qemu-boot-test.sh`: arranca la imagen como memoria USB (xHCI) en los tres
  modos y comprueba el informe; guarda capturas de pantalla.
- `.github/workflows/build.yml`: construye, prueba y sube `llevix-ubuntu-24.04.img.zst`
  (3,6 GB) como artefacto. Resultado: UEFI+SB 2 min, UEFI 65 s, BIOS 35 s (con KVM).

**Decisiones**
- Imagen de 28 GiB en lugar de 32 GB: una memoria "de 32 GB" real tiene 28,6–29,8 GiB.
- Etiqueta exFAT `LLEVIX` (máximo 11 caracteres); la partición GPT se llama `LLEVIX-DATOS`.
- GRUB firmado de Ubuntu busca grub.cfg en EFI/ubuntu, junto a sí mismo o en
  /boot/grub de la ESP: se deja un grub.cfg "puente" en los tres lugares.
- Firefox y Thunderbird (snaps) excluidos por ahora; se agregarán como snaps sembrados.
- Marca: GRUB y PRETTY_NAME dicen "Llevix, basado en Ubuntu 24.04 LTS"; logo de
  plymouth reemplazado. El escritorio (logos de GNOME/Ubuntu en apps) queda como lo
  trae la distro, según la regla "Llevix NO cambia el escritorio".

**Problemas encontrados**
- KVM quedaba solo para root tras instalar paquetes en el chroot: se activa después.
- El informe del puerto serie llegaba pegado a códigos de pantalla del firmware.

**Pendiente**
- Todas las imágenes comparten UUID de btrfs/ESP: dos USB de Llevix conectados a la
  vez podrían confundirse. Evaluar regenerar UUIDs en el creador o en el primer arranque.
- Probar con firmware que tenga solo el certificado 2011, solo el 2023 y ambos (Secure Boot).
- La captura en modo BIOS sale negra aunque el escritorio esté activo (revisar en fase 3).

## Fase 0 — Arranque del proyecto (2026-11-21)

**Qué se hizo**
- Estructura de carpetas, README.md, CONTRIBUTING.md, .gitignore y .gitattributes.
- `tools/check-env.sh`: revisa el entorno en Windows (creador), WSL/Linux (imágenes y
  pruebas) y lo común (git, gh, Node.js). Dentro de WSL ignora los programas de Windows
  que WSL comparte en el PATH (antes daba `npm` por instalado cuando no lo estaba).
- `.github/workflows/lint.yml`: shellcheck en todos los `.sh`.

**Decisiones**
- `.gitattributes` fuerza LF en todo el repositorio (se trabaja desde Windows).
- shellcheck local se ejecuta con Docker (`koalaman/shellcheck`) porque no está instalado.

**Pendiente**
- `check-env.sh` todavía marca faltantes en la PC del dueño (Rust en Windows; paquetes
  de imagen y Node.js en WSL). Instalarlos necesita la contraseña de sudo: ver PENDIENTES.md.
  No bloquea el avance porque la construcción y las pruebas corren en GitHub Actions.
- La WSL del dueño tiene Ubuntu 26.04, no 24.04 (la base de Llevix). Para desarrollar
  sirve igual.
