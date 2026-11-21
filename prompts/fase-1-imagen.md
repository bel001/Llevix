# Fase 1 — Primera imagen que arranca

**Objetivo:** `llevix-ubuntu-24.04.img` que arranca en QEMU con UEFI (con y sin
Secure Boot) y con BIOS, y llega al escritorio.
**Tiempo aprox.:** 1–2 semanas.

## Prompt

```
Fase 1. Primero escribe el plan en docs/planes/fase-1.md.

Quiero image/build.sh que reciba el nombre de una variante (por ejemplo
ubuntu-24.04) y genere out/llevix-<variante>.img de 32 GB (creada con truncate),
con el esquema de particiones de CLAUDE.md:
- debootstrap de Ubuntu 24.04 (noble) en la partición btrfs (subvolúmenes @ y
  @home, compresión zstd);
- kernel genérico (linux-generic) y linux-firmware;
- el escritorio que define image/distros/<variante>.conf (empieza con
  ubuntu-desktop-minimal);
- GRUB para UEFI con shim-signed y grub-efi-amd64-signed, y GRUB para BIOS
  (i386-pc) en la partición BIOS boot;
- fstab por UUID/LABEL, nunca por /dev/sdX;
- usuario temporal "llevix" sin contraseña SOLO para pruebas (se quitará en la fase 2).
Sin logos ni nombre de Ubuntu como marca del producto (ver CLAUDE.md).

Luego crea tests/qemu-boot-test.sh que arranque la imagen en QEMU en tres modos:
1) UEFI con OVMF y Secure Boot activado, 2) UEFI sin Secure Boot, 3) BIOS
(SeaBIOS). Debe detectar por consola serie que el sistema llegó a
graphical.target y reportar éxito o fallo con el log.

Como build.sh necesita sudo y loop devices, crea .github/workflows/build.yml
que construya la imagen y ejecute las pruebas en GitHub Actions. Guarda la
imagen comprimida con zstd como artefacto del workflow.
Itera con gh run watch / gh run view --log-failed hasta que los tres modos pasen.
```

## Qué haces tú
- Nada obligatorio. Opcional: descargar el artefacto de GitHub Actions,
  descomprimirlo y escribirlo a un USB con Rufus (modo DD) para verlo en una PC real.

## Listo cuando
- [ ] El workflow `build` pasa en GitHub
- [ ] Las 3 pruebas de QEMU (UEFI+SB, UEFI, BIOS) pasan
- [ ] El artefacto `llevix-ubuntu-24.04.img.zst` se puede descargar
