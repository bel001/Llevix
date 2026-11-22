# Plan — Más distros (A) e "ISO propia" (B)

Decisión del dueño (2026-11-22): seguir los caminos A y B para que el usuario pueda
usar la distro que quiera sin complicaciones.

## Base común: "escritorio completo" (ya en marcha)

Antes de sumar distros, cada imagen debe traer lo mismo que su ISO oficial. Ahora:
- Mint se instala con la lista de paquetes de su ISO oficial
  (`tools/manifiesto-iso.sh` + workflow `manifiestos`, guardada en `image/distros/paquetes/`).
- `build.sh` falla si falta red, WiFi, icono de red, sonido, navegador, terminal o
  administrador de archivos.
- En QEMU se comprueba que la red conecta, que hay sonido para la sesión, que Firefox
  funciona y que `apt-get update` no da errores (lo que vería el Gestor de actualizaciones).

## A — Catálogo más grande (imágenes construidas y probadas por Llevix)

Cada distro nueva es un archivo en `image/distros/` y pasa las mismas pruebas.

| Orden | Distro | Cómo se construye | Dificultad |
| --- | --- | --- | --- |
| 1 | Zorin OS 17 Core, Pop!_OS 22.04, elementary OS 8 | Base Ubuntu + su repositorio + lista de su ISO (como Mint) | Baja |
| 2 | Debian 13 (GNOME, KDE, Xfce) | `debootstrap trixie` + `shim-signed` de Debian; `BASE=debian` | Media |
| 3 | Fedora Workstation / KDE | `dnf --installroot` en un contenedor Fedora; GRUB y shim de Fedora; SELinux | Alta |

Arch y derivados (Manjaro, EndeavourOS) quedan fuera de la v1: no tienen shim firmado
por defecto y su modelo de actualización rompe más seguido.

## B — "Trae tu ISO" (familia Ubuntu/Debian)

El usuario elige en el creador un archivo `.iso` que descargó. Llevix la **instala de
verdad** en el disco (no la arranca "en vivo"), con su capa de portabilidad.

### Qué ISO se aceptan
- Con `casper/` (Ubuntu y sabores, Mint, Zorin, Pop!_OS, elementary, KDE neon, Linux Lite…):
  `filesystem.squashfs` o capas (`minimal.standard.squashfs`) y `filesystem.manifest-remove`.
- Debian live (`live/filesystem.squashfs`).
- Cualquier otra: el creador explica que no es compatible y sugiere el catálogo.

### Flujo
1. **Creador (Windows):** lee la ISO sin montarla (lector ISO 9660 en Rust) y comprueba
   que es compatible. Escribe la imagen **"Llevix instalador"** (sistema Debian mínimo,
   ~1 GB, con shim/GRUB firmados) con el esquema de particiones de siempre, y copia la ISO
   a `LLEVIX-DATOS\llevix-iso\` usando la letra que Windows le da a esa partición.
2. **Primer arranque (Linux, en el disco):** `llevix-instalar-iso`:
   - verifica la ISO y descomprime su squashfs en el subvolumen `@`;
   - quita los paquetes del modo en vivo (`manifest-remove`) con `dpkg` sin internet;
   - instala GRUB/shim **de la propia distro** (firmados) para UEFI y BIOS;
   - agrega la capa de Llevix (primer arranque, portabilidad, cuidado del disco);
   - borra la ISO, amplía LLEVIX-DATOS y reinicia en la distro instalada;
   - el primer arranque normal crea la cuenta con `llevix-config.json`.
   Si algo falla, el instalador muestra el motivo y el disco queda en "Llevix instalador".
3. Esto respeta la regla "Llevix no instala Linux desde Windows": la instalación ocurre
   en Linux, en el propio disco.

### Pruebas (CI)
Descargar ISOs reales (Kubuntu, Mint, Zorin, Debian live), simular el creador con un
archivo de imagen, arrancar en QEMU (UEFI+SB y BIOS) y comprobar escritorio, red, sonido,
navegador, cuenta y persistencia.

### Riesgos
- Distros con shim propio no firmado por Microsoft → no arrancan con Secure Boot. El
  instalador lo detecta antes y lo avisa (nunca pedir desactivar Secure Boot).
- ISOs modificadas o de terceros: se instala lo que el usuario eligió; Llevix no puede
  garantizarlas. El creador lo dice claramente.

## Orden de trabajo
1. Terminar "escritorio completo" (rama `beta-escritorio-completo`) y publicar prueba.
2. Fase 8 — B ("Trae tu ISO"): imagen "Llevix instalador", lector ISO en el creador,
   `llevix-instalar-iso`, pruebas con 3 ISOs reales.
3. Fase 9 — A: Zorin/Pop!_OS/elementary, luego Debian, luego Fedora.
